#!/bin/bash
set -euo pipefail
root=$1
export UNBOOT_UPDATE_DISABLED=1

echo bande > "$root/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tbande\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
cp -a --no-preserve=ownership "$HERE/rootfs/." "$root/"
if [ "$IMAGE_TARGET" = apple ]; then
    cp -a --no-preserve=ownership "$HERE/rootfs-apple/." "$root/"
    chroot "$root" dpkg-divert --no-rename --package bande-images \
        --divert /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf.asahi \
        --add /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf
    mkdir -p "$root/usr/lib/unboot"
    cp "$WORK/unboot.bin" "$WORK/u-boot-nodtb.bin" "$root/usr/lib/unboot/"
fi
mkdir -p "$root/etc/kernel" "$root/boot/efi"
echo debian > "$root/etc/kernel/entry-token"
echo layout=bande > "$root/etc/kernel/install.conf"
echo btrfs >> "$root/etc/initramfs-tools/modules"
[ "$IMAGE_TARGET" = apple ] || echo virtio_gpu >> "$root/etc/initramfs-tools/modules"

install -D -m 644 "$WORK/archive.gpg" "$root/etc/apt/keyrings/bande-image.gpg"
echo "deb [signed-by=/etc/apt/keyrings/bande-image.gpg] $ARCHIVE forky main" > "$root/etc/apt/sources.list.d/bande-image.list"
mkdir -p "$root/tmp/local"
cp -a "$WORK/local/." "$root/tmp/local/"
chroot "$root" sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends bande-archive-keyring bande-apt-source'
rm -f "$root/etc/apt/sources.list.d/bande-image.list" "$root/etc/apt/keyrings/bande-image.gpg"
[ "$IMAGE_TARGET" = apple ] && cp "$root/usr/share/bande-apt-source/bande-apple.sources" "$root/etc/apt/sources.list.d/"
chroot "$root" apt-get update -qq
extra="$(echo "$EXTRA" | tr "," " ")"
[ -z "$(chroot "$root" apt-cache policy bande-backup | grep Candidate | grep -v none || true)" ] && [ -z "$(cd "$root/tmp/local" && ls | grep '^bande-backup_' || true)" ] || extra="bande-backup $extra"
if [ -z "$(cd "$root/tmp/local" && ls | grep '^bande-recovery-tools_' || true)" ]; then
    if [ "${ALLOW_MISSING_APPS:-}" != 1 ] || [ -n "$(chroot "$root" apt-cache policy bande-recovery-tools | grep Candidate | grep -v none || true)" ]; then
        extra="bande-recovery-tools $extra"
    fi
fi
local_debs=$(cd "$root/tmp/local" && ls | sed 's|^|/tmp/local/|' | tr '\n' ' ')
apps=$(chroot "$root" apt-cache depends bande-desktop | sed -n 's/^ *Recommends: \(bande-[a-z0-9-]*\)$/\1/p' | sort -u | tr '\n' ' ')
missing=$(chroot "$root" apt-cache depends bande-desktop | sed -n 's/^ *Recommends: <\(bande-[a-z0-9-]*\)>$/\1/p' | tr '\n' ' ')
[ -z "$missing" ] || [ "${ALLOW_MISSING_APPS:-}" = 1 ] || {
    echo "bande-desktop recommends $missing, which the archive lacks (ALLOW_MISSING_APPS=1 builds without it)"
    exit 1
}
# shellcheck disable=SC2086
chroot "$root" env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bande-desktop $apps $extra $local_debs
rm -rf "$root/tmp/local" "$root"/var/lib/apt/lists/* "$root"/var/cache/apt/archives/*.deb

chroot "$root" systemctl enable NetworkManager systemd-resolved greetd bande-live-setup
chroot "$root" systemctl set-default graphical.target
ln -sf ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf"
chroot "$root" update-initramfs -u -k all
rm -f "$root/etc/machine-id" "$root/var/lib/dbus/machine-id"
touch "$root/etc/machine-id"
