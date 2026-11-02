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

# whs_device_candidates -> every detected name, most specific source first.
# Image-based distros set IMAGE_ID to the distro image (e.g. BengalOS), not
# the device, so the device tree must still be consulted after it.
whs_device_candidates() {
	whs_detect_device
	if [ -r /etc/deviceinfo ]; then
		sed -n 's/^deviceinfo_codename="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/deviceinfo | head -n1
	fi
	if [ -r /proc/device-tree/compatible ]; then
		first=$(tr '\0' '\n' </proc/device-tree/compatible | head -n1)
		case "$first" in
		*,*) echo "$(echo "$first" | cut -d, -f1)-$(echo "$first" | cut -d, -f2)" ;;
		esac
	fi
}

# whs_load_device ROOT  -> sources ROOT/devices/<first candidate with a
# config>.conf (or generic). $WHS_DEVICE, when set, is the only candidate.
whs_load_device() {
	_root="$1"
	_conf=""
	if [ -n "${WHS_DEVICE:-}" ]; then
		_cands=$WHS_DEVICE
	else
		_cands=$(whs_device_candidates)
	fi
	for _c in $_cands; do
		if [ -f "$_root/devices/$_c.conf" ]; then
			WHS_DEVICE=$_c
			_conf="$_root/devices/$_c.conf"
			break
		fi
	done
	if [ -z "$_conf" ]; then
		echo "device: no config for '$(echo "$_cands" | tr '\n' ' ')', using generic" >&2
		WHS_DEVICE=generic
		_conf="$_root/devices/generic.conf"
	fi
	# shellcheck disable=SC1090
	. "$_conf"
	WHS_DEVICE_CONF="$_conf"
	export WHS_DEVICE WHS_DEVICE_CONF
}
