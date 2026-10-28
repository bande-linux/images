#!/bin/bash
# Usage: load.sh <Image.gz> <dtb> <initrd> <log dir> <bootargs> [chosen.name=value ...]
# Reboots the mini into unboot's USB proxy and boots Linux with the given files. Run under
# mini-session to keep the lock for work on the booted system; otherwise it holds the lock
# only for the load.
set -euo pipefail
abs() { echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"; }
img=$(abs "$1") dtb=$(abs "$2") initrd=$(abs "$3") logs=$4 args=$5
shift 5
here=$(cd "$(dirname "$0")" && pwd)
home=${UNBOUND_HOME:-$HOME/Private/unbound-linux}
py=$HOME/.venvs/unboot/bin/python
lock=$home/hil-host/mini.lock
mkdir -p "$logs"
logs=$(cd "$logs" && pwd)

if [ -n "${MINI_LOCK_OWNER:-}" ]; then
    [ "$(cat "$lock/owner" 2>/dev/null)" = "$MINI_LOCK_OWNER" ] ||
        { echo "MINI_LOCK_OWNER is set but $lock is not held by it" >&2; exit 1; }
else
    "$here/mini-session" tether "$0" "$img" "$dtb" "$initrd" "$logs" "$args" "$@"
    exit
fi

sudo -n "$home/usbc-debug/usbc-debug" reboot > "$logs/usbc.log" 2>&1
for _ in $(seq 60); do ls /dev/cu.usbmodem* >/dev/null 2>&1 || break; sleep 1; done
for _ in $(seq 120); do ls /dev/cu.usbmodem*1 >/dev/null 2>&1 && break; sleep 1; done
proxy=$(ls /dev/cu.usbmodem*1 | head -1)
sleep 3
start=$SECONDS
(cd "$home/bootloader/proxyclient" && CHOSEN="$*" UNBOOTDEVICE=$proxy PYTHONPATH=. "$py" -u "$here/load.py" \
    -b "$args" "$img" "$dtb" "$initrd" < /dev/null > "$logs/boot.out" 2>&1) || true
grep -q "Ready to boot" "$logs/boot.out" || { echo "loading failed, see $logs/boot.out" >&2; exit 1; }
echo "booted after $((SECONDS - start)) s"
