#!/bin/sh
# The soft restart (specs/013) on real file systems; see test.sh.
set -u
# own PID namespace: nothing here may signal the container's processes
if [ -z "${GLASSINE_TEST_PIDNS:-}" ]; then
    GLASSINE_TEST_PIDNS=1 exec unshare -fp --mount-proc sh "$0" "$@"
fi
W=/w; mkdir -p $W && mount -t tmpfs -o size=900m tmpfs $W
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
. /p/lib/glassine-root.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); tail -n 3 $W/e2e.log 2>/dev/null; fi; }
P=media/glassine
KR=$(uname -r)
LOOPS=''
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1" && LOOPS="$LOOPS $LOOP"
}
GR_TMP=$W/grtmp; mkdir -p $GR_TMP
gr_log() { echo "gr: $*" >> $W/blog; }

# --- the partitions: a base that can run as a root (a static busybox, an init
# that reports what it found), two deployments, the running kernel's modules -----
truncate -s 256M $W/sys.img; mkfs.btrfs -q $W/sys.img
truncate -s 192M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 $W/ud.img
loop $W/sys.img; SD=$LOOP; loop $W/ud.img; UDEV=$LOOP
mkdir -p $W/sysmnt $W/udmnt
mount -t btrfs "$SD" $W/sysmnt && mount -t ext4 "$UDEV" $W/udmnt || { echo "FAIL cannot mount the loop devices"; exit 1; }
S=$W/sysmnt
mkdir -p $S/bases $S/modules $S/state
btrfs -q subvolume create $S/bases/b1
B=$S/bases/b1
mkdir -p $B/bin $B/sbin $B/etc $B/proc $B/sys $B/dev $B/run $B/tmp $B/home $B/var/lib/flatpak $B/var/tmp $B/usr/share/glassine $B/lib/modules $B/lib/firmware
cp /bin/busybox.static $B/bin/busybox; ln -s busybox $B/bin/sh
echo 'root:x:0:0:root:/root:/bin/sh' > $B/etc/passwd; echo 'root:x:0:root' > $B/etc/group
echo glassine > $B/etc/hostname
printf '/etc/hostname\n' > $B/usr/share/glassine/migrate.list
# the incoming session's init: what it found, onto userdata, then it ends (PID 1 of
# the test's namespace: the namespace ends with it)
cat > $B/sbin/init <<'INIT'
#!/bin/busybox sh
o=/run/glassine/userdata/media/glassine/report
/bin/busybox mkdir -p $o
/bin/busybox cat /proc/mounts > $o/mounts
/bin/busybox ls -A /run/glassine > $o/run
/bin/busybox ls -A /run/glassine/kept > $o/kept
/bin/busybox cp /run/glassine/restart /run/glassine/booted /run/glassine/storage $o/ 2>/dev/null
echo $$ > $o/pid
/bin/busybox sync
INIT
chmod 755 $B/sbin/init
btrfs property set -ts $B ro true
btrfs -q subvolume create $S/modules/$KR
mkdir -p $S/modules/$KR/kernel; echo ko > $S/modules/$KR/kernel/x.ko
btrfs property set -ts $S/modules/$KR ro true
echo version=1 > $S/state/format
U=$W/udmnt/$P
for d in d1 d2; do mkdir -p $U/deployments/$d/build && printf 'base=b1\nkind=install\ncarry=none\n' > $U/deployments/$d/meta; done
mkdir -p $U/deployments/dz && printf 'base=gone\n' > $U/deployments/dz/meta
mkdir -p $U/home $U/flatpak
ST0='current=d1\nprevious=d0\ncandidate=\ntries=0\nfailed=\nstaged=\n'
printf "$ST0" > $S/state/deploy
R=$W/root

# a boot initramfs's root (what gr_keep keeps)
IR=$W/ir
mkdir -p $IR/bin $IR/lib/glassine-boot $IR/etc/glassine-boot
cp /p/initramfs/init /p/initramfs/soft $IR/; cp /bin/busybox.static $IR/bin/busybox
for l in glassine-state glassine-root glassine-bootpart glassine-device; do cp /p/lib/$l.sh $IR/lib/glassine-boot/; done
printf 'ROOT_LAYOUT=deployments\nUSERDATA_PREFIX=%s\n' $P > $IR/etc/glassine-boot/board.conf
echo "rdinit=/init glassine.img=1abb421e678cbd3b" > $W/cmdline

# --- the kept assembly -----------------------------------------------------------
ok "gr_keep: init, soft, busybox, the libraries, board.conf; .complete last" "gr_keep $IR $W/kept && [ -x $W/kept/soft ] && [ -x $W/kept/bin/busybox ] && [ -r $W/kept/lib/glassine-boot/glassine-root.sh ] && [ -r $W/kept/etc/glassine-boot/board.conf ] && [ -e $W/kept/.complete ]"
mkdir -p $IR/lib/glassine-boot/hooks.d $IR/lib/glassine-boot/modules; echo x > $IR/lib/glassine-boot/hooks.d/a.sh
ok "gr_keep: no developer hooks, no boot modules (cold-start steps only)" "gr_keep $IR $W/kept && [ ! -e $W/kept/lib/glassine-boot/hooks.d ] && [ ! -e $W/kept/lib/glassine-boot/modules ]"
rm -rf $IR/lib/glassine-boot/hooks.d $IR/lib/glassine-boot/modules
ok "gr_keep: a copy that fails leaves no .complete" "! gr_keep $W/nothere $W/kept 2>/dev/null && [ ! -e $W/kept/.complete ]"

