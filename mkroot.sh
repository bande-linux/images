#!/bin/sh
# Usage: mkroot.sh <root dir> <output image> <filesystem uuid> [minimum size in MiB]
# Lays a finished root directory out as the btrfs of a new install. See NOTES/plans/update-safety.md
# in the desktop repo. The contents of the root directory move into the layout.
set -eu

root=$1
image=$2
uuid=$3
minimum=${4:-0}

top=$(mktemp -d -p "$(dirname "$root")")
trap 'rm -rf --one-file-system "$top"' EXIT

mkdir "$top/@system"
mv "$root" "$top/@system/1"
for pair in @home:home @var-log:var/log @var-cache:var/cache @var-tmp:var/tmp; do
    subvolume=${pair%%:*}
    path=$top/@system/1/${pair#*:}
    mv "$path" "$top/$subvolume"
    mkdir "$path"
done
mkdir "$top/@snapshots" "$top/@system/1/.snapshots"
chmod 700 "$top/@snapshots" "$top/@system/1/.snapshots"
cat > "$top/@system/1.info" <<EOT
created=${SOURCE_DATE_EPOCH:-$(date +%s)}
why=install
EOT

size=$(du -sm "$top" | cut -f1)
size=$(( (size * 13 / 10 + 512) / 4 * 4 ))
[ "$size" -ge "$minimum" ] || size=$minimum
rm -f "$image"
truncate -s "${size}M" "$image"
mkfs.btrfs -q -L root -U "$uuid" -r "$top" -m dup \
    --subvol rw:@system/1 --subvol rw:@home --subvol rw:@var-log --subvol rw:@var-cache \
    --subvol rw:@var-tmp --subvol rw:@snapshots --compress zstd:3 "$image"
mkdir "$root"
mv "$top/@system/1"/* "$top/@system/1"/.[!.]* "$root"/ 2>/dev/null || true
for pair in @home:home @var-log:var/log @var-cache:var/cache @var-tmp:var/tmp; do
    path=$root/${pair#*:}
    rmdir "$path"
    mv "$top/${pair%%:*}" "$path"
done
rmdir "$root/.snapshots"
