#!/bin/bash
# Usage: install.sh <state dir> install|remove
# The state dir holds Image.gz, t8112-j473.dtb, modules-*.tar.xz, image.zip, firmware.cpio,
# setup/ and plan. Boots the tether initramfs with the payload, which partitions and writes
# (or removes) only the "Unbound ESP" and "Unbound Linux" partitions and logs to the UNBOUND stick.
set -euo pipefail
state=$(cd "$1" && pwd) mode=$2
here=$(cd "$(dirname "$0")" && pwd)
case "$mode" in install|remove) ;; *) echo "mode must be install or remove" >&2; exit 1 ;; esac
grep -q "^MODE=$mode$" "$state/plan" || sed -i '' -e "s/^MODE=.*/MODE=$mode/" "$state/plan"
src() { COPYFILE_DISABLE=1 tar --no-xattrs -c -C "$here/.." tether -C "$state" "$@"; }
src $(cd "$state" && ls modules-*.tar.xz) | docker run --rm -i debian:trixie sh -euc '
    mkdir /w && cd /w && tar -x
    sh tether/mkinitramfs.sh modules-*.tar.xz /w/i >/dev/null 2>&1 && cat /w/i' > "$state/tether.cpio.xz"
if [ "$mode" = install ]; then
    src image.zip firmware.cpio setup plan | docker run --rm -i debian:trixie sh -euc '
        mkdir /w /o && cd /w && tar -x
        sh tether/payload.sh image.zip firmware.cpio setup plan /o >&2
        cd /o && tar -c payload.cpio image' | tar -x -C "$state"
else
    stage=$(mktemp -d)
    mkdir "$stage/payload"
    cp "$state/plan" "$here/run" "$stage/payload/"
    (cd "$stage" && find payload | cpio -o -H newc -R 0:0 --quiet) > "$state/payload.cpio"
    rm -rf "$stage"
fi
cat "$state/tether.cpio.xz" "$state/firmware.cpio" "$state/payload.cpio" > "$state/tether-$mode.img"
"$here/load.sh" "$state/Image.gz" "$state/t8112-j473.dtb" "$state/tether-$mode.img" "$state/logs/$mode" \
    "console=tty0 rdinit=/init"