# --- SC-002: the soft start's state/deploy equals a cold start's, byte for byte ---
# cold NAME STATE / soft NAME STATE: one start of each kind from STATE; the state it
# leaves in $W/<kind>.NAME, what booted in $W/<kind>.NAME.booted
# shellcheck disable=SC2034  # read by gr_carry
unset_rs() { GR_RS_KIND='' GR_RS_FROM='' GR_RS_COUNT='' GR_RS_SWITCH='' GR_CARRY_FROM='' GR_KEEP_SRC='' GR_KEEP_NONE=''; }
mtab() { awk -v r="$R" '$2 == r || index($2, r "/") == 1 || $2 == r ".rw" { sub(r, "R", $2); print $2, $3 }' /proc/mounts | sort; }
cold() {
    printf "$2" > $S/state/deploy; unset_rs
    gr_boot $SD $UDEV $P $R $KR 2>/dev/null && gr_carry $R || return 1
    cp $S/state/deploy $W/cold.$1; echo "$GR_BOOTED" > $W/cold.$1.booted
    mtab > $W/cold.$1.mtab; ls -A $R/run/glassine > $W/cold.$1.run
    gr_boot_umount $R; return 0
}
soft() {
    printf "$2" > $S/state/deploy; unset_rs
    mkdir -p $R.sys $R.ud && mount -t btrfs -o rw,noatime $SD $R.sys && mount -t ext4 -o rw,noatime $UDEV $R.ud || return 1
    # shellcheck disable=SC2034  # read by gr_carry
    GR_RS_KIND=soft GR_RS_FROM=d1 GR_RS_COUNT=1
    if ! gr_soft_boot $P $R $KR; then exec 9>&-; umount $R.ud $R.sys; return 1; fi
    gr_carry $R || return 1
    cp $S/state/deploy $W/soft.$1; echo "$GR_BOOTED" > $W/soft.$1.booted
    mtab > $W/soft.$1.mtab; ls -A $R/run/glassine > $W/soft.$1.run
    [ "${KEEP_ASSEMBLED:-}" = 1 ] || gr_boot_umount $R; return 0
}
same() { cmp -s $W/cold.$1 $W/soft.$1 && cmp -s $W/cold.$1.booted $W/soft.$1.booted; }
MC0=$(gs_dumpe2fs $UDEV 'Mount count')
pick() { cold "$1" "$2" && soft "$1" "$2" && same "$1"; }
ok "SC-002: a candidate with tries: the same state (its try used once), the candidate starts" "pick tries 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n' && [ \"\$(cat $W/soft.tries.booted)\" = d2 ] && [ \"\$(gs_kv $W/soft.tries tries)\" = 1 ]"
ok "SC-002: a candidate with no tries left: the same state (marked failed), current starts" "pick none 'current=d1\nprevious=d0\ncandidate=d2\ntries=0\nfailed=\nstaged=\n' && [ \"\$(cat $W/soft.none.booted)\" = d1 ] && [ \"\$(gs_kv $W/soft.none failed)\" = d2 ]"
ok "SC-002: a candidate that doesn't assemble: the same state (marked failed), current starts" "pick broken 'current=d1\nprevious=d0\ncandidate=dz\ntries=2\nfailed=\nstaged=\n' && [ \"\$(cat $W/soft.broken.booted)\" = d1 ] && [ \"\$(gs_kv $W/soft.broken failed)\" = dz ]"
ok "SC-002: no candidate: the same state, current starts" "pick current '$ST0' && [ \"\$(cat $W/soft.current.booted)\" = d1 ]"
ok "SC-002: no current: the same state, previous starts" "pick previous 'current=\nprevious=d2\ncandidate=\ntries=0\nfailed=\nstaged=\n' && [ \"\$(cat $W/soft.previous.booted)\" = d2 ]"
ok "SC-004: the incoming session's mounts equal a cold start's (root, overlay, storage binds, /run/glassine)" "cmp -s $W/cold.tries.mtab $W/soft.tries.mtab && grep -q '^R/home ' $W/soft.tries.mtab && grep -q '^R/run/glassine/userdata ' $W/soft.tries.mtab"
ok "SC-004: /run/glassine holds the same files as after a cold start" "cmp -s $W/cold.tries.run $W/soft.tries.run && grep -qx restart $W/soft.tries.run"
ok "FR-023: userdata's mount count unchanged by the soft starts" "[ \"\$(gs_dumpe2fs $UDEV 'Mount count')\" = '$MC0' ]"
ok "a soft start where the cold pick would boot bare: nothing assembled, exit 1 (the restart turns cold)" "printf 'current=dz\nprevious=\ncandidate=\ntries=0\n' > $S/state/deploy && mkdir -p $R.sys $R.ud && mount -t btrfs $SD $R.sys && mount -t ext4 $UDEV $R.ud && ! gr_soft_boot $P $R $KR && ! mountpoint -q $R && ! mountpoint -q $R/run; exec 9>&-; umount $R.ud $R.sys"
printf "$ST0" > $S/state/deploy
ok "a soft start without the two mounts: refused" "! gr_soft_boot $P $R $KR"

