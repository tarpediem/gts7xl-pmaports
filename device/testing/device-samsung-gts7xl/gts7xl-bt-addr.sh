#!/bin/sh
# Give hci0 a stable Bluetooth address. The QCA6390 controller has none (stock
# Android keeps it in EFS, which Linux never reads), so hci0 comes up
# unconfigured. The address is derived from /etc/machine-id (non-secret,
# generated on the first boot of the install): sha256 of a fixed prefix plus
# the machine id, first 6 bytes, with the first octet made locally
# administered and unicast. Same install, same address: pairings survive
# reboots. Runs before bluetoothd (bluetooth.service drop-in).
#
# hci0 shows up in sysfs before the controller is usable: hci_qca downloads its
# patch and NVM first (about 1.5 s on this tablet), and until that setup ends
# the mgmt interface has no index 0 and public-addr fails with "Invalid Index".
# So wait for mgmt to report index 0, either unconfigured with the public
# address missing (set it) or configured (already set: done), polling until
# GTS7XL_WAIT seconds have passed. Never fails the boot.

machine_id="${GTS7XL_MACHINE_ID:-/etc/machine-id}"
sysfs="${GTS7XL_SYSFS:-/sys}"
wait_s="${GTS7XL_WAIT:-60}"
poll="${GTS7XL_POLL:-1}"

log() { echo "gts7xl-bt-addr: $*"; }

# Print the address for machine id $1.
bt_addr() {
	h=$(printf 'gts7xl-bt-addr:%s' "$1" | sha256sum | cut -c1-12)
	first=$(( (0x$(echo "$h" | cut -c1-2) & 0xfc) | 0x02 ))
	printf '%02X' "$first"
	echo "$h" | cut -c3-12 | sed 's/../:&/g' | tr 'a-f' 'A-F'
}

id=$(cat "$machine_id" 2>/dev/null)
case "$id" in
	"" | uninitialized) log "no machine id in $machine_id, leaving hci0 alone"; exit 0 ;;
esac
addr=$(bt_addr "$id")

# Whole seconds of uptime: monotonic, unlike the wall clock, which jumps at
# boot here (no RTC; time sync can move it by months).
now() { cut -d. -f1 /proc/uptime; }

start=$(now)
elapsed() { echo $(( $(now) - start )); }

while [ ! -e "$sysfs/class/bluetooth/hci0" ]; do
	[ "$(elapsed)" -ge "$wait_s" ] && { log "no hci0 after ${wait_s}s"; exit 0; }
	sleep "$poll"
done

while :; do
	# Configured: index 0 is listed by "info" with its address.
	info=$(btmgmt --index 0 info 2>/dev/null)
	case "$info" in
	*"addr $addr"*) log "hci0 already has $addr"; exit 0 ;;
	*"addr "*)
		# Configured with another address: set ours once.
		if btmgmt --index 0 public-addr "$addr" >/dev/null 2>&1; then
			log "hci0 address changed to $addr"
		else
			log "btmgmt public-addr $addr failed on a configured hci0"
		fi
		exit 0 ;;
	esac
	# Unconfigured, setup done: the public address is a missing option.
	cfg=$(btmgmt --index 0 config 2>/dev/null)
	case "$cfg" in
	*"missing options:"*public-address*)
		if btmgmt --index 0 public-addr "$addr" >/dev/null 2>&1; then
			log "hci0 address set to $addr after $(elapsed)s"
			exit 0
		fi
		log "btmgmt public-addr $addr failed, retrying" ;;
	esac
	if [ "$(elapsed)" -ge "$wait_s" ]; then
		log "hci0 not ready for an address after ${wait_s}s, leaving it unconfigured"
		exit 0
	fi
	sleep "$poll"
done
