#!/bin/bash
set -euo pipefail
root=$1

echo bande > "$root/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tbande\n::1\tlocalhost ip6-localhost ip6-loopback\n' > "$root/etc/hosts"
cp -a --no-preserve=ownership "$HERE/rootfs/." "$root/"
if [ "$TARGET" = apple ]; then
    cp -a --no-preserve=ownership "$HERE/rootfs-apple/." "$root/"
    chroot "$root" dpkg-divert --no-rename --package bande-images \
        --divert /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf.asahi \
        --add /usr/share/alsa/ucm2/conf.d/macaudio/cs42l84/Headphones.conf
    mkdir -p "$root/usr/lib/unboot"
    cp "$WORK/unboot.bin" "$WORK/u-boot-nodtb.bin" "$root/usr/lib/unboot/"
fi
mkdir -p "$root/etc/kernel" "$root/boot/efi"
echo debian > "$root/etc/kernel/entry-token"

install -D -m 644 "$WORK/archive.gpg" "$root/etc/apt/keyrings/bande-image.gpg"
echo "deb [signed-by=/etc/apt/keyrings/bande-image.gpg] $ARCHIVE rolling main" > "$root/etc/apt/sources.list.d/bande-image.list"
mkdir -p "$root/tmp/local"
cp -a "$WORK/local/." "$root/tmp/local/"
chroot "$root" sh -c 'apt-get update -qq && apt-get install -y --no-install-recommends bande-archive-keyring bande-apt-source'
rm -f "$root/etc/apt/sources.list.d/bande-image.list" "$root/etc/apt/keyrings/bande-image.gpg"
[ "$TARGET" = apple ] && cp "$root/usr/share/bande-apt-source/bande-apple.sources" "$root/etc/apt/sources.list.d/"
chroot "$root" apt-get update -qq
extra="bande-recovery-tools $(echo "$EXTRA" | tr "," " ")"
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
