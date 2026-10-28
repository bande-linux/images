#!/bin/bash
# Usage: boot.sh <state dir>
# Boots the installed system: kernel and initramfs over USB, root and ESP from the mini's disk.
set -euo pipefail
state=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
. "$state/plan"
"$here/load.sh" "$state/Image.gz" "$state/t8112-j473.dtb" "$state/initrd.img" "$state/logs/boot" \
    "root=UUID=$ROOT_UUID rw console=tty0" "unbound,efi-system-partition=$ESP_UUID"
