#!/bin/sh
set -u
W=/w; mkdir -p $W && mount -t tmpfs -o size=640m tmpfs $W
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
. /p/lib/glassine-root.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
P=media/glassine
LOOPS=''
# loop FILE: attach it, LOOP = the device. A loop device the kernel creates after
# the container started has no node in its /dev (a copy of the host's): make it.
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1" && LOOPS="$LOOPS $LOOP"
}
finish() {
    gr_boot_umount $W/root 2>/dev/null
    umount $W/udmnt $W/sysmnt 2>/dev/null
    for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
    cd /; umount $W 2>/dev/null
}
# (no EXIT trap: this busybox ash runs it in every $(...) subshell too)

# --- the partitions ----------------------------------------------------------
truncate -s 256M $W/sys.img; mkfs.btrfs -q $W/sys.img
truncate -s 160M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 $W/ud.img
loop $W/sys.img; SD=$LOOP; loop $W/ud.img; UDEV=$LOOP
mkdir -p $W/sysmnt $W/udmnt
mount -t btrfs "$SD" $W/sysmnt && mount -t ext4 "$UDEV" $W/udmnt || { echo "FAIL cannot mount the loop devices"; finish; exit 1; }
S=$W/sysmnt
mkdir -p $S/bases $S/modules $S/state
btrfs -q subvolume create $S/bases/b1
B=$S/bases/b1
mkdir -p $B/etc/apk $B/etc/na1 $B/usr/bin $B/usr/local $B/opt $B/var/lib $B/lib/modules/7.3.0 $B/usr/share/glassine
echo alpine-base > $B/etc/apk/world
echo glassine > $B/etc/hostname
echo welcome > $B/etc/motd
echo '@stagger_ctl=3' > $B/etc/na1/eink.conf
echo 'root:x:0:0:root:/root:/bin/sh' > $B/etc/passwd
printf '#!/bin/sh\necho hello\n' > $B/usr/bin/hello; chmod 755 $B/usr/bin/hello
printf '# shipped\n/etc/na1/\n/etc/hostname\n/etc/passwd\n/var/lib/bluetooth/\n../escape\nrelative/path\n' > $B/usr/share/glassine/migrate.list
btrfs property set -ts $B ro true
btrfs -q subvolume create $S/modules/7.3.0
mkdir -p $S/modules/7.3.0/kernel; echo ko > $S/modules/7.3.0/kernel/x.ko
btrfs property set -ts $S/modules/7.3.0 ro true
echo version=1 > $S/state/format
printf 'current=d1\nprevious=\ncandidate=\ntries=0\n' > $S/state/deploy
U=$W/udmnt/$P
mkdir -p $U/deployments/d1/build $U/deployments/d1/switch $U/deployments/d1/work
printf 'base=b1\nkind=install\n' > $U/deployments/d1/meta
basesum() { find $B -print0 | sort -z | xargs -0 ls -ld --full-time 2>/dev/null | md5sum; find $B -type f -exec cat {} + | md5sum; }
SUM0=$(basesum)
R=$W/root
ro() { ! sh -c "echo x > $1" 2>/dev/null; }

