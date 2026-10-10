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
