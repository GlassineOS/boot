#!/bin/sh
set -u
# Own PID namespace: the hibernate step finds the watchdog daemon by name, so on a
# device (or any system with a watchdog daemon) it would stop and restart the real one.
if [ -z "${GLASSINE_TEST_PIDNS:-}" ]; then
    command -v unshare >/dev/null || { echo "FAIL unshare is needed (own PID namespace)"; exit 1; }
    GLASSINE_TEST_PIDNS=1 exec unshare -fp --mount-proc sh "$0" "$@"
fi
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
mkdir -p $B/etc/apk $B/etc/eink $B/usr/bin $B/usr/local $B/opt $B/var/lib $B/lib/modules/7.3.0 $B/usr/share/glassine
echo alpine-base > $B/etc/apk/world
echo glassine > $B/etc/hostname
echo welcome > $B/etc/motd
echo '@stagger_ctl=3' > $B/etc/eink/eink.conf
echo 'root:x:0:0:root:/root:/bin/sh' > $B/etc/passwd
printf '#!/bin/sh\necho hello\n' > $B/usr/bin/hello; chmod 755 $B/usr/bin/hello
printf '# shipped\n/etc/eink/\n/etc/hostname\n/etc/passwd\n/var/lib/bluetooth/\n../escape\nrelative/path\n' > $B/usr/share/glassine/migrate.list
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
# shellcheck disable=SC2034  # read in the eval of ok()
SUM0=$(basesum)
R=$W/root
ro() { ! sh -c "echo x > $1" 2>/dev/null; }

# --- a deployment's root, locked ---------------------------------------------
ok "gr_assemble d1" "gr_assemble $S $U d1 $R 7.3.0"
ok "/ is read-only: /usr, a new file in /" "ro $R/usr/bin/new && ro $R/newfile"
ok "/etc, /var, /usr/local, /opt are writable" "echo edited > $R/etc/eink/eink.conf && echo myhost > $R/etc/hostname && mkdir -p $R/var/lib/bluetooth && echo pair > $R/var/lib/bluetooth/k && echo l > $R/usr/local/x && echo o > $R/opt/y"
ok "the writes go through the overlay: copy-up into d1's switch layer" "[ \"\$(cat $U/deployments/d1/switch/etc/eink/eink.conf)\" = edited ] && [ -e $U/deployments/d1/switch/usr/local/x ]"
rm $R/etc/motd
ok "a deletion in /etc: a whiteout in the switch layer, the base keeps the file" "[ ! -e $R/etc/motd ] && [ -c $U/deployments/d1/switch/etc/motd ] && [ \"\$(cat $B/etc/motd)\" = welcome ]"
ok "rename-replace in /etc works (passwd-style)" "echo 'root:x:0:0:root:/root:/bin/ash' > $R/etc/passwd.new && mv $R/etc/passwd.new $R/etc/passwd && grep -q ash $R/etc/passwd"
ok "modules: on /lib/modules/7.3.0, read-only" "[ \"\$(cat $R/lib/modules/7.3.0/kernel/x.ko)\" = ko ] && ro $R/lib/modules/7.3.0/kernel/y.ko"
ok "unlock: / writable" "gr_unlock $R && echo new > $R/usr/bin/new && [ -e $U/deployments/d1/switch/usr/bin/new ]"
ok "lock: / read-only again" "gr_lock $R && ro $R/usr/bin/new2"
ok "the base is unchanged" "[ \"\$(basesum)\" = \"\$SUM0\" ]"
gr_umount $R
ok "gr_umount: nothing left mounted" "! grep -q \" $R\" /proc/mounts"
ok "persistence: reassembled, edits still there" "gr_assemble $S $U d1 $R 7.3.0 && [ \"\$(cat $R/etc/eink/eink.conf)\" = edited ] && [ ! -e $R/etc/motd ] && [ -e $R/usr/bin/new ] && ro $R/usr/bin/x"
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
ok "reset: the TWRP keep marker in the top-level media directory, status says so" "[ -f $W/udmnt/media/glassine/.twrp-keep ] && $G status --porcelain | grep -q '	twrp_keep=yes'"
N=$(st staged); NS=$U/deployments/$N/switch
ok "reset: meta = base b1, kind reset, carry migrate, from d1; layers empty" "grep -qx base=b1 $U/deployments/$N/meta && grep -qx kind=reset $U/deployments/$N/meta && grep -qx carry=migrate $U/deployments/$N/meta && grep -qx from=d1 $U/deployments/$N/meta && [ -z \"\$(ls -A $U/deployments/$N/build)\" ] && [ -z \"\$(ls -A $NS)\" ]"
ok "list + status: staged" "$G list --porcelain | grep -q \"id=$N	state=staged\" && $G status --porcelain | grep -q \"staged=$N\""
ok "gr_pick ignores a staged deployment" "[ \"\$(gr_pick $S/state)\" = d1 ]"
# a change after the reset, before the shutdown: must be carried (option a)
gr_assemble $S $U d1 $R && echo later > $R/etc/eink/eink.conf && gr_umount $R
mkdir -p $W/shim; printf '#!/bin/sh\nexit 1\n' > $W/shim/cp; chmod +x $W/shim/cp
echo leftover > $NS/leftover; cp $S/state/deploy $W/stS
ok "an interrupted switch (cut copy): exit 1, still staged, nothing selected, marker gone, nothing mounted" "PATH=$W/shim:\$PATH $G switch 2>/dev/null; [ \$? = 1 ] && cmp -s $S/state/deploy $W/stS && [ ! -e $W/run/switching ] && ! grep -q '$W/run' /proc/mounts"
: > $W/run/switching
ok "switch: a stale marker does not block it; redone from scratch; selected with 2 tries" "$G switch >/dev/null 2>&1 && [ \"\$(st candidate)\" = $N ] && [ \"\$(st tries)\" = 2 ] && [ -z \"\$(st staged)\" ] && [ ! -e $NS/leftover ] && [ ! -e $W/run/switching ]"
ok "switch carries the migrate list (shipped + the user's), with the change made after the reset" "[ \"\$(cat $NS/etc/eink/eink.conf)\" = later ] && [ \"\$(cat $NS/etc/hostname)\" = myhost ] && [ -e $NS/var/lib/bluetooth/k ] && [ -e $NS/etc/wireguard/wg0.conf ]"
ok "switch: the carried passwd is replaced by the merge (root from the base)" "grep -qx 'root:x:0:0:root:/root:/bin/sh' $NS/etc/passwd && [ -e $NS/etc/shadow ]"
ok "switch keeps modes (0700 wireguard)" "[ \$(stat -c %a $NS/etc/wireguard) = 700 ]"
ok "switch drops the rest (edits, packages, /usr/local, whiteouts)" "[ ! -e $NS/etc/junk ] && [ ! -e $NS/usr/bin/new ] && [ ! -e $NS/usr/local/x ] && [ ! -e $NS/etc/motd ] && [ ! -e $NS/escape ]"
ok "switch left nothing mounted" "! grep -q '$W/run' /proc/mounts"
ok "switch with nothing staged: exit 0" "$G switch >/dev/null"
ok "gr_pick: the candidate, tries 2 -> 1" "[ \"\$(gr_pick $S/state)\" = $N ] && [ \"\$(st tries)\" = 1 ]"
ok "the candidate's root: carried state, base files back, user edits gone" "gr_assemble $S $U $N $R && [ \"\$(cat $R/etc/eink/eink.conf)\" = later ] && [ \"\$(cat $R/etc/motd)\" = welcome ] && [ ! -e $R/usr/bin/new ] && [ ! -e $R/etc/junk ]"
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
# the write commands on unmounted partitions (a recovery): mount, write, unmount
cp $S/state/deploy $W/stU; DU0=$(ls $U/deployments)
umount $W/udmnt && umount $S
ok "rollback, nothing mounted before: nothing mounted after" "$G rollback >/dev/null && ! mountpoint -q $S && ! mountpoint -q $W/udmnt"
ok "reset --yes, nothing mounted before: nothing mounted after" "$G reset --yes >/dev/null && ! mountpoint -q $S && ! mountpoint -q $W/udmnt"
ok "reset --now --yes, nothing mounted before: nothing mounted after" "$G reset --now --yes >/dev/null && ! mountpoint -q $S && ! mountpoint -q $W/udmnt"
mount -t btrfs "$SD" $S && mount -t ext4 "$UDEV" $W/udmnt
cp $W/stU $S/state/deploy
for d in "$U"/deployments/*; do echo "$DU0" | grep -qx "${d##*/}" || rm -rf "$d"; done
$G select $N >/dev/null

