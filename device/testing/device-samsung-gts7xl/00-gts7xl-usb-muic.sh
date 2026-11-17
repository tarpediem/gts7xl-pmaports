#!/bin/sh
# Route the USB 2.0 data lines to the SoC.
#
# On the Tab S7 family D+/D- go through the switch of the MAX77705 MUIC, and
# the bootloader leaves it open on a normal boot: the gadget is configured but
# the host never sees a device. Mainline has no MUIC driver, so do what the
# vendor driver does on attach (com_to_usb_ap): opcode COMMAND_CONTROL1_WRITE
# (0x06) with COM_USB (0x09) written to OPCODE_WRITE (0x21), then
# OPCODE_WRITE_END (0x41) = 0. The MUIC answers at 0x25 on the bus of the
# MAX77705 (i2c@980000). Charger registers are not touched.

sysfs="${MUIC_SYSFS:-/sys}"	# overridden by the test only

log() {
	echo "gts7xl-usb-muic: $*"
	{ echo "gts7xl-usb-muic: $*" > /dev/kmsg; } 2>/dev/null
}

found=n
for adapter in "$sysfs"/devices/platform/soc@0/*.geniqup/980000.i2c/i2c-*; do
	[ -e "$adapter" ] || continue
	found=y
	bus="${adapter##*/i2c-}"
	if i2ctransfer -f -y "$bus" w3@0x25 0x21 0x06 0x09 &&
	   i2ctransfer -f -y "$bus" w2@0x25 0x41 0x00; then
		log "USB data lines switched to the SoC (i2c-$bus)"
	else
		log "write to the MUIC failed (i2c-$bus)"
	fi
done

[ "$found" = y ] || log "i2c@980000 adapter not found, USB stays disconnected"
exit 0
