#!/bin/sh
# glassine-deploy init and the first start (glassine-first-start), see test.sh.
set -u
W=/w; mkdir -p $W && mount -t tmpfs -o size=900m tmpfs $W
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
. /p/lib/glassine-root.sh
export GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
P=media/glassine K=7.3.0
LOOPS=''
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1" && LOOPS="$LOOPS $LOOP"
}
R=$W/root RG=$W/root/run/glassine
# shellcheck disable=SC2034  # read by lib/glassine-root.sh
GR_TMP=$W/grtmp
sha() { sha256sum < "$1" | cut -d' ' -f1; }
uuid() { dumpe2fs -h "$1" 2>/dev/null | sed -n 's/^Filesystem UUID: *//p'; }

# --- glassine-deploy init ------------------------------------------------------
truncate -s 160M $W/p0.img; mkfs.btrfs -q $W/p0.img; loop $W/p0.img; L0=$LOOP
mkdir -p $W/plain $W/tmpfs $W/pool $W/sub
mount -t tmpfs tmpfs $W/tmpfs
ok "init: not a mount point: refused, nothing written" "! GLASSINE_DEPLOY_CONF=/dev/null $G init $W/plain 2>$W/err && grep -q 'not a mount point' $W/err && [ -z \"\$(ls -A $W/plain)\" ]"
ok "init: not btrfs: refused, nothing written" "! GLASSINE_DEPLOY_CONF=/dev/null $G init $W/tmpfs 2>$W/err && grep -q 'tmpfs, not btrfs' $W/err && [ -z \"\$(ls -A $W/tmpfs)\" ]"
mount -t btrfs $L0 $W/pool && btrfs -q subvolume create $W/pool/sv && mount -t btrfs -o subvol=sv $L0 $W/sub
ok "init: a subvolume, not the top level: refused" "! GLASSINE_DEPLOY_CONF=/dev/null $G init $W/sub 2>$W/err && grep -q 'not the top level' $W/err && [ -z \"\$(ls -A $W/sub)\" ]"
umount $W/sub
ok "init: a pool that is not empty: refused, untouched" "! GLASSINE_DEPLOY_CONF=/dev/null $G init $W/pool 2>$W/err && grep -q 'not empty' $W/err && [ \"\$(ls -A $W/pool)\" = sv ]"
btrfs -q subvolume delete $W/pool/sv
ok "init without the marker: bases/, modules/, state/ (format 1, deploy and kernel empty), no install" "GLASSINE_DEPLOY_CONF=/dev/null $G init $W/pool >/dev/null && [ -d $W/pool/bases ] && [ -d $W/pool/modules ] && [ \"\$(gs_format_version $W/pool)\" = 1 ] && [ -z \"\$(gs_kv $W/pool/state/deploy current)\$(gs_kv $W/pool/state/deploy candidate)\" ] && [ \"\$(gs_kv $W/pool/state/deploy tries)\" = 0 ] && [ -e $W/pool/state/kernel ] && [ -e $W/pool/state/.lock ] && [ ! -e $W/pool/state/install ]"
ok "init a second time: refused (not empty)" "! GLASSINE_DEPLOY_CONF=/dev/null $G init $W/pool 2>/dev/null"
umount $W/pool; mkfs.btrfs -q -f $L0; mount -t btrfs $L0 $W/pool
ok "init --install-marker: state/install (format=1)" "GLASSINE_DEPLOY_CONF=/dev/null $G init $W/pool --install-marker >/dev/null && [ \"\$(gs_kv $W/pool/state/install format)\" = 1 ] && [ -n \"\$(gs_kv $W/pool/state/install created)\" ]"
printf 'SYSTEM_MNT=%s\n' $W/pool > $W/pool.conf
ok "status reads the new pool: format 1, migrated, nothing selected" "GLASSINE_DEPLOY_CONF=$W/pool.conf GLASSINE_DEPLOY_FAKE_MOUNTS=1 $G status --porcelain 2>/dev/null | sed -n 2p | grep -q '	format=1	supported=1	system_fs=btrfs	migrated=yes	current=	previous=	candidate=	staged=	failed=	tries=0	'"
umount $W/pool; losetup -d $L0; rm -f $W/p0.img

