#!/bin/sh
set -eu

[ $# -eq 1 ] || { echo "Usage: $0 <root>"; exit 1; }
root=${1%/}
clients=/usr/share/unbound-compositor/session-clients
greetd_units="/usr/lib/systemd/system/greetd.service /usr/lib/systemd/system/greetd.service.d/*.conf
/etc/systemd/system/greetd.service /etc/systemd/system/greetd.service.d/*.conf"

inside() {
    path=$1
    resolved=
    hops=0
    while [ -n "$path" ]; do
        path=${path#/}
        component=${path%%/*}
        case "$path" in
        */*) path=${path#*/} ;;
        *) path= ;;
        esac
        case "$component" in
        "" | .) continue ;;
        ..)
            resolved=${resolved%/*}
            continue
            ;;
        esac
        if [ -L "$root$resolved/$component" ]; then
            hops=$((hops + 1))
            [ $hops -le 40 ] || return 1
            target=$(readlink "$root$resolved/$component")
            case "$target" in
            /*) resolved= ;;
            esac
            path=$target${path:+/$path}
        else
            resolved=$resolved/$component
        fi
    done
    echo "${resolved:-/}"
}

executable() {
    real=$(inside "$1") || return 1
    [ -f "$root$real" ] && [ -x "$root$real" ]
}

resolve() {
    case "$1" in
    /*)
        echo "$1"
        return
        ;;
    esac
    for dir in /usr/local/bin /usr/bin /usr/local/sbin /usr/sbin /bin /sbin; do
        if executable "$dir/$1"; then
            echo "$dir/$1"
            return
        fi
    done
    echo "$1"
}

programs() {
    source=$1
    shift
    previous=
    for word in "$@"; do
        [ "$previous" = --cmd ] && echo "$source $word"
        case "$word" in
        --cmd=*) echo "$source ${word#--cmd=}" ;;
        esac
        previous=$word
    done
    while [ $# -gt 0 ]; do
        echo "$source $1"
        case "${1##*/}" in
        env)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -u | -C | -S | --unset | --chdir | --split-string) shift 2 ;;
                -* | *=*) shift ;;
                *) break ;;
                esac
            done
            ;;
        systemd-cat)
            shift
            while [ $# -gt 0 ]; do
                case "$1" in
                -t | -p | --identifier | --priority | --stderr-priority | --level-prefix) shift 2 ;;
                -*) shift ;;
                *) break ;;
                esac
            done
            ;;
        *) return ;;
        esac
    done
}

words() {
    set -f
    # shellcheck disable=SC2086
    programs "$1" $2
    set +f
}

exec_lines() {
    file=$1
    keys=$2
    sed -n "s/^[[:space:]]*\($keys\)[[:space:]]*=[[:space:]]*//p" "$root$file" | while read -r line; do
        line=$(echo "$line" | sed 's/^[-@:+!|]*//')
        [ -n "$line" ] && words "$file" "$line"
    done
}

each() {
    set -f
    for pattern in $1; do
        set +f
        for file in "$root"$pattern; do
            [ -f "$file" ] && echo "${file#"$root"}"
        done
        set -f
    done
    set +f
}

greetd_config() {
    config=/etc/greetd/config.toml
    for unit in $(each "$greetd_units"); do
        found=$(sed -n 's/^[[:space:]]*ExecStart[[:space:]]*=.*--config[[:space:]=]\{1,\}\([^[:space:]]*\).*/\1/p' "$root$unit" | tail -n 1)
        [ -n "$found" ] && config=$found
    done
    echo "$config"
}

commands() {
    if [ -f "$root$clients" ]; then
        while read -r client; do
            [ -n "$client" ] && echo "$clients $client"
        done <"$root$clients"
    else
        echo "unbound-compositor-package $clients"
    fi
    for unit in $(each "$greetd_units"); do
        exec_lines "$unit" 'ExecStart\|ExecStartPre\|ExecStartPost'
    done
    config=$(greetd_config)
    if [ -f "$root$config" ]; then
        sed -n 's/^[[:space:]]*command[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$root$config" | while read -r value; do
            value=$(echo "$value" | sed 's/^"\(.*\)"[[:space:]]*\(#.*\)\{0,1\}$/\1/; s/^'"'"'\(.*\)'"'"'[[:space:]]*\(#.*\)\{0,1\}$/\1/')
            words "$config" "$value"
        done
    else
        echo "$config $config"
    fi
    for file in $(each "/usr/share/wayland-sessions/*.desktop"); do
        exec_lines "$file" 'Exec\|TryExec'
    done
    for file in $(each "/usr/lib/systemd/user/*unbound*.service"); do
        exec_lines "$file" 'ExecStart\|ExecStartPre\|ExecStartPost'
    done
    for file in $(each "/usr/share/dbus-1/services/*unbound*.service"); do
        exec_lines "$file" 'Exec'
    done
}

missing=0
checked=$(commands | sort -u)
while read -r source cmd; do
    [ -n "$cmd" ] || continue
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
