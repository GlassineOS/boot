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
    umount $W/udmnt $W/sysmnt $W/dpmnt 2>/dev/null
    for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
    cd /; umount $W 2>/dev/null
}
# (no EXIT trap: this busybox ash runs it in every $(...) subshell too)

# --- the partitions ----------------------------------------------------------
truncate -s 256M $W/sys.img; mkfs.btrfs -q $W/sys.img
truncate -s 160M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 $W/ud.img
loop $W/sys.img; SD=$LOOP; loop $W/ud.img; UDEV=$LOOP
truncate -s 16M $W/ud2.img; mke2fs -q -F -t ext4 -b 4096 $W/ud2.img; loop $W/ud2.img; UD2=$LOOP   # never mounted
mkdir -p $W/sysmnt $W/udmnt
mount -t btrfs "$SD" $W/sysmnt && mount -t ext4 "$UDEV" $W/udmnt || { echo "FAIL cannot mount the loop devices"; finish; exit 1; }
S=$W/sysmnt
mkdir -p $S/bases $S/modules $S/state
btrfs -q subvolume create $S/bases/b1
B=$S/bases/b1
mkdir -p $B/etc/apk $B/etc/eink $B/usr/bin $B/usr/local $B/opt $B/var/lib $B/lib/modules $B/lib/firmware $B/usr/share/glassine
echo alpine-base > $B/etc/apk/world
echo glassine > $B/etc/hostname
echo welcome > $B/etc/motd
echo '@stagger_ctl=3' > $B/etc/eink/eink.conf
echo 'root:x:0:0:root:/root:/bin/sh' > $B/etc/passwd; echo 'root:x:0:root' > $B/etc/group
printf '#!/bin/sh\necho hello\n' > $B/usr/bin/hello; chmod 755 $B/usr/bin/hello
printf '# shipped\n/etc/eink/\n/etc/hostname\n/etc/passwd\n/var/lib/bluetooth/\n../escape\nrelative/path\n' > $B/usr/share/glassine/migrate.list
btrfs property set -ts $B ro true
btrfs -q subvolume create $S/modules/7.3.0
mkdir -p $S/modules/7.3.0/kernel $S/modules/7.3.0/firmware/qcom; echo ko > $S/modules/7.3.0/kernel/x.ko; echo fw > $S/modules/7.3.0/firmware/qcom/a.fw
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
roflag() { awk -v m="$1" '$2 == m { split($4, o, ","); r = o[1] } END { exit r != "ro" }' /proc/mounts; }   # the mount itself is ro

