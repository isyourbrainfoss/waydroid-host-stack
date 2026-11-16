# shellcheck shell=sh
# Install-path resolution shared by the installers (sourced, not executed).
#
# Override any of these from the environment:
#   PREFIX       root of installed binaries/scripts
#   BINDIR       daemons + CLI tools            (default: $PREFIX/bin)
#   SBINDIR      root-only helper scripts        (default: $PREFIX/sbin)
#   LIBEXECDIR   staged helpers (guest probe)    (default: $PREFIX/libexec)
#   UNITDIR      system unit directory
#   SYSCONFDIR   config fragments                (default: /etc/waydroid-bt)
#
# Defaults:
#   * image-based / immutable hosts (read-only /usr, e.g. Nura "Duranium",
#     systemd-sysext images):  PREFIX=/var/lib/waydroid-host-stack,
#                              UNITDIR=/etc/systemd/system
#   * classic mutable hosts:   PREFIX=/usr/local,
#                              UNITDIR=/etc/systemd/system
#   (/usr/lib/systemd/system is only used by distro packages / sysext images.)
#
# Note: on Duranium /etc is an overlay mounted noexec, so never put
# executables under SYSCONFDIR.

whs_usr_is_readonly() {
	# FORCE_IMMUTABLE=1|0 wins over detection.
	case "${FORCE_IMMUTABLE:-}" in
	1) return 0 ;;
	0) return 1 ;;
	esac
	if command -v findmnt >/dev/null 2>&1; then
		opts=$(findmnt -no OPTIONS -T /usr/local 2>/dev/null | head -n1)
		case ",$opts," in
		*,ro,*) return 0 ;;
		esac
	fi
	# Fallback: probe writability as root.
	if [ "$(id -u)" -eq 0 ]; then
		probe="/usr/local/.whs-probe.$$"
		if ( : >"$probe" ) 2>/dev/null; then
			rm -f "$probe"
			return 1
		fi
		return 0
	fi
	[ -w /usr/local ] && return 1
	return 0
}

whs_resolve_paths() {
	if whs_usr_is_readonly; then
		WHS_IMMUTABLE=1
		: "${PREFIX:=/var/lib/waydroid-host-stack}"
	else
		WHS_IMMUTABLE=0
		: "${PREFIX:=/usr/local}"
	fi
	: "${BINDIR:=$PREFIX/bin}"
	: "${SBINDIR:=$PREFIX/sbin}"
	: "${LIBEXECDIR:=$PREFIX/libexec}"
	: "${UNITDIR:=/etc/systemd/system}"
	: "${SYSCONFDIR:=/etc/waydroid-bt}"
	: "${WAYDROID_LXC_DIR:=/var/lib/waydroid/lxc/waydroid}"
	export PREFIX BINDIR SBINDIR LIBEXECDIR UNITDIR SYSCONFDIR WAYDROID_LXC_DIR WHS_IMMUTABLE
}

whs_print_paths() {
	echo "immutable=$WHS_IMMUTABLE"
	echo "PREFIX=$PREFIX"
	echo "BINDIR=$BINDIR"
	echo "SBINDIR=$SBINDIR"
	echo "LIBEXECDIR=$LIBEXECDIR"
	echo "UNITDIR=$UNITDIR"
	echo "SYSCONFDIR=$SYSCONFDIR"
}

# Locate an installed helper: $SBINDIR, then known legacy locations.
whs_find_helper() {
	name="$1"
	for d in "${SBINDIR:-}" "${BINDIR:-}" /var/lib/waydroid-host-stack/sbin \
		/var/lib/waydroid-host-stack/bin /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin; do
		[ -n "$d" ] || continue
		for cand in "$d/$name" "$d/$name.sh"; do
			if [ -x "$cand" ]; then
				echo "$cand"
				return 0
			fi
		done
	done
	return 1
}

# _whs_uid_ok UID -> 0 for a real (non-root, numeric) login uid.
_whs_uid_ok() {
	case "$1" in '' | 0 | *[!0-9]*) return 1 ;; esac
	return 0
}

# whs_waydroid_uid -> uid of the user who runs the Waydroid session.
# Order: waydroid.host.uid in waydroid.prop, $WAYDROID_UID, SUDO_UID/DOAS_USER,
# owner of a running `waydroid session`, owner of the active logind
# (graphical) session, the only /run/user/<uid> present, then 1000.
whs_waydroid_uid() {
	prop="${WAYDROID_PROP:-/var/lib/waydroid/waydroid.prop}"
	uid=$(sed -n 's/^waydroid.host.uid=//p' "$prop" 2>/dev/null | head -n1 | tr -d '[:space:]')
	_whs_uid_ok "$uid" && { echo "$uid"; return 0; }
	uid="${WAYDROID_UID:-}"
	_whs_uid_ok "$uid" && { echo "$uid"; return 0; }
	uid="${SUDO_UID:-}"
	_whs_uid_ok "$uid" && { echo "$uid"; return 0; }
	if [ -n "${DOAS_USER:-}" ]; then
		uid=$(id -u "$DOAS_USER" 2>/dev/null || true)
		_whs_uid_ok "$uid" && { echo "$uid"; return 0; }
	fi
	# Running session: the `waydroid session start` (or -w) process belongs
	# to the session user.
	if command -v pgrep >/dev/null 2>&1; then
		for pid in $(pgrep -f 'waydroid.* session start' 2>/dev/null || true); do
			uid=$(awk '/^Uid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
			_whs_uid_ok "$uid" && { echo "$uid"; return 0; }
		done
	fi
	# logind: owner of the active session (prefer wayland/x11 on a seat).
	if command -v loginctl >/dev/null 2>&1; then
		best=""
		for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
			info=$(loginctl show-session "$sid" -p User -p Type -p Active -p Class 2>/dev/null || true)
			u=$(printf '%s\n' "$info" | sed -n 's/^User=//p')
			_whs_uid_ok "$u" || continue
			printf '%s\n' "$info" | grep -q '^Class=user$' || continue
			if printf '%s\n' "$info" | grep -q '^Active=yes$' &&
				printf '%s\n' "$info" | grep -qE '^Type=(wayland|x11)$'; then
				echo "$u"
				return 0
			fi
			[ -n "$best" ] || best=$u
		done
		_whs_uid_ok "$best" && { echo "$best"; return 0; }
	fi
	# Exactly one user runtime dir (single-user phone).
	n=0
	for d in /run/user/[0-9]*; do
		[ -d "$d" ] || continue
		u=${d##*/}
		_whs_uid_ok "$u" || continue
		n=$((n + 1))
		uid=$u
	done
	[ "$n" -eq 1 ] && { echo "$uid"; return 0; }
	echo "WARN: could not determine the Waydroid user; assuming uid 1000 (set WAYDROID_UID)" >&2
	echo 1000
}