# --- reset --full, reset --now, replacing a staged one ----------------------------
ok "reset --full --now: selected at once, nothing carried" "$G reset --full --now --yes >/dev/null && F=\$(st candidate) && [ \"\$F\" != $N ] && [ -z \"\$(ls -A $U/deployments/\$F/build)\" ] && [ -z \"\$(ls -A $U/deployments/\$F/switch)\" ] && grep -qx kind=reset-full $U/deployments/\$F/meta && [ -z \"\$(st staged)\" ]"
$G select $N >/dev/null
$G reset --yes >/dev/null
# shellcheck disable=SC2034  # read in the eval of ok()
A1=$(st staged)
sleep 1; $G reset --full --yes >/dev/null; A2=$(st staged)
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

# --- glassine: lock, unlock, the apk wrapper (on a real locked root) --------------
GL=/p/sbin/glassine
gr_assemble $S $U d1 $R
mkdir -p $W/run2; echo d1 > $W/run2/booted
printf 'RUN_DIR=%s/run2\n' $W > $W/gl.conf
printf '#!/bin/sh\necho "$*" >> %s/apk-calls\ncase " $* " in *" add "*) echo pkg > %s/usr/bin/pkgfile || exit 9 ;; esac\nexit ${APK_RC:-0}\n' $W $R > $W/apk; chmod +x $W/apk
gl() { GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/apk sh $GL "$@"; }
ok "glassine status: locked" "gl status | grep -qx 'root: locked'"
ok "apk without the acknowledgement, no terminal: refused, nothing run" "gl apk add foo </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'GLASSINE_APK_ACK=1' $W/err && [ ! -e $W/apk-calls ]"
ok "apk search (no change): runs, / stays read-only, no acknowledgement needed" "gl apk search foo </dev/null && grep -qx 'search foo' $W/apk-calls && ro $R/usr/bin/t1"
printf '#!/bin/sh\necho "$*" >> %s/apk-calls\ncase " $* " in *" info "*) ;; *" add "*) echo pkg > %s/usr/bin/pkgfile || exit 9 ;; *" update "*) echo lock > %s/usr/bin/apklock || exit 9 ;; esac\nexit ${APK_RC:-0}\n' $W $R $R > $W/apk
ok "apk update: / writable for the run, no acknowledgement needed, read-only after" "gl apk --no-progress update </dev/null && [ \"\$(cat $R/usr/bin/apklock)\" = lock ] && ro $R/usr/bin/t7 && [ ! -e $R/etc/glassine/apk-acknowledged ]"
ok "apk info update (a package called update): / stays read-only" "gl apk info update </dev/null && grep -qx 'info update' $W/apk-calls && ro $R/usr/bin/t8"
ok "apk add: / writable for the run (the package lands), read-only after" "GLASSINE_APK_ACK=1 gl apk add foo && [ \"\$(cat $R/usr/bin/pkgfile)\" = pkg ] && ro $R/usr/bin/t2 && [ -e $R/etc/glassine/apk-acknowledged ]"
ok "apk: the change lands in the deployment's upper" "[ -e $U/deployments/d1/switch/usr/bin/pkgfile ]"
ok "apk: acknowledged once, then no more question; apk's exit code passed on" "APK_RC=3 gl apk del foo </dev/null; [ \$? = 3 ] && ro $R/usr/bin/t3"
ok "apk while another change holds the lock: waits, then runs" "( exec 8>>$W/run2/apk.lock; flock 8; sleep 2 ) & sleep 0.5; gl apk fix 2>$W/err && grep -q 'waiting' $W/err && ro $R/usr/bin/t4"
wait
ok "unlock: / writable, status says so" "gl unlock 2>/dev/null && echo x > $R/usr/bin/manual && gl status | grep -q 'root: unlocked'"
ok "apk while unlocked: stays unlocked after" "gl apk add bar && echo y > $R/usr/bin/manual2"
ok "lock: read-only again" "gl lock 2>/dev/null && ro $R/usr/bin/t5 && gl status | grep -qx 'root: locked'"
printf '#!/bin/sh\necho "$*" >> %s/apk-calls\ncase " $* " in *" --simulate "*) echo "(1/1) Upgrading musl (1 -> 2)" ;; esac\nexit 0\n' $W > $W/apkm; chmod +x $W/apkm
glm() { GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/apkm sh $GL "$@"; }
gl lock >/dev/null 2>&1
: > $W/apk-calls
ok "another repository replacing installed packages, no terminal: refused, named, relocked" "GLASSINE_APK_ACK=1 glm apk add foo@edge </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'Upgrading\|musl' $W/err && ! grep -qx 'add foo@edge' $W/apk-calls && ro $R/usr/bin/t9"
ok "GLASSINE_APK_MIX=1: goes on" "GLASSINE_APK_ACK=1 GLASSINE_APK_MIX=1 glm apk add foo@edge </dev/null 2>/dev/null && grep -qx 'add foo@edge' $W/apk-calls"
: > $W/apk-calls
ok "a plain add: no simulation, no question" "GLASSINE_APK_ACK=1 glm apk add foo </dev/null 2>/dev/null && ! grep -q simulate $W/apk-calls && grep -qx 'add foo' $W/apk-calls"
ok "called as apk: the wrapper" "mkdir -p $W/bin && ln -sf $GL $W/bin/apk && GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/apk $W/bin/apk add baz && ro $R/usr/bin/t6 && grep -qx 'add baz' $W/apk-calls"
rm -f $W/run2/booted
ok "not booted from a deployment: apk-tools unchanged (no unlock: the stub's write fails)" "gl apk add qux </dev/null 2>/dev/null; [ \$? = 9 ] && grep -qx 'add qux' $W/apk-calls && gl status | grep -q 'plain'"
ok "unlock refused when not booted from a deployment" "gl unlock 2>/dev/null; [ \$? = 1 ]"
gr_umount $R