# --- a deployment's root, locked ---------------------------------------------
ok "gr_assemble d1" "gr_assemble $S $U d1 $R 7.3.0"
ok "/ is read-only: /usr, a new file in /" "ro $R/usr/bin/new && ro $R/newfile"
ok "/etc, /var, /usr/local, /opt are writable" "echo edited > $R/etc/eink/eink.conf && echo myhost > $R/etc/hostname && mkdir -p $R/var/lib/bluetooth && echo pair > $R/var/lib/bluetooth/k && echo l > $R/usr/local/x && echo o > $R/opt/y"
ok "the writes go through the overlay: copy-up into d1's switch layer" "[ \"\$(cat $U/deployments/d1/switch/etc/eink/eink.conf)\" = edited ] && [ -e $U/deployments/d1/switch/usr/local/x ]"
rm $R/etc/motd
ok "a deletion in /etc: a whiteout in the switch layer, the base keeps the file" "[ ! -e $R/etc/motd ] && [ -c $U/deployments/d1/switch/etc/motd ] && [ \"\$(cat $B/etc/motd)\" = welcome ]"
ok "rename-replace in /etc works (passwd-style)" "printf 'root:x:0:0:root:/root:/bin/ash\nuser:x:1000:1000::/home/user:/bin/ash\n' > $R/etc/passwd.new && mv $R/etc/passwd.new $R/etc/passwd && grep -q ash $R/etc/passwd"
ok "modules: on /lib/modules/7.3.0 (the base has no such directory), read-only" "[ ! -e $B/lib/modules/7.3.0 ] && [ \"\$(cat $R/lib/modules/7.3.0/kernel/x.ko)\" = ko ] && ro $R/lib/modules/7.3.0/kernel/y.ko"
ok "the kernel's firmware: on /lib/firmware/updates, read-only" "[ \"\$(cat $R/lib/firmware/updates/qcom/a.fw)\" = fw ] && ro $R/lib/firmware/updates/b.fw"
ok "both binds carry the ro flag (not only the read-only subvolume)" "roflag $R/lib/modules/7.3.0 && roflag $R/lib/firmware/updates"
ok "unlock: / writable" "gr_unlock $R && echo new > $R/usr/bin/new && [ -e $U/deployments/d1/switch/usr/bin/new ]"
ok "lock: / read-only again" "gr_lock $R && ro $R/usr/bin/new2"
ok "the base is unchanged" "[ \"\$(basesum)\" = \"\$SUM0\" ]"
gr_umount $R
ok "gr_umount: nothing left mounted" "! grep -q \" $R\" /proc/mounts"
ok "persistence: reassembled, edits still there" "gr_assemble $S $U d1 $R 7.3.0 && [ \"\$(cat $R/etc/eink/eink.conf)\" = edited ] && [ ! -e $R/etc/motd ] && [ -e $R/usr/bin/new ] && ro $R/usr/bin/x"
gr_umount $R
ok "a kernel without modules: boots, says so" "gr_assemble $S $U d1 $R 9.9.9 2>$W/err && grep -q 'no modules for 9.9.9' $W/err && [ -z \"\$(ls $R/lib/modules/7.3.0)\" ]"
gr_umount $R
btrfs -q subvolume create $S/modules/7.3.1; mkdir -p $S/modules/7.3.1/kernel; btrfs property set -ts $S/modules/7.3.1 ro true
ok "a kernel without firmware/: modules bound, nothing on /lib/firmware/updates" "gr_assemble $S $U d1 $R 7.3.1 2>$W/err && mountpoint -q $R/lib/modules/7.3.1 && ! mountpoint -q $R/lib/firmware/updates && [ ! -s $W/err ]"
gr_umount $R
# the firmware's read-only remount fails: the bind undone, said, the modules stay
ok "a failed firmware bind: unbound, said, the modules stay" "(mount() { case \"\$*\" in *remount*/lib/firmware/updates) return 1 ;; esac; command mount \"\$@\"; }; gr_assemble $S $U d1 $R 7.3.0) 2>$W/err && grep -q \"7.3.0's firmware not bound\" $W/err && ! grep -q 'no modules' $W/err && mountpoint -q $R/lib/modules/7.3.0 && ! mountpoint -q $R/lib/firmware/updates"
gr_umount $R
ok "a failed modules remount: unbound, booting without" "(mount() { case \"\$*\" in *remount*/lib/modules/7.3.0) return 1 ;; esac; command mount \"\$@\"; }; gr_assemble $S $U d1 $R 7.3.0) 2>$W/err && grep -q 'no modules for 7.3.0' $W/err && ! mountpoint -q $R/lib/modules/7.3.0"
gr_umount $R
btrfs property set -fts $S/modules/7.3.1 ro false; btrfs -q subvolume delete $S/modules/7.3.1
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
mkdir -p $W/shim2; printf '#!/bin/sh\n: > %s/cpstarted\nsleep 2\nexec /bin/cp "$@"\n' $W > $W/shim2/cp; chmod +x $W/shim2/cp; rm -f $W/cpstarted
PATH=$W/shim2:$PATH $G switch >/dev/null 2>&1 &
swpid=$!
while [ ! -e $W/cpstarted ]; do sleep 0.1; done
kill -TERM $swpid; wait $swpid; swrc=$?
ok "TERM during the switch: the script exits (143), still staged, nothing selected, marker gone, nothing mounted" "[ $swrc = 143 ] && cmp -s $S/state/deploy $W/stS && [ ! -e $W/run/switching ] && ! grep -q '$W/run' /proc/mounts"
: > $W/run/switching
ok "switch: a stale marker does not block it; redone from scratch; selected with 2 tries" "$G switch >/dev/null 2>&1 && [ \"\$(st candidate)\" = $N ] && [ \"\$(st tries)\" = 2 ] && [ -z \"\$(st staged)\" ] && [ ! -e $NS/leftover ] && [ ! -e $W/run/switching ]"
ok "switch carries the migrate list (shipped + the user's), with the change made after the reset" "[ \"\$(cat $NS/etc/eink/eink.conf)\" = later ] && [ \"\$(cat $NS/etc/hostname)\" = myhost ] && [ -e $NS/var/lib/bluetooth/k ] && [ -e $NS/etc/wireguard/wg0.conf ] && grep -qx 'user:x:1000:1000::/home/user:/bin/ash' $NS/etc/passwd"
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
# a deployment the clean-up would remove, mounted as a real overlay: it stays
mkdir -p $U/deployments/dk/build $U/deployments/dk/switch $U/deployments/dk/work; printf 'base=b1\nkind=reset\n' > $U/deployments/dk/meta
gr_assemble $S $U dk $W/rootk
ok "accept with a kept deployment mounted (a real overlay): accepted, the clean-up leaves it, says so" "$G accept $N >/dev/null 2>$W/err && [ \"\$(st current)\" = $N ] && [ -e $U/deployments/dk/meta ] && grep -q 'deployment dk is mounted' $W/err && mountpoint -q $W/rootk"
gr_umount $W/rootk
ok "remove, on real mounts: the unmounted kept deployment goes, nothing left aside" "$G remove dk </dev/null >/dev/null && [ ! -e $U/deployments/dk ] && [ -z \"\$(ls -A $U/deployments.removing)\" ]"
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
# one trial at a time: a kernel candidate (docs/kernel-artifacts.md)
KF=$S/state/kernel; cp $S/state/deploy $W/stK
printf 'current=7.0.0\ncandidate=7.1.0\ncandidate_img=abcd\ntries=1\n' > $KF
ok "a kernel candidate: the switch leaves the staged deployment staged" "$G switch >$W/out 2>&1 && grep -q 'stays staged' $W/out && [ \"\$(st staged)\" = \"\$A2\" ] && cmp -s $S/state/deploy $W/stK"
ok "a kernel candidate: reset refuses, exit 8, names glassine-bootimg cancel" "$G reset --yes 2>$W/err; [ \$? = 8 ] && grep -q 'glassine-bootimg cancel' $W/err && cmp -s $S/state/deploy $W/stK && [ -e $U/deployments/\$A2 ]"
ok "a kernel candidate: stage refuses, exit 8" "$G stage b1 --no-replay --yes 2>/dev/null; [ \$? = 8 ] && cmp -s $S/state/deploy $W/stK"
ok "reset --now: the kernel candidate cancelled first, said, then switched" "$G reset --full --now --yes >/dev/null 2>$W/err && grep -q 'kernel candidate 7.1.0 is cancelled first' $W/err && [ -z \"\$(gs_kv $KF candidate)\$(gs_kv $KF candidate_img)\$(gs_kv $KF tries)\" ] && [ \"\$(gs_kv $KF current)\" = 7.0.0 ] && [ -n \"\$(st candidate)\" ] && [ -z \"\$(st staged)\" ]"
rm -rf "$U/deployments/$(st candidate)"; cp $W/stK $S/state/deploy; rm -f $KF
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
printf '#!/bin/sh\necho "$*" >> %s/apk-calls\ncase " $* " in *" -s "*) ;; *" add "*) echo pkg > %s/usr/bin/pkgfile || exit 9 ;; esac\nexit ${APK_RC:-0}\n' $W $R > $W/apk; chmod +x $W/apk
gl() { GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/apk sh $GL "$@"; }
ok "glassine status: locked" "gl status | grep -qx 'root: locked'"
ok "apk without the acknowledgement, no terminal: refused, nothing run" "gl apk add foo </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'GLASSINE_APK_ACK=1' $W/err && [ ! -e $W/apk-calls ]"
ok "apk search (no change): runs, / stays read-only, no acknowledgement needed" "gl apk search foo </dev/null && grep -qx 'search foo' $W/apk-calls && ro $R/usr/bin/t1"
ok "apk add -s: runs, / stays read-only, no acknowledgement, no lock" "rm -f $W/run2/apk.lock; gl apk add -s foo </dev/null && grep -qx 'add -s foo' $W/apk-calls && ro $R/usr/bin/t9 && [ ! -e $W/run2/apk.lock ] && [ ! -e $R/etc/glassine/apk-acknowledged ]"
ok "apk del --simulate, -qs: the same" "gl apk del --simulate foo </dev/null && gl apk -qs upgrade </dev/null && grep -qx 'del --simulate foo' $W/apk-calls && grep -qx -- '-qs upgrade' $W/apk-calls && ro $R/usr/bin/t10 && [ ! -e $W/run2/apk.lock ]"
mkdir -p $W/uid1000; printf '#!/bin/sh\necho 1000\n' > $W/uid1000/id; chmod +x $W/uid1000/id
ok "apk add as a user: apk's own answer, no lock, / stays read-only, no acknowledgement" "PATH=$W/uid1000:\$PATH gl apk add foo </dev/null 2>/dev/null; [ \$? = 9 ] && grep -qx 'add foo' $W/apk-calls && ro $R/usr/bin/t11 && [ ! -e $W/run2/apk.lock ] && [ ! -e $R/etc/glassine/apk-acknowledged ]"
printf '#!/bin/sh\necho "$*" >> %s/apk-calls\ncase " $* " in *" info "*) ;; *" add "*) echo pkg > %s/usr/bin/pkgfile || exit 9 ;; *" update "*) echo lock > %s/usr/bin/apklock || exit 9 ;; esac\nexit ${APK_RC:-0}\n' $W $R $R > $W/apk
ok "apk update: / writable for the run, no acknowledgement needed, read-only after" "gl apk --no-progress update </dev/null && [ \"\$(cat $R/usr/bin/apklock)\" = lock ] && ro $R/usr/bin/t7 && [ ! -e $R/etc/glassine/apk-acknowledged ]"
ok "apk info update (a package called update): / stays read-only" "gl apk info update </dev/null && grep -qx 'info update' $W/apk-calls && ro $R/usr/bin/t8"
ok "apk add: / writable for the run (the package lands), read-only after" "GLASSINE_APK_ACK=1 gl apk add foo && [ \"\$(cat $R/usr/bin/pkgfile)\" = pkg ] && ro $R/usr/bin/t2 && [ -e $R/etc/glassine/apk-acknowledged ]"
ok "apk: the change lands in the deployment's upper" "[ -e $U/deployments/d1/switch/usr/bin/pkgfile ]"
ok "apk: acknowledged once, then no more question; apk's exit code passed on" "APK_RC=3 gl apk del foo </dev/null; [ \$? = 3 ] && ro $R/usr/bin/t3"
mv $R/etc/glassine/apk-acknowledged $W/ack.sv; : > $W/apk-calls
ok "apk search cache, apk info fix: not changes (no acknowledgement, / stays read-only)" "gl apk search cache </dev/null && gl apk info fix </dev/null && grep -qx 'search cache' $W/apk-calls && grep -qx 'info fix' $W/apk-calls && [ ! -e $R/etc/glassine/apk-acknowledged ] && ro $R/usr/bin/t12"
mv $W/ack.sv $R/etc/glassine/apk-acknowledged
ok "apk -X URL add, --cache-dir DIR add: the applet is found past an option's value (the stub fails with 9 unless / is writable)" "gl apk -X http://x/y --no-progress add qq </dev/null && gl apk --cache-dir /x add zz </dev/null && grep -qx -- '--cache-dir /x add zz' $W/apk-calls && ro $R/usr/bin/t13"
ok "apk while another change holds the lock: waits, then runs" "( exec 8>>$W/run2/apk.lock; flock 8; sleep 2 ) & sleep 0.5; gl apk fix 2>$W/err && grep -q 'waiting' $W/err && ro $R/usr/bin/t4"
wait
printf '#!/bin/sh\n[ -e /proc/$$/fd/8 ] && echo leaked > %s/fd8\nexit 0\n' $W > $W/apkfd; chmod +x $W/apkfd; rm -f $W/fd8
ok "apk: the lock (fd 8) is not inherited by apk and its scripts" "GLASSINE_APK_ACK=1 GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/apkfd sh $GL apk add foo && [ ! -e $W/fd8 ]"
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
ok "apk: GLASSINE_APK is the wrapper itself (a link): refused, no loop, nothing run" "ln -sf $GL $W/selfapk && : > $W/apk-calls && GLASSINE_APK_ACK=1 GLASSINE_DEPLOY_CONF=$W/gl.conf GLASSINE_ROOT=$R GLASSINE_APK=$W/selfapk sh $GL apk search foo </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'is this wrapper' $W/err && [ ! -s $W/apk-calls ]"
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
# the replay changed /etc/passwd only (a package script adding a system user): the build
# layer holds that one file, group and shadow come from the base
mkdir -p $U/deployments/$SB/build/etc && printf '%s\nnewsvc:x:200:200::/:/sbin/nologin\n' "$(cat $B2/etc/passwd)" > $U/deployments/$SB/build/etc/passwd
ok "bases: the staged deployment uses b2" "$G bases --porcelain | grep -q 'name=b2	used_by=$SB'"
ok "switch: the staged update is the candidate" "$G switch >$W/swout 2>&1 && [ \"\$(st candidate)\" = $SB ] && [ -z \"\$(st staged)\" ]"
ok "switch: accounts merged (user + its password + wheel membership; bluetooth at the new base's ID)" "grep -qx 'user:x:1000:1000::/home/user:/bin/ash' $SW/etc/passwd && grep -qx 'bluetooth:x:101:101::/:/sbin/nologin' $SW/etc/passwd && grep -q '^user:\$6\$u:' $SW/etc/shadow && grep -qx 'wheel:x:10:root,user' $SW/etc/group && grep -qx 'user:x:1000:' $SW/etc/group"
ok "switch: a build layer with only passwd: the new account is in, the base's groups and shadow rows stay" "grep -qx 'newsvc:x:200:200::/:/sbin/nologin' $SW/etc/passwd && grep -qx 'root:x:0:root' $SW/etc/group && grep -qx 'shadow:x:42:' $SW/etc/group && grep -q '^bluetooth:' $SW/etc/shadow && [ \"\$(stat -c %u:%g:%a $SW/etc/shadow)\" = 0:42:640 ]"
ok "switch: carried files follow the moved bluetooth ID" "[ \"\$(stat -c %u:%g $SW/var/lib/bluetooth/AA/info)\" = 101:101 ] && [ \"\$(stat -c %u:%g $SW/var/lib/bluetooth/AA)\" = 101:101 ]"
ok "switch: reports the merge" "grep -q 'user user kept' $W/swout && grep -q 'uid 100 -> 101' $W/swout && [ ! -e $U/deployments/$SB/idmap ]"
ok "the candidate's root: the new base with the carried settings" "gr_assemble $S $U $SB $R && [ \"\$(cat $R/etc/motd)\" = two ] && [ \"\$(cat $R/etc/hostname)\" = myhost ] && [ \"\$(cat $R/etc/eink/eink.conf)\" = later ] && [ \"\$(cat $R/var/lib/bluetooth/AA/info)\" = key ] && grep -q '^user:' $R/etc/passwd"
gr_umount $R
# a base without /etc/passwd: the switch refuses, stays staged
btrfs -q subvolume create $W/src/bad; mkdir $W/src/bad/etc; btrfs property set -ts $W/src/bad ro true
btrfs -q send $W/src/bad | $G receive - >/dev/null
. /p/lib/glassine-accounts.sh
mkdir -p $W/wo/up $W/wo/low; echo 'root:x:0:root' > $W/wo/low/group; echo 'root:*:1::::::' > $W/wo/low/shadow; mknod $W/wo/up/shadow c 0 0
ga_lower $W/wo/out $W/wo/up $W/wo/low
ok "ga_lower: a whiteout in the build layer (a real overlay upper has them): deleted, not read from the base" "[ ! -e $W/wo/out/shadow ] && [ -e $W/wo/out/group ]"
ok "stage: a base without /etc/passwd: refused" "$G stage bad --yes 2>$W/err; [ \$? = 1 ] && grep -q 'no /etc/passwd' $W/err"
# a new base with an account at the kept user's ID: the switch refuses, nothing selected
btrfs -q subvolume snapshot $B2 $W/src/b4
printf 'clash:x:1000:1000::/:/sbin/nologin\n' >> $W/src/b4/etc/passwd; printf 'clash:x:1000:\n' >> $W/src/b4/etc/group
btrfs property set -ts $W/src/b4 ro true; btrfs -q send $W/src/b4 | $G receive - >/dev/null
$G stage b4 --yes >/dev/null; SK=$(st staged); cp $S/state/deploy $W/stK
ok "switch: a kept user's ID taken in the new base: refused, names the IDs, stays staged, nothing selected" "$G switch 2>$W/err; [ \$? = 1 ] && grep -q 'kept accounts would change ID (gid 1000 -> 1001, uid 1000 -> 1001)' $W/err && cmp -s $S/state/deploy $W/stK && [ \"\$(st staged)\" = $SK ] && [ ! -e $W/run/switching ] && ! grep -q '$W/run' /proc/mounts"
gs_update $S/state/deploy staged=; rm -rf $U/deployments/$SK
btrfs property set -fts $S/bases/b4 ro false; btrfs -q subvolume delete $S/bases/b4
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
# the same for the kernel (state/kernel, docs/kernel-artifacts.md)
echo "rdinit=/init glassine.img=bbbb" > $W/cmdline; export GLASSINE_PROC_CMDLINE=$W/cmdline
printf 'current=7.0.0\ncurrent_img=aaaa\n' > $S/state/kernel
ok "hibernate: the next boot runs another kernel image (a kernel rollback since this boot): exit 3" "hn check; [ \$? = 3 ] && grep -q 'next boot runs kernel image aaaa' $W/hout"
printf 'current=7.0.0\ncurrent_img=aaaa\ncandidate_img=bbbb\ntries=0\n' > $S/state/kernel
ok "hibernate: a kernel trial: exit 3" "hn check; [ \$? = 3 ] && grep -q 'kernel trial' $W/hout"
printf 'current=7.0.0\ncurrent_img=bbbb\nwriting=cccc\nwriting_op=rollback\n' > $S/state/kernel
ok "hibernate: an unfinished default-slot write: exit 3" "hn check; [ \$? = 3 ] && grep -q 'unfinished' $W/hout"
rm $S/state/kernel; unset GLASSINE_PROC_CMDLINE
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
# the board's DEVICE_PART (sysfs stand-in: GD_SYS_BLOCK) mounted read-write: refused
truncate -s 16M $W/devdata.img; mkfs.ext4 -q -F $W/devdata.img; loop $W/devdata.img; DPD=$LOOP
mkdir -p $W/sysblock/dp $W/dpmnt; printf 'MAJOR=7\nDEVNAME=%s\nPARTNAME=devdata\n' "${DPD#/dev/}" > $W/sysblock/dp/uevent
printf 'DEVICE_PART=devdata\n' > $W/board.conf
hd() { GLASSINE_BOARD_CONF=$W/board.conf GD_SYS_BLOCK=$W/sysblock hn "$@"; }
mount -o ro $DPD $W/dpmnt
ok "check: DEVICE_PART mounted read-only: ready" "hd check"
umount $W/dpmnt; mount -o rw $DPD $W/dpmnt
ok "check: DEVICE_PART mounted read-write (the seed tool writing): exit 3, said" "hd check; [ \$? = 3 ] && grep -q 'devdata (the device seed.s partition, $DPD) is mounted read-write' $W/hout"
ok "now: DEVICE_PART mounted read-write: exit 3, nothing touched" "hd now; [ \$? = 3 ] && [ ! -s $HC ] && [ ! -e $HP/resume ]"
umount $W/dpmnt
ok "check: DEVICE_PART not mounted: ready" "hd check"
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
# a file in the deployment's own /home, which the storage bind must hide, never move
mkdir -p $U/deployments/$CUR/switch/home && echo own > $U/deployments/$CUR/switch/home/own-file
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