# --- a deployment's root, locked ---------------------------------------------
ok "gr_assemble d1" "gr_assemble $S $U d1 $R 7.3.0"
ok "/ is read-only: /usr, a new file in /" "ro $R/usr/bin/new && ro $R/newfile"
ok "/etc, /var, /usr/local, /opt are writable" "echo edited > $R/etc/na1/eink.conf && echo myhost > $R/etc/hostname && mkdir -p $R/var/lib/bluetooth && echo pair > $R/var/lib/bluetooth/k && echo l > $R/usr/local/x && echo o > $R/opt/y"
ok "the writes go through the overlay: copy-up into d1's switch layer" "[ \"\$(cat $U/deployments/d1/switch/etc/na1/eink.conf)\" = edited ] && [ -e $U/deployments/d1/switch/usr/local/x ]"
rm $R/etc/motd
ok "a deletion in /etc: a whiteout in the switch layer, the base keeps the file" "[ ! -e $R/etc/motd ] && [ -c $U/deployments/d1/switch/etc/motd ] && [ \"\$(cat $B/etc/motd)\" = welcome ]"
ok "rename-replace in /etc works (passwd-style)" "echo 'root:x:0:0:root:/root:/bin/ash' > $R/etc/passwd.new && mv $R/etc/passwd.new $R/etc/passwd && grep -q ash $R/etc/passwd"
ok "modules: on /lib/modules/7.3.0, read-only" "[ \"\$(cat $R/lib/modules/7.3.0/kernel/x.ko)\" = ko ] && ro $R/lib/modules/7.3.0/kernel/y.ko"
ok "unlock: / writable" "gr_unlock $R && echo new > $R/usr/bin/new && [ -e $U/deployments/d1/switch/usr/bin/new ]"
ok "lock: / read-only again" "gr_lock $R && ro $R/usr/bin/new2"
ok "the base is unchanged" "[ \"\$(basesum)\" = \"\$SUM0\" ]"
gr_umount $R
ok "gr_umount: nothing left mounted" "! grep -q \" $R\" /proc/mounts"
ok "persistence: reassembled, edits still there" "gr_assemble $S $U d1 $R 7.3.0 && [ \"\$(cat $R/etc/na1/eink.conf)\" = edited ] && [ ! -e $R/etc/motd ] && [ -e $R/usr/bin/new ] && ro $R/usr/bin/x"
gr_umount $R
ok "a kernel without modules: boots, says so" "gr_assemble $S $U d1 $R 9.9.9 2>$W/err && grep -q 'no modules for 9.9.9' $W/err && [ -z \"\$(ls $R/lib/modules/7.3.0)\" ]"
gr_umount $R
ok "a deployment whose base is missing: refused, nothing mounted" "mkdir -p $U/deployments/dx && echo base=gone > $U/deployments/dx/meta && ! gr_assemble $S $U dx $R 2>/dev/null && ! grep -q \" $R\" /proc/mounts"
rm -rf $U/deployments/dx

# --- no userdata: the base + a tmpfs upper ---------------------------------------
ok "gr_assemble_bare: the base, writable /etc" "gr_assemble_bare $S b1 $R && [ \"\$(cat $R/etc/motd)\" = welcome ] && echo t > $R/etc/motd && ro $R/usr/bin/z"
gr_umount $R
ok "bare: nothing kept, base unchanged" "[ \"\$(basesum)\" = \"\$SUM0\" ] && gr_assemble_bare $S b1 $R && [ \"\$(cat $R/etc/motd)\" = welcome ]"
gr_umount $R

# --- gr_pick --------------------------------------------------------------------
cp $S/state/deploy $W/st0
ok "gr_pick, no candidate: current" "[ \"\$(gr_pick $S/state)\" = d1 ] && cmp -s $S/state/deploy $W/st0"
gs_update $S/state/deploy current= previous=d0
ok "gr_pick, no current: previous" "[ \"\$(gr_pick $S/state)\" = d0 ]"
cp $W/st0 $S/state/deploy

# --- reset (the tool, on the real mounts) ---------------------------------------
cat > $W/deploy.conf <<CONF
SYSTEM_DEV=$SD
SYSTEM_MNT=$S
USERDATA_DEV=$UDEV
USERDATA_MNT=$W/udmnt
USERDATA_PREFIX=$P
RUN_DIR=$W/run
CONF
mkdir -p $W/run
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh
st() { gs_kv $S/state/deploy "$1"; }
ok "status sees the btrfs system" "$G status --porcelain | grep -q 'system_fs=btrfs	migrated=yes	current=d1'"
gr_assemble $S $U d1 $R && mkdir -p $R/etc/wireguard $R/etc/glassine/migrate.d && echo wg > $R/etc/wireguard/wg0.conf && chmod 700 $R/etc/wireguard &&
    echo /etc/wireguard/ > $R/etc/glassine/migrate.d/user.list && echo junk > $R/etc/junk && gr_umount $R
