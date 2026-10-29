#!/bin/sh
# The guest side of test/qemu: an OpenRC service of the base runs this once the
# system is up. It reads its stage from userdata (qtest/stage), checks, acts,
# writes the next stage and powers off or hibernates. Every result is a line
# "QTEST ok|FAIL <check>" on the console; the host greps them.
set -u
. /usr/lib/glassine-boot/glassine-state.sh
UD=/run/glassine/userdata
Q=$UD/qtest
P=media/glassine
SW=$UD/$P/swap/hibernate
GUARD=$UD/$P/swap/hibernate.guard
say() { echo "QTEST $*" > /dev/console; }
chk() { if eval "$2"; then say "ok $1"; else say "FAIL $1"; fi; }
next() { echo "$1" > "$Q/stage"; sync; }
booted=$(cat /run/glassine/booted 2>/dev/null)
st() { glassine-deploy status --porcelain | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }

# hibernate: the hibernate step's job (written here until it exists): swap file
# on userdata, the guard, the watchdog off, the image to the swap file
hibernate() {
    if [ ! -e "$SW" ]; then
        mkdir -p "${SW%/*}" && dd if=/dev/zero of="$SW" bs=1M count=320 2>/dev/null && chmod 600 "$SW" && mkswap "$SW" >/dev/null
    fi
    swapon "$SW" 2>/dev/null
    off=$(debugfs -R "bmap /$P/swap/hibernate 0" /dev/vda2 2>/dev/null | tail -n 1)
    echo "$off" > /sys/power/resume_offset && cat /sys/class/block/vda2/dev > /sys/power/resume
    { gs_guard_mounts /dev/vda2; echo "deployment=$booted"; echo "krel=$(uname -r)"; echo "kver=$(uname -v)"; } | gs_write "$GUARD"
    killall watchdog 2>/dev/null; sleep 1
    echo shutdown > /sys/power/disk
    say "hibernating (offset $off)"
    echo disk > /sys/power/state
    # here only after a resume (or a failed hibernate)
}

stage=$(cat "$Q/stage" 2>/dev/null || echo 0)
say "stage $stage booted=$booted"
case $stage in
0)  # the first boot: d1 current; then a reset, a change after it, a user shutdown
    chk "booted d1" "[ \"$booted\" = d1 ]"
    chk "OpenRC kept the initramfs's /run (booted still there)" "[ -n \"$booted\" ]"
    chk "carried mounts still there in the default runlevel" "mountpoint -q /run/glassine/system && mountpoint -q $UD"
    chk "/ is read-only" "! touch /usr/qtest 2>/dev/null"
    chk "/etc and /var are writable" "mkdir -p /etc/qtest && echo first > /etc/qtest/a && touch /var/qtest"
    chk "modules subvolume on /lib/modules" "mountpoint -q /lib/modules/$(uname -r)"
    chk "state lock free for the system" "flock -n /run/glassine/system/state/.lock true"
    glassine-deploy reset --yes > /dev/console 2>&1
    S=$(st staged)
    chk "reset staged" "[ -n \"$S\" ]"
    echo "$S" > "$Q/staged"
    echo late > /etc/qtest/b          # after the reset: must be carried
    echo junk > /etc/qtest-junk       # not on the migrate list: must not be
    glassine-switch-hook --user-shutdown
    next 1
    say "poweroff (user shutdown, switch expected)"
    poweroff ;;
1)  # the switched deployment as candidate; accept; then hibernate
    S=$(cat "$Q/staged")
    chk "the staged reset boots as the candidate" "[ \"$booted\" = \"$S\" ]"
    chk "tries used: 1 left" "[ \"$(st tries)\" = 1 ]"
    chk "carried: the edit made before the reset" "[ \"\$(cat /etc/qtest/a 2>/dev/null)\" = first ]"
    chk "carried: the change made after the reset" "[ \"\$(cat /etc/qtest/b 2>/dev/null)\" = late ]"
    chk "not carried: a file outside the migrate list" "[ ! -e /etc/qtest-junk ]"
    # the boot-success service accepts it once it has been up ACCEPT_AFTER (40 s) and healthy
    n=0; while [ "$(st current)" != "$S" ] && [ $n -lt 60 ]; do sleep 5; n=$((n + 1)); done
    chk "accepted by glassine-deploy-accept after a healthy boot" "dmesg | grep -q 'glassine-deploy-accept: $S accepted'"
    chk "accepted: current" "[ \"$(st current)\" = \"$S\" ] && [ \"$(st previous)\" = d1 ] && [ -z \"$(st candidate)\" ]"
    echo alive > /run/qtest-mem
    next 2
    hibernate
    chk "resumed: memory state kept" "[ \"\$(cat /run/qtest-mem 2>/dev/null)\" = alive ]"
    chk "resumed: image cancelled after the resume" "[ \"\$(gs_sig_file $SW)\" != S1SUSPEND ]"
    # once more, for a boot that must not resume (the host passes glassine.noresume)
    next 3
    hibernate
    say "FAIL resumed although glassine.noresume" ;;
2)  say "FAIL booted fresh instead of resuming" ;;
3)  # booted with glassine.noresume: the image must be gone, nothing resumed
    chk "noresume: memory state gone" "[ ! -e /run/qtest-mem ]"
    chk "noresume: the image was cancelled" "[ \"\$(gs_sig_file $SW)\" = SWAPSPACE2 ]"
    chk "noresume: the initramfs said why" "dmesg | grep -q 'not resumed: no resume on this boot (noresume)'"
    chk "noresume: the accepted deployment boots" "[ \"$booted\" = \"$(cat "$Q/staged")\" ]"
    sleep 50
    chk "accept step: nothing to judge on a boot of the current deployment" "! dmesg | grep -q 'glassine-deploy-accept: .* not accepted'"
    next 4
    say DONE
    poweroff ;;
*)  say "FAIL unknown stage $stage"; poweroff ;;
esac
