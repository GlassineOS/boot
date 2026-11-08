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
# the person's storage: a mount of userdata's directory NAME on PATH
bound() { awk -v p="$2" -v r="/$P/$1" '$5 == p && $4 == r { ok = 1 } END { exit !ok }' /proc/self/mountinfo; }
shared() { awk -v m="$1" '$5 == m { for (i = 7; $i != "-"; i++) if ($i ~ /^shared:/) s = 1 } END { exit !s }' /proc/self/mountinfo; }

# hibernate: the real hibernate step (glassine-hibernate); returns after the resume
hibernate() {
    [ -e "$SW" ] || glassine-hibernate setup 320 > /dev/console 2>&1
    chk "glassine-hibernate check: ready" "glassine-hibernate check > /dev/console 2>&1"
    say "hibernating"
    glassine-hibernate now > /dev/console 2>&1
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
    chk "/proc/mounts: /var read-write, as glassine-bootimg's health check reads it here" "awk '\$2 == \"/var\" && \$4 ~ /^rw(,|\$)/ {ok = 1} END {exit !ok}' /proc/mounts"
    chk "kernel-boot recorded, empty (no kernel trial)" "[ -e /run/glassine/kernel-boot ] && [ -z \"\$(cat /run/glassine/kernel-boot)\" ]"
    chk "modules subvolume on /lib/modules" "mountpoint -q /lib/modules/$(uname -r)"
    chk "the kernel's firmware on /lib/firmware/updates, read-only" "[ \"\$(cat /lib/firmware/updates/qtest/a.fw)\" = fw ] && grep -q ' /lib/firmware/updates [^ ]* ro[, ]' /proc/mounts"
    chk "state lock free for the system" "flock -n /run/glassine/system/state/.lock true"
    chk "storage: home/ and flatpak/ bound on /home and /var/lib/flatpak, /var/tmp shared" "bound home /home && bound flatpak /var/lib/flatpak && shared /var/tmp"
    chk "storage: d1's own /home hidden, status says so" "[ ! -e /home/own-file ] && [ \"\$(st home)\" = bound ] && [ \"\$(st home_hidden)\" = yes ] && [ \"\$(st flatpak)\" = bound ]"
    mkdir -p /home/1000 && echo mine > /home/1000/f && echo app > /var/lib/flatpak/app
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
    chk "storage after a reset: the same home and Flatpak data, nothing hidden" "bound home /home && [ \"\$(cat /home/1000/f)\" = mine ] && [ \"\$(cat /var/lib/flatpak/app)\" = app ] && [ \"\$(st home_hidden)\" = no ]"
    # the boot-success service accepts it once it has been up ACCEPT_AFTER (40 s) and healthy
    n=0; while [ "$(st current)" != "$S" ] && [ $n -lt 60 ]; do sleep 5; n=$((n + 1)); done
    chk "accepted by glassine-deploy-accept after a healthy boot" "dmesg | grep -q 'glassine-deploy-accept: $S accepted'"
    chk "accepted: current" "[ \"$(st current)\" = \"$S\" ] && [ \"$(st previous)\" = d1 ] && [ -z \"$(st candidate)\" ]"
    echo alive > /run/qtest-mem
    next 2
    hibernate
    chk "glassine-hibernate: guard removed after the resume" "[ ! -e $GUARD ]"
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
    # a full reset: nothing carried, home and Flatpak's data kept
    echo later > /home/1000/g
    glassine-deploy reset --full --yes > /dev/console 2>&1
    F=$(st staged)
    chk "full reset staged" "[ -n \"$F\" ]"
    echo "$F" > "$Q/full"
    glassine-switch-hook --user-shutdown
    next 4
    say "poweroff (user shutdown, full reset expected)"
    poweroff ;;
4)  # the full reset as the candidate: home and Flatpak's data are the same
    chk "the full reset boots as the candidate" "[ \"$booted\" = \"\$(cat $Q/full)\" ]"
    chk "full reset: nothing carried" "[ ! -e /etc/qtest/a ]"
    chk "storage after a full reset: the same home and Flatpak data" "bound home /home && bound flatpak /var/lib/flatpak && [ \"\$(cat /home/1000/f)\" = mine ] && [ \"\$(cat /home/1000/g)\" = later ] && [ \"\$(cat /var/lib/flatpak/app)\" = app ]"
    # the next boot can't make flatpak/: a file of that name on userdata
    mv $UD/$P/flatpak $UD/$P/flatpak.saved && echo notadir > $UD/$P/flatpak
    next 5
    poweroff ;;
5)  # a storage step that fails: logged, the deployment's own directory, the boot goes on
    chk "a failed flatpak/: logged, status says so, the deployment's own /var/lib/flatpak" "dmesg | grep -q '/var/lib/flatpak: cannot create flatpak/ on userdata' && [ \"\$(st flatpak)\" = failed ] && ! bound flatpak /var/lib/flatpak && [ ! -e /var/lib/flatpak/app ]"
    chk "a failed flatpak/: nothing written there, home still bound" "[ \"\$(cat $UD/$P/flatpak)\" = notadir ] && bound home /home && [ \"\$(st home)\" = bound ]"
    rm $UD/$P/flatpak && mv $UD/$P/flatpak.saved $UD/$P/flatpak
    next 6
    say DONE
    poweroff ;;
*)  say "FAIL unknown stage $stage"; poweroff ;;
esac