# --- the installed state: a pool image made as an image builder does ----------
# mkpool [--install-marker]: a 160 MiB pool (init, a base, modules/$K), in a
# partition of 320 MiB (the file grown, the loop device's size read again)
mkpool() {
    [ -z "${SD:-}" ] || losetup -d "$SD"
    rm -f $W/sys.img; truncate -s 160M $W/sys.img; mkfs.btrfs -q $W/sys.img; loop $W/sys.img; SD=$LOOP
    mount -t btrfs "$SD" $W/pool || return 1
    GLASSINE_DEPLOY_CONF=/dev/null $G init $W/pool "$@" >/dev/null || return 1
    btrfs -q subvolume create $W/pool/bases/b1
    B=$W/pool/bases/b1
    mkdir -p $B/etc $B/usr/bin $B/var/tmp $B/lib/modules $B/run
    echo 'root:x:0:0:root:/root:/bin/sh' > $B/etc/passwd; echo 'root:x:0:root' > $B/etc/group
    echo welcome > $B/etc/motd
    btrfs property set -ts $B ro true
    btrfs -q subvolume create $W/pool/modules/$K; echo ko > $W/pool/modules/$K/x.ko; btrfs property set -ts $W/pool/modules/$K ro true
    umount $W/pool
    truncate -s 320M $W/sys.img; losetup -c "$SD"
}
# mkud stock|garbage: userdata as the installer leaves it: another system's
# ext4 with its files, or bytes that are no file system
mkud() {
    [ -z "${UDEV:-}" ] || losetup -d "$UDEV"
    rm -f $W/ud.img; truncate -s 96M $W/ud.img
    if [ "$1" = stock ]; then
        mke2fs -q -F -t ext4 -b 4096 $W/ud.img && debugfs -w -R "write /etc/hostname android.txt" $W/ud.img >/dev/null 2>&1
    else
        dd if=/dev/urandom of=$W/ud.img bs=1M count=4 conv=notrunc 2>/dev/null
    fi
    loop $W/ud.img; UDEV=$LOOP
}
has_android() { debugfs -R "stat /android.txt" "$UDEV" 2>/dev/null | grep -q '^Inode:'; }
cat > $W/deploy.conf <<CONF
SYSTEM_MNT=$RG/system
USERDATA_MNT=$RG/userdata
USERDATA_PREFIX=$P
RUN_DIR=$RG
CONF
conf() { sed -i '/^SYSTEM_DEV=\|^USERDATA_DEV=\|^USERDATA_RESERVE_KIB=/d' $W/deploy.conf; printf 'SYSTEM_DEV=%s\nUSERDATA_DEV=%s\nUSERDATA_RESERVE_KIB=%s\n' "$SD" "$UDEV" "${RESERVE:-0}" >> $W/deploy.conf; }
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY=$G GLASSINE_FIRST_START_KREL=$K
printf '#!/bin/sh\necho reboot >> %s/reboots\n' $W > $W/reboot; chmod +x $W/reboot
export GLASSINE_FIRST_START_REBOOT=$W/reboot
# boot / down: the initramfs's steps (gr_boot, gr_carry), and a power-off
boot() { gr_boot "$SD" "$UDEV" "$P" "$R" "$K" 2>>$W/blog && gr_carry "$R"; }
down() { gr_boot_umount "$R"; }
fs() { rm -f $W/reboots; sh /p/sbin/glassine-first-start > $W/fsout 2>&1; }
rebooted() { [ -s $W/reboots ]; }
booted() { cat $RG/booted; }
st() { gs_kv $RG/system/state/deploy "$1"; }
pool_kib() { df -Pk $RG/system | awk 'NR == 2 { print $2 }'; }