ok "reset without --yes, no terminal: refused, nothing built" "$G reset 2>/dev/null </dev/null; [ \$? = 1 ] && [ \$(ls $U/deployments | wc -l) = 1 ] && cmp -s $S/state/deploy $W/st0"
ok "reset --yes: staged, not selected" "$G reset --yes >/dev/null && [ -n \"\$(st staged)\" ] && [ -z \"\$(st candidate)\" ] && [ \"\$(st current)\" = d1 ]"
N=$(st staged); NS=$U/deployments/$N/switch
ok "reset: meta = base b1, kind reset, carry migrate, from d1; layers empty" "grep -qx base=b1 $U/deployments/$N/meta && grep -qx kind=reset $U/deployments/$N/meta && grep -qx carry=migrate $U/deployments/$N/meta && grep -qx from=d1 $U/deployments/$N/meta && [ -z \"\$(ls -A $U/deployments/$N/build)\" ] && [ -z \"\$(ls -A $NS)\" ]"
ok "list + status: staged" "$G list --porcelain | grep -q \"id=$N	state=staged\" && $G status --porcelain | grep -q \"staged=$N\""
ok "gr_pick ignores a staged deployment" "[ \"\$(gr_pick $S/state)\" = d1 ]"
# a change after the reset, before the shutdown: must be carried (option a)
gr_assemble $S $U d1 $R && echo later > $R/etc/na1/eink.conf && gr_umount $R
mkdir -p $W/shim; printf '#!/bin/sh\nexit 1\n' > $W/shim/cp; chmod +x $W/shim/cp
echo leftover > $NS/leftover; cp $S/state/deploy $W/stS
ok "an interrupted switch (cut copy): exit 1, still staged, nothing selected, marker gone, nothing mounted" "PATH=$W/shim:\$PATH $G switch 2>/dev/null; [ \$? = 1 ] && cmp -s $S/state/deploy $W/stS && [ ! -e $W/run/switching ] && ! grep -q '$W/run' /proc/mounts"
: > $W/run/switching
ok "switch: a stale marker does not block it; redone from scratch; selected with 2 tries" "$G switch >/dev/null 2>&1 && [ \"\$(st candidate)\" = $N ] && [ \"\$(st tries)\" = 2 ] && [ -z \"\$(st staged)\" ] && [ ! -e $NS/leftover ] && [ ! -e $W/run/switching ]"
ok "switch carries the migrate list (shipped + the user's), with the change made after the reset" "[ \"\$(cat $NS/etc/na1/eink.conf)\" = later ] && [ \"\$(cat $NS/etc/hostname)\" = myhost ] && [ -e $NS/var/lib/bluetooth/k ] && [ -e $NS/etc/wireguard/wg0.conf ] && grep -q ash $NS/etc/passwd"
ok "switch keeps modes (0700 wireguard)" "[ \$(stat -c %a $NS/etc/wireguard) = 700 ]"
ok "switch drops the rest (edits, packages, /usr/local, whiteouts)" "[ ! -e $NS/etc/junk ] && [ ! -e $NS/usr/bin/new ] && [ ! -e $NS/usr/local/x ] && [ ! -e $NS/etc/motd ] && [ ! -e $NS/escape ]"
ok "switch left nothing mounted" "! grep -q '$W/run' /proc/mounts"
ok "switch with nothing staged: exit 0" "$G switch >/dev/null"
ok "gr_pick: the candidate, tries 2 -> 1" "[ \"\$(gr_pick $S/state)\" = $N ] && [ \"\$(st tries)\" = 1 ]"
ok "the candidate's root: carried state, base files back, user edits gone" "gr_assemble $S $U $N $R && [ \"\$(cat $R/etc/na1/eink.conf)\" = later ] && [ \"\$(cat $R/etc/motd)\" = welcome ] && [ ! -e $R/usr/bin/new ] && [ ! -e $R/etc/junk ]"
gr_umount $R
ok "list: the candidate" "$G list --porcelain | grep -q \"id=$N	state=candidate\""
ok "gr_pick: tries 1 -> 0, still the candidate" "[ \"\$(gr_pick $S/state)\" = $N ] && [ \"\$(st tries)\" = 0 ]"
ok "gr_pick: no tries left -> failed, current boots" "[ \"\$(gr_pick $S/state)\" = d1 ] && [ -z \"\$(st candidate)\" ] && [ \"\$(st failed)\" = $N ]"
ok "list: failed" "$G list --porcelain | grep -q \"id=$N	state=failed\""
ok "accept of a non-candidate: refused" "$G accept $N 2>/dev/null; [ \$? = 1 ] && [ \"\$(st current)\" = d1 ]"
$G select $N >/dev/null
ok "accept the candidate: current, previous = d1" "$G accept $N >/dev/null && [ \"\$(st current)\" = $N ] && [ \"\$(st previous)\" = d1 ] && [ -z \"\$(st candidate)\" ]"
ok "accept of the current one: no-op" "$G accept $N >/dev/null && [ \"\$(st current)\" = $N ]"
ok "rollback: back to d1 as the candidate" "$G rollback >/dev/null && [ \"\$(st candidate)\" = d1 ]"
$G select $N >/dev/null

