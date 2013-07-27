#!/bin/sh
set -e

CONFIG=/etc/hotspot.conf
PIDFILE=/var/run/hotspot.pid
DEFAULT_ESSIDS="Telekom|Telekom_FlyNet|Telekom_ICE"
DEFAULT_INTERVAL=300
LOGGER=cat

msg() {
    echo "$@" | $LOGGER
}

warn() {
    msg "$@" >&2
}

error() {
    warn "$@"
    exit 1
}

get_essid() {
    iwconfig "$1" | perl -ne '/ESSID:\s*"?(.*?)\"/ and print $1'
}

is_valid_essid() {
    get_essid "$1" | grep -qE "^$ESSIDS\$"
}

login() {
    u_file=$(tempfile)
    chmod 600 "$u_file"
    printf '%s' "$USER" > "$u_file"

    p_file=$(tempfile)
    chmod 600 "$p_file"
    printf '%s' "$PASS" > "$p_file"

    curl -fsL 'https://hotspot.t-mobile.net/wlan/index.do' \
        --data-urlencode "username@$u_file" \
        --data-urlencode "password@$p_file" \
        --data "strHinweis=Zahlungsbedingungen" \
        --data "strAGB=AGB" \
    | grep -iF "Sie sind online" > /dev/null
    # ^- we can't use grep -q here as grep will close stdin on the first match and curl
    # complains with "curl: (23) Failed writing body (4012 != 8108)"
    rc="$?"
    rm -f "$u_file" "$p_file"
    return "$rc"
}

logout() {
    curl -fsL https://hotspot.t-mobile.net/wlan/stop.do \
    | grep -iF "Sie haben sich ausgeloggt" > /dev/null
    rc="$?"
    [ "$rc" -eq 0 ] && msg "Logged out"
    return "$rc"
}

if ! type printf | grep -qF builtin; then
    warn "printf does not appear to be a shell builtin. Your credentials may show up in the process list!"
fi

while [ "$#" -gt 0 ]; do
    case "$1" in
        -f)
            dofork=1
            shift
            ;;
        -l)
            dologout=1
            dokill=1
            shift
            ;;
        -k)
            dokill=1
            shift
            ;;
        -*)
            error "Unrecognized option $1"
            ;;
        *)
            break
            ;;
    esac
done

if [ "$2" ]; then
    error "Interface must be last argument"
fi

if [ "$dologout" ]; then
    logout
fi

if [ "$dokill" ]; then
    [ -e "$PIDFILE" ] || error "$0 not running"
    kill "$(cat "$PIDFILE")"
    rc=$?
    [ "$rc" -eq 0 ] && rm -f "$PIDFILE"
    exit $rc
fi

if [ ! -r "$CONFIG" ]; then
    error "Unable to read $CONFIG, aborting."
fi
. "$CONFIG"

if stat -L -c '%a' "$CONFIG" | grep -qE '[^0]$'; then
    warn "Warning: $CONFIG is world-readable!"
fi

[ -z "$USER" ] && error "Need to set USER in $CONFIG"
[ -z "$PASS" ] && error "Need to set PASS in $CONFIG"
ESSIDS="${ESSIDS:-$DEFAULT_ESSIDS}"
INTERFACE="${INTERFACE:-$1}"
INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"

[ -z "$INTERFACE" ] && error "Need to pass an interface (either via INTERFACE= in $CONFIG or command line)"

if [ -e "$PIDFILE" ]; then
    if [ ! -d /proc/"$(cat "$PIDFILE")" ]; then
        warn "Removing stale pid file $PIDFILE"
        rm -f "$PIDFILE"
    else
        error "$0 already running"
    fi
fi

if ! is_valid_essid "$INTERFACE"; then
    error "ESSID $(get_essid "$INTERFACE") not valid for hotspot"
fi

if ! login; then
    error "Initial log in failed"
else
    msg "Initial log in succeeded"
fi

loop() {
    while true; do
        sleep "$INTERVAL"
        if ! is_valid_essid "$INTERFACE"; then
            msg "ESSID $(get_essid "$INTERFACE") not valid anymore, exiting"
            break
        fi
        if login; then
            msg "Log in refreshed"
        else
            error "Refreshing log in failed"
        fi
    done
}

if [ "$dofork" ]; then
    TAG="$(basename "$0")"
    TAG="${TAG%.*}"
    LOGGER="logger -t $TAG"
    loop &
    echo $! > "$PIDFILE"
else
    loop
fi
