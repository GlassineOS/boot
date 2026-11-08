#!/bin/sh
# Host test of glassine-bootimg in the deployments layout (lib/glassine-kernel.sh,
# specs/004-kernel-records, phase 1): the system partition's top level is a
# plain directory, both slots are files, the hand-off is bootpart-test. Cut
# and failed writes come from GLASSINE_BI_AFTER_BODY.
set -u
W=/k; SYS=$W/sys; K=$SYS/state/kernel; BI=$SYS/state/bootimg
mkdir -p $SYS/state $SYS/modules $SYS/boot/dtb $SYS/boot/initramfs $W/run $W/sysblock
B=/p/sbin/glassine-bootimg
. /p/lib/glassine-state.sh
export GLASSINE_BI_SYSTEM=$SYS GLASSINE_BI_LIB=/p/lib GLASSINE_DEPLOY_CONF=$W/none GLASSINE_BI_BOARD=$W/board.conf \
    GLASSINE_BI_TEST_DEV=$W/testslot GLASSINE_BI_DEFAULT_DEV=$W/defslot GLASSINE_BI_CMDLINE=$W/cmdline \
    GLASSINE_BI_PACK=/p/lib/glassine-bootimg-pack GLASSINE_BI_LOG=$W/log GLASSINE_BI_TMP=$W/run GLASSINE_BI_NOREBOOT=1 \
    GLASSINE_BI_SYSBLOCK=$W/sysblock GLASSINE_BI_TEST=1
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
kv() { gs_kv $K "$1"; }
st() { $B status 2>/dev/null | sed -n "s/^$1=//p"; }
boot() { echo "panic=5 rdinit=/init glassine.img=$1" > $W/cmdline; }
bset() { sed -i "s#^$1=.*#$1=$2#" $W/board.conf; }
# holds DEV ID: DEV's first bytes are ID's image
holds() { [ "$(head -c "$(gs_kv $BI/$2.manifest size)" "$1" | sha256sum | cut -d' ' -f1)" = "$(gs_kv $BI/$2.manifest sha256)" ]; }
# same A B: the same keys set to the same values (gs_update may reorder them,
# or write a key empty)
same() { [ "$(grep -v '=$' "$1" | sort)" = "$(grep -v '=$' "$2" | sort)" ]; }
# the counter hook: the next N writes are corrupted after their body
corrupt() { echo "$1" > $W/cnt; }
export GLASSINE_BI_AFTER_BODY='n=$(cat /k/cnt 2>/dev/null || echo 0); echo $((n - 1)) > /k/cnt; [ "$n" -le 0 ] || printf X | dd of="$2" bs=1 seek=5000 conv=notrunc 2>/dev/null; true'
corrupt 0

SLOT=1048576
sed -e 's/^ROOT_LAYOUT=.*/ROOT_LAYOUT=deployments/' -e 's/^HANDOFF=.*/HANDOFF=bootpart-test/' -e 's/^DEVICE=.*/DEVICE=dev1/' \
    -e "s/^PART_SIZE=.*/PART_SIZE=$SLOT/" /p/conf/board.conf.example > $W/board.conf
mkrel() {   # mkrel REL [PROVIDES]: modules/REL with a kernel of that release
    mkdir -p $SYS/modules/$1
    printf 'junk Linux version %s (gcc) #1 SMP junk' "$1" | gzip > $SYS/modules/$1/Image.gz
    printf 'format=1\nrelease=%s\nprovides=%s\n' "$1" "${2:-btrfs overlayfs}" > $SYS/modules/$1/kernel.manifest
}
mkrel 6.0.0-old; mkrel 7.1.0-a; mkrel 7.1.0-b
mkdir -p $SYS/modules/7.1.0-bad; printf 'Linux version 7.0.9 (gcc)' | gzip > $SYS/modules/7.1.0-bad/Image.gz
printf 'format=1\nrelease=7.1.0-bad\nprovides=btrfs\n' > $SYS/modules/7.1.0-bad/kernel.manifest
echo dtb-a > $SYS/boot/dtb/dev1@aaaa.dtb; echo dtb-b > $SYS/boot/dtb/dev1@bbbb.dtb
echo initramfs-c1 > $SYS/boot/initramfs/c1.cpio.gz; printf 'format=1\ncommit=c1\nneeds=btrfs\n' > $SYS/boot/initramfs/c1.manifest
echo initramfs-c2 > $SYS/boot/initramfs/c2.cpio.gz; printf 'format=1\ncommit=c2\nneeds=btrfs zram-writeback\n' > $SYS/boot/initramfs/c2.manifest
echo version=1 > $SYS/state/format
printf 'current=d1\n' > $SYS/state/deploy
printf 'current=6.0.0-old\n' > $K
# the default slot holds an image of the current release, as after the migration
OLDID=$(python3 /p/lib/glassine-bootimg-pack $W/board.conf $SYS/modules/6.0.0-old/Image.gz $SYS/boot/dtb/dev1@aaaa.dtb \
    $SYS/boot/initramfs/c1.cpio.gz $W/old.img | sed -n 's/.*ID=\([0-9a-f]*\).*/\1/p')