# --- receive, bases, stage: a base update ------------------------------------------
# the new base b2 on a scratch btrfs (the build host's), sent as streams
truncate -s 128M $W/src.img; mkfs.btrfs -q $W/src.img; loop $W/src.img; SRC=$LOOP
mkdir -p $W/src && mount -t btrfs "$SRC" $W/src
btrfs -q subvolume create $W/src/b2; B2=$W/src/b2
mkdir -p $B2/etc/apk $B2/etc/eink $B2/usr/bin $B2/usr/share/glassine $B2/var/lib
cp $B/usr/share/glassine/migrate.list $B2/usr/share/glassine/; echo glassine > $B2/etc/hostname
echo two > $B2/etc/motd; echo '@stagger_ctl=4' > $B2/etc/eink/eink.conf
printf 'root:x:0:0:root:/root:/bin/sh\nbluetooth:x:101:101::/:/sbin/nologin\n' > $B2/etc/passwd
printf 'root:x:0:root\nwheel:x:10:root\nbluetooth:x:101:\nshadow:x:42:\n' > $B2/etc/group
printf 'root:*:1::::::\nbluetooth:!:1::::::\n' > $B2/etc/shadow; chown 0:42 $B2/etc/shadow; chmod 640 $B2/etc/shadow
btrfs property set -ts $B2 ro true
btrfs -q subvolume snapshot $B2 $W/src/b3; echo three > $W/src/b3/etc/motd; btrfs property set -ts $W/src/b3 ro true
btrfs -q send -f $W/b2.stream $B2; zstd -q $W/b2.stream -o $W/b2.stream.zst
btrfs -q send -f $W/b3.inc -p $B2 $W/src/b3
btrfs -q send -f $W/two.stream $B2 $W/src/b3
head -c 4096 $W/b2.stream > $W/cut.stream
SHA2=$(sha256sum $W/b2.stream.zst | cut -d ' ' -f 1)
# the current deployment: a user account, its group, a file the bluetooth daemon owns
CUR=$(st current); NB=$(gs_kv $U/deployments/$CUR/meta base)
gr_assemble $S $U $CUR $R && printf 'root:x:0:0:root:/root:/bin/sh\nbluetooth:x:100:100::/:/sbin/nologin\nuser:x:1000:1000::/home/user:/bin/ash\n' > $R/etc/passwd &&
    printf 'root:x:0:root\nwheel:x:10:root,user\nbluetooth:x:100:\nuser:x:1000:\n' > $R/etc/group &&
    printf 'root:$6$r:1::::::\nuser:$6$u:1::::::\n' > $R/etc/shadow && mkdir -p $R/var/lib/bluetooth/AA &&
    echo key > $R/var/lib/bluetooth/AA/info && chown -R 100:100 $R/var/lib/bluetooth/AA && gr_umount $R
