#!/bin/sh
set -eu
missing=
for package in mmdebstrap arch-test btrfs-progs cryptsetup-bin squashfs-tools dosfstools mtools fdisk zip python3 gpg \
    qemu-system-arm qemu-system-x86 qemu-efi-aarch64 ovmf qemu-utils qemu-user-binfmt; do
    dpkg -s "$package" >/dev/null 2>&1 || missing="$missing $package"
done
[ -z "$missing" ] && exit 0
sudo apt-get update -qq
# shellcheck disable=SC2086
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $missing
