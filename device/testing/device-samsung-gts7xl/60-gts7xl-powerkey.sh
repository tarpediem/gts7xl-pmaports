#!/bin/sh
# Power key in the initramfs debug shell: a short press (< 3 s) toggles the
# display off/on, and the touchscreen with it so that touches on a dark screen
# do not type on buffyboard. A long press does nothing here (the PMIC
# long-press reset still applies).
#
# Off: inhibit the touchscreen input device (input core calls close(): the
# driver stops scanning and masks its IRQ), then blank fb0 (DRM fbdev: the
# CRTC is disabled, the panel runs its disable/unprepare sequence).
# On: unblank fb0 (panel prepare/enable), then uninhibit the touchscreen.
#
# Reads struct input_event from the pm8941_pwrkey event device with dd + od
# (busybox only). On arm64 an event is 24 bytes: tv_sec (8), tv_usec (8),
# type (2), code (2), value (4), little endian. The press duration comes from
# the event timestamps.
#
# The state is kept here, not read back from fb0: the vt keyboard handler
# unblanks the console on any key press (the power key included), so fb0 is
# already unblanked when the release arrives. A volume key also unblanks the
# screen while the touchscreen stays inhibited; the next short press then
# turns everything on.
#
# Runs in the background; the hook itself returns at once.
# gts7xl.nopowerkey on the command line disables it.
#
# The same file is /usr/libexec/gts7xl-powerkey in the root filesystem
# (device-samsung-gts7xl-console, gts7xl-powerkey.service, GTS7XL_FOREGROUND=1):
# switch_root kills this hook's shell, so the initramfs watcher does not carry
# over (its last dd/od pair is left reading until the next press, then exits).

sysfs="${GTS7XL_SYSFS:-/sys}"
devdir="${GTS7XL_DEVINPUT:-/dev/input}"
cmdline="${GTS7XL_CMDLINE:-/proc/cmdline}"
long_ms="${GTS7XL_LONG_MS:-3000}"
wait_s="${GTS7XL_WAIT:-30}"
# GTS7XL_* variables below are for the test only
poll="${GTS7XL_POLL:-1}"
eof_exit="${GTS7XL_EOF_EXIT:-0}"

pwrkey_name="pm8941_pwrkey"
touch_name="STM FTS1BA90A Touchscreen"
EV_KEY=1
KEY_POWER=116

log() {
	echo "gts7xl-powerkey: $*"
	{ echo "gts7xl-powerkey: $*" > /dev/kmsg; } 2>/dev/null
}

if grep -qw gts7xl.nopowerkey "$cmdline" 2>/dev/null; then
	log "gts7xl.nopowerkey set, not watching the power key"
	exit 0
fi

# Print the /sys/class/input/inputN directory of the device named $1.
find_input() {
	for d in "$sysfs"/class/input/input*; do
		[ -r "$d/name" ] || continue
		if [ "$(cat "$d/name")" = "$1" ]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

# Print the /dev/input/eventN node of input directory $1.
event_node() {
	for e in "$1"/event*; do
		[ -e "$e" ] || continue
		echo "$devdir/${e##*/}"
		return 0
	done
	return 1
}

set_touch() {
	t=$(find_input "$touch_name") || { log "no touchscreen, display only"; return 0; }
	echo "$1" > "$t/inhibited" 2>/dev/null || log "cannot write $t/inhibited"
}

set_blank() {
	echo "$1" > "$sysfs/class/graphics/fb0/blank" 2>/dev/null || log "cannot write fb0/blank=$1"
}

display_off() {
	set_touch 1
	set_blank 1
	log "display off"
}

display_on() {
	set_blank 0
	set_touch 0
	log "display on"
}

watch() {
	n=0
	while ! pk=$(find_input "$pwrkey_name"); do
		[ "$n" -ge "$wait_s" ] && { log "no $pwrkey_name input device after ${wait_s}s"; return 1; }
		sleep "$poll"
		n=$((n + 1))
	done
	ev=$(event_node "$pk") || { log "no event node under $pk"; return 1; }
	log "watching $ev"

	off=0
	down_ms=""
	while :; do
		exec 3< "$ev" || { log "cannot open $ev"; return 1; }
		while :; do
			# shellcheck disable=SC2046
			set -- $(dd bs=24 count=1 <&3 2>/dev/null | od -An -v -tu1)
			[ "$#" -eq 24 ] || break
			type=$((${17} + ${18} * 256))
			code=$((${19} + ${20} * 256))
			value=$((${21} + ${22} * 256))
			[ "$type" -eq "$EV_KEY" ] && [ "$code" -eq "$KEY_POWER" ] || continue
			ms=$((($1 + $2 * 256 + $3 * 65536 + $4 * 16777216) * 1000 + \
				($9 + ${10} * 256 + ${11} * 65536) / 1000))
			if [ "$value" -eq 1 ]; then
				down_ms=$ms
			elif [ "$value" -eq 0 ] && [ -n "$down_ms" ]; then
				held=$((ms - down_ms))
				down_ms=""
				if [ "$held" -ge "$long_ms" ]; then
					log "long press (${held} ms), ignored"
				elif [ "$off" -eq 0 ]; then
					display_off
					off=1
				else
					display_on
					off=0
				fi
			fi
		done
		exec 3<&-
		[ "$eof_exit" = 1 ] && return 0
		log "$ev closed, reopening"
		sleep "$poll"
		ev=$(event_node "$pk") || { log "$pk gone"; return 1; }
	done
}

# Detached from the hook's stdout: messages from here on go to /dev/kmsg only.
if [ "${GTS7XL_FOREGROUND:-0}" = 1 ]; then
	watch
	exit $?
fi
watch < /dev/null > /dev/null 2>&1 &
exit 0
