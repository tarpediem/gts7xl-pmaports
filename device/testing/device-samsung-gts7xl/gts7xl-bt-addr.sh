#!/bin/sh
# Give hci0 a stable Bluetooth address. The QCA6390 controller has none (stock
# Android keeps it in EFS, which Linux never reads), so hci0 comes up
# unconfigured. The address is derived from /etc/machine-id (non-secret,
# generated on the first boot of the install): sha256 of a fixed prefix plus
# the machine id, first 6 bytes, with the first octet made locally
# administered and unicast. Same install, same address: pairings survive
# reboots. Runs before bluetoothd (bluetooth.service drop-in).

machine_id="${GTS7XL_MACHINE_ID:-/etc/machine-id}"
sysfs="${GTS7XL_SYSFS:-/sys}"
wait_s="${GTS7XL_WAIT:-30}"
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

n=0
while [ ! -e "$sysfs/class/bluetooth/hci0" ]; do
	[ "$n" -ge "$wait_s" ] && { log "no hci0 after ${wait_s}s"; exit 0; }
	sleep "$poll"
	n=$((n + 1))
done

if btmgmt --index 0 info 2>/dev/null | grep -qi "addr $addr"; then
	log "hci0 already has $addr"
	exit 0
fi
if btmgmt --index 0 public-addr "$addr"; then
	log "hci0 address set to $addr"
else
	log "btmgmt public-addr $addr failed"
fi
exit 0
