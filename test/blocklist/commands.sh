#!/bin/sh
# Host test of glassine-bootimg with HANDOFF=blocklist (specs/005, phase 2): real
# ext4 userdata and a real slot on loop devices, a size-limited system partition,
# and the simulated bootloader reader standing in for the bootloader. A trial is
# what the reader, the initramfs (tries=0) and the next boot's promote leave.
set -u
W=/c; mkdir -p $W && mount -t tmpfs -o size=128m tmpfs $W
B=/p/sbin/glassine-bootimg
READER="python3 /p/test/blocklist/reader.py"
SYS=$W/sys; K=$SYS/state/kernel; BI=$SYS/state/bootimg; UDK=$W/ud/media/glassine/kernel
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); tail -n 3 $W/log | sed 's/^/     log: /'; fi; }
LOOPS=''
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1" && LOOPS="$LOOPS $LOOP"
}
truncate -s 48M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 $W/ud.img; loop $W/ud.img; UD=$LOOP
mkdir -p $W/ud $SYS; mount -t ext4 "$UD" $W/ud || { echo "FAIL cannot mount userdata"; exit 1; }
mount -t tmpfs -o size=24m tmpfs $SYS || { echo "FAIL cannot mount the system partition"; exit 1; }
truncate -s 8M $W/slot.img; loop $W/slot.img; SLOT=$LOOP
REC=$(( (8 * 1024 * 1024 - 65536) / 4096 ))
mkdir -p $W/run $W/rundir $W/modes/pon $W/ps/bat $W/plain $W/empty
head -c 1048576 /dev/urandom > $W/abl
echo 'bootloader recovery blocklist' > $W/modes/pon/reboot_modes
echo Battery > $W/ps/bat/type; echo 80 > $W/ps/bat/capacity
. /p/lib/glassine-state.sh
export GLASSINE_BI_SYSTEM=$SYS GLASSINE_BI_LIB=/p/lib GLASSINE_DEPLOY_CONF=$W/none GLASSINE_BI_BOARD=$W/board.conf \
    GLASSINE_BI_DEFAULT_DEV=$SLOT GLASSINE_BI_RECORD_DEV=$SLOT GLASSINE_BI_USERDATA_DEV=$UD GLASSINE_BI_USERDATA_MNT=$W/ud \
    GLASSINE_BI_ABL_DEV=$W/abl GLASSINE_BI_BLOCKLIST=/p/lib/glassine-blocklist GLASSINE_BI_REBOOT_MODES=$W/modes \
    GLASSINE_POWER_SUPPLY=$W/ps GLASSINE_BI_CMDLINE=$W/cmdline GLASSINE_BI_PACK=/p/lib/glassine-bootimg-pack \
    GLASSINE_BI_LOG=$W/log GLASSINE_BI_TMP=$W/run GLASSINE_BI_NOREBOOT=1 GLASSINE_BI_TEST=1 GLASSINE_BI_RUN_DIR=$W/rundir \
    GLASSINE_BI_UNAME=7.1.0-a GLASSINE_BI_MOUNTS=$W/mounts
ABLSHA=$(sha256sum < $W/abl | cut -d' ' -f1)
sed -e 's/^ROOT_LAYOUT=.*/ROOT_LAYOUT=deployments/' -e 's/^HANDOFF=.*/HANDOFF=blocklist/' -e 's/^DEVICE=.*/DEVICE=dev1/' \
    -e 's/^PART_SIZE=.*/PART_SIZE=8388608/' -e "s/^BLOCKLIST_ABL_SHA256=.*/BLOCKLIST_ABL_SHA256=$ABLSHA/" /p/conf/board.conf.example > $W/board.conf
