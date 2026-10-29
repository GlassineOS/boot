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

echo "$fails failed"
[ $fails = 0 ]