# --- the restart record (FR-008) and the cold note ---------------------------------
unset_rs
ok "a cold start: restart kind=cold, count=0, at=; no kept assembly without GR_KEEP_SRC (kept.none)" "gr_boot $SD $UDEV $P $R $KR 2>/dev/null && gr_carry $R && [ \"\$(gs_kv $R/run/glassine/restart kind)\" = cold ] && [ \"\$(gs_kv $R/run/glassine/restart count)\" = 0 ] && [ -n \"\$(gs_kv $R/run/glassine/restart at)\" ] && [ \"\$(cat $R/run/glassine/kept.none)\" = no-assembly ]"
gr_boot_umount $R
echo processes > $U/restart.cold
ok "the cold start after a soft restart that turned cold: cold_reason= once, the note removed" "gr_boot $SD $UDEV $P $R $KR 2>/dev/null && gr_carry $R && [ \"\$(gs_kv $R/run/glassine/restart cold_reason)\" = processes ] && [ ! -e $U/restart.cold ]"
gr_boot_umount $R
echo 'bad word!' > $U/restart.cold
ok "a note that isn't a word: cold_reason=unknown" "gr_boot $SD $UDEV $P $R $KR 2>/dev/null && gr_carry $R && [ \"\$(gs_kv $R/run/glassine/restart cold_reason)\" = unknown ]"
gr_boot_umount $R

# --- SC-007: a hibernate after a soft start ----------------------------------------
cat > $W/hib.conf <<CONF
SYSTEM_DEV=$SD
SYSTEM_MNT=$R/run/glassine/system
USERDATA_DEV=$UDEV
USERDATA_MNT=$R/run/glassine/userdata
USERDATA_PREFIX=$P
RUN_DIR=$R/run/glassine
HIBERNATE_RESERVE_MB=8
HIBERNATE_HOOKS=$W/hooks
CONF
HP=$W/hpower; mkdir -p $HP; echo 'freeze mem disk' > $HP/state; echo 'platform [shutdown] reboot' > $HP/disk
hn() { GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh GLASSINE_DEPLOY_CONF=$W/hib.conf GLASSINE_SYSPOWER=$HP GLASSINE_PROC_CMDLINE=$W/cmdline GLASSINE_UNAME=$KR /p/sbin/glassine-hibernate "$@" > $W/hout 2>&1; }
KEEP_ASSEMBLED=1 soft hib 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n'
hn setup 2 >/dev/null 2>&1
ok "SC-007: after a soft start into the candidate (a try left): the hibernate check passes" "hn check && [ \"\$(cat $R/run/glassine/booted)\" = d2 ]"
: > $R/run/glassine/restarting
ok "FR-027: the hibernate step refuses while a restart runs (exit 4)" "hn check; [ \$? = 4 ] && grep -q 'a restart is running' $W/hout"
rm $R/run/glassine/restarting
gr_boot_umount $R
KEEP_ASSEMBLED=1 soft hib 'current=d1\nprevious=d0\ncandidate=d2\ntries=1\nfailed=\nstaged=\n'
ok "SC-007: after a soft start on the candidate's last try: refused (exit 3)" "hn check; [ \$? = 3 ] && grep -q 'next boot would be d1, not d2' $W/hout"
gr_boot_umount $R
rm -f $U/swap/hibernate

# --- the restart step: glassine-deploy restart --check, on a cold start's session ---
printf "$ST0" > $S/state/deploy; unset_rs
GR_KEEP_SRC=$IR gr_boot $SD $UDEV $P $R $KR 2>/dev/null && GR_KEEP_SRC=$IR gr_carry $R || echo "FAIL the session for the restart step"
RD=$R/run/glassine
cat > $W/deploy.conf <<CONF
SYSTEM_DEV=$SD
SYSTEM_MNT=$RD/system
USERDATA_DEV=$UDEV
USERDATA_MNT=$RD/userdata
USERDATA_PREFIX=$P
RUN_DIR=$RD
RESTART_INIT_S=0
CONF
mkdir -p $W/psu/bat; echo Battery > $W/psu/bat/type; echo 80 > $W/psu/bat/capacity
printf '#!/bin/sh\necho "hook $*" >> %s/calls\n' $W > $W/hook; chmod +x $W/hook
printf '#!/bin/sh\ncase $1 in restart-check) cat %s/markword 2>/dev/null ;; has-record) exit 3 ;; esac\nexit 0\n' $W > $W/mark; chmod +x $W/mark
printf '#!/bin/sh\necho "signal" >> %s/calls; cp %s/restarting %s/restarting.seen\n' $W $RD $W > $W/sig; chmod +x $W/sig
printf '#!/bin/sh\necho "reboot $*" >> %s/calls\n' $W > $W/reboot; chmod +x $W/reboot
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh GLASSINE_DEPLOY_INIT_OK=1 \
    GLASSINE_LOADER_MARK=$W/mark GLASSINE_UNAME=$KR GLASSINE_DEPLOY_CMDLINE=$W/cmdline GLASSINE_POWER_SUPPLY=$W/psu \
    GLASSINE_SWITCH_HOOK=$W/hook GLASSINE_DEPLOY_SIGNAL_INIT=$W/sig GLASSINE_DEPLOY_REBOOT=$W/reboot