noleft() { [ -z "$(btrfs subvolume list $S | grep -v ' path \(bases/b1\|modules/7.3.0\|bases/b2\|bases/b3\|modules/m9\|bases/bad\)$')" ]; }
ok "receive: a wrong --sha256: refused before anything is written" "$G receive $W/b2.stream.zst --sha256 00 2>$W/err; [ \$? = 1 ] && grep -q 'expected 00' $W/err && [ ! -e $S/bases/b2 ] && noleft"
ok "receive: a cut stream: exit 1, nothing kept" "$G receive $W/cut.stream 2>/dev/null; [ \$? = 1 ] && [ ! -e $S/bases/b2 ] && noleft"
ok "receive: two subvolumes in one stream: exit 1, nothing kept" "$G receive $W/two.stream 2>/dev/null; [ \$? = 1 ] && [ ! -e $S/bases/b2 ] && [ ! -e $S/bases/b3 ] && noleft"
ok "receive: .zst with the right --sha256: bases/b2, read-only, a received UUID" "$G receive $W/b2.stream.zst --sha256 $SHA2 >/dev/null && [ \"\$(btrfs property get -ts $S/bases/b2 ro)\" = ro=true ] && btrfs subvolume show $S/bases/b2 | grep -q 'Received UUID:[[:space:]]*[0-9a-f]' && [ \"\$(cat $S/bases/b2/etc/motd)\" = two ] && noleft"
ok "receive: the same name again: exit 1, the first one kept" "$G receive $W/b2.stream 2>$W/err; [ \$? = 1 ] && [ \"\$(cat $S/bases/b2/etc/motd)\" = two ] && noleft"
ok "receive: an incremental stream (stdin) onto the received base" "$G receive - < $W/b3.inc >/dev/null && [ \"\$(cat $S/bases/b3/etc/motd)\" = three ] && [ \"\$(btrfs property get -ts $S/bases/b3 ro)\" = ro=true ]"
ok "receive --modules: into modules/" "btrfs -q subvolume snapshot -r $W/src/b3 $W/src/m9 && btrfs -q send $W/src/m9 | $G receive - --modules >/dev/null && [ -d $S/modules/m9 ] && [ ! -e $S/bases/m9 ]"
ok "receive: --sha256 with stdin: usage" "$G receive - --sha256 00 </dev/null 2>/dev/null; [ \$? = 2 ]"
ok "bases: each subvolume with its users" "$G bases --porcelain | grep -q \"kind=base	name=$NB	used_by=.*$CUR\" && $G bases --porcelain | grep -q 'kind=base	name=b2	used_by=$' && $G bases --porcelain | grep -q 'kind=module	name=m9'"
ok "stage: an unknown base: exit 1, nothing staged" "$G stage nope --yes 2>$W/err; [ \$? = 1 ] && grep -q 'no base nope' $W/err && [ -z \"\$(st staged)\" ]"
ok "stage: a bad name: exit 2" "$G stage ../b2 --yes 2>/dev/null; [ \$? = 2 ]"
ok "stage --full: usage" "$G stage b2 --full --yes 2>/dev/null; [ \$? = 2 ] && [ -z \"\$(st staged)\" ]"
ok "stage b2: staged, kind update, carry migrate, base b2" "$G stage b2 --yes >/dev/null && SB=\$(st staged) && grep -qx base=b2 $U/deployments/\$SB/meta && grep -qx kind=update $U/deployments/\$SB/meta && grep -qx carry=migrate $U/deployments/\$SB/meta && grep -qx from=$CUR $U/deployments/\$SB/meta && [ \"\$(st current)\" = $CUR ]"
SB=$(st staged); SW=$U/deployments/$SB/switch
ok "bases: the staged deployment uses b2" "$G bases --porcelain | grep -q 'name=b2	used_by=$SB'"
ok "switch: the staged update is the candidate" "$G switch >$W/swout 2>&1 && [ \"\$(st candidate)\" = $SB ] && [ -z \"\$(st staged)\" ]"
ok "switch: accounts merged (user + its password + wheel membership; bluetooth at the new base's ID)" "grep -qx 'user:x:1000:1000::/home/user:/bin/ash' $SW/etc/passwd && grep -qx 'bluetooth:x:101:101::/:/sbin/nologin' $SW/etc/passwd && grep -q '^user:\$6\$u:' $SW/etc/shadow && grep -qx 'wheel:x:10:root,user' $SW/etc/group && grep -qx 'user:x:1000:' $SW/etc/group"
ok "switch: carried files follow the moved bluetooth ID" "[ \"\$(stat -c %u:%g $SW/var/lib/bluetooth/AA/info)\" = 101:101 ] && [ \"\$(stat -c %u:%g $SW/var/lib/bluetooth/AA)\" = 101:101 ]"
ok "switch: reports the merge" "grep -q 'user user kept' $W/swout && grep -q 'uid 100 -> 101' $W/swout && [ ! -e $U/deployments/$SB/idmap ]"
ok "the candidate's root: the new base with the carried settings" "gr_assemble $S $U $SB $R && [ \"\$(cat $R/etc/motd)\" = two ] && [ \"\$(cat $R/etc/hostname)\" = myhost ] && [ \"\$(cat $R/etc/eink/eink.conf)\" = later ] && [ \"\$(cat $R/var/lib/bluetooth/AA/info)\" = key ] && grep -q '^user:' $R/etc/passwd"
gr_umount $R
# a base without /etc/passwd: the switch refuses, stays staged
btrfs -q subvolume create $W/src/bad; mkdir $W/src/bad/etc; btrfs property set -ts $W/src/bad ro true
btrfs -q send $W/src/bad | $G receive - >/dev/null
ok "stage: a base without /etc/passwd: refused" "$G stage bad --yes 2>$W/err; [ \$? = 1 ] && grep -q 'no /etc/passwd' $W/err"
# --- bases remove ---------------------------------------------------------------
PREV0=$(gs_kv $S/state/deploy previous)
mkdir -p $U/deployments/rm1; echo base=bad > $U/deployments/rm1/meta; gs_update $S/state/deploy previous=rm1
ok "bases remove: a bad name: exit 2; another verb: usage" "$G bases remove ../x 2>/dev/null; a=\$?; $G bases drop b3 2>/dev/null; [ \$a\$? = 22 ] && [ -e $S/bases/b3 ]"
ok "bases remove: an unknown base: exit 1" "$G bases remove nope --yes 2>$W/err; [ \$? = 1 ] && grep -q 'no base nope' $W/err"
ok "bases remove: the current deployment's base: refused even with --yes" "$G bases remove $NB --yes 2>$W/err; [ \$? = 1 ] && grep -q \"in use by deployment $CUR\" $W/err && [ -e $S/bases/$NB ]"
ok "bases remove: the candidate's base: refused" "$G bases remove b2 --yes 2>$W/err; [ \$? = 1 ] && grep -q \"in use by deployment $SB\" $W/err && [ -e $S/bases/b2 ]"
ok "bases remove: unreadable deployments do not read as unused" "mv $U/deployments/$CUR/meta $W/meta.save; $G bases remove b3 --yes 2>$W/err; a=\$?; mv $W/meta.save $U/deployments/$CUR/meta; [ \$a = 1 ] && grep -q 'cannot read the deployments' $W/err && [ -e $S/bases/b3 ]"
ok "bases remove: an unused base: gone, without asking" "$G bases remove b3 </dev/null >/dev/null && [ ! -e $S/bases/b3 ] && ! btrfs subvolume list $S | grep -q 'bases/b3$'"
ok "bases remove: the previous deployment's base: asks, names the rollback, nothing removed" "$G bases remove bad </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'rm1' $W/err && grep -q 'Rollback to rm1 is lost' $W/err && [ -e $S/bases/bad ]"
ok "bases remove --yes: removed; the deployment stays, base_present=no" "$G bases remove bad --yes >/dev/null && [ ! -e $S/bases/bad ] && [ -e $U/deployments/rm1/meta ] && $G list --porcelain | grep 'id=rm1' | grep -q 'base_present=no'"
C0=$(st candidate)
ok "select, rollback: a deployment without its base: refused, candidate unchanged" "$G select rm1 2>$W/err; a=\$?; $G rollback 2>/dev/null; [ \$a\$? = 11 ] && grep -q 'its base bad is not on' $W/err && [ \"\$(st candidate)\" = \"$C0\" ]"
rm -rf $U/deployments/rm1; gs_update $S/state/deploy "previous=$PREV0"
gs_update $S/state/deploy candidate= tries=0; rm -rf $U/deployments/$SB
for v in bases/b2 bases/b3 bases/bad modules/m9; do btrfs property set -fts $S/$v ro false 2>/dev/null; btrfs -q subvolume delete $S/$v; done
umount $W/src