# --- the first start, uninterrupted ---------------------------------------------
mkpool --install-marker; mkud stock; conf
U0=$(uuid "$UDEV")
ok "first boot: bare (no deployment), the stock userdata mounted by the initramfs" "boot && [ \"\$(booted)\" = bare:b1 ] && mountpoint -q $RG/userdata && [ -e $RG/system/state/install ]"
K0=$(pool_kib)
ok "first start: done, rebooted" "fs && rebooted"
ok "the marker is gone" "[ ! -e $RG/system/state/install ]"
CAND=$(st candidate)
ok "a candidate with 2 tries, nothing staged, no current" "[ -n \"$CAND\" ] && [ \"\$(st tries)\" = 2 ] && [ -z \"\$(st staged)\$(st current)\" ]"
ok "the kernel's release recorded" "[ \"\$(gs_kv $RG/system/state/kernel current)\" = $K ]"
ok "the pool grew to its partition" "[ \$(pool_kib) -gt \$((K0 + 100000)) ]"
ok "userdata formatted: a new ext4, 4096-byte blocks, the stock files gone, not mounted any more" "[ \"\$(uuid $UDEV)\" != \"$U0\" ] && ! has_android && dumpe2fs -h $UDEV 2>/dev/null | grep -q '^Block size: *4096' && ! mountpoint -q $RG/userdata"
ok "the deployment: base b1, kind=install, carry=none" "[ \"\$(debugfs -R 'cat /$P/deployments/$CAND/meta' $UDEV 2>/dev/null | sed -n 's/^base=//p')\" = b1 ] && debugfs -R 'cat /$P/deployments/$CAND/meta' $UDEV 2>/dev/null | grep -qx kind=install && debugfs -R 'cat /$P/deployments/$CAND/meta' $UDEV 2>/dev/null | grep -qx carry=none"
ok "logged" "grep -q 'first deployment $CAND selected (base b1); rebooting' $W/fsout"
down
ok "the next boot: the candidate" "boot && [ \"\$(booted)\" = $CAND ] && [ \"\$(cat $R/etc/motd)\" = welcome ]"
ok "the first start on it: nothing (no marker), no reboot" "fs && ! rebooted && [ ! -s $W/fsout ]"
ok "the accept makes it current" "$G accept $CAND >/dev/null && [ \"\$(st current)\" = $CAND ] && [ -z \"\$(st candidate)\" ]"
down

# --- no marker: nothing at all --------------------------------------------------
mkpool; mkud stock; conf
mkdir -p $RG/system && mount -t btrfs "$SD" $RG/system && echo bare:b1 > $RG/booted
H0=$(sha $W/ud.img) D0=$(sha $RG/system/state/deploy) K0=$(pool_kib)
ok "no marker: exit 0, userdata byte for byte the same, state the same, the pool not grown, no reboot" "fs && [ \"\$(sha $W/ud.img)\" = $H0 ] && [ \"\$(sha $RG/system/state/deploy)\" = $D0 ] && [ \$(pool_kib) = $K0 ] && ! rebooted && [ ! -s $W/fsout ]"
umount $RG/system; rm -f $RG/booted

# --- the marker on a deployment's boot with nothing selected: refused -------------
mkpool --install-marker; mkud stock; conf
mount -t btrfs "$SD" $RG/system && echo d9 > $RG/booted
H0=$(sha $W/ud.img)
ok "marker on a deployment boot, nothing selected: refused (exit 1), userdata untouched, marker kept" "! fs && grep -q 'refused' $W/fsout && [ \"\$(sha $W/ud.img)\" = $H0 ] && [ -e $RG/system/state/install ] && ! rebooted"
umount $RG/system; rm -f $RG/booted

# --- userdata that does not unmount: not formatted -------------------------------
mkpool --install-marker; mkud stock; conf; boot
U0=$(uuid "$UDEV")
exec 7<"$RG/userdata/android.txt"
ok "userdata in use (a file open on it): exit 1, not formatted (same UUID, the stock file there), marker kept, no reboot" "! fs && grep -q 'does not unmount' $W/fsout && [ \"\$(uuid $UDEV)\" = \"$U0\" ] && [ -e $RG/userdata/android.txt ] && [ -e $RG/system/state/install ] && [ -z \"\$(st candidate)\" ] && ! rebooted"
exec 7<&-
down