# rc [ARGS]: restart --check --porcelain; RC = its exit, F_<key> its fields
rc() {
    $G restart --check --porcelain "$@" > $W/rout 2>$W/rerr; RC=$?
    F() { sed -n 2p $W/rout | tr '\t' '\n' | sed -n "s/^$1=//p"; }
}
why() { rc "$@"; [ $RC = 9 ] && [ "$(F restart)" = cold ] && [ "$(F restart_reason)" = "$W1" ]; }
ok "check: a session that hasn't reached its healthy time: cold, not-healthy (exit 9)" "W1=not-healthy why"
echo at=1 > $RD/healthy
ok "check: everything holds: soft (exit 0), the target is the pick's, no switch" "rc && [ \$RC = 0 ] && [ \"\$(F restart)\" = soft ] && [ \"\$(F restart_target)\" = d1 ] && [ \"\$(F switch)\" = no ] && [ \"\$(F switch_reason)\" = nothing-staged ]"
ok "check: the human output says soft" "$G restart --check | grep -q '^restart: soft$'"
echo SOFT_RESTART=no >> $W/deploy.conf
ok "check: SOFT_RESTART=no: cold, off" "W1=off why"
sed -i '/^SOFT_RESTART=/d' $W/deploy.conf
rm $RD/kept/.complete
ok "check: no kept assembly: cold, no-assembly" "W1=no-assembly why"
: > $RD/kept/.complete
echo trial > $RD/kernel-boot
ok "check: a kernel trial boot: cold, kernel-trial" "W1=kernel-trial why"
: > $RD/kernel-boot
printf 'current=%s\ncurrent_img=aaaa\n' $KR > $S/state/kernel
ok "check: the next cold start runs another kernel image: cold, kernel" "W1=kernel why"
printf 'current=%s\ncurrent_img=1abb421e678cbd3b\nwriting=cccc\n' $KR > $S/state/kernel
ok "check: an unfinished default-slot write: cold, kernel" "W1=kernel why"
printf 'current=%s\ncurrent_img=1abb421e678cbd3b\n' $KR > $S/state/kernel
ok "check: state/kernel names the running image: soft" "rc && [ \$RC = 0 ]"
rm $S/state/kernel
ok "check: no modules for the running release: cold, modules" "GLASSINE_UNAME=9.9.9 W1=modules why"
: > $S/state/install
ok "check: an installed system's first start (state/install): cold, first-start" "W1=first-start why"
rm $S/state/install
cp $RD/booted $W/booted.keep; echo bare:b1 > $RD/booted
ok "check: a bare boot: cold, bare" "W1=bare why"
cp $W/booted.keep $RD/booted
echo loader-request > $W/markword
ok "check: the loader record holds a request: cold, loader-request" "W1=loader-request why"
rm $W/markword
ok "check: PID 1 can't hand over: cold, init" "GLASSINE_DEPLOY_INIT_OK=0 W1=init why"
# the target's base needs a feature: the running kernel's manifest must provide it
btrfs property set -fts $B ro false; echo 'needs=gpu-a5xx' > $B/usr/share/glassine/base.manifest
ok "check: the kernel doesn't cover the target's base: cold, not-covered" "W1=not-covered why"
btrfs property set -fts $S/modules/$KR ro false; echo 'provides=gpu-a5xx other' > $S/modules/$KR/kernel.manifest
ok "check: the kernel's manifest provides what the base needs: soft" "rc && [ \$RC = 0 ]"
rm $S/modules/$KR/kernel.manifest $B/usr/share/glassine/base.manifest
btrfs property set -ts $S/modules/$KR ro true; btrfs property set -ts $B ro true
# the switch beforehand (FR-012)
gs_update $S/state/deploy staged=d2
ok "check: a deployment staged, the switch would run: switch=yes, the target is the staged one" "rc && [ \$RC = 0 ] && [ \"\$(F switch)\" = yes ] && [ \"\$(F restart_target)\" = d2 ]"
echo 10 > $W/psu/bat/capacity
ok "check: the battery below SWITCH_MIN_CAPACITY: switch=no battery, the target is current" "rc && [ \"\$(F switch)\" = no ] && [ \"\$(F switch_reason)\" = battery ] && [ \"\$(F restart_target)\" = d1 ]"
echo 80 > $W/psu/bat/capacity
printf 'base=b1\nkind=update\ncarry=migrate\n' > $U/deployments/d2/meta
mkdir -p $W/live/usr/share/glassine $W/live/etc; echo /etc/big > $W/live/usr/share/glassine/migrate.list
dd if=/dev/zero of=$W/live/etc/big bs=1M count=200 2>/dev/null
ok "check: too little space for the switch's copy: switch=no space" "GLASSINE_DEPLOY_ROOT=$W/live rc && [ \"\$(F switch)\" = no ] && [ \"\$(F switch_reason)\" = space ]"
: > $W/calls
ok "restart: too little space for the switch: exit 5, nothing stopped" "GLASSINE_DEPLOY_ROOT=$W/live $G restart 2>$W/rerr; [ \$? = 5 ] && [ ! -e $RD/restarting ] && [ ! -s $W/calls ]"
rm -f $W/live/etc/big
printf 'base=b1\nkind=install\ncarry=none\n' > $U/deployments/d2/meta
gs_update $S/state/deploy staged=
ok "status: restart=soft, restart_reason=, last_start=cold" "$G status --porcelain | sed -n 2p | tr '\t' '\n' > $W/sout && grep -qx restart=soft $W/sout && grep -qx restart_reason= $W/sout && grep -qx last_start=cold $W/sout"