cp $W/board.conf $W/board.good
bset() { sed -i "s#^$1=.*#$1=$2#" $W/board.conf; }
kv() { gs_kv $K "$1"; }
# boot ID [ARG]: a new boot: this image's command line, and RAM's markers gone
boot() { echo "panic=5 rdinit=/init glassine.img=$1${2:+ $2}" > $W/cmdline; rm -f "${W:?}"/run/glassine-bootimg.requested "${W:?}"/run/glassine-bootimg.started; }
try() { gs_update $K tries=0 requested=; }             # what the initramfs does on a trial
mkdir -p $SYS/state $SYS/modules $SYS/boot/dtb $SYS/boot/initramfs
mkrel() {
    mkdir -p $SYS/modules/$1
    printf 'junk Linux version %s (gcc) #1 SMP junk' "$1" | gzip > $SYS/modules/$1/Image.gz
    printf 'format=1\nrelease=%s\nprovides=btrfs overlayfs\n' "$1" > $SYS/modules/$1/kernel.manifest
}
mkrel 6.0.0-old; mkrel 7.1.0-a; mkrel 7.1.0-b
echo 'dtb reboot-mode mode-blocklist' > $SYS/boot/dtb/dev1@aaaa.dtb; echo 'dtb without the mode' > $SYS/boot/dtb/dev1@bbbb.dtb
echo initramfs-c1 > $SYS/boot/initramfs/c1.cpio.gz; printf 'format=1\ncommit=c1\nneeds=btrfs\n' > $SYS/boot/initramfs/c1.manifest
echo version=1 > $SYS/state/format; printf 'current=d1\n' > $SYS/state/deploy
OLDID=$(python3 /p/lib/glassine-bootimg-pack $W/board.conf $SYS/modules/6.0.0-old/Image.gz $SYS/boot/dtb/dev1@aaaa.dtb \
    $SYS/boot/initramfs/c1.cpio.gz $W/old.img | sed -n 's/.*ID=\([0-9a-f]*\).*/\1/p')
OLDSZ=$(stat -c %s $W/old.img); OLDSHA=$(sha256sum < $W/old.img | cut -d' ' -f1)
echo '/x /lib/modules/7.1.0-a none rw 0 0' > $W/mounts

