#!/bin/sh
# Route the USB 2.0 data lines to the SoC, and bring the USB gadget up even
# when the controller shows up late.
#
# On the Tab S7 family D+/D- go through the switch of the MAX77705 MUIC, and
# the bootloader leaves it open on a normal boot: the gadget is configured but
# the host never sees a device. Mainline has no MUIC driver, so do what the
# vendor driver does on attach (com_to_usb_ap): opcode COMMAND_CONTROL1_WRITE
# (0x06) with COM_USB (0x09) written to OPCODE_WRITE (0x21), then
# OPCODE_WRITE_END (0x41) = 0. The MUIC answers at 0x25 on the bus of the
# MAX77705 (i2c@980000). Charger registers are not touched.
#
# The initramfs sets the gadget up once, before the hooks, and gives up if no
# UDC exists at that moment. The i2c bus and dwc3 may probe later (deferred
# probes), so this hook polls for both for up to 30 seconds, then binds the
# gadget and starts the DHCP server itself if the initramfs could not. It runs
# before the debug shell, which then finds a bound gadget, as on a device
# whose UDC was there from the start.

sysfs="${MUIC_SYSFS:-/sys}"				# the MUIC_* variables are for the test only
functions="${MUIC_INIT_FUNCTIONS:-/init_functions.sh}"
tries="${MUIC_WAIT:-30}"				# polls, one per $poll seconds
poll="${MUIC_POLL:-1}"

log() {
	echo "gts7xl-usb-muic: $*"
	{ echo "gts7xl-usb-muic: $*" > /dev/kmsg; } 2>/dev/null
}

# Prints the bus number of i2c@980000, nothing if the adapter is not there yet.
muic_bus() {
	for adapter in "$sysfs"/devices/platform/soc@0/*.geniqup/980000.i2c/i2c-*; do
		[ -e "$adapter" ] || continue
		echo "${adapter##*/i2c-}"
		return
	done
}

switch_to_soc() {
	if i2ctransfer -f -y "$1" w3@0x25 0x21 0x06 0x09 &&
	   i2ctransfer -f -y "$1" w2@0x25 0x41 0x00; then
		log "USB data lines switched to the SoC (i2c-$1, after ${n}s)"
	else
		log "write to the MUIC failed (i2c-$1)"
	fi
}

have_udc() {
	[ -n "$(ls "$sysfs"/class/udc 2>/dev/null)" ]
}

# Bind the gadget and start DHCP unless the initramfs already did.
gadget_up() {
	# shellcheck disable=SC1090
	. "$functions"
	if [ -n "$(cat "$CONFIGFS"/g1/UDC 2>/dev/null)" ]; then
		log "UDC present (after ${n}s), gadget already bound by the initramfs"
	else
		if [ -e "$CONFIGFS"/g1 ]; then
			setup_usb_configfs_udc
		else
			setup_usb_network_configfs
		fi
		bound="$(cat "$CONFIGFS"/g1/UDC 2>/dev/null)"
		log "UDC present (after ${n}s), gadget bound to: ${bound:-NOTHING (gadget setup failed)}"
	fi
	start_unudhcpd
}

muic=n udc=n n=0
while :; do
	if [ "$muic" = n ]; then
		bus="$(muic_bus)"
		if [ -n "$bus" ]; then
			muic=y
			switch_to_soc "$bus"
		fi
	fi
	if [ "$udc" = n ] && have_udc; then
		udc=y
		gadget_up
	fi
	[ "$muic$udc" = yy ] && break
	[ "$n" -ge "$tries" ] && break
	[ "$n" = 0 ] && log "waiting up to ${tries}s for i2c@980000 (found: $muic) and the UDC (found: $udc)"
	sleep "$poll"
	n=$((n + 1))
done

[ "$muic" = y ] || log "i2c@980000 adapter not found after ${tries}s, USB stays disconnected"
[ "$udc" = y ] || log "no UDC after ${tries}s, no USB gadget"
exit 0
