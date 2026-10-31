#!/bin/bash
# Build the Bande install ISO for one PC architecture with simple-cdd: a Debian
# testing netinst that adds the Bande archive and installs bande-os.
#
# Usage: iso/build.sh <amd64|arm64> [out-dir]
# Run natively on that architecture, as root, in Debian testing.
#
# BANDE_APT       yes, no or auto (default): add the Bande archive to the
#                 installed system; auto adds it once the archive is published.
# BANDE_PACKAGES  packages to install; auto (default) means bande-os once the
#                 archive carries it, otherwise none, for a minimal Debian system.
set -euo pipefail

arch=${1:?usage: iso/build.sh <amd64|arm64> [out-dir]}
out=$(realpath -m "${2:-out}")
here=$(dirname "$(realpath "$0")")
mirror=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
daily=https://d-i.debian.org/daily-images/$arch
apt_url=https://bande-linux.github.io/apt
key_fpr=04FCEAF9B79998D9828C256B7963AC449BD9992E
: "${BANDE_APT:=auto}" "${BANDE_PACKAGES:=auto}"

die() { echo "build.sh: $*" >&2; exit 1; }
case $arch in amd64|arm64) ;; *) die "unsupported architecture: $arch" ;; esac
[ "$(dpkg --print-architecture)" = "$arch" ] || die "build $arch on an $arch machine"
fetch() { curl -fsSL --retry 5 --retry-all-errors "$@"; }

fpr=$(gpg --show-keys --with-colons "$here/bande-archive-key.asc" | awk -F: '/^fpr/ && !f { f = $10 } END { print f }')
[ "$fpr" = "$key_fpr" ] || die "bande-archive-key.asc has fingerprint $fpr, expected $key_fpr"

if [ "$BANDE_APT" = auto ]; then
    BANDE_APT=no
    fetch -o /dev/null "$apt_url/dists/rolling/InRelease" 2>/dev/null && BANDE_APT=yes
fi
if [ "$BANDE_PACKAGES" = auto ]; then
    BANDE_PACKAGES=
    if [ "$BANDE_APT" = yes ]; then
        for a in "$arch" all; do
            if fetch "$apt_url/dists/rolling/main/binary-$a/Packages.gz" 2>/dev/null |
                    gzip -dc | grep -x 'Package: bande-os' >/dev/null; then
                BANDE_PACKAGES=bande-os
            fi
        done
    fi
fi
[ "$BANDE_APT" = yes ] || [ "$BANDE_APT" = no ] || die "BANDE_APT must be yes, no or auto"
echo "Bande archive: $BANDE_APT; packages: ${BANDE_PACKAGES:-none (minimal Debian)}"

codename=$(fetch "$mirror/dists/testing/Release" | sed -n 's/^Codename: //p')
[ -n "$codename" ] || die "cannot read the codename of testing"

# The installer's kernel must match the kernel module udebs on the medium.
# Testing's own installer images lag far behind its kernel, so take the newest
# daily build whose kernel matches the udebs of sid (preferred, the daily is
# built from sid) or of testing.
udeb_kernel() {
    fetch "$mirror/dists/$1/main/debian-installer/binary-$arch/Packages.xz" |
        xz -dc | awk '/^Package: linux-base-.*-di$/ && !k { k = $2 } END { sub(/^linux-base-/, "", k); sub(/-di$/, "", k); print k }'
}
sid_kernel=$(udeb_kernel sid)
testing_kernel=$(udeb_kernel "$codename")
di_build= di_codename=
for d in $(fetch "$daily/" | grep -oE 'href="\./[0-9]{8}-[0-9:]+/"' | cut -d/ -f2 | sort -r | head -14); do
    k=$(fetch "$daily/$d/MANIFEST.udebs" 2>/dev/null |
        awk '$1 ~ /^linux-base-.*-di$/ && !k { k = $1 } END { sub(/^linux-base-/, "", k); sub(/-di$/, "", k); print k }') || continue
    [ -n "$k" ] || continue
    if [ "$k" = "$sid_kernel" ]; then di_codename=sid
    elif [ "$k" = "$testing_kernel" ]; then di_codename=$codename
    else continue
    fi
    di_build=$d
    break
done
[ -n "$di_build" ] || die "no recent installer daily has kernel $sid_kernel (sid) or $testing_kernel ($codename)"
echo "Installer: daily $di_build, kernel $k, udebs from $di_codename"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
images=$work/di/installer-$arch/current/images
mkdir -p "$images"
fetch -o "$images/SHA256SUMS" "$daily/$di_build/SHA256SUMS"
grep -E '  \./(MANIFEST|MANIFEST\.udebs|cdrom/.*)$' "$images/SHA256SUMS" |
    grep -v /depthcharge/ > "$work/di-files"
while read -r _ f; do
    mkdir -p "$images/$(dirname "$f")"
    fetch -o "$images/$f" "$daily/$di_build/$f"
done < "$work/di-files"
(cd "$images" && sha256sum --quiet -c "$work/di-files")

mkdir -p "$work/profiles"
cp "$here/profiles/default.preseed" "$here/profiles/bande.postinst" \
    "$here/profiles/bande.description" "$here/bande-archive-key.asc" "$work/profiles/"
echo "$work/profiles/bande-archive-key.asc" > "$work/profiles/bande.extra"
if [ "$BANDE_APT" = yes ]; then apt_tag=; else apt_tag='/^@APT@/d;'; fi
sed -e "$apt_tag" -e 's/^@APT@//' -e "s|@APT_URL@|$apt_url|" -e "s|@PACKAGES@|$BANDE_PACKAGES|" \
    "$here/profiles/bande.preseed.in" > "$work/profiles/bande.preseed"
grep -v "^#" "$work/profiles/bande.preseed" | grep -q @ && die "unfilled value in bande.preseed"

cat > "$work/bande.conf" <<EOF
CODENAME="$codename"
DI_CODENAME="$di_codename"
SUITE="testing"
ARCH="$arch"
ARCHES="$arch"
debian_mirror="$mirror/"
custom_installer="$work/di"
security_mirror=""
updates_mirror=""
DISABLE_UEFI_32="1"
DEBVERSION="testing"
OUT="$work/images"
EOF

date=$(date -u +%F)
iso=bande-os-$date-$arch.iso
(cd "$work" && build-simple-cdd --force-root --conf "$work/bande.conf" \
    --dist "$codename" --profiles bande --auto-profiles bande --verbose)

mkdir -p "$out"
built=$(find "$work/images" -name '*.iso' | head -1)
[ -n "$built" ] || die "simple-cdd made no ISO"
mv "$built" "$out/$iso"
cat > "$out/$iso.info" <<EOF
iso=$iso
arch=$arch
suite=testing ($codename)
installer=d-i daily $di_build, kernel $k, udebs from $di_codename
bande-apt=$BANDE_APT
packages=$BANDE_PACKAGES
EOF
(cd "$out" && sha256sum "$iso" > "$iso.sha256")
cat "$out/$iso.info"
ls -l "$out/$iso"
