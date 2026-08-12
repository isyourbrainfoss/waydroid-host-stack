#!/bin/sh
# Capture host-side journals for Phosh/phoc freezes during Waydroid setup.
# Designed to run as the Phosh user with passwordless sudo for journalctl -f.
#
# Usage:
#   phosh-freeze-capture start   # begin logging to ~/phosh-freeze-logs/session-*/
#   phosh-freeze-capture stop
#   phosh-freeze-capture status
#   phosh-freeze-capture toggle
set -eu

SESSIONS_ROOT="${PHOSH_FREEZE_LOG_ROOT:-$HOME/phosh-freeze-logs}"
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/phosh-freeze-capture"
PIDFILE="$STATE_DIR/pids"
ACTIVE="$STATE_DIR/active-dir"

mkdir -p "$STATE_DIR" "$SESSIONS_ROOT"

notify() {
	title="$1"
	body="$2"
	if command -v notify-send >/dev/null 2>&1; then
		notify-send -a "Phosh Freeze Log" -i utilities-system-monitor "$title" "$body" 2>/dev/null || true
	fi
	logger -t phosh-freeze-capture "$title: $body" 2>/dev/null || true
}

is_running() {
	[ -f "$PIDFILE" ] || return 1
	while read -r pid; do
		[ -n "$pid" ] || continue
		if kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
	done <"$PIDFILE"
	return 1
}

stop_session() {
	dir=""
	[ -f "$ACTIVE" ] && dir=$(cat "$ACTIVE" 2>/dev/null || true)
	if [ -f "$PIDFILE" ]; then
		while read -r pid; do
			[ -n "$pid" ] || continue
			kill "$pid" 2>/dev/null || true
			kill -- -"$pid" 2>/dev/null || true
		done <"$PIDFILE"
		rm -f "$PIDFILE"
	fi
	if [ -n "$dir" ] && [ -d "$dir" ]; then
		{
			echo "stopped: $(date -Is)"
			uptime
			free -m
			waydroid status 2>/dev/null || true
			df -h /run / /tmp 2>/dev/null || true
			df -i /run 2>/dev/null || true
			mount | grep -E 'waydroid|lxc' | head -40 || true
		} >"$dir/session-end.txt" 2>/dev/null || true
		# Snapshot tails (survive even if follow was cut by freeze)
		journalctl -b --no-pager -n 800 >"$dir/journal-boot-tail.txt" 2>/dev/null || true
		journalctl -b -k --no-pager -n 300 >"$dir/kernel-boot-tail.txt" 2>/dev/null || true
		journalctl -b -u waydroid-container -u waydroid-container.service \
			-u waydroid-bt-host -u waydroid-bt-inject -u waydroid-bt-inject.timer \
			--no-pager -n 400 >"$dir/waydroid-units-tail.txt" 2>/dev/null || true
		journalctl -b --user -u phosh -u phoc --no-pager -n 200 \
			>"$dir/phosh-user-units-tail.txt" 2>/dev/null || true
		# Best-effort process snapshot
		ps aux 2>/dev/null | head -5 >"$dir/ps-head.txt" || true
		ps aux --sort=-%cpu 2>/dev/null | head -40 >"$dir/ps-top-cpu.txt" || true
		ps aux --sort=-%mem 2>/dev/null | head -40 >"$dir/ps-top-mem.txt" || true
		echo "stopped $(date -Is)" >"$dir/STOPPED"
		sz=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
		notify "Freeze logging stopped" "Saved: $dir ($sz)"
		echo "Stopped. Logs in: $dir"
	else
		notify "Freeze logging stopped" "No active session dir"
		echo "Stopped (no active session dir)."
	fi
	rm -f "$ACTIVE"
}

