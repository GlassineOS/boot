#!/bin/sh
# The guest side of test/qemu for an outside base (test.sh --base): installed
# in the first deployment's build layer as /usr/local/sbin/qtest-agent and
# carried by every switch (its migrate list, build-base.sh). It uses only the
# base's own tools (glassine-deploy, the glassine apk wrapper, OpenRC). It
# reads its stage from userdata (qtest/stage), checks, acts, writes the next
# stage and powers off. Every result is a line "QTEST ok|FAIL <check>" on the
# console; the host greps them.
#
#   0  d1 (the candidate) comes up and is accepted; a package added live; a
#      file of the base's migrate list changed, an account added; the second
#      base received (delta) and staged with the package replayed; a user
#      shutdown (the switch)
#   1  the staged deployment boots as the candidate on the second base: carried
#      changes, machine id and account, the package replayed; accepted;
#      rollback selected
#   2  d1 boots again with its own state; accepted; reset; a user shutdown
#   3  the reset boots on d1's base with the migrate list only; accepted; a
#      reset marked to fail (health check); a user shutdown
#   4, 5  the failing candidate: not accepted, twice (its two tries)
#   6  the reset boots as current again, the candidate marked failed; DONE
# Without a second base (no qtest/base2.btrfs.zst) stage 0 ends with DONE.
# Each check is a test command followed by `res $? NAME`, on purpose:
# shellcheck disable=SC2319
set -u
# a user's shell's PATH (OpenRC's puts /sbin first, before the apk wrapper)
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
UD=/run/glassine/userdata
SYS=/run/glassine/system
Q=$UD/qtest
P=media/glassine
# a small package from the base's own repositories, not in the base
PKG=tree
# services the base enables that cannot run in this VM: they are listed, not
# checked. bluetooth: the virt kernel has no Bluetooth (build-base.sh makes the
# service refuse to start there instead of crashing).
VM_DOWN=bluetooth
TAB=$(printf '\t')
ACCEPT_AFTER=120
# shellcheck source=/dev/null
[ -r /etc/glassine/deploy.conf ] && . /etc/glassine/deploy.conf

say() { echo "QTEST $*" > /dev/console; }
res() { if [ "$1" = 0 ]; then say "ok $2"; else say "FAIL $2"; fi; }
next() { echo "$1" > "$Q/stage"; sync; }
st() { glassine-deploy status --porcelain 2>/dev/null | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }
meta() { sed -n "s/^$2=//p" "$UD/$P/deployments/$1/meta" 2>/dev/null | head -n 1; }
up() { cut -d. -f1 /proc/uptime; }
off() { say "poweroff${1:+ ($1)}"; sync; poweroff; exit 0; }
user_off() { glassine-switch-hook --user-shutdown > /dev/console 2>&1; off "user shutdown, the switch runs"; }
has_pkg() { /sbin/apk info -e "$PKG" >/dev/null 2>&1; }
added() { glassine-deploy packages "$booted" --porcelain 2>/dev/null | grep -q "^type=package${TAB}change=added${TAB}entry=$PKG\$"; }
booted=$(cat /run/glassine/booted 2>/dev/null)

# services: every service of sysinit, boot and default (but the agent's own) is
# started, and none crashed. Waits until the system has been up 60 s, so that a
# supervised service that dies has been seen dying.
services() {
    while [ "$(up)" -lt 60 ]; do sleep 5; done
    for rl in sysinit boot default; do
        for l in /etc/runlevels/$rl/*; do
            [ -e "$l" ] || continue
            s=${l##*/}
            [ "$s" = qtest ] && continue
            case " $VM_DOWN " in *" $s "*) say "skip service $rl/$s: needs hardware this VM lacks"; continue ;; esac
            rc-service "$s" status >/dev/null 2>&1
            res $? "service $rl/$s started ($(rc-service "$s" status 2>&1 | sed 's/.*status: //' | tr -d '\n'))"
        done
    done
    c=$(rc-status --crashed 2>/dev/null | tr '\n' ' ')
    [ -z "${c% }" ]; res $? "no crashed service (rc-status --crashed: ${c:-none})"
}

