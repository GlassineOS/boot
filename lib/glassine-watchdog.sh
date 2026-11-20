# SPDX-License-Identifier: GPL-2.0-or-later
# The board's hardware watchdogs, for the initramfs (init) and the soft start (soft).
#
# board.conf: WATCHDOGS="DEVICE:SECONDS ..." (default "/dev/watchdog:20"): each device
# gets its own busybox watchdog daemon, petting every 5 s with that timeout. A board
# with two (an SoC watchdog and a PMIC watchdog) names both, by the numbers its device
# tree fixes with aliases.
#
#   gw_list           "DEVICE SECONDS" per line (a bad or missing timeout: 20)
#   gw_arm [WAIT]     a daemon per listed device; waits up to WAIT seconds (default 0)
#                     for a device that isn't there yet (a driver still probing)
#   gw_open           opens each listed device for a feeder: fds 7, 6, 5, 4 in list
#                     order (at most four); a fd already open is kept (a re-exec)
#   gw_feed           one ping on each open fd
#   gw_close          closes them without the magic character: the devices stay armed
#
# Callers set gw_log (default: nothing). GW_DAEMON is the daemon (tests).
# Stopping goes by the daemons: SIGTERM = busybox's magic close (the device stops),
# SIGKILL = no close (the device stays armed).

GW_FDS=''
command -v gw_log >/dev/null 2>&1 || gw_log() { :; }

gw_list() {
    for _gw in ${WATCHDOGS:-/dev/watchdog:20}; do
        _gd=${_gw%%:*} _gt=${_gw#*:}
        [ "$_gt" != "$_gw" ] || _gt=20
        case $_gt in ''|*[!0-9]*) _gt=20 ;; esac
        echo "$_gd $_gt"
    done
}

gw_arm() {
    _gwait=$(( ${1:-0} * 10 ))
    gw_list | while read -r _gd _gt; do
        _gn=0
        while [ ! -e "$_gd" ] && [ $_gn -lt $_gwait ]; do sleep 0.1; _gn=$((_gn + 1)); done
        if [ ! -e "$_gd" ]; then gw_log "no $_gd"; continue; fi
        if ${GW_DAEMON:-watchdog} -t 5 -T "$_gt" "$_gd"; then gw_log "watchdog $_gd armed ($_gt s)"
        else gw_log "watchdog $_gd: the daemon did not start"; fi
    done
}

gw_open() {
    _gf=7
    for _gl in $(gw_list | cut -d' ' -f1); do
        [ $_gf -ge 4 ] || break
        if [ -e "/proc/self/fd/$_gf" ]; then GW_FDS="$GW_FDS $_gf"
        elif [ -e "$_gl" ]; then
            # once the earlier holder's close is through
            _gn=0
            until eval "command exec $_gf>\"\$_gl\"" 2>/dev/null; do
                _gn=$((_gn + 1)); [ $_gn -lt 50 ] || break; sleep 0.1
            done
            if [ $_gn -lt 50 ]; then GW_FDS="$GW_FDS $_gf"
            else gw_log "cannot open $_gl: no watchdog on it through the restart"; fi
        fi
        _gf=$((_gf - 1))
    done
}

gw_feed() {
    for _gf in $GW_FDS; do eval "printf k >&$_gf" 2>/dev/null; done
    return 0
}

gw_close() {
    for _gf in $GW_FDS; do eval "exec $_gf>&-"; done
    GW_FDS=''
}