# --- reset --full, reset --now, replacing a staged one ----------------------------
ok "reset --full --now: selected at once, nothing carried" "$G reset --full --now --yes >/dev/null && F=\$(st candidate) && [ \"\$F\" != $N ] && [ -z \"\$(ls -A $U/deployments/\$F/build)\" ] && [ -z \"\$(ls -A $U/deployments/\$F/switch)\" ] && grep -qx kind=reset-full $U/deployments/\$F/meta && [ -z \"\$(st staged)\" ]"
$G select $N >/dev/null
$G reset --yes >/dev/null; A1=$(st staged); sleep 1; $G reset --full --yes >/dev/null; A2=$(st staged)
ok "a second reset replaces the staged one (the old one is removed)" "[ \"\$A1\" != \"\$A2\" ] && [ ! -e $U/deployments/\$A1 ] && grep -qx carry=none $U/deployments/\$A2/meta"
gs_update $S/state/deploy staged=; rm -rf $U/deployments/$A2

# --- failures leave nothing behind -------------------------------------------------
cp $S/state/deploy $W/st1; n0=$(ls $U/deployments | wc -l)
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > $W/shim/dd; chmod +x $W/shim/dd
ok "reset: a cut meta write: exit 1, no half-built deployment, state unchanged" "PATH=$W/shim:\$PATH $G reset --yes 2>/dev/null; [ \$? = 1 ] && [ \$(ls $U/deployments | wc -l) = $n0 ] && cmp -s $S/state/deploy $W/st1"
rm $W/shim/dd
mkdir -p $U/deployments/$N/switch/var/lib/bluetooth; dd if=/dev/zero of=$U/deployments/$N/switch/var/lib/bluetooth/big bs=1M count=24 2>/dev/null
$G reset --yes >/dev/null; A3=$(st staged); cp $S/state/deploy $W/st2
dd if=/dev/zero of=$W/udmnt/fill bs=1M count=$(( $(df -Pk $W/udmnt | awk 'NR==2{print $4}') / 1024 - 10 )) 2>/dev/null
ok "switch, not enough space: exit 5, stays staged, nothing selected" "$G switch 2>/dev/null; [ \$? = 5 ] && cmp -s $S/state/deploy $W/st2 && [ \"\$(st staged)\" = \$A3 ]"
rm -f $W/udmnt/fill $U/deployments/$N/switch/var/lib/bluetooth/big
gs_update $S/state/deploy staged=; rm -rf $U/deployments/$A3