# the slot's first N bytes, the device's own
slotsha() { dd if=$SLOT bs=4096 count=$((($1 + 4095) / 4096)) iflag=direct 2>/dev/null | head -c "$1" | sha256sum | cut -d' ' -f1; }
oldslot() { [ "$(slotsha $OLDSZ)" = "$OLDSHA" ]; }
holds() { [ "$(slotsha "$(gs_kv $BI/$1.manifest size)")" = "$(gs_kv $BI/$1.manifest sha256)" ]; }
readrec() { dd if=$SLOT bs=4096 skip=$REC count=1 iflag=direct 2>/dev/null; }
recid() { readrec > $W/r; python3 /p/lib/glassine-blocklist decode $W/r | sed -n 's/^id=//p;s/^record=none/none/p'; }
noperm() { lsattr "$1" | cut -d' ' -f1 | grep -q i; }
# wipe userdata's kernel directory, as a format of userdata would
wipe_ud() { for f in "${UDK:?}"/*.img; do [ -e "$f" ] || continue; chattr -i "$f"; rm -f "$f"; done; }
fresh() {
    wipe_ud; rm -f "${BI:?}"/* "${SYS:?}"/fill
    printf 'current=6.0.0-old\n' > $K; cp $W/board.good $W/board.conf
    dd if=/dev/zero of=$SLOT bs=4096 count=2048 conv=notrunc,fsync 2>/dev/null
    dd if=$W/old.img of=$SLOT bs=4096 conv=notrunc,fsync 2>/dev/null
    echo d1 > $W/rundir/booted; echo 80 > $W/ps/bat/capacity
    echo 'bootloader recovery blocklist' > $W/modes/pon/reboot_modes
    unset GLASSINE_BI_AFTER_BODY GLASSINE_BI_AFTER_RECORD
    boot $OLDID
}
install() { $B install "${1:-7.1.0-a}" --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err; }
cid() { kv candidate_img; }
reader_ok() { $READER $SLOT $UD $W/o >/dev/null && [ "$(sha256sum < $W/o | cut -d' ' -f1)" = "$(gs_kv $BI/$1.manifest sha256)" ]; }
nothing() { [ -z "$(kv candidate)" ] && [ "$(recid)" = none ] && oldslot; }
export GLASSINE_BI_HEALTH=true

echo "--- install's refusals"
fresh; bset BLOCKLIST_ABL_SHA256 deadbeef
ok "a bootloader not known to read the record: refused" "! install && grep -q 'not one known' $W/err && nothing"
fresh; bset BLOCKLIST_ABL_SHA256 ""
ok "no known bootloader at all: refused" "! install && grep -q 'no bootloader build' $W/err && nothing"
fresh; echo 'bootloader recovery' > $W/modes/pon/reboot_modes
ok "the running kernel has no reboot mode for it: refused" "! install && grep -q 'no reboot mode' $W/err && nothing"
fresh
ok "the candidate's device tree has no mode-blocklist: refused" "! $B install 7.1.0-a --dtb dev1@bbbb --initramfs c1 >/dev/null 2>$W/err && grep -q 'no mode-blocklist' $W/err && nothing"
fresh; echo bare:b1 > $W/rundir/booted
ok "a bare boot: refused" "! install && grep -q 'bare boot' $W/err && nothing"
fresh
ok "userdata isn't ext4: refused" "! GLASSINE_BI_USERDATA_MNT=$W/plain $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err && grep -q 'on tmpfs' $W/err && nothing"
fresh
ok "the record partition isn't the default slot: refused" "! GLASSINE_BI_RECORD_DEV=$W/abl $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err && grep -q 'not the default slot' $W/err && nothing"
fresh; python3 -c "
import os,struct
f=os.open('$SLOT',os.O_RDWR)
h=bytearray(os.pread(f,4096,0)); struct.pack_into('<I',h,8,8*1024*1024-65536); os.pwrite(f,bytes(h),0); os.fsync(f)"
ok "the default image reaches the record: refused, the record untouched" "! install && grep -q 'install: the image in .* reaches the record' $W/err && [ \"\$(recid)\" = none ] && [ -z \"\$(kv candidate)\" ] && ! ls $BI/*.manifest 2>/dev/null | grep -q ."
fresh; dd if=/dev/zero of=$SYS/fill bs=1M 2>/dev/null
ok "no room on the system partition: refused" "! install && grep -q 'no room' $W/err && nothing"
fresh

echo "--- install"
ok "install: exit 0, the candidate set" "install && [ \"\$(kv candidate)\" = 7.1.0-a ] && [ \"\$(kv tries)\" = 1 ]"
ID=$(cid)
ok "... the file is on userdata, immutable" "[ -f $UDK/$ID.img ] && noperm $UDK/$ID.img"
ok "... no copy on the system partition yet" "[ ! -e $BI/$ID.img ] && [ -f $BI/$ID.manifest ]"
ok "... the record names it" "[ \"\$(recid)\" = $ID ]"
ok "... the default image is untouched" "oldslot"
ok "... the simulated reader returns exactly the image" "reader_ok $ID"
install 7.1.0-b; IB=$(cid)
ok "a new install replaces the candidate: its record, its file" "[ \"\$(recid)\" = $IB ] && [ ! -e $UDK/$ID.img ] && reader_ok $IB"

echo "--- reboot-test"
fresh; install; ID=$(cid)
cat > $W/rc <<RC
#!/bin/sh
echo "\$1" > $W/reason
RC
chmod +x $W/rc
ok "reboot-test: requested set, the reboot asked with the board's reason" "GLASSINE_BI_NOREBOOT= GLASSINE_BI_REBOOT_CLEAN=$W/rc $B reboot-test >/dev/null 2>&1 && [ \"\$(kv requested)\" = $ID ] && [ \"\$(cat $W/reason)\" = blocklist ]"
gs_update $K requested=; boot $ID
ok "during the trial: refused" "! $B reboot-test 2>$W/err && grep -q 'trial boot already' $W/err"
boot $OLDID; echo 10 > $W/ps/bat/capacity
ok "below the battery rule: refused" "! $B reboot-test 2>$W/err && grep -q 'below 30' $W/err && [ -z \"\$(kv requested)\" ]"
mkdir -p $W/ps/ac; echo Mains > $W/ps/ac/type; echo 1 > $W/ps/ac/online
ok "... a charger is enough" "$B reboot-test 2>/dev/null && [ \"\$(kv requested)\" = $ID ]"
gs_update $K requested=; rm -f $W/ps/ac/type $W/ps/ac/online; rmdir $W/ps/ac; echo 80 > $W/ps/bat/capacity
rm -f $W/run/glassine-bootimg.requested
echo 'bootloader recovery' > $W/modes/pon/reboot_modes
ok "the running kernel no longer lists the mode: refused" "! $B reboot-test 2>$W/err && grep -q 'no reboot mode' $W/err"
echo 'bootloader recovery blocklist' > $W/modes/pon/reboot_modes
cp $UDK/$ID.img $UDK/$ID.new; sync; chattr -i $UDK/$ID.img; mv -f $UDK/$ID.new $UDK/$ID.img; sync; chattr +i $UDK/$ID.img
ok "the file's blocks moved: refused, and it names install" "! $B reboot-test 2>$W/err && grep -q 'no longer has the blocks' $W/err && grep -q 'install again' $W/err && [ -z \"\$(kv requested)\" ]"
fresh; install; ID=$(cid)
FIRST=$(python3 /p/lib/glassine-blocklist map $UDK/$ID.img | head -n 1 | cut -d' ' -f1)
printf X | dd of=$UD bs=4096 seek=$FIRST conv=notrunc,fsync 2>/dev/null
ok "the file's blocks hold something else: refused" "! $B reboot-test 2>$W/err && grep -q \"don't hold the image\" $W/err"
fresh; install; ID=$(cid)
readrec > $W/r; { head -c 100 $W/r; head -c 3996 /dev/zero; } > $W/torn
dd if=$W/torn of=$SLOT bs=4096 seek=$REC count=1 conv=notrunc,fsync 2>/dev/null
ok "a torn record: refused" "! $B reboot-test 2>$W/err && grep -q 'install again' $W/err"

echo "--- the generic trial scenarios, through the simulated reader"
scen() { fresh; install; ID=$(cid); $B reboot-test >/dev/null 2>&1; reader_ok $ID; }
scen; ok "boot fails (never reaches the initramfs): the reader had it" "reader_ok $ID"
boot $OLDID
ok "... the next boot's promote fails it, no-boot, no manual step" "$B promote 2>/dev/null && [ \"\$(kv failed_img)\" = $ID ] && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = no-boot ] && [ -z \"\$(kv candidate)\" ]"
ok "... the record is gone, the default boot is the old kernel, the file kept" "[ \"\$(recid)\" = none ] && oldslot && [ -f $UDK/$ID.img ] && ! $READER $SLOT $UD $W/o >/dev/null"
scen; try; boot $OLDID
ok "hangs after the initramfs took the try: no-verdict, the record gone" "$B promote 2>/dev/null && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = no-verdict ] && [ \"\$(recid)\" = none ] && oldslot"
scen; try; boot $ID
ok "fails its health check: failed with the reason, the record gone" "GLASSINE_BI_HEALTH='echo sick; false' $B promote 2>/dev/null && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = 'health: sick' ] && [ \"\$(recid)\" = none ] && oldslot"

echo "--- the hand-off verdict"
scen; boot $OLDID; FIRST=$(python3 /p/lib/glassine-blocklist map $UDK/$ID.img | head -n 1 | cut -d' ' -f1)
printf X | dd of=$UD bs=4096 seek=$FIRST conv=notrunc,fsync 2>/dev/null
ok "the blocks no longer pass: handoff" "$B promote 2>/dev/null && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = handoff ]"
scen; boot $OLDID glassine.handoff_err=sha256
ok "the bootloader said it rejected the record: handoff" "$B promote 2>/dev/null && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = handoff ]"
mkdir -p $W/nopy; for d in /bin /sbin /usr/bin /usr/sbin; do for f in $d/*; do case ${f##*/} in python*) ;; *) ln -sf "$f" $W/nopy/ ;; esac; done; done
scen; boot $OLDID
ok "no python3: the verdict still happens, no-boot, the record cleared" "PATH=$W/nopy $B promote 2>/dev/null && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = no-boot ] && [ \"\$(recid)\" = none ]"