# accepted ID: the boot-success step accepts the booted candidate ID
accepted() {
    n=0
    while [ "$(st current)" != "$1" ] && [ $n -lt $((ACCEPT_AFTER + 180)) ]; do sleep 5; n=$((n + 5)); done
    dmesg | grep -q "glassine-deploy-accept: $1 accepted"; res $? "$1 accepted by the boot-success step"
    dmesg | grep -q "glassine-deploy-accept: $1 accepted" || say "info the boot-success step said: $(dmesg | sed -n 's/.*\(glassine-deploy-accept: .*\)/\1/p' | tr '\n' '|')"
    [ "$(st current)" = "$1" ] && [ -z "$(st candidate)" ]; res $? "$1 is current (previous: $(st previous))"
}

# not_accepted ID: the boot-success step judged ID and did not accept it
not_accepted() {
    n=0
    while ! dmesg | grep -q "glassine-deploy-accept: $1 not accepted" && [ $n -lt $((ACCEPT_AFTER + 180)) ]; do sleep 5; n=$((n + 5)); done
    dmesg | grep -q "glassine-deploy-accept: $1 not accepted"; res $? "$1 not accepted ($(dmesg | sed -n "s/.*glassine-deploy-accept: $1 not accepted: //p" | tail -n 1))"
}

# come_up ID BASE: ID booted on BASE, from the read-only overlay of its layers
come_up() {
    [ "$booted" = "$1" ]; res $? "booted $1 (booted=$booted)"
    [ "$(meta "$booted" base)" = "$2" ]; res $? "its base is $2"
    root=$(awk '$2 == "/" { l = $0 } END { print l }' /proc/mounts)
    echo "$root" | awk '{ exit !($3 == "overlay" && $4 ~ /^ro(,|$)/) }'; res $? "/ is the overlay, read-only ($root)"
    grep " / / " /proc/self/mountinfo | tail -n 1 | grep -q "lowerdir=[^ ,]*deployments/$1/build:[^ ,]*bases/$2[, ]"
    res $? "the overlay's lowers are $1's build layer and base $2"
    ! touch /usr/.qtest 2>/dev/null; res $? "writing under / fails"
    { touch /etc/.qtest && rm /etc/.qtest && touch /var/.qtest && rm /var/.qtest; } 2>/dev/null; res $? "/etc and /var are writable"
    { touch /tmp/.qtest && rm /tmp/.qtest; } 2>/dev/null; res $? "/tmp is writable"
    grep -qx '[0-9a-f]\{32\}' /etc/machine-id; res $? "the machine id is filled in ($(cat /etc/machine-id 2>/dev/null))"
    # a clean power-off before: no journal or log replay on this boot
    ! dmesg | grep -q 'EXT4-fs (vda2): recovery complete'; res $? "userdata mounted without a journal replay"
    ! dmesg | grep -q 'BTRFS.*start tree-log replay'; res $? "the system partition mounted without a log replay"
}

# glassine-deploy's temporary files go to TMPDIR, else /tmp: where /tmp is not
# writable (a check above fails then), a directory on /run, so that the later
# checks still run
{ touch /tmp/.qtest && rm /tmp/.qtest; } 2>/dev/null || { mkdir -p /run/qtest-tmp && export TMPDIR=/run/qtest-tmp; }