cp $W/old.img $W/defslot; truncate -s $SLOT $W/defslot
head -c $SLOT /dev/zero > $W/testslot
oldslot() { head -c "$(stat -c %s $W/old.img)" $W/defslot | cmp -s - $W/old.img; }
boot $OLDID

ok "status, nothing set: format=1, state=none, the keys" "[ \"\$($B status | head -n 2 | tr '\n' ' ')\" = 'format=1 state=none ' ] && [ \"\$(st current)\" = 6.0.0-old ]"
ok "promote: nothing done in this layout yet, exit 0" "cp $K $W/k0; $B promote 2>/dev/null && cmp -s $K $W/k0"

# --- install refusals: nothing written ------------------------------------------
cp $K $W/k0
bset HANDOFF ''
ok "HANDOFF empty: install refused, kernel updates are paused, nothing written" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'kernel updates are paused' $W/err && cmp -s $K $W/k0 && [ ! -e $BI ]"
bset HANDOFF blocklist
ok "HANDOFF=blocklist: refused until hub#56" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'not built yet (hub#56)' $W/err && cmp -s $K $W/k0"
bset HANDOFF kexec
ok "an unknown HANDOFF: refused" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q \"unknown HANDOFF 'kexec'\" $W/err && cmp -s $K $W/k0"
bset HANDOFF bootpart-test
ok "bootpart-test on the recovery partition (by-partlabel): refused" "! GLASSINE_BI_TEST_DEV=/dev/disk/by-partlabel/recovery $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'recovery partition' $W/err && cmp -s $K $W/k0"
mkdir -p $W/sysblock/testslot; echo PARTNAME=recovery > $W/sysblock/testslot/uevent
ok "bootpart-test on the recovery partition (PARTNAME in sysfs): refused" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'recovery partition' $W/err && cmp -s $K $W/k0"
rm -r $W/sysblock/testslot
ok "a release without modules/: refused, nothing written" "! $B install 9.9.9 --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'no $SYS/modules/9.9.9' $W/err && cmp -s $K $W/k0"
ok "Image.gz of another release: refused, no image, no temp file" "! $B install 7.1.0-bad --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q 'is not kernel release 7.1.0-bad' $W/err && cmp -s $K $W/k0 && [ -z \"\$(ls $BI)\" ] && [ -z \"\$(ls $W/run)\" ]"
ok "no --initramfs and no current image to take it from: refused, names the flag" "! $B install 7.1.0-a --dtb dev1@aaaa 2>$W/err && grep -q -- '--initramfs COMMIT12@ID' $W/err && cmp -s $K $W/k0"
ok "rule 1: the initramfs needs what the kernel doesn't provide: refused" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c2 2>$W/err && grep -q 'needs: zram-writeback' $W/err && cmp -s $K $W/k0"
mv $SYS/boot/initramfs/c2.manifest $W/c2.manifest
ok "rule 1: an initramfs without a manifest: refused" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c2 2>$W/err && grep -q 'c2.manifest' $W/err && cmp -s $K $W/k0"
mv $W/c2.manifest $SYS/boot/initramfs/c2.manifest
ok "no --dtb and no current image to take it from: refused, names the flag" "! $B install 7.1.0-a --initramfs c1 2>$W/err && grep -q -- '--dtb DEVICE@ID' $W/err && cmp -s $K $W/k0"
ok "a device tree for another device than DEVICE: refused" "echo x > $SYS/boot/dtb/dev2@cccc.dtb; ! $B install 7.1.0-a --initramfs c1 --dtb dev2@cccc 2>$W/err && grep -q 'for another device than dev1' $W/err && cmp -s $K $W/k0"
ok "names with path characters: refused" "! $B install 7.1.0-a --initramfs ../c1 --dtb dev1@aaaa 2>$W/err && grep -q 'bad initramfs name' $W/err && ! $B install 7.1.0-a --initramfs c1 --dtb 'dev1@../aaaa' 2>$W/err && grep -q 'bad device tree name' $W/err && cmp -s $K $W/k0"
head -c 8192 /dev/zero > $W/small
ok "rule 2: an image that doesn't fit the test slot: refused, slot untouched" "! GLASSINE_BI_TEST_DEV=$W/small $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 2>$W/err && grep -q \"doesn't fit $W/small\" $W/err && cmp -s $K $W/k0 && [ \$(tr -d '\\000' < $W/small | wc -c) = 0 ]"
ok "install without a release, or a stray flag: usage, exit 2" "$B install 2>/dev/null; a=\$?; $B install 7.1.0-a --dtb dev1@aaaa --frob 2>/dev/null; [ \$a\$? = 22 ]"

