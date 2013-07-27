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
    iwconfig "$1" 2>/dev/null | perl -ne '/ESSID:\s*"?(.*?)\"/ and print $1'
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

# sanity check
if ! type printf | grep -qF builtin; then
    warn "printf does not appear to be a shell builtin. Your credentials may show up in the process list!"
fi

# check if we are being called from ifupdown
if [ "$PHASE" -a "$IFACE" ]; then
    ifupdown=1
fi

if [ "$ifupdown" ]; then
    case "$PHASE" in
        post-up)
            dofork=1
            ;;
        pre-down)
            dologout=1
            dokill=1
            ;;
        *)
            error "$0 not valid for ifupdown phase $PHASE"
            ;;
    esac
else
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
    [ "$ifupdown" ] || error "Unable to read $CONFIG, aborting."
else
    if stat -L -c '%a' "$CONFIG" | grep -qE '[^0]$'; then
        warn "Warning: $CONFIG is world-readable!"
    fi
    . "$CONFIG"
fi


# overrides from ifupdown
if [ "$ifupdown" ]; then
    USER=${IF_HOTSPOT_USERNAME:-$USER}
    PASS=${IF_HOTSPOT_PASSWORD:-$PASS}
    INTERVAL=${IF_HOTSPOT_INTERVAL:-$INTERVAL}
    if [ "$IF_HOTSPOT_ESSIDS" ]; then
        ESSIDS="$IF_HOTSPOT_ESSIDS"
    elif [ "$IF_WIRELESS_ESSID" ]; then # trust the user if she set an essid via wireless-tools
        ESSIDS="$IF_WIRELESS_ESSID"
    fi
    [ "$IFACE" ] || error "Huh, called from ifupdown but \$IFACE is unset?"
    INTERFACE="$IFACE"
    setwhere="in /etc/network/interfaces"
else
    INTERFACE="${1:-$INTERFACE}"
    [ -z "$INTERFACE" ] && error "Need to pass an interface (either via INTERFACE= in $CONFIG or command line)"
    setwhere="in $CONFIG"
fi

[ -z "$USER" ] && error "Need to set username $setwhere"
[ -z "$PASS" ] && error "Need to set password $setwhere"

# defaults
ESSIDS="${ESSIDS:-$DEFAULT_ESSIDS}"
INTERVAL="${INTERVAL:-$DEFAULT_INTERVAL}"

if [ -e "$PIDFILE" ]; then
    if [ ! -d /proc/"$(cat "$PIDFILE")" ]; then
        warn "Removing stale pid file $PIDFILE"
        rm -f "$PIDFILE"
    else
        error "$0 already running"
    fi
fi

if ! is_valid_essid "$INTERFACE"; then
    error "ESSID \"$(get_essid "$INTERFACE")\" on $INTERFACE not valid for hotspot"
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