stage=$(cat "$Q/stage" 2>/dev/null || echo 0)
say "stage $stage booted=$booted uptime=$(up)"
B1=$(cat "$Q/base1" 2>/dev/null)
B2=$(cat "$Q/base2" 2>/dev/null)
F2=$(cat "$Q/base2-file" 2>/dev/null)
case $stage in
0)  come_up d1 "$B1"
    [ "$(st tries)" = 1 ]; res $? "d1 is the candidate with 1 try left"
    accepted d1
    services
    cp /etc/machine-id "$Q/machine-id"
    # live changes: a package, a file of the base's migrate list, an account
    n=0; while ! ip -4 route show default | grep -q . && [ $n -lt 180 ]; do sleep 5; n=$((n + 5)); done
    ip -4 route show default | grep -q .; res $? "network up (default route, from the base's network service)"
    [ "$(command -v apk)" = /usr/sbin/apk ]; res $? "apk on PATH is the base's wrapper ($(command -v apk))"
    GLASSINE_APK_ACK=1 apk update > /dev/console 2>&1 && GLASSINE_APK_ACK=1 apk add "$PKG" > /dev/console 2>&1
    res $? "apk add $PKG, live (the base's apk wrapper)"
    has_pkg; res $? "$PKG installed (apk info -e)"
    ! touch /usr/.qtest 2>/dev/null; res $? "/ read-only again after apk"
    added; res $? "glassine-deploy packages: $PKG added"
    echo qtest-carried > /etc/hostname
    echo junk > /etc/qtest-junk
    adduser -D -H -u 1500 qtest > /dev/console 2>&1 && echo 'qtest:qtest-pw' | chpasswd > /dev/console 2>&1
    res $? "account qtest added (uid 1500, a password)"
    grep '^qtest:' /etc/shadow | cut -d: -f2 > "$Q/pwhash"
    if [ ! -e "$Q/base2.btrfs.zst" ]; then
        next finished; say DONE; off "no second base"
    fi
    before=$(ls "$SYS/bases")
    glassine-deploy receive "$Q/base2.btrfs.zst" > /dev/console 2>&1
    res $? "glassine-deploy receive: the second base's delta"
    B2=''
    for b in "$SYS"/bases/*; do printf '%s\n' "$before" | grep -qxF "${b##*/}" || B2=${b##*/}; done
    echo "$B2" > "$Q/base2"
    [ -n "$B2" ] && btrfs subvolume show "$SYS/bases/$B2" | grep -q 'Received UUID:[[:space:]]*[0-9a-f]'
    res $? "base $B2 received, read-only with a received UUID"
    out=$(glassine-deploy stage "$B2" --yes 2>&1); rc=$?
    echo "$out" > /dev/console
    S=$(st staged)
    [ $rc = 0 ] && [ -n "$S" ]; res $? "glassine-deploy stage $B2: $S staged"
    echo "$out" | grep -q "replaying your packages.*add $PKG"; res $? "the stage replays $PKG"
    [ -e "$UD/$P/deployments/$S/build/etc/apk/world" ] && grep -qx "$PKG" "$UD/$P/deployments/$S/build/etc/apk/world"
    res $? "$PKG in the staged deployment's build layer (its world)"
    echo "$S" > "$Q/S"
    next 1
    user_off ;;
1)  S=$(cat "$Q/S")
    [ "$(st tries)" = 1 ]; res $? "$S is the candidate with 1 try left"
    come_up "$S" "$B2"
    accepted "$S"
    [ "$(st previous)" = d1 ]; res $? "previous: d1"
    services
    [ -z "$F2" ] || { [ -e "$F2" ]; res $? "the second base's file is there ($F2)"; }
    [ "$(cat /etc/hostname)" = qtest-carried ]; res $? "carried: /etc/hostname (migrate list)"
    [ ! -e /etc/qtest-junk ]; res $? "not carried: a file outside the migrate list"
    cmp -s /etc/machine-id "$Q/machine-id"; res $? "carried: the machine id"
    [ "$(grep '^qtest:' /etc/shadow | cut -d: -f2)" = "$(cat "$Q/pwhash")" ] && [ "$(id -u qtest 2>/dev/null)" = 1500 ]
    res $? "carried: account qtest, its uid and password"
    has_pkg; res $? "replayed: $PKG installed"
    added; res $? "glassine-deploy packages: $PKG added"
    echo own > /etc/qtest-s
    glassine-deploy rollback --yes > /dev/console 2>&1
    [ "$(st candidate)" = d1 ] && [ "$(st tries)" = 2 ]; res $? "rollback: d1 is the candidate (2 tries)"
    next 2
    off "rollback selected" ;;