# --- the restart step's phases ---------------------------------------------------------
rm -f $RD/healthy; : > $W/calls
ok "restart --soft, would be cold: exit 9, nothing stopped or written" "$G restart --soft 2>$W/rerr; [ \$? = 9 ] && [ ! -s $W/calls ] && [ ! -e $RD/restarting ] && grep -q not-healthy $W/rerr"
ok "restart --once, would be cold: exit 9" "$G restart --once d2 2>/dev/null; [ \$? = 9 ] && [ ! -s $W/calls ]"
ok "restart, would be cold: the user-shutdown mark, then the orderly reboot" "$G restart >/dev/null 2>&1 && [ \"\$(tr '\n' ' ' < $W/calls)\" = 'hook --user-shutdown reboot  ' ] && [ ! -e $RD/restarting ]"
echo at=1 > $RD/healthy; : > $W/calls
ok "restart --cold: cold whatever the check says" "$G restart --cold >/dev/null 2>&1 && grep -qx 'reboot ' $W/calls && ! grep -q signal $W/calls"
ok "restart --cold --once: usage (exit 2)" "$G restart --cold --once d2 2>/dev/null; [ \$? = 2 ]"
ok "restart --check --soft: usage (exit 2)" "$G restart --check --soft 2>/dev/null; [ \$? = 2 ]"
ok "status --restart: usage (exit 2)" "$G status --restart 2>/dev/null; [ \$? = 2 ]"
: > $W/calls
ok "restart --once gone: refused before anything stops" "$G restart --once gone 2>$W/rerr; [ \$? = 1 ] && [ ! -s $W/calls ]"
gs_update $S/state/deploy staged=d2
ok "restart --once of the staged deployment: refused" "$G restart --once d2 2>$W/rerr; [ \$? = 1 ] && grep -q 'is staged' $W/rerr"
gs_update $S/state/deploy staged=
btrfs property set -fts $B ro false; echo 'needs=gpu-a5xx' > $B/usr/share/glassine/base.manifest; btrfs property set -ts $B ro true
: > $W/calls
ok "restart --once ID the running kernel doesn't cover: exit 8" "$G restart --once d2 2>$W/rerr; [ \$? = 8 ] && [ ! -s $W/calls ]"
btrfs property set -fts $B ro false; rm $B/usr/share/glassine/base.manifest; btrfs property set -ts $B ro true
flock $S/state/.lock sleep 3 & LP=$!; sleep 1; : > $W/calls
ok "restart while the state is locked (the hibernate step holds it): exit 6, nothing stopped" "$G restart 2>/dev/null; [ \$? = 6 ] && [ ! -e $RD/restarting ] && [ ! -s $W/calls ]"
wait $LP
: > $RD/restarting
ok "restart while one runs: exit 6" "$G restart 2>/dev/null; [ \$? = 6 ]"
rm $RD/restarting
: > $W/calls
$G restart --once d2 > $W/rout 2>$W/rerr; RC=$?
ok "restart --once d2, soft: the restart record written before PID 1 is signalled" "grep -qx from=d1 $W/restarting.seen && grep -qx once=d2 $W/restarting.seen && grep -qx count=1 $W/restarting.seen && grep -qx sysdev=$SD $W/restarting.seen && grep -qx uddev=$UDEV $W/restarting.seen && grep -qx prefix=$P $W/restarting.seen"
ok "restart, soft: user-shutdown mark, then the signal to PID 1" "[ \"\$(head -n 2 $W/calls | tr '\n' ' ')\" = 'hook --user-shutdown signal ' ]"
ok "restart, soft, PID 1 doesn't act: restarting removed, cold, the next start says init" "grep -qx 'reboot ' $W/calls && [ ! -e $RD/restarting ] && [ \"\$(cat $U/restart.cold)\" = init ]"
rm -f $U/restart.cold
: > $W/calls
ok "select --restart: selected, then the restart" "$G select d2 --restart >/dev/null 2>&1 && [ \"\$(gs_kv $S/state/deploy candidate)\" = d2 ] && grep -qx signal $W/calls && grep -qx 'from=d1' $W/restarting.seen"
gs_update $S/state/deploy candidate= tries=0
# the session's stop (OpenRC's killprocs) ends the waiting restart with TERM: it
# leaves, the restart record stays for the soft start, no cold fallback
printf '#!/bin/sh\necho signal >> %s/calls\n' $W > $W/sig0; chmod +x $W/sig0; : > $W/calls
rm -f $U/restart.cold $RD/restarting
sed -i 's/^RESTART_INIT_S=.*/RESTART_INIT_S=30/' $W/deploy.conf
( GLASSINE_DEPLOY_SIGNAL_INIT=$W/sig0 exec $G restart > /dev/null 2>&1 ) & RP=$!
n=0; while ! grep -qx signal $W/calls && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
kill -TERM $RP; sleep 1; pkill -TERM -P $RP; wait $RP; RC=$?
ok "restart, soft, the stop's TERM while it waits: it ends (143), restarting kept, no reboot, no cold note" "[ \$RC = 143 ] && [ -e $RD/restarting ] && ! grep -q reboot $W/calls && [ ! -e $U/restart.cold ]"
rm -f $RD/restarting
sed -i 's/^RESTART_INIT_S=.*/RESTART_INIT_S=0/' $W/deploy.conf
# a session started by an older initramfs (no restart record, no kept assembly): cold,
# and status still answers
mv $RD/kept $W/kept.away; mv $RD/restart $W/restart.away
ok "an older initramfs's session (no kept/, no restart record): check says cold, no-assembly" "W1=no-assembly why"
ok "... status: restart=cold, last_start empty" "$G status --porcelain | sed -n 2p | tr '\t' '\n' > $W/sout && grep -qx restart=cold $W/sout && grep -qx last_start= $W/sout"
mv $W/kept.away $RD/kept; mv $W/restart.away $RD/restart

