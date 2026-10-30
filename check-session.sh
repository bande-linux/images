#!/bin/sh
set -eu

[ $# -eq 1 ] || { echo "Usage: $0 <root>"; exit 1; }
root=${1%/}

spawned="unbound-compositor unbound-bar unbound-clipboard unbound-desktop-surface unbound-launcher
unbound-lock unbound-screenshot unbound-controlcenter unbound-notifications unbound-greeter unbound-monitor"

executable() {
    link=$1
    hops=0
    while [ -L "$root$link" ]; do
        hops=$((hops + 1))
        [ $hops -le 16 ] || return 1
        target=$(readlink "$root$link")
        case "$target" in
        /*) link=$target ;;
        *) link=$(dirname "$link")/$target ;;
        esac
    done
    [ -f "$root$link" ] && [ -x "$root$link" ]
}

resolve() {
    case "$1" in
    /*) echo "$1"; return ;;
    esac
    for dir in /usr/bin /usr/sbin /bin /sbin; do
        if executable "$dir/$1"; then
            echo "$dir/$1"
            return
        fi
    done
    echo "/usr/bin/$1"
}

commands() {
    for name in $spawned; do
        echo "compositor $name"
    done
    if [ -f "$root/etc/greetd/config.toml" ]; then
        sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$root/etc/greetd/config.toml" |
            while read -r first rest; do
                echo "greetd $first"
                case " $rest " in
                *" --cmd "?*)
                    cmd=${rest#*--cmd }
                    echo "greetd ${cmd%% *}"
                    ;;
                esac
            done
    fi
    for file in "$root"/usr/share/wayland-sessions/*.desktop; do
        [ -f "$file" ] || continue
        sed -n 's/^\(Exec\|TryExec\)=\([^[:space:]]*\).*/\2/p' "$file" | while read -r cmd; do
            echo "${file#"$root"} $cmd"
        done
    done
    for file in "$root"/usr/lib/systemd/user/unbound-*.service; do
        [ -f "$file" ] || continue
        sed -n 's/^ExecStart=[-@:+!]*\([^[:space:]]*\).*/\1/p' "$file" | while read -r cmd; do
            echo "${file#"$root"} $cmd"
        done
    done
    for file in "$root"/usr/share/dbus-1/services/*unbound*.service; do
        [ -f "$file" ] || continue
        sed -n 's/^Exec=\([^[:space:]]*\).*/\1/p' "$file" | while read -r cmd; do
            echo "${file#"$root"} $cmd"
        done
    done
}

missing=0
checked=$(commands | sort -u)
while read -r source cmd; do
    path=$(resolve "$cmd")
    if ! executable "$path"; then
        echo "check-session: $path is missing from the root filesystem (needed by $source)" >&2
        missing=1
    fi
done <<EOT
$checked
EOT
[ $missing -eq 0 ] || exit 1
echo "check-session: all $(echo "$checked" | wc -l) session executables are present"