echo "--- accept"
scen; try; boot $ID
ok "a healthy trial: accepted, the default slot holds it" "$B promote 2>/dev/null && holds $ID && [ \"\$(kv current)\" = 7.1.0-a ] && [ \"\$(kv current_img)\" = $ID ] && [ -z \"\$(kv writing)\" ]"
ok "... the record is cleared, and the reader finds none" "[ \"\$(recid)\" = none ] && $READER $SLOT $UD $W/o | grep -q 'no record'"
ok "... its image is on the system partition, not userdata" "[ -f $BI/$ID.img ] && [ ! -e $UDK/$ID.img ]"
ok "... the old kernel is seeded on the system partition" "[ \"\$(kv previous_img)\" = $OLDID ] && [ -f $BI/$OLDID.img ] && [ ! -e $UDK/$OLDID.img ]"

echo "--- rollback with userdata formatted"
wipe_ud; echo 10 > $W/ps/bat/capacity
ok "below the battery rule: refused" "! $B rollback 2>$W/err && grep -q 'below 30' $W/err && holds $ID"
echo 80 > $W/ps/bat/capacity
ok "rollback needs neither userdata nor a pack" "GLASSINE_BI_PACK=/nonexistent PATH=$W/nopy $B rollback >/dev/null 2>&1 && oldslot && [ \"\$(kv current_img)\" = $OLDID ] && [ \"\$(kv previous_img)\" = $ID ]"
ok "and back again to the accepted kernel" "$B rollback >/dev/null 2>&1 && holds $ID && [ \"\$(kv current_img)\" = $ID ]"
scen; try; boot $ID
GLASSINE_BI_AFTER_BODY='exit 9' $B promote >/dev/null 2>&1
ok "an accept cut in its default-slot write: writing set, the slot not valid" "[ \"\$(kv writing)\" = $ID ] && [ \"\$(kv writing_op)\" = accept ] && ! holds $ID"
wipe_ud
ok "... finished on the next boot even with userdata formatted" "$B promote 2>/dev/null && holds $ID && [ -z \"\$(kv writing)\" ] && [ \"\$(kv current_img)\" = $ID ] && [ \"\$(recid)\" = none ]"
boot $OLDID
GLASSINE_BI_AFTER_BODY='exit 9' $B rollback >/dev/null 2>&1
ok "a rollback cut in its write: finished on the next boot" "[ \"\$(kv writing_op)\" = rollback ] && $B promote 2>/dev/null && oldslot && [ -z \"\$(kv writing)\" ] && [ \"\$(kv current_img)\" = $OLDID ]"