# --- the boot-success step (FR-016, FR-017) --------------------------------------------
A=/p/sbin/glassine-deploy-accept
AW=$W/acc; mkdir -p $AW/run $AW/health
printf '#!/bin/sh\n[ "$1" = status ] && printf "v\\n%%s\\n" "$(cat %s/status)"\n[ "$1" = accept ] && echo "accept $2" >> %s/calls\nexit 0\n' $AW $AW > $AW/deploy; chmod +x $AW/deploy
printf 'RUN_DIR=%s/run\nACCEPT_AFTER=120\nACCEPT_HEALTH_DIR=%s/health\n' $AW $AW > $AW/conf
printf 'type=status\tcandidate=\ttries=0\n' > $AW/status
echo d1 > $AW/run/booted; echo '130.0 1.0' > $AW/uptime
acc() { : > $AW/calls; GLASSINE_DEPLOY_CONF=$AW/conf GLASSINE_DEPLOY=$AW/deploy GLASSINE_ACCEPT_UPTIME=$AW/uptime GLASSINE_LOADER_MARK=/nonexistent sh $A > $AW/out 2>&1; }
ok "accept: nothing to accept, no slot, no record: health still checked, the healthy record written" "acc && [ -n \"\$(gs_kv $AW/run/healthy at)\" ]"
rm $AW/run/healthy; printf '#!/bin/sh\necho bad\nexit 1\n' > $AW/health/x; chmod +x $AW/health/x
ok "accept: unhealthy: no healthy record" "! acc && [ ! -e $AW/run/healthy ]"
rm $AW/health/x
printf 'type=status\tcandidate=d1\ttries=1\n' > $AW/status
ok "accept: an older initramfs's session (no restart record): waits from boot, accepts the candidate" "acc && grep -qx 'accept d1' $AW/calls && [ -e $AW/run/healthy ]"
printf 'type=status\tcandidate=\ttries=0\n' > $AW/status; rm -f $AW/run/healthy
printf 'kind=soft\nat=100.5\n' > $AW/run/restart
acc & AP=$!; sleep 1
ok "accept: a soft start at 100 s waits ACCEPT_AFTER from there (up 130 s: still waiting)" "kill -0 $AP && [ ! -e $AW/run/healthy ]"
echo '221.0 1.0' > $AW/uptime
ok "accept: then, 120 s into its own session: healthy" "wait $AP && [ -e $AW/run/healthy ]"