# --- two bases: refused before any write -------------------------------------------
mkpool --install-marker; mkud stock; conf
mount -t btrfs "$SD" $W/pool && btrfs -q subvolume snapshot -r $W/pool/bases/b1 $W/pool/bases/b2 >/dev/null && umount $W/pool
boot
H0=$(sha $W/ud.img) K0=$(pool_kib)
ok "two bases: refused (exit 1), the pool not grown, userdata untouched, marker kept" "! fs && grep -q 'more than one base' $W/fsout && [ \$(pool_kib) = $K0 ] && [ -e $RG/userdata/android.txt ] && [ -e $RG/system/state/install ] && ! rebooted"
down

# --- a garbage userdata, a reserve at its end -----------------------------------
mkpool --install-marker; mkud garbage; RESERVE=16 conf
ok "garbage userdata: bare boot, nothing mounted from it" "boot && [ \"\$(booted)\" = bare:b1 ] && ! mountpoint -q $RG/userdata"
ok "first start: formatted, selected, rebooted" "fs && rebooted && [ -n \"\$(st candidate)\" ] && [ ! -e $RG/system/state/install ]"
# shellcheck disable=SC2034  # read in the eval of ok()
SZ=$(stat -c %s $W/ud.img)
ok "userdata has no orphan_file (an older e2fsck refuses it)" "! dumpe2fs -h $UDEV 2>/dev/null | grep '^Filesystem features:' | grep -qw orphan_file"
ok "USERDATA_RESERVE_KIB=16: the file system ends 16 KiB before the partition" "[ \"\$(dumpe2fs -h $UDEV 2>/dev/null | sed -n 's/^Block count: *//p')\" = \$(( (SZ / 1024 - 16) / 4 )) ]"
down
conf

# --- a power cut after each step, then the next boot ---------------------------
# cut STEP: the first start killed right after STEP (no clean-up), the device off
cut() {
    mkpool --install-marker; mkud stock; conf
    boot || return 1
    rm -f $W/reboots
    { ( export GLASSINE_FIRST_START_TEST=1 "GLASSINE_FIRST_START_AFTER_$1=kill -9 \$\$"; exec sh /p/sbin/glassine-first-start ) > $W/fsout 2>&1; } 2>/dev/null
    [ $? = 137 ] || { echo "     (the first start was not cut after $1)"; return 1; }
    UC=$(uuid "$UDEV")
    down; return 0
}
for step in KERNEL GROW FORMAT; do
    ok "cut after $step" "cut $step && ! rebooted"
    ok "  next boot: bare again, the first start runs from the top and finishes" "boot && [ \"\$(booted)\" = bare:b1 ] && fs && rebooted && [ ! -e $RG/system/state/install ] && [ -n \"\$(st candidate)\" ] && [ \"\$(st tries)\" = 2 ] && [ \"\$(gs_kv $RG/system/state/kernel current)\" = $K ]"
    case $step in FORMAT)
        ok "  userdata not formatted a second time (the recorded UUID)" "[ \"\$(uuid $UDEV)\" = \"$UC\" ] && grep -q 'formatted already' $W/fsout" ;;
    esac
    C=$(st candidate)
    down
    ok "  then the candidate boots" "boot && [ \"\$(booted)\" = $C ]"
    down
done
ok "cut after STAGE (selected, marker still there)" "cut STAGE && ! rebooted"
ok "  next boot: the candidate, with the marker" "boot && [ \"\$(booted)\" = \"\$(st candidate)\" ] && [ -e $RG/system/state/install ]"
echo kept > $RG/userdata/$P/sentinel
ok "  the first start only removes the marker: no format (the file on userdata kept, same UUID), no reboot" "fs && ! rebooted && [ ! -e $RG/system/state/install ] && [ \"\$(cat $RG/userdata/$P/sentinel)\" = kept ] && [ \"\$(uuid $UDEV)\" = \"$UC\" ] && grep -q 'selected already' $W/fsout"
down
ok "cut after CLEAR (before the reboot)" "cut CLEAR && ! rebooted"
ok "  next boot: the candidate, no marker; the first start does nothing" "boot && [ \"\$(booted)\" = \"\$(st candidate)\" ] && [ ! -e $RG/system/state/install ] && fs && ! rebooted && [ ! -s $W/fsout ]"
down

