#!/bin/sh
set -u
W=/w; mkdir -p $W/run $W/sys $W/ud
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
P=media/glassine
cat > $W/deploy.conf <<CONF
SYSTEM_DEV=$W/system.img
SYSTEM_MNT=$W/sysmnt
USERDATA_DEV=$W/userdata.img
USERDATA_MNT=$W/udmnt
USERDATA_PREFIX=$P
RUN_DIR=$W/run
CONF
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh
st() { $G status --porcelain | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }

# --- the shutdown hook (glassine-switch-hook), on a stub glassine-deploy --------
H=/p/sbin/glassine-switch-hook
HW=$W/hook; mkdir -p $HW/ps $HW/run
printf '#!/bin/sh\ncase $1 in\nstatus) printf "v\\tx\\n%%s\\n" "$(cat %s/status)" ;;\nswitch) echo switch >> %s/calls; exit $(cat %s/rc) ;;\nesac\n' $HW $HW $HW > $HW/deploy; chmod +x $HW/deploy
printf 'RUN_DIR=%s/run\nSWITCH_MIN_CAPACITY=30\n' $HW > $HW/conf
hook() { : > $HW/calls; GLASSINE_DEPLOY_CONF=$HW/conf GLASSINE_DEPLOY=$HW/deploy GLASSINE_POWER_SUPPLY=$HW/ps sh $H "$@" > $HW/out 2>&1; }
psu() { rm -rf $HW/ps/*; for x in "$@"; do n=${x%%:*}; mkdir -p $HW/ps/$n; v=${x#*:}; echo ${v%%=*} > $HW/ps/$n/type; [ "${v%%=*}" = Battery ] && echo ${v#*=} > $HW/ps/$n/capacity || echo ${v#*=} > $HW/ps/$n/online; done; }
echo 0 > $HW/rc
printf 'system_fs=btrfs\tstaged=\n' > $HW/status; psu bat:Battery=80
ok "hook: nothing staged: no switch" "hook && [ ! -s $HW/calls ]"
printf 'system_fs=btrfs\tstaged=r1\n' > $HW/status
ok "hook: staged, shutdown not started by the user: stays staged" "hook && [ ! -s $HW/calls ] && grep -q 'not started by the user' $HW/out"
ok "hook --user-shutdown: marks this shutdown" "hook --user-shutdown && [ -e $HW/run/user-shutdown ]"
psu bat:Battery=20 usb:USB=0
ok "hook: user shutdown, battery 20 %, no charger: stays staged, mark kept" "hook && [ ! -s $HW/calls ] && grep -q 'battery 20 %, below 30' $HW/out && [ -e $HW/run/user-shutdown ]"
psu bat:Battery=20 usb:USB=1
ok "hook: battery 20 % but the charger online: switches" "hook && grep -qx switch $HW/calls && grep -q 'charger usb' $HW/out && [ ! -e $HW/run/user-shutdown ]"
hook --user-shutdown; psu bat:Battery=30 ac:Mains=0
ok "hook: battery at the threshold: switches" "hook && grep -qx switch $HW/calls"
hook --user-shutdown; psu
ok "hook: no battery (a board without one): switches" "hook && grep -qx switch $HW/calls && grep -q 'no battery' $HW/out"
hook --user-shutdown; psu bat:Battery=x
ok "hook: unreadable capacity: stays staged" "hook && [ ! -s $HW/calls ]"
psu bat:Battery=90; echo 5 > $HW/rc
ok "hook: the switch fails: its exit code, said" "hook; [ \$? = 5 ] && grep -q 'switch failed (exit 5): r1 stays staged' $HW/out"
ok "hook: a stray argument: usage, exit 2" "hook --now; [ \$? = 2 ]"

# --- the library -------------------------------------------------------------
printf 'a=1\nb=2\n' > $W/kv
ok "gs_kv reads a key" "[ \"\$(gs_kv $W/kv b)\" = 2 ]"
ok "gs_kv missing key = empty" "[ -z \"\$(gs_kv $W/kv c)\" ]"
ok "gs_kv missing file = empty, exit 0" "[ -z \"\$(gs_kv $W/nofile a)\" ]"
gs_set $W/kv b 3
ok "gs_set replaces one key, keeps the rest" "[ \"\$(gs_kv $W/kv b)\" = 3 ] && [ \"\$(gs_kv $W/kv a)\" = 1 ] && [ \$(grep -c '^b=' $W/kv) = 1 ]"
ok "gs_set leaves no temp file" "[ -z \"\$(ls $W | grep 'kv.tmp')\" ]"
ok "gs_format_ok 1" "gs_format_ok 1"
ok "gs_format_ok refuses 2, empty, junk" "! gs_format_ok 2 && ! gs_format_ok '' && ! gs_format_ok x1"

# --- status: nothing there ---------------------------------------------------
ok "status, no devices: exit 0, migrated=no, hibernated=unknown" "$G status --porcelain >/dev/null && [ \"\$(st migrated)\" = no ] && [ \"\$(st system_fs)\" = none ] && [ \"\$(st hibernated)\" = unknown ]"
ok "porcelain first line" "[ \"\$($G status --porcelain | head -n 1)\" = 'glassine-deploy 1' ]"
ok "porcelain record starts with type=status" "$G status --porcelain | sed -n 2p | grep -q '^type=status	'"
ok "porcelain paths" "[ \"\$(st swapfile)\" = $P/swap/hibernate ] && [ \"\$(st guard)\" = $P/swap/hibernate.guard ] && [ \"\$(st userdata_prefix)\" = $P ]"
ok "human output: key: value lines" "$G status | grep -q '^migrated: no$'"
ok "usage: exit 2" "$G bogus 2>/dev/null; [ \$? = 2 ]"

# --- status: an ext4 system partition (today's layout): never mounted --------
head -c 8388608 /dev/zero > $W/system.img; mke2fs -q -F -t ext4 $W/system.img
ok "ext4 system: migrated=no, system_fs=ext4" "[ \"\$(st migrated)\" = no ] && [ \"\$(st system_fs)\" = ext4 ]"

# --- status: a migrated system (top level as a directory) --------------------
export GLASSINE_DEPLOY_FAKE_MOUNTS=1
mkdir -p $W/sysmnt/state
echo version=1 > $W/sysmnt/state/format
printf 'current=d2\nprevious=d1\ncandidate=\ntries=0\n' > $W/sysmnt/state/deploy
printf 'current=7.3.0-na1\nprevious=7.2.3-1\n' > $W/sysmnt/state/kernel
ok "migrated: tables" "[ \"\$(st migrated)\" = yes ] && [ \"\$(st format)\" = 1 ] && [ \"\$(st current)\" = d2 ] && [ \"\$(st previous)\" = d1 ] && [ \"\$(st kernel_current)\" = 7.3.0-na1 ]"
echo version=2 > $W/sysmnt/state/format
ok "newer format: exit 3, both versions printed, no tables" "$G status --porcelain >$W/o 2>/dev/null; [ \$? = 3 ] && grep -q 'format=2	supported=1' $W/o && ! grep -q 'current=' $W/o"
echo version=x > $W/sysmnt/state/format
ok "junk format: exit 3" "$G status --porcelain >/dev/null 2>&1; [ \$? = 3 ]"
echo version=1 > $W/sysmnt/state/format

# --- hibernation: the swap file on an ext4 userdata image ---------------------
unset GLASSINE_DEPLOY_FAKE_MOUNTS
head -c 33554432 /dev/zero > $W/userdata.img; mke2fs -q -F -t ext4 -b 4096 $W/userdata.img
ok "userdata without a swap file: hibernated=no" "[ \"\$(st hibernated)\" = no ]"
head -c 1048576 /dev/zero > $W/swap; mkswap $W/swap >/dev/null 2>&1
debugfs -w -R "mkdir /media" $W/userdata.img 2>/dev/null; debugfs -w -R "mkdir /$P" $W/userdata.img 2>/dev/null
debugfs -w -R "mkdir /$P/swap" $W/userdata.img 2>/dev/null; debugfs -w -R "write $W/swap /$P/swap/hibernate" $W/userdata.img >/dev/null 2>&1
B=$(gs_dev_block $W/userdata.img $P/swap/hibernate)
ok "gs_dev_block finds the first block" "[ -n \"\$B\" ] && [ \"\$B\" -gt 0 ]"
ok "a plain swap file: SWAPSPACE2, hibernated=no" "[ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ] && [ \"\$(st hibernated)\" = no ]"
printf 'S1SUSPEND\000' | dd of=$W/userdata.img bs=1 seek=$((B * 4096 + 4086)) conv=notrunc 2>/dev/null
ok "a hibernate image: hibernated=yes (unmounted, debugfs)" "[ \"\$(st hibernated)\" = yes ]"
gs_invalidate_dev $W/userdata.img $B
ok "gs_invalidate_dev: SWAPSPACE2 back, hibernated=no" "[ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ] && [ \"\$(st hibernated)\" = no ]"
ok "the file read through the fs sees it too" "debugfs -R 'dump /$P/swap/hibernate $W/back' $W/userdata.img 2>/dev/null; [ \"\$(gs_sig_file $W/back)\" = SWAPSPACE2 ]"
ok "gs_invalidate_dev on a swap file is a no-op" "gs_invalidate_dev $W/userdata.img \$B && [ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ]"
head -c 33554432 /dev/zero > $W/ud1k.img; mke2fs -q -F -t ext4 -b 1024 $W/ud1k.img
ok "gs_dev_block refuses a 1 KiB block size" "! gs_dev_block $W/ud1k.img $P/swap/hibernate"

# --- hibernation: userdata mounted (file mode) --------------------------------
export GLASSINE_DEPLOY_FAKE_MOUNTS=1
mkdir -p $W/udmnt/$P/swap; cp $W/swap $W/udmnt/$P/swap/hibernate
printf 'S1SUSPEND\000' | dd of=$W/udmnt/$P/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "mounted: hibernated=yes" "[ \"\$(st hibernated)\" = yes ]"
gs_invalidate_file $W/udmnt/$P/swap/hibernate
ok "gs_invalidate_file: hibernated=no, size unchanged" "[ \"\$(st hibernated)\" = no ] && [ \$(wc -c < $W/udmnt/$P/swap/hibernate) = 1048576 ]"

# --- list / select / rollback (fake mounts) ----------------------------------
U=$W/udmnt/$P
for d in d1 d2 d3 d4; do mkdir -p $U/deployments/$d/build; printf 'base=v3.22.%s\nkernel=7.3.0-na1\ncreated=2026-10-2%s\n' ${d#d} ${d#d} > $U/deployments/$d/meta; done
echo failed=1 >> $U/deployments/d3/meta
echo x > $U/deployments/notadir
printf 'current=d2\nprevious=d1\ncandidate=\ntries=0\nextra=keep\n' > $W/sysmnt/state/deploy
D=$W/sysmnt/state/deploy
lst() { $G list --porcelain | grep "	id=$1	" | tr '\t' '\n' | sed -n "s/^$2=//p"; }
ok "list: header + 4 records" "[ \"\$($G list --porcelain | head -n 1)\" = 'glassine-deploy 1' ] && [ \$($G list --porcelain | grep -c '^type=deployment	') = 4 ]"
ok "list: states current/previous/failed/kept" "[ \"\$(lst d2 state)\" = current ] && [ \"\$(lst d1 state)\" = previous ] && [ \"\$(lst d3 state)\" = failed ] && [ \"\$(lst d4 state)\" = kept ]"
ok "list: meta fields + size" "[ \"\$(lst d4 base)\" = v3.22.4 ] && [ \"\$(lst d4 created)\" = 2026-10-24 ] && [ -n \"\$(lst d4 size_kib)\" ]"
ok "list: human table" "$G list | grep -q '^d4 *kept'"
$G select d4 >/dev/null
ok "select d4: candidate=d4 tries=2, current kept, other keys kept" "[ \"\$(gs_kv \$D candidate)\" = d4 ] && [ \"\$(gs_kv \$D tries)\" = 2 ] && [ \"\$(gs_kv \$D current)\" = d2 ] && [ \"\$(gs_kv \$D extra)\" = keep ]"
ok "list: d4 is the candidate" "[ \"\$(lst d4 state)\" = candidate ]"
$G select d2 >/dev/null
ok "select current: candidate cleared" "[ -z \"\$(gs_kv \$D candidate)\" ] && [ \"\$(gs_kv \$D tries)\" = 0 ]"
cp $D $W/before
ok "select unknown id: exit 1, state unchanged" "$G select d9 2>/dev/null; [ \$? = 1 ] && cmp -s $D $W/before"
ok "select a bad id: exit 2" "$G select ../d1 2>/dev/null; [ \$? = 2 ] && cmp -s $D $W/before"
ok "select needs exactly one id: exit 2" "$G select 2>/dev/null; [ \$? = 2 ]"
$G rollback >/dev/null
ok "rollback: candidate = previous" "[ \"\$(gs_kv \$D candidate)\" = d1 ] && [ \"\$(gs_kv \$D tries)\" = 2 ]"
gs_update $D candidate= tries=0 previous=
ok "rollback without a previous: exit 1" "$G rollback 2>/dev/null; [ \$? = 1 ]"
gs_set $D previous d1; cp $D $W/before

# refusals must leave the state alone
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "hibernated: select refuses, exit 4, state unchanged" "$G select d4 2>/dev/null </dev/null; [ \$? = 4 ] && cmp -s $D $W/before && [ \"\$(st hibernated)\" = yes ]"
ok "--discard-hibernation without --yes, no terminal: exit 1, image kept" "$G select d4 --discard-hibernation 2>/dev/null </dev/null; [ \$? = 1 ] && cmp -s $D $W/before && [ \"\$(st hibernated)\" = yes ]"
ok "--discard-hibernation --yes: invalidated, then selected" "$G select d4 --discard-hibernation --yes >/dev/null && [ \"\$(st hibernated)\" = no ] && [ \"\$(gs_kv \$D candidate)\" = d4 ]"
cp $D $W/before
: > $W/run/switching
ok "a stale switch marker (no lock holder): removed, select goes on" "$G select d1 >/dev/null 2>&1 && [ ! -e $W/run/switching ] && [ \"\$(gs_kv \$D candidate)\" = d1 ]"
cp $W/before $D
( exec 9>>$W/sysmnt/state/.lock; flock -n 9 && : > $W/held && sleep 5 ) &
while [ ! -e $W/held ]; do sleep 0.1; done
ok "lock held: exit 6, unchanged" "$G select d1 2>/dev/null; [ \$? = 6 ] && cmp -s $D $W/before"
wait; rm -f $W/held
mkdir -p $W/shim; printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > $W/shim/dd; chmod +x $W/shim/dd
ok "a cut write (dd fails): exit 1, old file intact, no temp file" "PATH=$W/shim:\$PATH $G select d1 2>$W/err; [ \$? = 1 ] && grep -q 'cannot write' $W/err && cmp -s $D $W/before && [ -z \"\$(ls -a $W/sysmnt/state | grep tmp)\" ]"
echo version=2 > $W/sysmnt/state/format
ok "newer format: select, list, rollback exit 3, unchanged" "$G select d1 2>/dev/null; a=\$?; $G list >/dev/null 2>&1; b=\$?; $G rollback 2>/dev/null; c=\$?; [ \$a\$b\$c = 333 ] && cmp -s $D $W/before"
echo version=1 > $W/sysmnt/state/format

# --- hibernate-invalidate -----------------------------------------------------
ok "invalidate, nothing hibernated: exit 0" "$G hibernate-invalidate >/dev/null"
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "invalidate without --yes, no terminal: exit 1, kept" "$G hibernate-invalidate 2>/dev/null </dev/null; [ \$? = 1 ] && [ \"\$(st hibernated)\" = yes ]"
ok "invalidate --yes (mounted): hibernated=no" "$G hibernate-invalidate --yes >/dev/null && [ \"\$(st hibernated)\" = no ]"
unset GLASSINE_DEPLOY_FAKE_MOUNTS
printf 'S1SUSPEND\000' | dd of=$W/userdata.img bs=1 seek=$((B * 4096 + 4086)) conv=notrunc 2>/dev/null
ok "invalidate --yes (unmounted, raw): hibernated=no" "[ \"\$(st hibernated)\" = yes ] && $G hibernate-invalidate --yes >/dev/null && [ \"\$(st hibernated)\" = no ]"

# --- list on unmounted userdata (debugfs) -------------------------------------
debugfs -w -R "mkdir /$P/deployments" $W/userdata.img 2>/dev/null
for d in d1 d2; do debugfs -w -R "mkdir /$P/deployments/$d" $W/userdata.img 2>/dev/null; debugfs -w -R "write $U/deployments/$d/meta /$P/deployments/$d/meta" $W/userdata.img >/dev/null 2>&1; done
ok "list (debugfs): 2 records, meta read, no size" "[ \$($G list --porcelain | grep -c '^type=deployment	') = 2 ] && [ \"\$(lst d2 base)\" = v3.22.2 ] && [ -z \"\$(lst d2 size_kib)\" ]"
ok "select on an ext4 (unmigrated) system: exit 1" "$G select d1 2>/dev/null; [ \$? = 1 ]"

echo "$fails failed"
[ $fails = 0 ]