# --- the soft start as PID 1 (initramfs/soft): a session, then its restart ----------
# A namespace of its own (mount and PID) makes the outgoing session: a cold start of
# d1 (gr_boot, gr_carry with the kept assembly), the restart record, then the kept
# soft start runs in it as PID 1, as busybox init's restart action would. Only the
# namespace holds that session's mounts. The incoming session's init reports onto
# userdata and ends, and the namespace with it.
gr_boot_umount $R
cat > $W/test.conf <<'TC'
GLASSINE_SOFT_REBOOT=soft_test_reboot
soft_test_reboot() { exit 0; }
GLASSINE_SOFT_STAGE=/run/stage
GLASSINE_SOFT_KMSG=/dev/null
GLASSINE_SOFT_KEEP_RW=1
TC
REP=$U/report
# e2e STATE [CUT]: one soft restart from STATE (the state as the outgoing session and
# its switch left it); EXTRA: shell code run in the session's /run/glassine ($RD)
# first; PRE: run right before PID 1 hands over; RUN = how it ended
e2e() {
    rm -rf $REP $U/restart.cold
    printf "$ST0" > $S/state/deploy
    printf "$1" > $W/e2e.state
    timeout 60 unshare -mpf sh -c "
        mount --make-rprivate /
        . /p/lib/glassine-state.sh; . /p/lib/glassine-root.sh; gr_log() { :; }
        GR_KEEP_SRC=$IR gr_boot $SD $UDEV $P $R $KR && GR_KEEP_SRC=$IR gr_carry $R || { echo 'the outgoing session did not start'; exit 1; }
        RD=$R/run/glassine
        cp $W/e2e.state \$RD/system/state/deploy
        printf 'from=d1\nonce=%s\ncount=1\nsysdev=%s\nuddev=%s\nprefix=%s\nlimit=%s\n' '${ONCE:-}' $SD $UDEV $P ${LIMIT:-3} > \$RD/restarting
        cp $W/test.conf \$RD/kept/test.conf
        [ -z '${2:-}' ] || echo 'GLASSINE_SOFT_CUT=${2:-}' >> \$RD/kept/test.conf
        echo at=1 > \$RD/healthy
        cd \$RD && { ${EXTRA:-:}; } && cd / || exit 1
        mount -t proc proc $R/proc && mount -t sysfs sys $R/sys && mount --rbind /dev $R/dev || exit 1
        ${PRE:-:}
        exec chroot $R /run/glassine/kept/bin/busybox sh /run/glassine/kept/soft" > $W/e2e.log 2>&1
    if [ -e $REP/booted ]; then RUN=soft; elif [ -e $U/restart.cold ]; then RUN=cold; else RUN=none; fi
}
MC1=$(gs_dumpe2fs $UDEV 'Mount count')
e2e 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n'
[ $RUN = soft ] || cat $W/e2e.log
ok "e2e: the soft start reaches the incoming init as PID 1, into the candidate (a try used)" "[ \$RUN = soft ] && [ \"\$(cat $REP/booted)\" = d2 ] && [ \"\$(cat $REP/pid)\" = 1 ] && [ \"\$(gs_kv $S/state/deploy tries)\" = 1 ]"
ok "e2e: the restart record: kind=soft, from=d1, count=1" "[ \"\$(gs_kv $REP/restart kind)\" = soft ] && [ \"\$(gs_kv $REP/restart from)\" = d1 ] && [ \"\$(gs_kv $REP/restart count)\" = 1 ]"
ok "e2e: a new kept assembly for the next restart (without the test hook)" "grep -qx .complete $REP/kept && grep -qx soft $REP/kept && ! grep -qx test.conf $REP/kept"
ok "SC-004 e2e: no mount of the old root is left, the stage is gone, the person's storage bound" "! grep -q ' /oldroot' $REP/mounts && ! grep -q ' /run/stage' $REP/mounts && grep -q ' /home ' $REP/mounts && grep -q ' /run/glassine/userdata ' $REP/mounts"
ok "SC-004 e2e: /run/glassine: per start files made anew; restarting, healthy, user-shutdown gone" "grep -qx booted $REP/run && grep -qx storage $REP/run && ! grep -qx restarting $REP/run && ! grep -qx healthy $REP/run"
ok "FR-023 e2e: userdata's mount count unchanged" "[ \"\$(gs_dumpe2fs $UDEV 'Mount count')\" = '$MC1' ]"
EXTRA='echo x > loader-marked; echo x > limit-done' e2e "$ST0"
ok "FR-024 e2e: loader-marked and limit-done carried into the incoming session" "[ \$RUN = soft ] && grep -qx loader-marked $REP/run && grep -qx limit-done $REP/run"
ONCE=d2 e2e "$ST0"
ok "e2e: restart --once d2: d2 starts, state/deploy byte for byte unchanged" "[ \$RUN = soft ] && [ \"\$(cat $REP/booted)\" = d2 ] && [ \"\$(printf '$ST0')\" = \"\$(cat $S/state/deploy)\" ]"
EXTRA='printf "switch=no\\nswitch_reason=battery\\n" > switch-result' e2e "$ST0"
ok "FR-012 e2e: the switch's result reaches the incoming session (switch=no battery)" "[ \"\$(gs_kv $REP/restart switch_reason)\" = battery ]"
# SC-003: the loader record byte for byte the same. Its files and the command line
# sit in a directory of /dev, which moves along onto the stage (a FAT boot partition
# would be mounted for the read)
TD=/dev/glassine-soft-test; rm -rf $TD; mkdir -p $TD/bp/glassine
cp /p/test/bootpart/golden/loader.a /p/test/bootpart/golden/loader.b $TD/bp/glassine/; cp $W/cmdline $TD/cmdline
printf 'ROOT_LAYOUT=deployments\nUSERDATA_PREFIX=%s\nHANDOFF=uefi\n' $P > $IR/etc/glassine-boot/board.conf
LSUM=$(cat $TD/bp/glassine/loader.a $TD/bp/glassine/loader.b | md5sum)
printf 'GLASSINE_SOFT_CMDLINE=%s/cmdline\nexport GLASSINE_BI_BOOTPART_DIR=%s/bp\n' $TD $TD >> $W/test.conf
e2e "$ST0"
ok "SC-003 e2e: the record read (HANDOFF=uefi, its default = this image): soft, the loader record byte for byte the same" "[ \$RUN = soft ] && [ \"\$(cat $TD/bp/glassine/loader.a $TD/bp/glassine/loader.b | md5sum)\" = '$LSUM' ]"
printf 'ROOT_LAYOUT=deployments\nUSERDATA_PREFIX=%s\n' $P > $IR/etc/glassine-boot/board.conf
sed -i '/GLASSINE_BI_BOOTPART_DIR/d' $W/test.conf
# SC-006: a cut at every step of phase 2
for c in private copy move pivot procs mount umount decide assemble carry; do
    e2e 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n' $c
    ok "SC-006: cut at $c: a cold start, no try used, no session" "[ \$RUN = cold ] && [ \"\$(gs_kv $S/state/deploy tries)\" = 2 ] && [ \"\$(gs_kv $S/state/deploy candidate)\" = d2 ] && [ \"\$(cat $U/restart.cold)\" = cut ]"