# --- the hibernation gate on real mounts -------------------------------------------
mkdir -p $U/swap; head -c 1048576 /dev/zero > $U/swap/hibernate; mkswap $U/swap/hibernate >/dev/null 2>&1
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "hibernated: reset refuses (exit 4), nothing built" "$G reset --yes 2>/dev/null; [ \$? = 4 ] && [ \$(ls $U/deployments | wc -l) = $n0 ]"
# userdata mounted elsewhere (a recovery's /data): the tool must use that mount, never the raw device
sed "s|^USERDATA_MNT=.*|USERDATA_MNT=$W/notmounted|" $W/deploy.conf > $W/deploy2.conf
printf '#!/bin/sh\n: > %s/debugfs-used\nexit 1\n' $W > $W/shim/debugfs; chmod +x $W/shim/debugfs; rm -f $W/shim/cp
ok "userdata mounted elsewhere: found, read through the mount (no debugfs)" "[ \"\$(GLASSINE_DEPLOY_CONF=$W/deploy2.conf PATH=$W/shim:\$PATH $G status --porcelain | tr '\t' '\n' | sed -n 's/^hibernated=//p')\" = yes ] && [ ! -e $W/debugfs-used ]"
ok "invalidate through that mount: no raw write" "GLASSINE_DEPLOY_CONF=$W/deploy2.conf PATH=$W/shim:\$PATH $G hibernate-invalidate --yes >/dev/null && [ \"\$(gs_sig_file $U/swap/hibernate)\" = SWAPSPACE2 ] && [ ! -e $W/debugfs-used ] && [ ! -e $W/notmounted ]"