echo "--- writes that fail"
scen; try; boot $ID; echo 2 > $W/cnt
export GLASSINE_BI_AFTER_BODY='n=$(cat /c/cnt 2>/dev/null || echo 0); echo $((n - 1)) > /c/cnt; [ "$n" -le 0 ] || printf X | dd of="$2" bs=1 seek=5000 conv=notrunc,fsync 2>/dev/null; true'
ok "the default-slot write fails: its image back from RAM, the candidate failed, the record gone" "! $B promote 2>/dev/null; oldslot && [ -z \"\$(kv writing)\" ] && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = 'default slot write' ] && [ \"\$(recid)\" = none ]"
unset GLASSINE_BI_AFTER_BODY
scen; try; boot $ID; dd if=/dev/zero of=$SYS/fill bs=1M 2>/dev/null; truncate -s $(($(stat -c %s $SYS/fill) - 12288)) $SYS/fill
ok "the system partition has no room for the copy: failed, the default slot untouched" "! $B promote 2>/dev/null; oldslot && [ \"\$(gs_kv $BI/$ID.manifest reason)\" = 'copy to the system partition' ] && [ -z \"\$(kv writing)\" ] && [ ! -e $BI/$ID.img ] && [ \"\$(recid)\" = none ]"
scen; try; boot $ID; dd if=/dev/zero of=$SYS/fill bs=1M 2>/dev/null
ok "the system partition is completely full: exit 1, nothing written to the default slot" "! $B promote 2>/dev/null; oldslot && [ -z \"\$(kv writing)\" ]"
rm -f "${SYS:?}"/fill
fresh
cat > $W/nochk <<NC
#!/usr/bin/env python3
import os,sys
if sys.argv[1] == 'check': print('injected read-back failure', file=sys.stderr); sys.exit(1)
os.execv(sys.executable, [sys.executable, '/p/lib/glassine-blocklist'] + sys.argv[1:])
NC
ok "the read-back fails at install: no candidate, no record, the file removed" "! GLASSINE_BI_BLOCKLIST=$W/nochk $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err && nothing && ! ls $UDK/*.img 2>/dev/null | grep -q ."

fresh; install; OLDC=$(cid)
ok "a new install whose record can't be made: no candidate, and no record of the old one" "! GLASSINE_BI_BLOCKLIST=$W/nochk $B install 7.1.0-b --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err && nothing && [ ! -e $UDK/$OLDC.img ]"

echo "--- a deferred install"
fresh; printf 'current=d1\nstaged=s1\n' > $SYS/state/deploy
ok "a staged deployment: the release waits, nothing written" "install && [ \"\$(kv deferred)\" = 7.1.0-a ] && nothing"
printf 'current=d1\n' > $SYS/state/deploy
ok "promote installs it: the candidate, its record" "$B promote >/dev/null 2>&1 && [ \"\$(kv candidate)\" = 7.1.0-a ] && [ \"\$(recid)\" = \"\$(cid)\" ] && [ -z \"\$(kv deferred)\" ]"