start_session() {
	if is_running; then
		notify "Freeze logging already on" "Tap again to stop, or: $0 stop"
		echo "Already running. Use: $0 stop"
		exit 0
	fi

	ts=$(date +%Y%m%d-%H%M%S)
	dir="$SESSIONS_ROOT/session-$ts"
	mkdir -p "$dir"
	echo "$dir" >"$ACTIVE"
	: >"$PIDFILE"

	{
		echo "started: $(date -Is)"
		echo "user: $(id)"
		uname -a
		cat /etc/os-release 2>/dev/null || true
		echo "--- free ---"
		free -m
		echo "--- df ---"
		df -h / /run /tmp 2>/dev/null || true
		df -i /run 2>/dev/null || true
		echo "--- waydroid status ---"
		waydroid status 2>/dev/null || true
		echo "--- environment.d ---"
		ls -la "$HOME/.config/environment.d" 2>/dev/null || true
		cat "$HOME/.config/environment.d"/* 2>/dev/null || true
		echo "--- inject unit ---"
		systemctl is-active waydroid-bt-inject.timer waydroid-bt-inject.service 2>/dev/null || true
		systemctl cat waydroid-bt-inject.timer 2>/dev/null || true
		echo "--- phosh pids ---"
		ps aux 2>/dev/null | grep -iE 'phosh|phoc|waydroid|lxc' | grep -v grep || true
	} >"$dir/session-start.txt" 2>&1 || true

	# Use setsid so loggers outlive this shell / SSH. Prefer plain journalctl
	# (no sudo pipes) so freezes still leave files on disk.

	# Kernel follow (user can read recent boots)
	setsid journalctl -k -f -o short-iso --no-pager \
		>"$dir/kernel.follow.log" 2>>"$dir/kernel.follow.err" </dev/null &
	echo $! >>"$PIDFILE"

	# System units: waydroid + inject + bluetooth
	setsid journalctl -f -o short-iso --no-pager \
		-u waydroid-container -u waydroid-container.service \
		-u waydroid-bt-host -u waydroid-bt-inject -u waydroid-bt-inject.timer \
		-u bluetooth -u greetd \
		>"$dir/system-units.follow.log" 2>>"$dir/system-units.follow.err" </dev/null &
	echo $! >>"$PIDFILE"

	# Full system journal follow (large) — best signal for phosh/phoc
	if command -v sudo >/dev/null && sudo -n true >/dev/null 2>&1; then
		setsid sudo -n journalctl -f -o short-iso --no-pager \
			>"$dir/journal-full.follow.log" 2>>"$dir/journal-full.err.log" </dev/null &
		echo $! >>"$PIDFILE"
	else
		setsid journalctl --user -f -o short-iso --no-pager \
			>"$dir/journal-user.follow.log" 2>>"$dir/journal-user.err.log" </dev/null &
		echo $! >>"$PIDFILE"
	fi

	# Sample load/mem every 5s (survives better than pure journal under freeze)
	setsid sh -c "
		while true; do
			{
				date -Is
				cat /proc/loadavg
				free -m | awk 'NR==2'
				ps -eo pid,pcpu,pmem,comm --sort=-pcpu 2>/dev/null | head -12
				echo ---
			} >>'$dir/load-sample.txt' 2>/dev/null || true
			sleep 5
		done
	" </dev/null >/dev/null 2>&1 &
	echo $! >>"$PIDFILE"

	notify "Freeze logging STARTED" "$dir\nNow start Waydroid from the app drawer.\nIf Phosh freezes: hard reboot, then run: $0 stop (or pull ~/phosh-freeze-logs/)"
	echo "Started logging → $dir"
	echo "1) Start Waydroid from Phosh app drawer (do not use Tesla yet)."
	echo "2) If freeze: hard reboot."
	echo "3) After reboot: $0 stop   # finalizes last session if still marked active"
	echo "   or inspect: ls -lt $SESSIONS_ROOT/"
}

cmd="${1:-toggle}"
case "$cmd" in
	start) start_session ;;
	stop) stop_session ;;
	status)
		if is_running; then
			echo "RUNNING"
			[ -f "$ACTIVE" ] && echo "dir=$(cat "$ACTIVE")"
			cat "$PIDFILE" 2>/dev/null || true
		else
			echo "STOPPED"
			ls -lt "$SESSIONS_ROOT" 2>/dev/null | head -8 || true
		fi
		;;
	toggle)
		if is_running; then
			stop_session
		else
			start_session
		fi
		;;
	*)
		echo "usage: $0 {toggle|start|stop|status}" >&2
		exit 2
		;;
esac