# --- the boot steps (initramfs): resume or invalidate, boot, carry ---------------
CUR=$(gr_would_pick $S/state)
debugfs_w() { printf "$1" > $W/dbg; debugfs -w -f $W/dbg $UDEV >/dev/null 2>&1; }
umount $W/udmnt $S          # the initramfs starts with nothing mounted
GR_SYSPOWER=$W/power GR_TMP=$W/grtmp; mkdir -p $GR_SYSPOWER
SWB=$(gs_dev_block $UDEV $P/swap/hibernate)
hib() { printf 'S1SUSPEND\000' | dd of=$UDEV bs=1 seek=$((SWB * 4096 + 4086)) conv=notrunc 2>/dev/null; sync; blockdev --flushbufs $UDEV; rm -f $GR_SYSPOWER/*; }
sig() { gs_sig_dev $UDEV $SWB; }
guard() {   # guard [KEY=VALUE...]: the guard file, written with debugfs (no mount: the mount count stays)
    { echo "mount_count=$(gr_dumpe2fs $UDEV 'Mount count')"; echo "last_mount=$(gr_dumpe2fs $UDEV 'Last mount time')"
      echo "deployment=$CUR"; echo "krel=$(uname -r)"; echo "kver=$(uname -v)"; } > $W/g
    for kv in "$@"; do sed -i "s|^${kv%%=*}=.*|$kv|" $W/g; done
    debugfs_w "cd /$P/swap\nrm hibernate.guard\nwrite $W/g hibernate.guard\n"
}
WD=$W/wd; gr_wd_stop() { echo stop >> $WD; }; gr_wd_start() { echo start >> $WD; }
res() { : > $WD; gr_resume $SD $UDEV $P "$1" 2>$W/rlog; }
ok "resume step: no hibernate image: nothing written" "res resume && [ -z \"\$(ls $GR_SYSPOWER)\" ] && [ \"\$(sig)\" = SWAPSPACE2 ]"
hib
ok "resume step, noresume: invalidated, no resume write" "res noresume && [ \"\$(sig)\" = SWAPSPACE2 ] && [ -z \"\$(ls $GR_SYSPOWER)\" ] && grep -q 'no resume on this boot (noresume)' $W/rlog"
hib
ok "resume step, no guard file: invalidated" "res resume && [ \"\$(sig)\" = SWAPSPACE2 ] && [ -z \"\$(ls $GR_SYSPOWER)\" ] && grep -q 'no guard file' $W/rlog"
guard; mount -t ext4 $UDEV $W/udmnt && umount $W/udmnt; hib
ok "resume step, userdata mounted after the hibernate: invalidated" "res resume && [ \"\$(sig)\" = SWAPSPACE2 ] && [ -z \"\$(ls $GR_SYSPOWER)\" ] && grep -q 'userdata was mounted since the hibernate (mount_count)' $W/rlog"
guard kver=other; hib
ok "resume step, another kernel build: invalidated" "res resume && [ \"\$(sig)\" = SWAPSPACE2 ] && grep -q 'another kernel build' $W/rlog"
guard deployment=d9; hib
ok "resume step, state/ boots another deployment: invalidated, the system partition unmounted again" "res resume && [ \"\$(sig)\" = SWAPSPACE2 ] && grep -q \"state/ boots $CUR, the session ran d9\" $W/rlog && ! grep -q '$GR_TMP' /proc/mounts"
guard; hib
MM=$(stat -L -c '%t %T' $UDEV); MM=$(printf '%d:%d' 0x${MM% *} 0x${MM#* })
ok "resume step, every check passes: resume_offset + resume written, watchdog stopped around it" "res resume && [ \"\$(cat $GR_SYSPOWER/resume_offset)\" = $SWB ] && [ \"\$(cat $GR_SYSPOWER/resume)\" = $MM ] && [ \"\$(cat $WD | tr '\n' ' ')\" = 'stop start ' ]"
ok "resume step: the kernel returned (refused image): invalidated" "[ \"\$(sig)\" = SWAPSPACE2 ] && grep -q 'did not resume it' $W/rlog"

ok "gr_boot: the current deployment, system + userdata mounted, state locked" "gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = $CUR ] && mountpoint -q $R.sys && mountpoint -q $R.ud && ro $R/usr/bin/x && ! flock -n $R.sys/state/.lock true"
ok "gr_carry: mounts under /run/glassine, booted recorded, lock released" "gr_carry $R && mountpoint -q $R/run/glassine/system && mountpoint -q $R/run/glassine/userdata && mountpoint -q $R/run/glassine/root && ! mountpoint -q $R.sys && [ \"\$(cat $R/run/glassine/booted)\" = $CUR ] && flock -n $R/run/glassine/system/state/.lock true"
ok "after the carry: / still read-only, /etc writable" "ro $R/usr/bin/x && echo c > $R/etc/carried && [ -e $R/run/glassine/userdata/$P/deployments/$CUR/switch/etc/carried ]"
sed -e "s|^SYSTEM_MNT=.*|SYSTEM_MNT=$R/run/glassine/system|" -e "s|^USERDATA_MNT=.*|USERDATA_MNT=$R/run/glassine/userdata|" -e "s|^RUN_DIR=.*|RUN_DIR=$R/run/glassine|" $W/deploy.conf > $W/deploy3.conf
ok "the system's glassine-deploy works on the carried mounts (select = a state write)" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G select d1 >/dev/null && [ \"\$(gs_kv $R/run/glassine/system/state/deploy candidate)\" = d1 ] && GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G select $CUR >/dev/null"
mkdir -p $R/run/glassine/userdata/$P/deployments/dz && echo base=gone > $R/run/glassine/userdata/$P/deployments/dz/meta
gs_update $R/run/glassine/system/state/deploy candidate=dz tries=2
gr_boot_umount $R
ok "gr_boot_umount: nothing left mounted" "! grep -q \" $R\" /proc/mounts"
ok "gr_boot: a candidate that does not assemble: failed, current boots" "gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = $CUR ] && [ \"\$(gs_kv $R.sys/state/deploy failed)\" = dz ] && [ -z \"\$(gs_kv $R.sys/state/deploy candidate)\" ] && grep -q 'deployment dz does not assemble' $W/blog"
rm -rf $R.ud/$P/deployments/dz; gs_update $R.sys/state/deploy candidate=d1 tries=2 failed=; echo version=9 > $R.sys/state/format
gr_boot_umount $R
ok "gr_boot: a newer state format: boots what it would pick, writes nothing" "gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = d1 ] && [ \"\$(gs_kv $R.sys/state/deploy tries)\" = 2 ] && grep -q 'newer than this initramfs' $W/blog"
echo version=1 > $R.sys/state/format; gs_update $R.sys/state/deploy candidate= tries=0
gr_boot_umount $R
ok "gr_boot without userdata: bare on the newest base" "gr_boot $SD '' $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = bare:b1 ] && [ \"\$(cat $R/etc/motd)\" = welcome ] && gr_carry $R && mountpoint -q $R/run/glassine/bare"
gr_boot_umount $R
mount -t btrfs $SD $S && mount -t ext4 $UDEV $W/udmnt
ok "base unchanged after everything" "[ \"\$(basesum)\" = \"\$SUM0\" ]"

finish
echo "$fails failed"
[ $fails = 0 ]