echo "--- cut between steps, and stale records"
fresh; GLASSINE_BI_AFTER_RECORD='exit 9' $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>&1; 
ok "an install cut after its record: a record and no candidate" "[ -z \"\$(kv candidate)\" ] && [ \"\$(recid)\" != none ]"
ok "... the next boot's promote clears it" "$B promote 2>/dev/null && [ \"\$(recid)\" = none ] && oldslot"
scen; readrec > $W/saved; try; boot $ID; $B promote 2>/dev/null; dd if=$W/saved of=$SLOT bs=4096 seek=$REC count=1 conv=notrunc,fsync 2>/dev/null
ok "an accept cut before it cleared the record: cleared on the next boot" "[ \"\$(recid)\" = $ID ] && $B promote 2>/dev/null && [ \"\$(recid)\" = none ]"
scen; gs_kernel_cancel $K
ok "glassine-deploy's cancel-first leaves the record, and promote clears it" "[ \"\$(recid)\" = $ID ] && PATH=$W/nopy $B promote 2>/dev/null && [ \"\$(recid)\" = none ]"
export GLASSINE_BI_AFTER_RECORD='echo x >> /c/hits'
fresh; : > $W/hits; rm -f "${SYS:?}"/state/.lock
ok "a boot with nothing to do: nothing written" "$B promote 2>/dev/null && [ ! -s $W/hits ] && [ ! -e $SYS/state/.lock ]"
unset GLASSINE_BI_AFTER_RECORD

echo "--- cancel"
fresh; install; ID=$(cid)
ok "cancel: the record cleared first, the keys gone, the file kept" "$B cancel >/dev/null 2>&1 && [ \"\$(recid)\" = none ] && [ -z \"\$(kv candidate)\" ] && [ -f $UDK/$ID.img ] && oldslot"
fresh; install; dd if=/dev/zero of=$SLOT bs=4096 count=1 conv=notrunc,fsync 2>/dev/null
ok "a slot with no boot image: the clear fails, the cancel still happens" "$B cancel >/dev/null 2>$W/err && [ -z \"\$(kv candidate)\" ] && grep -q 'could not be cleared' $W/err"

echo "--- retry"
scen; boot $OLDID; $B promote 2>/dev/null
ok "retry of a failed candidate: the record back, it can be booted again" "$B retry >/dev/null 2>&1 && [ \"\$(cid)\" = $ID ] && [ -z \"\$(kv failed_img)\" ] && [ \"\$(kv tries)\" = 1 ] && reader_ok $ID && $B reboot-test >/dev/null 2>&1"
scen; boot $OLDID; $B promote 2>/dev/null; FIRST=$(python3 /p/lib/glassine-blocklist map $UDK/$ID.img | head -n 1 | cut -d' ' -f1)
printf X | dd of=$UD bs=4096 seek=$FIRST conv=notrunc,fsync 2>/dev/null
ok "retry when the raw blocks read wrong: stays failed, no record, the file removed" "! $B retry >/dev/null 2>&1 && [ \"\$(kv failed_img)\" = $ID ] && [ \"\$(recid)\" = none ] && [ ! -e $UDK/$ID.img ]"
ok "retry with the file gone: refused, it names install" "! $B retry 2>$W/err && grep -q 'install the kernel again' $W/err"

echo "--- what stays on userdata"
fresh; install; ID=$(cid); dd if=/dev/zero of=$SLOT bs=4096 count=1 conv=notrunc,fsync 2>/dev/null; $B cancel >/dev/null 2>&1
ok "a file a record still names is not removed" "( . $W/board.conf; BOARD=$W/board.conf DEFDEV=$SLOT TMP=$W/run; log() { :; }; die() { exit 1; }; . /p/lib/glassine-state.sh; . /p/lib/glassine-kernel.sh; gk_open; gk_prune ) && [ -f $UDK/$ID.img ]"

[ "$fails" = 0 ] && echo "all command checks passed" || echo "$fails command checks FAILED"
umount $W/ud $SYS 2>/dev/null
for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
cd /; umount $W 2>/dev/null
[ "$fails" = 0 ]
