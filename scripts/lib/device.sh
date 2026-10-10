# shellcheck shell=sh
# Per-device configuration loader (sourced). Sets WHS_DEVICE and sources
# devices/<codename>.conf from the repo (or $SYSCONFDIR/device.conf).
#
# Detection order: $WHS_DEVICE, os-release IMAGE_ID, pmOS deviceinfo,
# device-tree compatible string.

whs_detect_device() {
	if [ -n "${WHS_DEVICE:-}" ]; then
		echo "$WHS_DEVICE"
		return 0
	fi
	if [ -r /etc/os-release ]; then
		id=$(sed -n 's/^IMAGE_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/os-release | head -n1)
		if [ -n "$id" ]; then
			echo "$id"
			return 0
		fi
	fi
	if [ -r /etc/deviceinfo ]; then
		cn=$(sed -n 's/^deviceinfo_codename="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/deviceinfo | head -n1)
		if [ -n "$cn" ]; then
			echo "$cn"
			return 0
		fi
	fi
	if [ -r /proc/device-tree/compatible ]; then
		first=$(tr '\0' '\n' </proc/device-tree/compatible | head -n1)
		case "$first" in
		*,*) echo "$(echo "$first" | cut -d, -f1)-$(echo "$first" | cut -d, -f2)"; return 0 ;;
		esac
	fi
	echo generic
}

# whs_load_device ROOT  -> sources ROOT/devices/$WHS_DEVICE.conf (or generic)
whs_load_device() {
	_root="$1"
	WHS_DEVICE=$(whs_detect_device)
	_conf="$_root/devices/$WHS_DEVICE.conf"
	if [ ! -f "$_conf" ]; then
		echo "device: no config for '$WHS_DEVICE', using generic" >&2
		_conf="$_root/devices/generic.conf"
	fi
	# shellcheck disable=SC1090
	. "$_conf"
	WHS_DEVICE_CONF="$_conf"
	export WHS_DEVICE WHS_DEVICE_CONF
}