# --- install --------------------------------------------------------------------
ok "install 7.1.0-a: the candidate, tries=1" "$B install 7.1.0-a --initramfs c1 --dtb dev1@aaaa >$W/out 2>&1 && [ \"\$(kv candidate)\" = 7.1.0-a ] && [ -n \"\$(kv candidate_img)\" ] && [ \"\$(kv tries)\" = 1 ] && grep -q 'reboot-test' $W/out"
IDA=$(kv candidate_img); MA=$BI/$IDA.manifest
ok "the record: format=1, the release, size and sha256 of the .img" "[ \"\$(gs_kv $MA format)\" = 1 ] && [ \"\$(gs_kv $MA id)\" = $IDA ] && [ \"\$(gs_kv $MA release)\" = 7.1.0-a ] && [ \"\$(gs_kv $MA size)\" = \$(stat -c %s $BI/$IDA.img) ] && [ \"\$(gs_kv $MA sha256)\" = \"\$(sha256sum < $BI/$IDA.img | cut -d' ' -f1)\" ]"
ok "the record: the boot record (device, kernel, dtb, initramfs, cmdline, board)" "[ \"\$(gs_kv $MA device)\" = dev1 ] && [ \"\$(gs_kv $MA kernel)\" = 7.1.0-a ] && [ \"\$(gs_kv $MA dtb)\" = dev1@aaaa ] && [ \"\$(gs_kv $MA initramfs)\" = c1 ] && gs_kv $MA cmdline | grep -q 'glassine.img=$IDA\$' && [ \"\$(gs_kv $MA board)\" = \"\$(sha256sum < $W/board.conf | cut -d' ' -f1)\" ] && grep -q '^staged=20[0-9-]*T[0-9:]*Z\$' $MA"
ok "the test slot holds it, the default slot is untouched" "holds $W/testslot $IDA && oldslot"
ok "status: state=candidate, the keys" "[ \"\$(st state)\" = candidate ] && [ \"\$(st candidate_img)\" = $IDA ] && [ \"\$(st tries)\" = 1 ]"
ok "glassine-hibernate's check: nothing to refuse while the candidate waits" "[ -z \"\$(gs_kernel_refusal $K $W/cmdline 6.0.0-old)\" ]"
ok "reboot-test: requested = the candidate's image" "$B reboot-test 2>/dev/null && [ \"\$(kv requested)\" = $IDA ]"