done
e2e 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n' handover
ok "SC-006: cut after the try is written: a cold start that counts it (FR-015)" "[ \$RUN = cold ] && [ \"\$(gs_kv $S/state/deploy tries)\" = 1 ]"
# the second decision sees the state as the switch left it
printf 'current=%s\ncurrent_img=aaaa\n' $KR > $S/state/kernel
e2e "$ST0"
ok "FR-003 e2e: a state that changed after the check (another kernel image): the second decision restarts cold" "[ \$RUN = cold ] && [ \"\$(cat $U/restart.cold)\" = kernel ]"
rm $S/state/kernel
e2e 'current=dz\nprevious=\ncandidate=\ntries=0\nfailed=\nstaged=\n'
ok "FR-014 e2e: nothing can assemble (the cold pick would boot bare): cold" "[ \$RUN = cold ] && [ \"\$(cat $U/restart.cold)\" = no-target ]"

# SC-005: a process that doesn't end, and a mount that doesn't unmount
truncate -s 16M $W/fz.img; mke2fs -q -F -t ext4 $W/fz.img; loop $W/fz.img; FZ=$LOOP
mkdir -p $W/fzmnt
ok "SC-005 setup: a file system to freeze" "mount -t ext4 $FZ $W/fzmnt"
rm -f $U/restart.cold     # the poll below waits for this run's
PRE="fsfreeze -f $W/fzmnt && { sh -c 'echo x > $W/fzmnt/f' & sleep 1; }" LIMIT=2 e2e 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n' &
EP=$!
n=0; while [ ! -e $U/restart.cold ] && [ $n -lt 40 ]; do sleep 1; n=$((n + 1)); done
sleep 1; fsfreeze -u $W/fzmnt; wait $EP
ok "SC-005: a process in uninterruptible sleep: cold (processes), no try used" "[ \"\$(cat $U/restart.cold)\" = processes ] && [ \"\$(gs_kv $S/state/deploy tries)\" = 2 ] && [ ! -e $REP/booted ]"
umount $W/fzmnt
# a loop device on a file of the old root's /run keeps that mount busy, and no
# process of the restart's namespace holds it
EXTRA='truncate -s 1M "$PWD/busy.img" && losetup -f "$PWD/busy.img"' LIMIT=2 e2e 'current=d1\nprevious=d0\ncandidate=d2\ntries=2\nfailed=\nstaged=\n'
ok "SC-005: a mount that doesn't unmount: cold (mounts), no try used" "[ \$RUN = cold ] && [ \"\$(cat $U/restart.cold)\" = mounts ] && [ \"\$(gs_kv $S/state/deploy tries)\" = 2 ]"
for l in $(losetup -a | grep busy.img | cut -d: -f1); do losetup -d $l; done

umount $W/udmnt $W/sysmnt 2>/dev/null
for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
rm -rf /dev/glassine-soft-test
echo "$fails failed"
[ $fails = 0 ]