ok "a bare boot while a candidate is selected and the marker is there: the marker removed, a reboot, no format" "cut STAGE >/dev/null 2>&1 && UC=\$(uuid $UDEV) && mount -t btrfs $SD $RG/system && echo bare:b1 > $RG/booted && fs && rebooted && [ ! -e $RG/system/state/install ] && [ \"\$(uuid $UDEV)\" = \"\$UC\" ] && grep -q 'rebooting into it' $W/fsout"
umount $RG/system; rm -f $RG/booted

# --- a step that fails half way ----------------------------------------------------
# mke2fs that formats, then fails (cut before the UUID is recorded)
mkdir -p $W/bin
printf '#!/bin/sh\n/sbin/mke2fs "$@"\nexit 1\n' > $W/bin/mke2fs; chmod +x $W/bin/mke2fs
mkpool --install-marker; mkud stock; conf; boot
ok "mke2fs fails: exit 1, no UUID recorded, nothing selected, no reboot" "! PATH=$W/bin:\$PATH fs && [ -z \"\$(gs_kv $RG/system/state/install userdata)\" ] && [ -z \"\$(st candidate)\" ] && ! rebooted"
UC=$(uuid "$UDEV")
down
ok "  the next boot formats again and finishes" "boot && fs && rebooted && [ \"\$(uuid $UDEV)\" != \"$UC\" ] && [ -n \"\$(st candidate)\" ]"
down
# a stage cut between staged and selected
printf '#!/bin/sh\n[ "$1" = stage ] || exec %s "$@"\n%s stage "$2" --no-replay --yes\nexit 1\n' $G $G > $W/bin/deploy-cut; chmod +x $W/bin/deploy-cut
mkpool --install-marker; mkud stock; conf; boot
ok "the stage cut before the switch: exit 1, staged, nothing selected, marker kept" "! GLASSINE_DEPLOY=$W/bin/deploy-cut fs && [ -n \"\$(st staged)\" ] && [ -z \"\$(st candidate)\" ] && [ -e $RG/system/state/install ]"
S1=$(st staged)
down
ok "  the next boot: staged again and selected; the cut one removed" "boot && [ \"\$(booted)\" = bare:b1 ] && fs && rebooted && [ -n \"\$(st candidate)\" ] && [ \"\$(st candidate)\" != \"$S1\" ] && [ -z \"\$(st staged)\" ] && [ \"\$(debugfs -R 'ls -p /$P/deployments' $UDEV 2>/dev/null | awk -F/ 'NF > 6 && \$6 != \".\" && \$6 != \"..\"' | wc -l)\" = 1 ]"
down

# --- stage with no current, outside the first start --------------------------------
mkpool; mkud stock; conf; boot
ok "stage with no current deployment and a replay: refused, nothing staged" "! $G stage b1 --yes 2>$W/err && grep -q 'no current deployment to replay' $W/err && [ -z \"\$(st staged)\" ]"
umount $RG/userdata
ok "stage --no-replay with no current: the first deployment staged (kind=install, carry=none)" "$G stage b1 --no-replay --yes >/dev/null && ID=\$(st staged) && [ -n \"\$ID\" ] && debugfs -R \"cat /$P/deployments/\$ID/meta\" $UDEV 2>/dev/null | grep -qx kind=install"
ok "switch selects it (nothing carried)" "$G switch >/dev/null && [ \"\$(st candidate)\" = \"\$ID\" ] && [ \"\$(st tries)\" = 2 ]"
down

for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
cd /; umount $W 2>/dev/null
[ $fails = 0 ] && echo "all checks passed" || { echo "$fails check(s) FAILED"; exit 1; }
