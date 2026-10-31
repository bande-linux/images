#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <archive key> <output dir> [desktop version]"
    exit 1
}
case $# in
2 | 3) ;;
*) usage ;;
esac
key=$(realpath "$1")
out=$(realpath -m "$2")
want=${3:-}
: "${ARCHIVE:=https://bande-linux.github.io/apt}"
: "${ARCH:=arm64}"
fail() {
    echo "fetch-desktop: $*" >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
get() { curl -fsSL --retry 3 -o "$work/$1" "$ARCHIVE/$2" || fail "cannot fetch $ARCHIVE/$2"; }

gpg --batch --quiet --dearmor < "$key" > "$work/keyring.gpg"
get InRelease dists/rolling/InRelease
gpgv --quiet --keyring "$work/keyring.gpg" --output "$work/Release" "$work/InRelease" 2> /dev/null ||
    fail "rolling/InRelease is not signed by the archive key"
index=main/binary-$ARCH/Packages.xz
sha=$(awk -v p="$index" '/^SHA256:/ { f = 1; next } /^[^ ]/ { f = 0 } f && $3 == p { print $1 }' "$work/Release")
[ -n "$sha" ] || fail "rolling/Release does not list $index"
get Packages.xz "dists/rolling/$index"
echo "$sha  $work/Packages.xz" | sha256sum -c --quiet - || fail "rolling/$index does not match Release"
xz -dc "$work/Packages.xz" | awk '
    /^Package: / { p = $2 } /^Version: / { v = $2 } /^Architecture: / { a = $2 }
    /^Filename: / { f = $2 } /^SHA256: / { s = $2 }
    /^$/ { if (p != "") print p, v, a, f, s; p = "" }
    END { if (p != "") print p, v, a, f, s }' > "$work/list"
get owners state/owners

version=$(awk '$1 == "bande-desktop" { print $2 }' "$work/list")
[ -n "$version" ] || fail "the archive serves no bande-desktop for $ARCH"
[ -z "$want" ] || [ "$want" = "$version" ] ||
    fail "the archive serves bande-desktop $version, not $want; it keeps only the newest version"

rm -rf "$out"
mkdir -p "$out"
count=0
while read -r package source; do
    [ "$source" = desktop ] || [ "$source" = apt ] || continue
    read -r _ deb_version arch filename sha256 < <(awk -v p="$package" '$1 == p' "$work/list") || continue
    [ "$arch" = "$ARCH" ] || [ "$arch" = all ] || fail "$package is listed for $arch in binary-$ARCH"
    [ "$source" != desktop ] || [ "$deb_version" = "$version" ] ||
        fail "$package is $deb_version, bande-desktop is $version"
    deb=$out/$(basename "$filename")
    curl -fsSL --retry 3 -o "$deb" "$ARCHIVE/$filename" || fail "cannot fetch $filename"
    echo "$sha256  $deb" | sha256sum -c --quiet - || fail "$filename does not match the index"
    [ "$(dpkg-deb --field "$deb" Package)" = "$package" ] || fail "$filename is not $package"
    count=$((count + 1))
done < "$work/owners"
for package in bande-desktop bande-compositor bande-archive-keyring bande-apt-source; do
    compgen -G "$out/${package}_*.deb" > /dev/null || fail "the archive lacks $package"
done
echo "Fetched $count packages of bande-desktop $version for $ARCH into $out"
