#!/bin/sh
# Load the board modules that are still being brought up (touchscreen) only
# once the USB debug shell is reachable, so that a module that hangs never
# keeps the telnet shell from coming up.
#
# The modules are in the initramfs but blacklisted for udev (autoload by
# modalias would load them at setup_udev, before USB). This hook runs after
# 00-gts7xl-usb-muic.sh; it forks, waits until telnetd runs (debug shell) or
# the timeout ends, then modprobes each module, then restarts buffyboard so it
# sees the new input device. Then the QCA6390 modules, in power-up order:
# the PMU power sequencer, the PCI power control driver (the builtin PCIe
# controller defers until it is bound), ath11k (Wi-Fi) and hci_uart (BT).
# A kernel oops still panics (oops=panic): boot with gts7xl.nomodules on the
# command line (kexec) to skip this hook, gts7xl.nowireless to skip only the
# Wi-Fi/Bluetooth modules.

modules="${GTS7XL_MODULES-stmfts1b}"
wireless="${GTS7XL_WIRELESS_MODULES-pwrseq_qcom_wcn pci_pwrctrl_pwrseq ath11k_pci qrtr_mhi hci_uart}"
cmdline="${GTS7XL_CMDLINE:-/proc/cmdline}"
wait_s="${GTS7XL_WAIT:-30}"				# polls, one per $poll seconds
# GTS7XL_* variables are for the test only
poll="${GTS7XL_POLL:-1}"
settle="${GTS7XL_SETTLE:-2}"

log() {
	echo "gts7xl-modules: $*"
	{ echo "gts7xl-modules: $*" > /dev/kmsg; } 2>/dev/null
}

if grep -qw gts7xl.nomodules "$cmdline" 2>/dev/null; then
	log "gts7xl.nomodules set, not loading: $modules $wireless"
	exit 0
fi
if [ -n "$wireless" ] && grep -qw gts7xl.nowireless "$cmdline" 2>/dev/null; then
	log "gts7xl.nowireless set, not loading: $wireless"
	wireless=""
fi

probe() {
	for m in "$@"; do
		if modprobe "$m"; then
			log "loaded $m"
		else
			log "modprobe $m failed"
		fi
	done
}

load() {
	n=0
	while ! pgrep telnetd > /dev/null 2>&1; do
		[ "$n" -ge "$wait_s" ] && { log "no telnetd after ${wait_s}s, loading anyway"; break; }
		sleep "$poll"
		n=$((n + 1))
	done
	sleep "$settle"
	# shellcheck disable=SC2086
	probe $modules
	if pgrep buffyboard > /dev/null 2>&1; then
		pkill buffyboard
		sleep 1
		buffyboard > /dev/null 2>&1 &
		log "buffyboard restarted"
	fi
	# shellcheck disable=SC2086
	[ -n "$wireless" ] && probe $wireless
}

# Detached from the hook's stdout: messages from here on go to /dev/kmsg only.
load < /dev/null > /dev/null 2>&1 &
exit 0