# --- the hibernation gate on real mounts -------------------------------------------
mkdir -p $U/swap; head -c 1048576 /dev/zero > $U/swap/hibernate; mkswap $U/swap/hibernate >/dev/null 2>&1
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "hibernated: reset refuses (exit 4), nothing built" "$G reset --yes 2>/dev/null; [ \$? = 4 ] && [ \$(ls $U/deployments | wc -l) = $n0 ]"
# userdata mounted elsewhere (a recovery's /data): the tool must use that mount, never the raw device
sed "s|^USERDATA_MNT=.*|USERDATA_MNT=$W/notmounted|" $W/deploy.conf > $W/deploy2.conf
printf '#!/bin/sh\n: > %s/debugfs-used\nexit 1\n' $W > $W/shim/debugfs; chmod +x $W/shim/debugfs; rm -f $W/shim/cp
ok "userdata mounted elsewhere: found, read through the mount (no debugfs)" "[ \"\$(GLASSINE_DEPLOY_CONF=$W/deploy2.conf PATH=$W/shim:\$PATH $G status --porcelain | tr '\t' '\n' | sed -n 's/^hibernated=//p')\" = yes ] && [ ! -e $W/debugfs-used ]"
ok "invalidate through that mount: no raw write" "GLASSINE_DEPLOY_CONF=$W/deploy2.conf PATH=$W/shim:\$PATH $G hibernate-invalidate --yes >/dev/null && [ \"\$(gs_sig_file $U/swap/hibernate)\" = SWAPSPACE2 ] && [ ! -e $W/debugfs-used ] && [ ! -e $W/notmounted ]"

