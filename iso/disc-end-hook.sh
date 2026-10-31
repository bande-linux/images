#!/bin/sh
# debian-cd DISC_END_HOOK: <tdir> <mirror> <disknum> <cddir> <archlist>
#
# debian-cd lists SHA512 hashes in the disc's Release, but the Packages
# entries it copies from the mirror only carry SHA256. debootstrap picks the
# strongest hash in Release that the installer can compute, and the installer's
# busybox now has sha512sum, so it looks for SHA512 fields that do not exist
# and rejects every package as corrupt. Drop SHA512 from Release (it is the
# last section) and update its line in md5sum.txt.
set -eu
cd "$4"
for r in dists/*/Release; do
    [ -L "$r" ] && continue
    sed -i '/^SHA512:/,$d' "$r"
    sum=$(md5sum < "$r" | cut -d' ' -f1)
    sed -i "s|^[0-9a-f]\{32\}  \./$r\$|$sum  ./$r|" md5sum.txt
done
