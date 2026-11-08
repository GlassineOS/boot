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
mkdir -p /run/qtest    # scratch (/tmp is on the read-only root)
st() { glassine-deploy status --porcelain | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }
# the person's storage: a mount of userdata's directory NAME on PATH
bound() { awk -v p="$2" -v r="/$P/$1" '$5 == p && $4 == r { ok = 1 } END { exit !ok }' /proc/self/mountinfo; }
shared() { awk -v m="$1" '$5 == m { for (i = 7; $i != "-"; i++) if ($i ~ /^shared:/) s = 1 } END { exit !s }' /proc/self/mountinfo; }

# device data: DEVICE_PART and the two source partitions (build.sh); the seed
# as the booted system sees it; the list put in every deployment's upper
# directory, whichever the next boot picks (the base has none: the stand-in
# for a root update that adds one), and in /run/qtest/list for this boot's runs
DP=/dev/vda3 SX=/dev/vda4 SV=/dev/vda5 DS=/run/glassine/device DM=/run/glassine/device-part
LIST=/usr/share/glassine/device-data.list
FWP=/sys/module/firmware_class/parameters/path
setlist() {
    printf 'format=1\n%s\n' "$1" > /run/qtest/list
    for _d in "$UD/$P"/deployments/*/switch; do mkdir -p "$_d${LIST%/*}" && cp /run/qtest/list "$_d$LIST"; done
    sync
}
seed() { glassine-device-seed "$@" > /run/qtest/seed.out 2>&1; }
said() { grep -q "$1" /run/qtest/seed.out; }
srcsum() { cat $SX $SV | sha256sum | cut -d' ' -f1; }
src_same() { [ "$(srcsum)" = "$(cat $Q/src.sum)" ]; }
# a source file on the unmounted ext4 source, read and replaced (the test's own write)
sx_cat() { debugfs -R "cat $1" $SX 2>/dev/null; }
sx_put() { debugfs -w -R "rm $2" $SX >/dev/null 2>&1; debugfs -w -R "write $1 $2" $SX >/dev/null 2>&1; srcsum > $Q/src.sum; sync; }
sv_cat() { mkdir -p /run/qtest/sv && mount -t vfat -o ro $SV /run/qtest/sv && cat "/run/qtest/sv$1"; umount /run/qtest/sv; }
# the seed's copy of NAME is the source's bytes
same_sx() { [ "$(sha256sum < $DS/$1)" = "$(sx_cat "$2" | sha256sum)" ]; }
complete() { glassine-device-seed status > /run/qtest/status.out 2>&1; }
bound_ro() { awk -v m=$DS '$2 == m && $4 ~ /^ro(,|$)/ { ok = 1 } END { exit !ok }' /proc/mounts; }
# DEVICE_PART written by the test (a damaged copy) on /run/qtest/dp: the seed unbound
# first, left unbound
dp_rw() { umount $DS 2>/dev/null; umount $DM 2>/dev/null; mkdir -p /run/qtest/dp && mount -t ext4 $DP /run/qtest/dp; }
dp_write() { dp_rw && sh -c "$1" && sync && umount /run/qtest/dp; }
wbf() {
    { printf 'WBF\0'; printf "\\$(printf %o $(($1 & 255)))\\$(printf %o $(($1 >> 8 & 255)))\\$(printf %o $(($1 >> 16 & 255)))\\$(printf %o $(($1 >> 24 & 255)))"
      head -c $(($1 - 8)) /dev/urandom; } > "$2"
}
# a power cut at a point of the seed write (the tool's test hook): sysrq power off, no sync
# cut_at BEFORE_MANIFEST|AFTER_MANIFEST LIST [ARGS]
# developer access: the board's DEVMODE_ADDR (build.sh), ssh without prompts
A=10.0.9.1 DMD=$UD/$P/devmode
sshq() { ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/run/qtest/kh -o ConnectTimeout=10 "$@"; }
cut_at() { echo 1 > /proc/sys/kernel/sysrq; _w=$1 _f=$2; shift 2
    env GLASSINE_SEED_TEST=1 "GLASSINE_SEED_$_w=echo o > /proc/sysrq-trigger; sleep 60" GLASSINE_SEED_LIST="$_f" glassine-device-seed "$@" > /dev/console 2>&1; }
L1='waveform.wbf srcext:/waveform/panel.wbf wbf
firmware/vendor/x-renamed.bin srcext:/fw/x.bin
firmware/vendor/dsp.* srcext:/image/dsp.*
firmware/board.bin srcvfat:/BOARD.BIN'

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
    chk "no developer access without glassine.devmode: no SSH or address server, no developer folder" "! pidof sshd >/dev/null && ! pidof udhcpd >/dev/null && ! netstat -ltn | grep -q ':22 ' && [ ! -e $UD/$P/devmode ]"
    chk "no device data (a root without a list): no device-data step in the log, DEVICE_PART untouched" "! dmesg | grep -q 'device data\|glassine-device' && [ ! -e $DM ] && [ \"\$(sha256sum < $DP | cut -d' ' -f1)\" = \"\$(cat $Q/devdata.sum)\" ]"
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
    # device data from the next boot on: a list names files (a pattern, a
    # rename, directories, a vfat source)
    setlist "$L1"
    next 6
    poweroff ;;
6)  # the first boot with a list: the initramfs finds no seed, the service fills it
    chk "device data: the initramfs found no seed yet" "dmesg | grep -q 'device data: no seed on $DP yet'"
    chk "device data: the service made the seed, complete, bound read-only" "complete && bound_ro && [ \$(grep -c ' ok ' /run/qtest/status.out) = 4 ]"
    chk "device data: a rename into a directory, the waveform" "same_sx firmware/vendor/x-renamed.bin /fw/x.bin && same_sx waveform.wbf /waveform/panel.wbf"
    chk "device data: the split image resolved, each part a line of the manifest" "same_sx firmware/vendor/dsp.mdt /image/dsp.mdt && same_sx firmware/vendor/dsp.b01 /image/dsp.b01 && [ \$(grep -c '^firmware/vendor/dsp\.' $DS/manifest) = 3 ] && [ ! -e $DS/firmware/vendor/dsp.b02 ]"
    chk "device data: the vfat source" "[ \"\$(sha256sum < $DS/firmware/board.bin)\" = \"\$(sv_cat /BOARD.BIN | sha256sum)\" ]"
    # the virt kernel builds the firmware loader without its path parameter: the
    # value is checked where it exists (test/root, test/seed check it on files)
    if [ -e $FWP ]; then
        chk "device data: the firmware path, without a newline" "[ \"\$(cat $FWP)\" = $DS/firmware ] && [ \$(wc -c < $FWP) = 30 ]"
    else
        chk "device data: no firmware path parameter in this kernel: said" "dmesg | grep -q 'glassine-device-seed: the firmware path could not be set'"
    fi
    chk "device data: DEVICE_PART's other files untouched; the sources read the same (SC-003)" "[ \"\$(cat $DM/other)\" = keep ] && src_same"
    chk "device data: glassine-hibernate refuses while DEVICE_PART is mounted read-write" "dp_rw && { glassine-hibernate check > /run/qtest/h.out 2>&1; r=\$?; umount /run/qtest/dp; [ \$r = 3 ] && grep -q 'devdata (the device seed.s partition' /run/qtest/h.out; }"
    # a damaged copy for the next boot
    dp_write "echo bad > /run/qtest/dp/glassine/firmware/board.bin"
    next 7
    poweroff ;;
7)  # a damaged copy: the initramfs binds nothing, the service repairs it
    chk "device data: a damaged copy: the initramfs bound nothing" "dmesg | grep -q \"device data: the seed on $DP doesn't verify: nothing bound\""
    chk "device data: the service copied it again, complete, bound" "complete && bound_ro && [ \"\$(sha256sum < $DS/firmware/board.bin)\" = \"\$(sv_cat /BOARD.BIN | sha256sum)\" ]"
    # a changed source: not taken without a refresh
    wbf 6144 /run/qtest/w2; sx_put /run/qtest/w2 /waveform/panel.wbf
    dp_write "echo bad > /run/qtest/dp/glassine/waveform.wbf"
    chk "device data: a changed source: left out, the rest verified and bound" "seed; [ \$? = 1 ] && said 'now gives other bytes' && [ ! -e $DS/waveform.wbf ] && bound_ro && [ -f $DS/firmware/board.bin ]"
    chk "device data: refresh --now takes the new bytes" "seed refresh --now && same_sx waveform.wbf /waveform/panel.wbf"
    # a source gone: the seed's copy stays
    sx_cat /fw/x.bin > /run/qtest/x.keep; debugfs -w -R 'rm /fw/x.bin' $SX >/dev/null 2>&1; srcsum > $Q/src.sum
    chk "device data: a source gone: said, the seed's copy stays, bound" "seed refresh --now; [ \$? = 1 ] && said 'could not be read' && said \"the seed's copy stays\" && [ \"\$(sha256sum < $DS/firmware/vendor/x-renamed.bin)\" = \"\$(sha256sum < /run/qtest/x.keep)\" ] && bound_ro"
    debugfs -w -R 'write /run/qtest/x.keep /fw/x.bin' $SX >/dev/null 2>&1; srcsum > $Q/src.sum; seed refresh --now
    chk "device data: the sources read as the test left them (SC-003)" "src_same"
    # a list grown by an update of the root; the fill cut off after the manifest's rename
    setlist "$L1
firmware/vendor/y.bin srcext:/fw/y.bin"
    next 8
    say "power cut after the seed manifest's rename"
    cut_at AFTER_MANIFEST /run/qtest/list
    say "FAIL no power cut" ;;
8)  # after the cut: the journal needs recovery or the new seed verifies; either way complete
    chk "device data: after a cut after the manifest's rename: complete with the grown list, no temp file" "complete && same_sx firmware/vendor/y.bin /fw/y.bin && ! find $DS -name '.*' | grep -q . && bound_ro"
    chk "device data: the initramfs bound it or left it to the service's journal replay" "dmesg | grep -q 'device data: seed bound on /run/glassine/device\|device data: the journal of $DP needs recovery'"
    M0=$(sha256sum < $DS/manifest)
    # a shorter list: what it no longer names stays, unread
    printf 'format=1\nwaveform.wbf srcext:/waveform/panel.wbf wbf\n' > /run/qtest/l3
    chk "device data: a shorter list: complete, the old files stay" "GLASSINE_SEED_LIST=/run/qtest/l3 glassine-device-seed > /run/qtest/seed.out 2>&1 && [ -f $DS/firmware/board.bin ] && bound_ro"
    chk "device data: a name the kernel's firmware provides: refused, named" "printf 'format=1\nfirmware/qtest/a.fw srcext:/fw/y.bin\n' > /run/qtest/l4; GLASSINE_SEED_LIST=/run/qtest/l4 glassine-device-seed > /run/qtest/seed.out 2>&1; [ \$? = 1 ] && said 'firmware/qtest/a.fw: the kernel .* provides firmware qtest/a.fw itself; refused' && [ ! -e $DS/firmware/qtest ]"
    head -c 50 /dev/urandom > /run/qtest/g; for p in mdt b00 b02; do debugfs -w -R "write /run/qtest/g /image/gap.$p" $SX >/dev/null 2>&1; done; srcsum > $Q/src.sum
    chk "device data: a split image with a gap: fails as a whole, adds nothing" "printf 'format=1\nfirmware/gap.* srcext:/image/gap.*\n' > /run/qtest/l5; GLASSINE_SEED_LIST=/run/qtest/l5 glassine-device-seed > /run/qtest/seed.out 2>&1; [ \$? = 1 ] && said 'have a gap' && ! ls $DS/firmware/gap.* 2>/dev/null"
    chk "device data: a source on DEVICE_PART: the list is invalid, nothing seeded" "printf 'format=1\nx devdata:/other\n' > /run/qtest/l6; GLASSINE_SEED_LIST=/run/qtest/l6 glassine-device-seed > /run/qtest/seed.out 2>&1; [ \$? = 2 ] && said 'invalid' && [ ! -e $DS/x ]"
    chk "device data: none of these changed the seed's manifest" "[ \"\$(sha256sum < $DS/manifest)\" = \"$M0\" ]"
    # a refresh with a changed source, cut off before the manifest's rename
    wbf 2048 /run/qtest/w3; sx_put /run/qtest/w3 /waveform/panel.wbf
    next 9
    say "power cut before the seed manifest's rename"
    cut_at BEFORE_MANIFEST $LIST refresh --now
    say "FAIL no power cut" ;;
9)  # the new file under the old manifest: never bound; the refresh is done again
    chk "device data: after a cut before the manifest's rename: the initramfs bound nothing" "dmesg | grep -q \"device data: the seed on $DP doesn't verify: nothing bound\|device data: the journal of $DP needs recovery\""
    chk "device data: the cut refresh done again at boot: complete, the new bytes, no temp file" "dmesg | grep -q 'refresh asked for' && complete && same_sx waveform.wbf /waveform/panel.wbf && ! find $DS -name '.*' | grep -q . && bound_ro"
    chk "device data: the sources read as the test left them (SC-003)" "src_same"
    # developer access from the next boot on (with glassine.devmode=usb): the
    # developer folder and a key, as an administrator puts them there
    mkdir -p $DMD && chmod 0700 $DMD
    ssh-keygen -q -t ed25519 -N '' -f $Q/devkey; ssh-keygen -q -t ed25519 -N '' -f $Q/otherkey
    cp $Q/devkey.pub $DMD/authorized_keys; sync
    next 10
    poweroff ;;
10) # glassine.devmode=usb: SSH on DEVMODE_ADDR with the developer folder's keys
    chk "devmode: the developer folder root:root 0700, the host key made there" "[ \"\$(stat -c '%u:%g %a' $DMD)\" = '0:0 700' ] && [ -s $DMD/ssh_host_ed25519_key ]"
    chk "devmode: running, the address on the interface, the address server up" "glassine-devmode status >/dev/null && ip addr show dm0 | grep -q 'inet $A/' && kill -0 \$(cat /run/glassine-devmode/udhcpd.pid)"
    chk "devmode: SSH listens on DEVMODE_ADDR:22 and nowhere else" "netstat -ltn | grep -q ' $A:22 ' && [ \$(netstat -ltn | grep -c ':22 ') = 1 ]"
    chk "devmode: SSH with the developer folder's key" "[ \"\$(sshq -i $Q/devkey root@$A echo in)\" = in ]"
    chk "devmode: refused with another key" "! sshq -i $Q/otherkey root@$A true 2>/dev/null"
    chk "devmode: refused with a password (only keys are offered)" "! sshq -o PubkeyAuthentication=no root@$A true > /run/qtest/pw 2>&1 && grep -q 'Permission denied (publickey)' /run/qtest/pw"
    ssh-keygen -l -f $DMD/ssh_host_ed25519_key.pub > $Q/hostkey.fp
    glassine-deploy reset --yes > /dev/console 2>&1
    st staged > $Q/staged2
    glassine-switch-hook --user-shutdown
    next 11
    poweroff ;;
11) # after a reset: the developer folder and its host key kept
    chk "devmode after a reset: the new deployment, the same host key" "[ \"$booted\" = \"\$(cat $Q/staged2)\" ] && [ \"\$(ssh-keygen -l -f $DMD/ssh_host_ed25519_key.pub)\" = \"\$(cat $Q/hostkey.fp)\" ]"
    chk "devmode after a reset: SSH with the key" "sshq -i $Q/devkey root@$A true"
    next 12
    say DONE
    poweroff ;;
*)  say "FAIL unknown stage $stage"; poweroff ;;
esac