# --- the hibernate step (glassine-hibernate), on the real mounts ------------------
# The kernel side is plain files: GLASSINE_SYSPOWER (a write to state "returns"
# = the session resumed), GLASSINE_PROC_SWAPS + swapon/swapoff stubs (never
# the host's swap), a stand-in watchdog daemon named watchdog.
H=/p/sbin/glassine-hibernate
rm -f $W/shim/debugfs
HP=$W/hpower; mkdir -p $HP; HC=$W/hcalls; printf 'Filename\tType\n' > $W/swaps
printf '#!/bin/sh\necho swapon >> %s\necho "$1 file 0 0 -2" >> %s\n' $HC $W/swaps > $W/shim/swapon
printf '#!/bin/sh\necho swapoff >> %s\ngrep -v "^$1 " %s > %s.n; mv %s.n %s\n' $HC $W/swaps $W/swaps $W/swaps $W/swaps > $W/shim/swapoff
# sync: also keeps a copy of the guard while it exists (the wrapper removes it after the resume)
printf '#!/bin/sh\n[ -f %s ] && cp %s %s\nexec /bin/sync\n' $U/swap/hibernate.guard $U/swap/hibernate.guard $W/guard-seen > $W/shim/sync
mkdir -p $W/wdbin
printf '#!/bin/sh\necho "start $*" >> %s\ntrap "echo stop >> %s; exit 0" TERM\nwhile :; do sleep 0.1; done\n' $W/wdlog $W/wdlog > $W/wdbin/watchdog
chmod +x $W/shim/swapon $W/shim/swapoff $W/shim/sync $W/wdbin/watchdog
hpow() { rm -rf "${HP:?}"/*; echo 'freeze mem disk' > $HP/state; echo 'platform [shutdown] reboot' > $HP/disk; : > $HC; rm -f $W/guard-seen; }
printf 'HIBERNATE_RESERVE_MB=8\nHIBERNATE_HOOKS=%s/hooks\n' $W >> $W/deploy.conf
hn() { GLASSINE_SYSPOWER=$HP GLASSINE_PROC_SWAPS=$W/swaps PATH=$W/shim:$PATH $H "$@" >$W/hout 2>&1; }
HS=$U/swap/hibernate
hpow
ok "hibernate: not a deployments boot (no booted): exit 3" "hn check; [ \$? = 3 ] && grep -q 'not a deployments boot' $W/hout"
echo bare:b1 > $W/run/booted
ok "hibernate: a bare boot: exit 3" "hn check; [ \$? = 3 ] && grep -q 'a bare boot' $W/hout"
HD=$(gr_would_pick $S/state)      # the deployment booted = the one the state boots next
cp $S/state/deploy $W/deploy.keep
echo dX > $W/run/booted
ok "hibernate: the state would boot another deployment next: exit 3" "hn check; [ \$? = 3 ] && grep -q 'next boot would be $HD, not dX' $W/hout"
echo "$HD" > $W/run/booted
gs_update $S/state/deploy candidate="$HD" tries=0 current=dZ
ok "hibernate: the booted candidate on its last try (next boot = current): exit 3" "hn check; [ \$? = 3 ] && grep -q 'next boot would be dZ, not $HD' $W/hout"
cp $W/deploy.keep $S/state/deploy
ok "setup 2:a 2 MiB swap file, swap signature, mode 600" "hn setup 2 && [ \$(stat -c %s $HS) = 2097152 ] && [ \"\$(gs_sig_file $HS)\" = SWAPSPACE2 ] && [ \$(stat -c %a $HS) = 600 ]"
HI=$(stat -c %i $HS); printf 'S1SUSPEND\000' | dd of=$HS bs=1 seek=4086 conv=notrunc 2>/dev/null; echo x > $HS.guard
ok "setup again, same size: the file kept, an old image + guard invalidated" "hn setup 2 && [ \$(stat -c %i $HS) = $HI ] && [ \"\$(gs_sig_file $HS)\" = SWAPSPACE2 ] && [ ! -e $HS.guard ]"
# recreated = the old content gone (a marker in block 100; the inode number may be reused)
hmark() { printf OLDFILE | dd of=$HS bs=4096 seek=100 conv=notrunc 2>/dev/null; }
hmarked() { [ "$(dd if=$HS bs=4096 skip=100 count=1 2>/dev/null | head -c 7)" = OLDFILE ]; }
rm -f $HS; fallocate -l 2097152 $HS; mkswap $HS >/dev/null 2>&1; hmark
ok "setup, same size but allocated, not written: recreated without unwritten extents" "filefrag -v $HS | grep -q unwritten && hn setup 2 && ! hmarked && ! filefrag -v $HS | grep -q unwritten && [ \"\$(gs_sig_file $HS)\" = SWAPSPACE2 ]"
printf '#!/bin/sh\nexit 1\n' > $W/shim/filefrag; chmod +x $W/shim/filefrag; hmark
ok "setup, the extents can't be read (filefrag fails): recreated" "hn setup 2 && ! hmarked"
rm -f $W/shim/filefrag; HI=$(stat -c %i $HS)
ok "setup, more than the free space: exit 3, the file kept" "hn setup 9999; [ \$? = 3 ] && [ \$(stat -c %i $HS) = $HI ] && grep -q 'not enough space' $W/hout"
ok "setup, size junk: exit 2" "hn setup 2x; [ \$? = 2 ]"
: > $W/kmsg-ro; mount --bind $W/kmsg-ro /dev/kmsg && mount -o remount,ro,bind /dev/kmsg
ok "setup without a writable /dev/kmsg: still exit 0" "hn setup 2"
umount /dev/kmsg
HB=$(gs_dev_block $UDEV $P/swap/hibernate)
HMM=$(stat -L -c '%t %T' $UDEV); HMM=$(printf '%d:%d' 0x${HMM% *} 0x${HMM#* })
ok "check: ready, the block the initramfs finds" "hn check && grep -q \"swap block $HB on $HMM\" $W/hout"
: > $W/run/switching
ok "now, a switch running: exit 4, nothing touched" "hn now; [ \$? = 4 ] && [ ! -s $HC ] && [ ! -e $HP/resume ]"
rm $W/run/switching
ok "now, the state locked by glassine-deploy: exit 4, nothing touched" "flock $S/state/.lock sh -c 'GLASSINE_SYSPOWER=$HP GLASSINE_PROC_SWAPS=$W/swaps PATH=$W/shim:\$PATH $H now' >$W/hout 2>&1; [ \$? = 4 ] && [ ! -s $HC ] && [ ! -e $HP/resume ]"
echo 'freeze mem' > $HP/state
ok "now, a kernel without hibernation: exit 3" "hn now; [ \$? = 3 ] && [ ! -s $HC ]"
hpow; : > $W/wdlog; $W/wdbin/watchdog -t 5 -T 20 /dev/null & sleep 0.3
ok "now: resumed (exit 0), the resume files, disk=shutdown, the watchdog stopped + started with its arguments" "hn now && sleep 0.5 && [ \"\$(cat $HP/resume_offset)\" = $HB ] && [ \"\$(cat $HP/resume)\" = $HMM ] && [ \"\$(cat $HP/disk)\" = shutdown ] && [ \"\$(cat $HP/state)\" = disk ] && [ \"\$(cat $W/wdlog | tr '\n' ' ')\" = 'start -t 5 -T 20 /dev/null stop start -t 5 -T 20 /dev/null ' ]"
ok "now: the restarted watchdog does not hold the state lock" "flock -n $S/state/.lock true"
pkill -f "$W/wdbin/watchdog" 2>/dev/null
{ gs_guard_mounts $UDEV; echo "deployment=$HD"; echo "krel=$(uname -r)"; echo "kver=$(uname -v)"; } > $W/guard-want
ok "now: the guard as the initramfs reads it (rule 4 + 7), removed after the resume" "cmp -s $W/guard-seen $W/guard-want && [ ! -e $HS.guard ]"
ok "now: swapon before, swapoff after, the signature plain swap" "[ \"\$(cat $HC | tr '\n' ' ')\" = 'swapon swapoff ' ] && [ \"\$(gs_sig_file $HS)\" = SWAPSPACE2 ] && ! grep -q \"^$HS \" $W/swaps"
hpow; echo "$HS file 0 0 -2" >> $W/swaps
ok "now, the swap file already on: not switched on or off" "hn now && [ ! -s $HC ] && grep -q \"^$HS \" $W/swaps"
grep -v "^$HS " $W/swaps > $W/swaps.n; mv $W/swaps.n $W/swaps
hpow; mount -o bind $HP/state $HP/state && mount -o remount,ro,bind $HP/state
ok "now, the kernel refuses (state write fails): exit 1, guard gone, swap off" "hn now; [ \$? = 1 ] && grep -q 'did not hibernate' $W/hout && [ ! -e $HS.guard ] && [ \"\$(cat $HC | tr '\n' ' ')\" = 'swapon swapoff ' ]"
umount $HP/state
# device hooks: pre in name order, post in reverse, a failing pre cancels
mkdir -p $W/hooks; HL=$W/hooklog
printf '#!/bin/sh\necho "10-a $*" >> %s\n' $HL > $W/hooks/10-a
printf '#!/bin/sh\necho "20-b $*" >> %s\n[ "$1" != pre ] || [ ! -e %s/hookfail ]\n' $HL $W > $W/hooks/20-b
chmod +x $W/hooks/10-a $W/hooks/20-b
echo 'not run' > $W/hooks/30-not-executable
hpow; : > $HL
ok "now, device hooks: pre in name order, post resumed in reverse" "hn now && [ \"\$(cat $HL | tr '\n' ,)\" = '10-a pre,20-b pre,20-b post resumed,10-a post resumed,' ]"
hpow; : > $HL; : > $W/hookfail
ok "now, a pre hook fails: exit 1, nothing switched on or written, post failed for all" "hn now; [ \$? = 1 ] && grep -q 'hook 20-b pre failed' $W/hout && [ ! -s $HC ] && [ ! -e $HP/resume ] && [ ! -e $HS.guard ] && [ \"\$(cat $HL | tr '\n' ,)\" = '10-a pre,20-b pre,20-b post failed,10-a post failed,' ]"
rm -f $W/hookfail
hpow; printf '#!/bin/sh\n[ "$1" = post ] && sleep 30 >/dev/null 2>&1 &\nexit 0\n' > $W/hooks/40-daemon; chmod +x $W/hooks/40-daemon
ok "now, a post hook leaves a process running: it does not hold the state lock" "hn now && flock -n $S/state/.lock true"
pkill -f 'sleep 30' 2>/dev/null; rm -f $W/hooks/40-daemon
hpow
ok "now --reboot: disk=reboot" "hn now --reboot && [ \"\$(cat $HP/disk)\" = reboot ]"
hpow; echo '[shutdown] test' > $HP/disk; : > $HL
ok "now --reboot, the kernel offers no reboot: exit 3, guard gone, swap off, post failed" "hn now --reboot; [ \$? = 3 ] && [ ! -e $HS.guard ] && [ \"\$(cat $HC | tr '\n' ' ')\" = 'swapon swapoff ' ] && [ \"\$(cat $HP/state)\" = 'freeze mem disk' ] && tail -n 1 $HL | grep -qx '10-a post failed'"
hpow; rm $HP/disk; : > $HL
ok "now --reboot without /sys/power/disk: exit 3, guard gone, swap off, no hibernate" "hn now --reboot; [ \$? = 3 ] && [ ! -e $HS.guard ] && [ \"\$(cat $HC | tr '\n' ' ')\" = 'swapon swapoff ' ] && [ \"\$(cat $HP/state)\" = 'freeze mem disk' ]"
hpow; rm $HP/disk
ok "now without /sys/power/disk: the kernel default (power off), hibernates" "hn now && [ \"\$(cat $HP/state)\" = disk ]"
ok "now --bogus: usage" "hn now --bogus; [ \$? = 2 ]"
rm -rf $W/hooks
hpow; mkdir $HP/resume_offset
ok "now, the resume files cannot be written: exit 1, no hibernate, guard gone, swap off" "hn now; [ \$? = 1 ] && [ \"\$(cat $HP/state)\" = 'freeze mem disk' ] && [ ! -e $HS.guard ] && [ \"\$(cat $HC | tr '\n' ' ')\" = 'swapon swapoff ' ]"
sed -i '/^HIBERNATE_/d' $W/deploy.conf
rm -f $W/run/booted $W/shim/swapon $W/shim/swapoff $W/shim/sync

# --- the boot steps (initramfs): resume or invalidate, boot, carry ---------------
CUR=$(gr_would_pick $S/state)
debugfs_w() { printf "$1" > $W/dbg; debugfs -w -f $W/dbg $UDEV >/dev/null 2>&1; }
umount $W/udmnt $S          # the initramfs starts with nothing mounted
GR_SYSPOWER=$W/power GR_TMP=$W/grtmp; mkdir -p $GR_SYSPOWER
SWB=$(gs_dev_block $UDEV $P/swap/hibernate)
hib() { printf 'S1SUSPEND\000' | dd of=$UDEV bs=1 seek=$((SWB * 4096 + 4086)) conv=notrunc 2>/dev/null; sync; blockdev --flushbufs $UDEV; rm -f $GR_SYSPOWER/*; }
sig() { gs_sig_dev $UDEV $SWB; }
guard() {   # guard [KEY=VALUE...]: the guard file, written with debugfs (no mount: the mount count stays)
    { TZ=CET-1CEST gs_guard_mounts $UDEV        # the wrapper's own time zone must not matter
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
ok "gs_dumpe2fs: the same last mount time under any TZ" "[ \"\$(TZ=CET-1CEST gs_dumpe2fs $UDEV 'Last mount time')\" = \"\$(TZ=JST-9 gs_dumpe2fs $UDEV 'Last mount time')\" ]"
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
# the shutdown switch in the running system: OpenRC's localmount has unmounted
# /run/glassine/*; a mount on top of / must not leak into the carried state
GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G reset --yes >/dev/null; LS=$(gs_kv $R/run/glassine/system/state/deploy staged)
echo live > $R/etc/eink/eink.conf
mount -t tmpfs tmpfs $R/var/lib/bluetooth && echo submount > $R/var/lib/bluetooth/fromsubmount
umount $R/run/glassine/root $R/run/glassine/userdata $R/run/glassine/system
ok "switch in the running deployment: carries from its live root, selects, leaves nothing mounted" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf GLASSINE_DEPLOY_ROOT=$R $G switch >/dev/null && LSW=$U/deployments/$LS/switch && mount -t ext4 $UDEV $W/udmnt && [ \"\$(cat $W/udmnt/$P/deployments/$LS/switch/etc/eink/eink.conf)\" = live ] && ! grep -q 'view\.' /proc/mounts"
ok "switch in the running deployment: a mount on top of / is not carried" "[ -e $W/udmnt/$P/deployments/$LS/switch/var/lib/bluetooth/k ] && [ ! -e $W/udmnt/$P/deployments/$LS/switch/var/lib/bluetooth/fromsubmount ]"
umount $W/udmnt $R/var/lib/bluetooth
mkdir -p $R/run/glassine/system $R/run/glassine/userdata && mount -t btrfs $SD $R/run/glassine/system && mount -t ext4 $UDEV $R/run/glassine/userdata
ok "after the switch: the staged one is the candidate" "[ \"\$(gs_kv $R/run/glassine/system/state/deploy candidate)\" = $LS ]"
GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G select $CUR >/dev/null; rm -rf $R/run/glassine/userdata/$P/deployments/$LS
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