# a replace while requested is set (Story 1.6)
ok "install 7.1.0-b replaces it, requested cleared" "$B install 7.1.0-b --initramfs c1 --dtb dev1@bbbb >$W/out 2>$W/err && grep -q 'replaces the candidate 7.1.0-a' $W/out && [ \"\$(kv candidate)\" = 7.1.0-b ] && [ -z \"\$(kv requested)\" ]"
IDB=$(kv candidate_img)
ok "the replaced candidate's image is removed, its record stays" "[ ! -e $BI/$IDA.img ] && [ -e $BI/$IDA.manifest ] && [ -e $BI/$IDB.img ] && holds $W/testslot $IDB"
corrupt 2
ok "a failed test-slot write during a replace: exit 1, no candidate left, said" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>$W/err && grep -q 'there is no kernel candidate now' $W/err && [ -z \"\$(kv candidate)\$(kv candidate_img)\$(kv tries)\" ] && oldslot"
corrupt 0
$B install 7.1.0-b --initramfs c1 --dtb dev1@bbbb >/dev/null 2>&1
printf X | dd of=$W/testslot bs=1 seek=5000 conv=notrunc 2>/dev/null
ok "reboot-test with a test slot that doesn't match: refused, names retry, nothing requested" "! $B reboot-test 2>$W/err && grep -q 'glassine-bootimg retry' $W/err && [ -z \"\$(kv requested)\" ]"
ok "retry: the test slot written again, tries=1" "$B retry >/dev/null 2>&1 && holds $W/testslot $IDB && [ \"\$(kv tries)\" = 1 ] && [ \"\$(kv candidate_img)\" = $IDB ]"
printf X | dd of=$W/testslot bs=1 seek=5000 conv=notrunc 2>/dev/null; corrupt 2
ok "the write hook runs only with GLASSINE_BI_TEST=1" "env -u GLASSINE_BI_TEST $B retry >/dev/null 2>&1 && holds $W/testslot $IDB && [ \"\$(cat $W/cnt)\" = 2 ]"
corrupt 0

# --- deferral (Story 1.5) -------------------------------------------------------
printf 'current=d1\ncandidate=d2\ntries=2\n' > $SYS/state/deploy
ok "a deployment candidate: install deferred, exit 0, the candidate kept" "$B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >$W/out 2>&1 && [ \"\$(kv deferred)\" = 7.1.0-a ] && [ \"\$(kv candidate_img)\" = $IDB ] && grep -q 'after the deployment candidate d2' $W/out"
ok "the deferred install keeps its device tree and initramfs" "[ \"\$(kv deferred_dtb)\" = dev1@aaaa ] && [ \"\$(kv deferred_initramfs)\" = c1 ]"
ok "a deferred install with flags: the flags kept" "$B install 7.1.0-b --initramfs c1 --dtb dev1@bbbb >/dev/null 2>&1 && [ \"\$(kv deferred)\" = 7.1.0-b ] && [ \"\$(kv deferred_dtb)\" = dev1@bbbb ] && [ \"\$(kv deferred_initramfs)\" = c1 ]"
cp $K $W/k0
ok "an install that would be refused isn't deferred (rule 1, no initramfs to take)" "! $B install 7.1.0-a --dtb dev1@aaaa --initramfs c2 2>/dev/null && ! $B install 7.1.0-a --dtb dev1@aaaa 2>/dev/null && cmp -s $K $W/k0"
ok "reboot-test during a deployment candidate: refused, nothing requested" "! $B reboot-test 2>$W/err && grep -q 'deployment candidate d2' $W/err && [ -z \"\$(kv requested)\" ]"
ok "retry during a deployment candidate: refused, unchanged" "! $B retry 2>/dev/null && cmp -s $K $W/k0"
printf 'current=d1\nstaged=d3\n' > $SYS/state/deploy; gs_update $K deferred= deferred_dtb= deferred_initramfs=
ok "a staged deployment: deferred" "$B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>&1 && [ \"\$(kv deferred)\" = 7.1.0-a ]"
ok "reboot-test with a staged deployment: refused" "! $B reboot-test 2>$W/err && grep -q 'staged deployment d3' $W/err && [ -z \"\$(kv requested)\" ]"
printf 'current=d1\n' > $SYS/state/deploy; gs_update $K deferred= deferred_dtb= deferred_initramfs=
boot $IDB
ok "status on the candidate's boot: state=trial" "[ \"\$(st state)\" = trial ]"
ok "during the trial: install deferred" "$B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>&1 && [ \"\$(kv deferred)\" = 7.1.0-a ] && [ \"\$(kv candidate_img)\" = $IDB ]"
ok "glassine-hibernate's check: refused during the trial" "gs_kernel_refusal $K $W/cmdline 7.1.0-b | grep -q 'kernel trial'"

# --- cancel (Story 3.1, 3.2) ----------------------------------------------------
ok "cancel during the trial: the keys cleared, deferred stays, the files kept, said" "$B cancel >$W/out 2>&1 && [ -z \"\$(kv candidate)\$(kv candidate_img)\$(kv tries)\$(kv requested)\" ] && [ \"\$(kv deferred)\" = 7.1.0-a ] && [ -e $BI/$IDB.img ] && grep -q 'the next boot runs 6.0.0-old' $W/out && oldslot"
ok "glassine-hibernate's check: still refused after the cancel (another kernel boots next)" "gs_kernel_refusal $K $W/cmdline 7.1.0-b | grep -q 'next boot runs kernel 6.0.0-old'"
ok "cancel with no candidate: exit 0" "$B cancel >/dev/null 2>&1"

# --- a trial that ended without a verdict, then an install (Story 1.7) ----------
boot $OLDID
$B install 7.1.0-b --initramfs c1 --dtb dev1@bbbb >/dev/null 2>&1; gs_update $K tries=0
ok "install with tries=0 on another boot: the old one failed (no-verdict) first, then installed" "$B install 7.1.0-a --dtb dev1@aaaa --initramfs c1 >/dev/null 2>&1 && [ \"\$(kv failed)\" = 7.1.0-b ] && [ \"\$(kv failed_img)\" = $IDB ] && [ \"\$(gs_kv $BI/$IDB.manifest reason)\" = no-verdict ] && [ \"\$(kv candidate_img)\" = $IDA ] && [ \"\$(kv tries)\" = 1 ]"
ok "installing the deferred release clears deferred and its flags; the failed image is kept" "[ -z \"\$(kv deferred)\$(kv deferred_dtb)\$(kv deferred_initramfs)\" ] && [ -e $BI/$IDB.img ]"

# --- accept, the first one: seeding (FR-015) ------------------------------------
ok "accept on a boot that isn't the trial: refused, nothing written" "cp $K $W/k0; ! $B accept 2>$W/err && grep -q \"not the candidate's\" $W/err && cmp -s $K $W/k0 && oldslot"
boot $IDA
# the first accept in a copy of the state, with another image on the default slot (FR-015)
seedcase() {   # seedcase SLOT [CURRENT]: accept there; the copy is $W/c
    rm -rf $W/c; mkdir -p $W/c; cp -a $SYS $W/c/sys; cp $W/testslot $W/c/testslot; cp "$1" $W/c/defslot
    [ -z "${2:-}" ] || gs_update $W/c/sys/state/kernel "current=$2"
    GLASSINE_BI_SYSTEM=$W/c/sys GLASSINE_BI_DEFAULT_DEV=$W/c/defslot GLASSINE_BI_TEST_DEV=$W/c/testslot $B accept 2>$W/c/err
}
cnot() { [ "$(gs_kv $W/c/sys/state/kernel current_img)" = $IDA ] && [ -z "$(gs_kv $W/c/sys/state/kernel previous_img)" ] && [ ! -e $W/c/sys/state/bootimg/$OLDID.manifest ]; }
ok "accept, the default slot's kernel isn't release current: accepted, nothing seeded" "seedcase $W/defslot 6.0.0-other && cnot && grep -q 'is not release 6.0.0-other' $W/c/err"
ok "... then rollback: no previous image" "! GLASSINE_BI_SYSTEM=$W/c/sys GLASSINE_BI_DEFAULT_DEV=$W/c/defslot GLASSINE_BI_TEST_DEV=$W/c/testslot $B rollback 2>$W/c/err && grep -q 'no previous image' $W/c/err"
cp $W/defslot $W/slot.v1; printf '\001' | dd of=$W/slot.v1 bs=1 seek=40 conv=notrunc 2>/dev/null
ok "accept, a header v1 image on the default slot: no image to keep, nothing seeded" "seedcase $W/slot.v1 && cnot && grep -q 'holds no image to keep' $W/c/err"
head -c $SLOT /dev/zero > $W/slot.none
ok "accept, no image on the default slot: nothing seeded" "seedcase $W/slot.none && cnot"
rm -rf $W/c $W/slot.v1 $W/slot.none
ok "accept: the default slot = the candidate" "$B accept 2>/dev/null && holds $W/defslot $IDA && [ \"\$(kv current)\" = 7.1.0-a ] && [ \"\$(kv current_img)\" = $IDA ]"
ok "accept: the candidate keys, requested and writing cleared" "[ -z \"\$(kv candidate)\$(kv candidate_img)\$(kv tries)\$(kv requested)\$(kv writing)\$(kv writing_op)\" ]"
ok "seeded: previous = the old release and the default slot's image, marked seeded=1" "[ \"\$(kv previous)\" = 6.0.0-old ] && [ \"\$(kv previous_img)\" = $OLDID ] && [ \"\$(gs_kv $BI/$OLDID.manifest seeded)\" = 1 ] && [ \"\$(gs_kv $BI/$OLDID.manifest release)\" = 6.0.0-old ] && cmp -s $BI/$OLDID.img $W/old.img"
ok "status after accept: state=failed (the earlier 7.1.0-b), with its reason" "[ \"\$(st state)\" = failed ] && [ \"\$(st reason)\" = no-verdict ]"
ok "glassine-hibernate's check: nothing to refuse (the running image is the current one)" "[ -z \"\$(gs_kernel_refusal $K $W/cmdline 7.1.0-a)\" ]"

# --- rollback (Story 3.3): a cut write first, then one without an image to keep --
cp $K $W/k0
GLASSINE_BI_AFTER_BODY='kill -9 $$' $B rollback 2>/dev/null
ok "a cut rollback write (killed after the body): writing set, the slot has no header" "[ \"\$(kv writing)\" = $OLDID ] && [ \"\$(kv writing_op)\" = rollback ] && [ \"\$(head -c 8 $W/defslot | tr -d '\\000')\" = '' ] && [ \"\$(kv current)\" = 7.1.0-a ]"
ok "status: state=writing, default_slot=bad" "[ \"\$(st state)\" = writing ] && [ \"\$(st default_slot)\" = bad ]"
ok "while writing is set: install, rollback, cancel, accept, retry refused" "! $B install 7.1.0-b --dtb dev1@aaaa --initramfs c1 2>/dev/null && ! $B rollback 2>/dev/null && ! $B cancel 2>/dev/null && ! $B accept 2>/dev/null && ! $B retry 2>/dev/null"
ok "glassine-hibernate's check: refused while writing is set" "gs_kernel_refusal $K $W/cmdline 7.1.0-a | grep -q 'unfinished'"
rm -f $W/run/*                                  # a reboot: /run is empty
boot $OLDID
ok "a boot of the image being written: state=finishing" "[ \"\$(st state)\" = finishing ]"
boot $IDA; cp $W/k0 $K                          # the write undone by hand (phase 2's promote does it)
ok "rollback with no image on the default slot to keep: written anyway, logged" "$B rollback >$W/out 2>/dev/null && holds $W/defslot $OLDID && grep -q 'holds no image to keep' $W/log"
ok "rollback: current and previous swapped" "[ \"\$(kv current)\" = 6.0.0-old ] && [ \"\$(kv current_img)\" = $OLDID ] && [ \"\$(kv previous)\" = 7.1.0-a ] && [ \"\$(kv previous_img)\" = $IDA ] && [ -z \"\$(kv writing)\" ]"
ok "glassine-hibernate's check: refused after the rollback (this boot runs the other image)" "gs_kernel_refusal $K $W/cmdline 7.1.0-a | grep -q 'next boot runs kernel image $OLDID'"
gs_update $K candidate=7.1.0-b candidate_img=$IDB tries=1; cp $K $W/k1; corrupt 2
ok "a failed rollback with a candidate set: exit 1, the old image back, state/kernel as before" "! $B rollback >/dev/null 2>&1 && holds $W/defslot $OLDID && same $K $W/k1"
corrupt 0
boot $OLDID
ok "rollback again: back to 7.1.0-a" "$B rollback >$W/out 2>&1 && holds $W/defslot $IDA && [ \"\$(kv current_img)\" = $IDA ] && [ \"\$(kv previous_img)\" = $OLDID ]"
ok "... the candidate cancelled with it, said" "[ -z \"\$(kv candidate)\$(kv candidate_img)\$(kv tries)\$(kv requested)\" ] && grep -q 'kernel candidate 7.1.0-b cancelled' $W/out"

# --- retry a failed candidate (Story 3.6) ---------------------------------------
boot $IDA
ok "retry the failed 7.1.0-b: its image on the test slot again, candidate, failed cleared" "$B retry >/dev/null 2>&1 && holds $W/testslot $IDB && [ \"\$(kv candidate_img)\" = $IDB ] && [ \"\$(kv tries)\" = 1 ] && [ -z \"\$(kv failed)\$(kv failed_img)\" ] && [ -z \"\$(gs_kv $BI/$IDB.manifest reason)\" ]"

# --- accept: a read-back mismatch, then a failed write put back from RAM, then a
# restore that fails too (FR-009) ------------------------------------------------
boot $IDB; corrupt 1
ok "accept with one read-back mismatch: the retry writes it, accepted" "$B accept 2>/dev/null && holds $W/defslot $IDB && [ \"\$(kv current_img)\" = $IDB ] && [ \"\$(kv previous_img)\" = $IDA ] && grep -q 'read-back failed (try 1)' $W/log"
ok "the seed's image is gone once nothing names it" "[ ! -e $BI/$OLDID.img ] && [ -e $BI/$OLDID.manifest ]"
boot $IDB
ok "no --dtb: the current image's device tree" "[ \"\$(gs_kv $BI/$IDB.manifest dtb)\" = dev1@bbbb ] && $B install 7.1.0-a --initramfs c1 >/dev/null 2>&1 && [ \"\$(gs_kv $BI/\$(kv candidate_img).manifest dtb)\" = dev1@bbbb ]"
IDC=$(kv candidate_img)
boot $IDC; corrupt 2; cp $K $W/k0
ok "accept, both tries fail: exit 1, the old image back from RAM" "! $B accept 2>/dev/null && holds $W/defslot $IDB && [ -z \"\$(kv writing)\$(kv writing_op)\" ]"
ok "... the candidate failed (default slot write), the rest as before" "[ \"\$(kv failed_img)\" = $IDC ] && [ \"\$(gs_kv $BI/$IDC.manifest reason)\" = 'default slot write' ] && [ \"\$(kv current_img)\" = $IDB ] && [ \"\$(kv previous_img)\" = $IDA ] && [ -z \"\$(kv candidate)\" ]"
$B retry >/dev/null 2>&1; corrupt 4
ok "accept, the write and the restore fail: exit 1, writing stays" "! $B accept 2>/dev/null && [ \"\$(kv writing)\" = $IDC ] && [ \"\$(kv writing_op)\" = accept ] && [ \"\$(kv current_img)\" = $IDB ]"
ok "status on that boot: state=writing, default_slot=bad" "[ \"\$(st state)\" = writing ] && [ \"\$(st default_slot)\" = bad ]"
ok "glassine-hibernate's check: refused" "gs_kernel_refusal $K $W/cmdline 7.1.0-a | grep -q 'unfinished'"
corrupt 0

# --- state format, lock, usage --------------------------------------------------
gs_update $K writing= writing_op=; cp $K $W/k0
echo version=2 > $SYS/state/format
ok "a newer state format: install, cancel, status exit 3, nothing written" "$B install 7.1.0-b --dtb dev1@aaaa --initramfs c1 2>/dev/null; a=\$?; $B cancel 2>/dev/null; b=\$?; $B status >/dev/null 2>&1; [ \$a\$b\$? = 333 ] && cmp -s $K $W/k0"
echo version=1 > $SYS/state/format
gs_update $BI/$IDB.manifest format=2
ok "a newer image record: rollback exit 3" "boot $IDB; gs_update $K previous_img=$IDB; $B rollback 2>/dev/null; r=\$?; cp $W/k0 $K; [ \$r = 3 ]"
gs_update $BI/$IDB.manifest format=1
( exec 9>>$SYS/state/.lock; flock -n 9 && : > $W/held && sleep 5 ) &
while [ ! -e $W/held ]; do sleep 0.1; done
ok "the lock held: exit 6, nothing written" "$B cancel 2>/dev/null; [ \$? = 6 ] && cmp -s $K $W/k0"
wait; rm -f $W/held
ok "usage: exit 2" "$B frob 2>/dev/null; a=\$?; $B status x 2>/dev/null; [ \$a\$? = 22 ]"
ok "no temp files left in /run" "[ -z \"\$(ls $W/run | grep -v -e notice -e started)\" ]"

echo "--- log"; cat $W/log
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