ok "the invalidated image's guard is still on userdata before the boot" "debugfs -R 'stat /$P/swap/hibernate.guard' $UDEV 2>/dev/null | grep -q '^Inode:'"
ok "gr_boot: the current deployment, system + userdata mounted, state locked" "gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = $CUR ] && mountpoint -q $R.sys && mountpoint -q $R.ud && ro $R/usr/bin/x && ! flock -n $R.sys/state/.lock true"
ok "gr_boot: the stale hibernate guard removed" "[ ! -e $R.ud/$P/swap/hibernate.guard ]"
ok "gr_carry: mounts under /run/glassine, booted recorded, lock released" "gr_carry $R && mountpoint -q $R/run/glassine/system && mountpoint -q $R/run/glassine/userdata && mountpoint -q $R/run/glassine/root && ! mountpoint -q $R.sys && [ \"\$(cat $R/run/glassine/booted)\" = $CUR ] && flock -n $R/run/glassine/system/state/.lock true"
ok "after the carry: / still read-only, /etc writable" "ro $R/usr/bin/x && echo c > $R/etc/carried && [ -e $R/run/glassine/userdata/$P/deployments/$CUR/switch/etc/carried ]"
sed -e "s|^SYSTEM_MNT=.*|SYSTEM_MNT=$R/run/glassine/system|" -e "s|^USERDATA_MNT=.*|USERDATA_MNT=$R/run/glassine/userdata|" -e "s|^RUN_DIR=.*|RUN_DIR=$R/run/glassine|" $W/deploy.conf > $W/deploy3.conf
# the person's storage (FR-014..019)
RU=$R/run/glassine/userdata/$P
shared() { awk -v m="$1" '$5 == m { for (i = 7; $i != "-"; i++) if ($i ~ /^shared:/) s = 1 } END { exit !s }' /proc/self/mountinfo; }
ok "storage: home/ and flatpak/ made on userdata (root:root 0755), bound on /home and /var/lib/flatpak" "mountpoint -q $R/home && mountpoint -q $R/var/lib/flatpak && [ \"\$(stat -c '%u:%g %a' $RU/home)\" = '0:0 755' ] && [ \"\$(stat -c '%u:%g %a' $RU/flatpak)\" = '0:0 755' ]"
ok "storage: a write in /home and /var/lib/flatpak lands on userdata, not in the deployment" "mkdir -p $R/home/1000 && echo h > $R/home/1000/f && echo a > $R/var/lib/flatpak/app && [ -e $RU/home/1000/f ] && [ -e $RU/flatpak/app ] && [ ! -e $RU/deployments/$CUR/switch/home/1000 ] && [ ! -e $RU/deployments/$CUR/switch/var/lib/flatpak/app ]"
ok "storage: the deployment's own /home hidden by the bind, not moved or deleted" "[ ! -e $R/home/own-file ] && [ \"\$(cat $RU/deployments/$CUR/switch/home/own-file)\" = own ]"
ok "storage: /var/tmp a shared bind of itself, its files in the deployment's /var" "shared $R/var/tmp && echo t > $R/var/tmp/t && [ -e $RU/deployments/$CUR/switch/var/tmp/t ]"
ok "storage: recorded for status in /run/glassine/storage" "[ \"\$(cat $R/run/glassine/storage | tr '\n' ' ')\" = 'home=bound flatpak=bound vartmp=shared ' ]"
ok "storage: status reports the binds and the non-empty hidden /home" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G status --porcelain | grep -q '	home=bound	home_hidden=yes	flatpak=bound	flatpak_hidden=no	vartmp=shared	'"
ok "the system's glassine-deploy works on the carried mounts (select = a state write)" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G select d1 >/dev/null && [ \"\$(gs_kv $R/run/glassine/system/state/deploy candidate)\" = d1 ] && GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G select $CUR >/dev/null"
# the shutdown switch in the running system: OpenRC's localmount has unmounted
# /run/glassine/*; a mount on top of / must not leak into the carried state
GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G reset --yes >/dev/null; LS=$(gs_kv $R/run/glassine/system/state/deploy staged)
echo live > $R/etc/eink/eink.conf
mount -t tmpfs tmpfs $R/var/lib/bluetooth && echo submount > $R/var/lib/bluetooth/fromsubmount
umount $R/run/glassine/root $R/run/glassine/userdata $R/run/glassine/system
ok "switch in the running deployment: carries from its live root, selects, leaves nothing mounted" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf GLASSINE_DEPLOY_ROOT=$R $G switch >/dev/null && LSW=$U/deployments/$LS/switch && mount -t ext4 $UDEV $W/udmnt && [ \"\$(cat $W/udmnt/$P/deployments/$LS/switch/etc/eink/eink.conf)\" = live ] && ! grep -q 'view\.' /proc/mounts"
ok "switch in the running deployment: a mount on top of / is not carried" "[ -e $W/udmnt/$P/deployments/$LS/switch/var/lib/bluetooth/k ] && [ ! -e $W/udmnt/$P/deployments/$LS/switch/var/lib/bluetooth/fromsubmount ]"
ok "switch in the running deployment: home and Flatpak's data not carried (the binds), still on userdata" "[ ! -e $W/udmnt/$P/deployments/$LS/switch/home/1000 ] && [ ! -e $W/udmnt/$P/deployments/$LS/switch/var/lib/flatpak/app ] && [ -e $W/udmnt/$P/home/1000/f ]"
umount $W/udmnt $R/var/lib/bluetooth
# OpenRC's localmount has also unmounted the person's storage binds (their
# mount points aren't in its keep list)
umount $R/home $R/var/lib/flatpak $R/var/tmp
# power-off (glassine-mount-ro, after OpenRC's mount-ro, which remounted the /etc
# bind read-only and with it the overlay): userdata is in no mount table any more,
# only the overlay keeps it alive, so its journal still needs a replay
needs_rec() { dumpe2fs -h $UDEV 2>/dev/null | grep -q '^Filesystem features:.*needs_recovery'; }
ok "power-off, before the step: userdata in no mount table, alive and dirty" "! grep -q '^$UDEV ' /proc/mounts && needs_rec"
exec 8>$R/var/busy
ok "gr_shutdown_ro with a writer left (a file open for writing): refused, said, still writable, no mount left" "! gr_shutdown_ro $UDEV 2>$W/err && grep -q 'cannot remount read-only (still in use), left writable' $W/err && needs_rec && echo y > $R/var/still && ! grep -q ' $GR_TMP/ro ' /proc/mounts"
exec 8>&-
mount -o remount,ro $R/etc
ok "gr_shutdown_ro userdata: read-only, journal clean, the extra mount gone" "gr_shutdown_ro $UDEV 2>$W/err && ! needs_rec && [ ! -s $W/err ] && ! grep -q '^$UDEV ' /proc/mounts"
ok "gr_shutdown_ro: the overlay's upper is read-only (a write through it fails)" "mount -o remount,rw $R/etc 2>/dev/null; ! sh -c 'echo x > $R/etc/after-ro' 2>/dev/null"
mount -t btrfs $SD $W/sysmnt
ok "gr_shutdown_ro system: read-only, with a mount of it that is still in the table" "gr_shutdown_ro $SD 2>$W/err && [ ! -s $W/err ] && roflag $W/sysmnt && ro $W/sysmnt/after-ro && [ \$(grep -c '^$SD ' /proc/mounts) = 3 ]"
umount $W/sysmnt
ok "gr_shutdown_ro of a file system that isn't mounted: nothing mounted, nothing written" "S0=\$(md5sum < $W/ud2.img) && gr_shutdown_ro $UD2 && [ \"\$(md5sum < $W/ud2.img)\" = \"\$S0\" ] && ! grep -q '^$UD2 ' /proc/mounts"
ok "gr_shutdown_ro of a path that isn't a device: nothing" "gr_shutdown_ro $W/nodev"
# the rest of the test: both writable again
mkdir -p $W/rw && mount -t ext4 -o ro $UDEV $W/rw && mount -o remount,rw $W/rw && umount $W/rw
mount -t btrfs $SD $W/rw && umount $W/rw    # btrfs: a read-write mount of a read-only one makes it read-write
mount -o remount,rw $R/etc
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
echo version=1 > $R.sys/state/format
# the kernel trial (FR-011): a deployment candidate it must not pick or try
gs_update $R.sys/state/deploy candidate=d1 tries=2
printf 'current=7.3.0\ncandidate=7.4.0\ncandidate_img=c0ffee\ntries=1\nrequested=c0ffee\n' > $R.sys/state/kernel
gr_boot_umount $R
ok "gr_kernel_mode: the candidate's image a trial, another none, read-only and unmounted again" "[ \"\$(gr_kernel_mode $SD c0ffee)\" = trial ] && [ -z \"\$(gr_kernel_mode $SD beef)\$(gr_kernel_mode $SD '')\" ] && ! grep -q '$GR_TMP' /proc/mounts"
# the state lock held on a trial boot: it still boots as a trial, nothing written
mount -t btrfs $SD $S; ( exec 8>>$S/state/.lock; flock -n 8 && : > $W/lheld; exec sleep 60 ) & LH=$!
while [ ! -e $W/lheld ]; do sleep 0.1; done
ok "gr_boot, a kernel trial with the state locked: boots current, the try not taken, said" "gr_boot $SD $UDEV $P $R 7.3.0 c0ffee 2>$W/blog && [ \"\$GR_KBOOT\" = trial ] && [ \"\$GR_BOOTED\" = $CUR ] && [ \"\$(gs_kv $R.sys/state/kernel tries)\" = 1 ] && [ \"\$(gs_kv $R.sys/state/kernel requested)\" = c0ffee ] && grep -q 'its try could not be taken' $W/blog"
kill $LH; wait $LH 2>/dev/null; rm -f $W/lheld
gr_boot_umount $R; umount $S
ok "gr_boot, a kernel trial: the try taken, requested cleared, current with no deployment pick or try" "gr_boot $SD $UDEV $P $R 7.3.0 c0ffee 2>$W/blog && [ \"\$GR_KBOOT\" = trial ] && [ \"\$GR_BOOTED\" = $CUR ] && [ \"\$(gs_kv $R.sys/state/kernel tries)\" = 0 ] && [ -z \"\$(gs_kv $R.sys/state/kernel requested)\" ] && [ \"\$(gs_kv $R.sys/state/deploy candidate)\" = d1 ] && [ \"\$(gs_kv $R.sys/state/deploy tries)\" = 2 ]"
ok "gr_carry after a trial: kernel-boot = trial" "gr_carry $R && [ \"\$(cat $R/run/glassine/kernel-boot)\" = trial ]"
# a release the base has no directory for (a base never carries one)
mkdir -p $R/run/glassine/system/modules/7.4.0-new; echo ko > $R/run/glassine/system/modules/7.4.0-new/x.ko
gr_boot_umount $R
ok "gr_boot: a release the base has no directory for: made through the merged root, the modules bound" "gr_boot $SD $UDEV $P $R 7.4.0-new c0ffee 2>$W/blog && [ \"\$(cat $R/lib/modules/7.4.0-new/x.ko)\" = ko ] && mountpoint -q $R/lib/modules/7.4.0-new && ! grep -q 'no modules for' $W/blog"
gr_carry $R
gs_update $R/run/glassine/system/state/kernel writing=c0ffee writing_op=accept requested=c0ffee
gr_boot_umount $R
ok "gr_kernel_mode: the image writing names: finishing" "[ \"\$(gr_kernel_mode $SD c0ffee)\" = finishing ]"
ok "gr_boot, a finishing boot: no try taken, state/kernel unwritten, current with no pick" "gr_boot $SD $UDEV $P $R 7.3.0 c0ffee 2>$W/blog && [ \"\$GR_KBOOT\" = finishing ] && [ \"\$GR_BOOTED\" = $CUR ] && [ \"\$(gs_kv $R.sys/state/kernel requested)\" = c0ffee ] && [ \"\$(gs_kv $R.sys/state/deploy tries)\" = 2 ]"
gs_update $R.sys/state/kernel writing= writing_op=; echo version=9 > $R.sys/state/format
gr_boot_umount $R
ok "a newer state format: no kernel trial, state/kernel unwritten" "[ -z \"\$(gr_kernel_mode $SD c0ffee)\" ] && gr_boot $SD $UDEV $P $R 7.3.0 c0ffee 2>$W/blog && [ -z \"\$GR_KBOOT\" ] && [ \"\$GR_BOOTED\" = d1 ] && [ \"\$(gs_kv $R.sys/state/kernel requested)\" = c0ffee ]"
ok "gr_carry, no kernel trial: kernel-boot empty" "gr_carry $R && [ -e $R/run/glassine/kernel-boot ] && [ -z \"\$(cat $R/run/glassine/kernel-boot)\" ]"
echo version=1 > $R/run/glassine/system/state/format; rm $R/run/glassine/system/state/kernel
gs_update $R/run/glassine/system/state/deploy candidate= tries=0
gr_boot_umount $R
# storage failures: flatpak/ can't be created (a file of that name), the /home bind fails
mount -t ext4 $UDEV $W/udmnt && echo notadir > $U/flatpak.tmp && mv $U/flatpak $W/flatpak.saved && mv $U/flatpak.tmp $U/flatpak && umount $W/udmnt
( mount() { case "$*" in *--bind*/home*) return 1 ;; esac; command mount "$@"; }; gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && gr_carry $R )
ok "storage: a failed bind and a directory that can't be made: logged, the deployment's own directories, the boot goes on" "[ \"\$(cat $R/run/glassine/booted)\" = $CUR ] && grep -q '/home: the bind on /home failed' $W/blog && grep -q '/var/lib/flatpak: cannot create flatpak/ on userdata' $W/blog && ! mountpoint -q $R/home && ! mountpoint -q $R/var/lib/flatpak && [ \"\$(cat $R/home/own-file)\" = own ]"
ok "storage: nothing written into the userdata directories, the failures recorded" "[ \"\$(cat $R/run/glassine/userdata/$P/flatpak)\" = notadir ] && [ -z \"\$(ls -A $R/run/glassine/userdata/$P/home | grep -v '^1000\$')\" ] && grep -qx home=failed $R/run/glassine/storage && grep -qx 'home_error=the bind on /home failed' $R/run/glassine/storage && grep -qx flatpak=failed $R/run/glassine/storage && grep -qx vartmp=shared $R/run/glassine/storage"
ok "storage: status reports the failures" "GLASSINE_DEPLOY_CONF=$W/deploy3.conf $G status --porcelain | grep -q '	home=failed	home_error=the bind on /home failed	home_hidden=yes	flatpak=failed	flatpak_error=cannot create flatpak/ on userdata	'"
rm -f $R/run/glassine/userdata/$P/flatpak && mv $W/flatpak.saved $R/run/glassine/userdata/$P/flatpak
gr_boot_umount $R
ok "storage: the next boot tries again and binds both" "gr_boot $SD $UDEV $P $R 7.3.0 2>$W/blog && mountpoint -q $R/home && mountpoint -q $R/var/lib/flatpak && [ -e $R/var/lib/flatpak/app ] && [ -e $R/home/1000/f ]"
gr_boot_umount $R
ok "gr_boot without userdata: bare on the newest base" "gr_boot $SD '' $P $R 7.3.0 2>$W/blog && [ \"\$GR_BOOTED\" = bare:b1 ] && [ \"\$(cat $R/etc/motd)\" = welcome ] && gr_carry $R && mountpoint -q $R/run/glassine/bare"
ok "a bare boot binds nothing from userdata; /var/tmp shared" "! mountpoint -q $R/home && ! mountpoint -q $R/var/lib/flatpak && shared $R/var/tmp && [ \"\$(cat $R/run/glassine/storage)\" = vartmp=shared ]"
gr_boot_umount $R
mount -t btrfs $SD $S && mount -t ext4 $UDEV $W/udmnt
ok "base unchanged after everything" "[ \"\$(basesum)\" = \"\$SUM0\" ]"

# The initramfs's device data step (gd_boot, lib/glassine-device.sh) on a real
# ext4 DEVICE_PART ($DPD): bind when the seed's files verify, else nothing.
. /p/lib/glassine-device.sh
GD=$W/gdroot; mkdir -p $GD/run; : > $W/gdcmd; FWP=$W/fwparam
gdb() { : > $FWP; gd_boot $GD $DPD $W/gdcmd $FWP 2>$W/gdlog; }
gdun() { umount $GD/run/glassine/device 2>/dev/null; umount $GD/run/glassine/device-part 2>/dev/null; }
gdnone() { ! mountpoint -q $GD/run/glassine/device && ! mountpoint -q $GD/run/glassine/device-part && [ ! -s $FWP ]; }
gdw() { mount -o rw $DPD $W/dpmnt && sh -c "$1" && umount $W/dpmnt; }
echo keep > $W/other
gdw "cp $W/other $W/dpmnt/other"
ok "gd_boot: no seed on DEVICE_PART: nothing bound, said" "gdb && gdnone && grep -q 'no seed on $DPD yet' $W/gdlog"
gdw "mkdir -p $W/dpmnt/glassine/firmware/vendor && echo w > $W/dpmnt/glassine/waveform.wbf && echo f > $W/dpmnt/glassine/firmware/vendor/a.bin && printf 'format=1\nfirmware/vendor/a.bin p1:/a %s\nwaveform.wbf p1:/w %s\nfirmware/vendor/b.bin p1:/b %s\n' \$(echo f | sha256sum | cut -d' ' -f1) \$(echo w | sha256sum | cut -d' ' -f1) 0123 > $W/dpmnt/glassine/manifest"
ok "gd_boot: a seed that verifies (one line not held): bound read-only, DEVICE_PART read-only" "gdb && [ \"\$(cat $GD/run/glassine/device/waveform.wbf)\" = w ] && ! touch $GD/run/glassine/device/x 2>/dev/null && awk -v m=$GD/run/glassine/device-part '\$2 == m' /proc/mounts | grep -q ' ro,' && grep -q 'seed bound on /run/glassine/device, firmware path set' $W/gdlog"
ok "gd_boot: the firmware path as the booted system sees it, no newline" "[ \"\$(od -c $FWP | head -n 1 | tr -s ' ')\" = \"\$(printf '/run/glassine/device/firmware' | od -c | head -n 1 | tr -s ' ')\" ] && [ \$(wc -c < $FWP) = 29 ]"
gdun
echo 'console=ttyS0 firmware_class.path=/lib/fw-board' > $W/gdcmd
ok "gd_boot: firmware_class.path on the command line: bound, the parameter not written" "gdb && mountpoint -q $GD/run/glassine/device && [ ! -s $FWP ]"
gdun; : > $W/gdcmd
gdw "echo x > $W/dpmnt/glassine/waveform.wbf"
ok "gd_boot: a file that doesn't verify: nothing bound, nothing left mounted" "gdb && gdnone && grep -q \"doesn't verify\" $W/gdlog"
gdw "echo w > $W/dpmnt/glassine/waveform.wbf && echo s > $W/dpmnt/glassine/.waveform.wbf.new"
ok "gd_boot: a stray file (a cut-off write's temp file): nothing bound" "gdb && gdnone"
gdw "rm $W/dpmnt/glassine/.waveform.wbf.new"
debugfs -w -R 'feature needs_recovery' $DPD >/dev/null 2>&1
ok "gd_boot: the journal needs recovery: nothing bound, DEVICE_PART not mounted" "gdb && gdnone && grep -q 'journal of $DPD needs recovery' $W/gdlog"
debugfs -w -R 'feature -needs_recovery' $DPD >/dev/null 2>&1
ok "gd_boot: bound again once it verifies" "gdb && mountpoint -q $GD/run/glassine/device"
gdun
ok "gd_boot: DEVICE_PART's other files untouched" "mount -o ro $DPD $W/dpmnt && cmp -s $W/dpmnt/other $W/other; r=\$?; umount $W/dpmnt; [ \$r = 0 ]"

finish
echo "$fails failed"
[ $fails = 0 ]
