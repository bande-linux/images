#!/bin/sh
# Runs in debian:trixie. $1: modules tarball from the kernel job, $2: output.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
apt-get update -qq
apt-get install -y -qq --no-install-recommends busybox-static dropbear-bin fdisk util-linux zstd cpio xz-utils kmod >/dev/null
R=/tmp/rootfs
mkdir -p $R/bin $R/sbin $R/etc $R/proc $R/sys $R/dev $R/usr/bin $R/usr/sbin $R/root
cp /bin/busybox $R/bin/busybox
for a in $(/bin/busybox --list); do [ "$a" = busybox ] || ln -sf busybox $R/bin/$a; done
ln -s ../bin/busybox $R/sbin/modprobe
tar -C $R -xJf "$1"
M=$(echo $R/lib/modules/*)
(cd $M && find kernel -name '*.ko*' | grep -f "$here/modules.allow") > /tmp/keep
while :; do
    n=$(wc -l < /tmp/keep)
    awk -F: 'NR==FNR { k[$1]; next } ($1 in k) { print $1; n = split($2, d, " "); for (i = 1; i <= n; i++) print d[i] }' /tmp/keep $M/modules.dep | sort -u > /tmp/keep.new
    sort -u /tmp/keep /tmp/keep.new > /tmp/keep.all; mv /tmp/keep.all /tmp/keep
    [ "$(wc -l < /tmp/keep)" = "$n" ] && break
done
(cd $M && find kernel -name '*.ko*') | grep -vxF -f /tmp/keep | (cd $M && xargs rm -f)
depmod -b $R "$(basename $M)"
for b in /usr/sbin/dropbear /usr/sbin/sfdisk /usr/sbin/blkid /usr/bin/zstd; do
    cp $b $R/usr/sbin/
    ldd $b | grep -o '/[^ ]*' | while read l; do mkdir -p $R$(dirname $l); cp -L $l $R$l; done
done
mkdir -p $R/lib/firmware
ln -s /vendorfw $R/lib/firmware/vendor
cp "$here/init" $R/init
cp "$here/usb-gadget" $R/usr/sbin/usb-gadget
chmod +x $R/init $R/usr/sbin/usb-gadget
echo 'root::0:0:root:/root:/bin/sh' > $R/etc/passwd
(cd $R && find . | cpio -o -H newc -R 0:0 --quiet | xz --check=crc32 -6) > "$2"