2)  S=$(cat "$Q/S")
    come_up d1 "$B1"
    accepted d1
    [ "$(st previous)" = "$S" ]; res $? "previous: $S"
    services
    has_pkg; res $? "own state: $PKG (added live on d1)"
    [ ! -e /etc/qtest-s ]; res $? "own state: no file written on $S"
    [ -z "$F2" ] || { [ ! -e "$F2" ]; res $? "own base: the second base's file is not there"; }
    cmp -s /etc/machine-id "$Q/machine-id"; res $? "the machine id unchanged"
    out=$(glassine-deploy reset --yes 2>&1); rc=$?
    echo "$out" > /dev/console
    R=$(st staged)
    [ $rc = 0 ] && [ -n "$R" ]; res $? "glassine-deploy reset: $R staged"
    echo "$R" > "$Q/R"
    next 3
    user_off ;;
3)  R=$(cat "$Q/R")
    [ "$(st tries)" = 1 ]; res $? "$R is the candidate with 1 try left"
    come_up "$R" "$B1"
    [ "$(meta "$R" kind)" = reset ]; res $? "$R is a reset (kind=reset)"
    accepted "$R"
    services
    [ "$(cat /etc/hostname)" = qtest-carried ]; res $? "reset kept: /etc/hostname (migrate list)"
    cmp -s /etc/machine-id "$Q/machine-id"; res $? "reset kept: the machine id"
    [ "$(id -u qtest 2>/dev/null)" = 1500 ]; res $? "reset kept: account qtest"
    ! has_pkg; res $? "reset dropped: $PKG"
    ! added; res $? "glassine-deploy packages: nothing added"
    # a candidate that never reaches the boot-success step: its health check fails
    out=$(glassine-deploy reset --yes 2>&1); rc=$?
    echo "$out" > /dev/console
    F=$(st staged)
    [ $rc = 0 ] && [ -n "$F" ]; res $? "glassine-deploy reset: $F staged, to fail"
    echo "$F" > "$Q/fail"; sync
    next 4
    user_off ;;
4|5) F=$(cat "$Q/fail")
    come_up "$F" "$B1"
    t=$((5 - stage))
    [ "$(st tries)" = $t ]; res $? "$F is the candidate with $t tries left"
    not_accepted "$F"
    [ "$(st current)" = "$(cat "$Q/R")" ] && [ "$(st candidate)" = "$F" ]; res $? "nothing changed: current $(st current), candidate $(st candidate)"
    next $((stage + 1))
    off "try $((stage - 3)) of $F" ;;
6)  F=$(cat "$Q/fail") R=$(cat "$Q/R")
    come_up "$R" "$B1"
    [ "$(st current)" = "$R" ] && [ -z "$(st candidate)" ]; res $? "out of tries: current $R boots, no candidate"
    [ "$(st failed)" = "$F" ]; res $? "$F marked failed (state failed=$(st failed))"
    glassine-deploy list --porcelain | grep -q "^type=deployment${TAB}id=$F${TAB}state=failed"; res $? "glassine-deploy list: $F failed"
    services
    while [ "$(up)" -lt $((ACCEPT_AFTER + 20)) ]; do sleep 5; done
    ! dmesg | grep -q 'glassine-deploy-accept: .* not accepted'; res $? "the boot-success step leaves the current deployment alone"
    rm -f "$Q/fail"
    next finished
    say DONE
    off ;;
*)  say "FAIL unknown stage $stage"; off ;;
esac
