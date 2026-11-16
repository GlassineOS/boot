#!/bin/sh
# Host test of the uefi hand-off (lib/glassine-bootpart.sh, glassine-bootimg with
# HANDOFF=uefi; docs/boot-partition.md, specs/010 FR-025 to FR-028), in Alpine
# (busybox as on the device). What it writes is read back by loader_model.py, a
# port of the loader's own reader (GlassineOS/loader core/src/record.rs, setrec.rs),
# and the installer's golden bytes (golden/, from GlassineOS/installer
# core/tests/golden/pc-boot/) are read and reproduced. Cut writes and read-back
# mismatches come from GLASSINE_BI_AFTER_SLOT / GLASSINE_BI_AFTER_SETFILE.
# Part 1: the library. Part 2: glassine-bootimg on a directory as the boot
# partition. Part 3 (privileged): a real FAT file system on a loop device.
set -u
D=/p/test/bootpart
M="python3 $D/loader_model.py"
W=/w; mkdir -p $W
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ ! -s $W/err ] || sed "s/^/     err: /" $W/err | tail -n 3; fails=$((fails + 1)); fi; : > $W/err; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
export GLASSINE_BI_TEST=1
TMP=$W/tmp; mkdir -p $TMP
. /p/lib/glassine-bootpart.sh
GP_TMP=$TMP

# --- 1. the library ---------------------------------------------------------------
BP=$W/bp; mkdir -p $BP/glassine
cp $D/golden/loader.a $D/golden/loader.b $BP/glassine/
ok "the installer's golden slots: slot a in use, seq 1, both valid" "gp_in_use $BP && [ \$GP_USE\$GP_SEQ\$GP_BOTH = a11 ] && [ \"\$(gp_get \$GP_REC default)\" = 1abb421e678cbd3b ]"
ok "the installer's record: every key as the loader reads it" "[ \"\$(sed '\$d' \$GP_REC)\" = \"\$($M in-use $BP | tail -n +2 | grep -v '^check=')\" ]"
KS=$(printf kernel | sha256sum | cut -d' ' -f1) IS=$(printf initrd | sha256sum | cut -d' ' -f1)
ok "a set's id: the installer's for the same kernel, initrd and base" "[ \"\$(gp_set_id $KS $IS 'console=ttyS0 quiet')\" = 1abb421e678cbd3b ]"
gp_set_rec $W/set.rec 1abb421e678cbd3b 6.18.63-0-lts $KS 12345678 $IS 34567890 \
    'console=ttyS0 quiet glassine.system=PARTUUID=0f3e26a1-5c7b-4a55-9b8d-2c4f6e8a1b3d glassine.userdata=PARTUUID=6d1a5e2b-8c4f-4b3a-a9e7-1f2d3c4b5a69 glassine.img=1abb421e678cbd3b' \
    0123456789ab@00000000deadbeef
ok "set.rec: the installer's golden bytes" "cmp -s $W/set.rec $D/golden/set.rec"
ok "set.rec's sha256 is the golden record's default_rec" "[ \"\$(sha $W/set.rec)\" = \"\$(gp_get \$GP_REC default_rec)\" ]"
printf 'ROOT_LAYOUT=deployments\nCMDLINE="panic=10 loglevel=4"\n' > $W/board.conf
gp_board_archive $W/board.conf $W/ba
ok "the board archive: the installer's bytes (board_archive)" "$M board-archive $W/board.conf | cmp -s - $W/ba"
python3 - $W/board.conf > $W/ba.pack <<'EOF'
import sys
src = open('/p/lib/glassine-bootimg-pack').read()
start = src.index('def newc'); end = src.index('\n\n', start)
ns = {}
exec(src[start:end], ns)
sys.stdout.buffer.write(ns['newc']([('etc', 0o40755, b''), ('etc/glassine-boot', 0o40755, b''),
                                    ('etc/glassine-boot/board.conf', 0o100644, open(sys.argv[1], 'rb').read())]))
EOF
ok "the board archive: the same bytes glassine-bootimg-pack's newc makes" "cmp -s $W/ba.pack $W/ba"

# the base command line, as the installer reads it
bc() { printf '%s\n' "$1" > $W/bc.conf; gp_board_cmdline $W/bc.conf 2>/dev/null; }
ok "CMDLINE=\"<text>\" and CMDLINE=<word> read" "[ \"\$(bc 'CMDLINE=\"a b\"')\" = 'a b' ] && [ \"\$(bc CMDLINE=quiet)\" = quiet ]"
ok "CMDLINE with a \$, a quote, two lines or none: refused" "! bc 'CMDLINE=\"a \$b\"' && ! bc \"CMDLINE='a'\" && ! bc 'CMDLINE=\"a\" x' && ! bc 'X=1' && ! { printf 'CMDLINE=a\nCMDLINE=b\n' > $W/bc.conf; gp_board_cmdline $W/bc.conf 2>/dev/null; }"
ok "a base holding an own key, or not single-spaced: refused" "! gp_base_ok 'quiet glassine.img=1' 2>/dev/null && ! gp_base_ok 'a  b' 2>/dev/null && gp_base_ok 'panic=10 loglevel=4'"

# one write: to the other slot, seq + 1, the other keys kept in their order
cp $BP/glassine/loader.a $W/a0
ok "a write: slot b, seq 2, the loader reads it" "gp_write $BP trial=0123456789abcdef trial_rec=x newkey=1 && [ \"\$($M in-use $BP | head -n 1)\" = 'b 2 1' ] && [ \"\$($M get $BP trial)\" = 0123456789abcdef ] && [ \"\$($M get $BP newkey)\" = 1 ]"
ok "a write: the slot in use (a) not touched, both 16384 bytes" "cmp -s $BP/glassine/loader.a $W/a0 && [ \$(wc -c < $BP/glassine/loader.b) = 16384 ]"
ok "a write: unknown keys kept, keys in the record's order, new ones at the end" "[ \"\$($M in-use $BP | sed -n '2,6p' | cut -d= -f1 | tr '\n' ' ')\" = 'format seq default default_rec previous ' ] && [ \"\$($M in-use $BP | grep -v '^check=' | tail -n 1)\" = newkey=1 ]"
python3 - $BP/glassine/loader.b <<'EOF' > $W/same
import sys
sys.path.insert(0, '/p/test/bootpart'); import loader_model as m
print(int(open(sys.argv[1], 'rb').read() == (lambda r: (lambda b: b + b'\n' * (16384 - len(b)))(m.text(r).encode()))(m.read_slot(open(sys.argv[1], 'rb').read())[1])))
EOF
ok "a write: the bytes the loader's own writer (record.rs next) would make for that record" "[ \"\$(cat $W/same)\" = 1 ]"
ok "the next write: slot a, seq 3" "gp_write $BP && [ \"\$($M in-use $BP | head -n 1)\" = 'a 3 1' ]"
ok "a write after the loader's own (record.rs next): read and raised" "$M next $BP request= started=1abb421e678cbd3b && gp_write $BP && [ \"\$($M in-use $BP | head -n 1)\" = 'a 5 1' ] && [ \"\$($M get $BP started)\" = 1abb421e678cbd3b ]"
# a slot that isn't valid: the other one is in use, the write goes to the bad one
printf 'garbage' | dd of=$BP/glassine/loader.b bs=1 seek=100 conv=notrunc 2>/dev/null
ok "one slot not valid: the other in use, both_valid 0, the write goes over the bad one" "gp_in_use $BP && [ \$GP_USE\$GP_BOTH = a0 ] && gp_write $BP && [ \"\$($M in-use $BP | head -n 1)\" = 'b 6 1' ]"
cp $BP/glassine/loader.a $W/a1; cp $BP/glassine/loader.b $W/b1
printf '\000' | dd of=$BP/glassine/loader.a bs=1 seek=16000 conv=notrunc 2>/dev/null
ok "a slot holding a NUL byte: refused (2), nothing written" "gp_in_use $BP; [ \$? = 2 ] && ! gp_write $BP && cmp -s $BP/glassine/loader.b $W/b1"
cp $W/a1 $BP/glassine/loader.a
ok "a record that wouldn't fit its slot: refused, nothing written" "! gp_write $BP big=\$(head -c 17000 /dev/zero | tr '\\000' x) && cmp -s $BP/glassine/loader.a $W/a1 && cmp -s $BP/glassine/loader.b $W/b1"
ok "a value holding a newline, a bad key: refused" "! gp_write $BP 'a=x
y' && ! gp_write $BP 'A-B=1' && cmp -s $BP/glassine/loader.a $W/a1"
# cut writes: the slot written is cut after its bytes (both tries)
export GLASSINE_BI_AFTER_SLOT='n=$(cat /w/cnt); echo $((n - 1)) > /w/cnt; [ "$n" -le 0 ] || truncate -s 300 "$1"'
echo 2 > $W/cnt
ok "a write cut both times (read-back mismatch): 1, the slot in use as it was, the loader reads the old record" "! gp_write $BP x=1 && cmp -s $BP/glassine/loader.b $W/b1 && [ \"\$($M in-use $BP | head -n 1)\" = 'b 6 0' ] && [ -z \"\$($M get $BP x)\" ]"
echo 1 > $W/cnt
ok "a write cut once: the retry writes it whole" "gp_write $BP x=2 && [ \"\$($M in-use $BP | head -n 1)\" = 'a 7 1' ] && [ \"\$($M get $BP x)\" = 2 ]"
echo 0 > $W/cnt
export GLASSINE_BI_AFTER_SLOT='printf Z | dd of="$1" bs=1 seek=40 conv=notrunc 2>/dev/null'
ok "a write whose bytes don't read back (a flipped byte): 1, the old record in use" "! gp_write $BP x=3 && [ \"\$($M get $BP x)\" = 2 ] && [ \"\$($M in-use $BP | head -n 1 | cut -d' ' -f1-2)\" = 'a 7' ]"
unset GLASSINE_BI_AFTER_SLOT
# a cut at any byte leaves the old record or the new one, for the loader and for us
cp $BP/glassine/loader.a $W/ua; cp $BP/glassine/loader.b $W/ub
gp_write $BP x=4 >/dev/null; cp $BP/glassine/loader.b $W/nb
cut_ok=1
for at in 0 1 100 500 600 1000 4095 4096 8192 16383; do
    cp $W/ua $BP/glassine/loader.a; head -c $at $W/nb > $W/cut; tail -c +$((at + 1)) $W/ub >> $W/cut; cp $W/cut $BP/glassine/loader.b
    mine=$(gp_in_use $BP && echo "$GP_USE $GP_SEQ"); theirs=$($M in-use $BP | head -n 1 | cut -d' ' -f1-2)
    [ "$mine" = "$theirs" ] && { [ "$theirs" = 'a 7' ] || [ "$theirs" = 'b 8' ]; } || { cut_ok=0; echo "  cut at $at: ours '$mine', the loader's '$theirs'"; }
done
ok "a write cut at any byte: the old record or the new, the same one the loader reads" "[ $cut_ok = 1 ]"
cp $W/ua $BP/glassine/loader.a; cp $W/ub $BP/glassine/loader.b
export GLASSINE_BI_AFTER_SLOT='truncate -s 9000 "$1"'
ok "a slot that doesn't read back but still holds the whole new record (cut in its newlines): 0, it is in use, as the loader reads it" "gp_write $BP x=0 && [ \"\$($M get $BP x)\" = 0 ] && gp_in_use $BP && [ \"\$(gp_get \$GP_REC x)\" = 0 ]"
unset GLASSINE_BI_AFTER_SLOT
rm $BP/glassine/loader.a; printf 'format=1\nseq=x\n' > $BP/glassine/loader.b
ok "no valid slot: refused, no record invented" "! gp_in_use $BP && ! gp_write $BP && [ ! -e $BP/glassine/loader.a ]"

# a set's files: .new, synced, read back, renamed
printf 'kernel-bytes' > $W/k
mkdir -p $W/s
ok "gp_put: written, no .new left" "gp_put $W/k $W/s/vmlinuz && cmp -s $W/k $W/s/vmlinuz && [ ! -e $W/s/vmlinuz.new ]"
rm $W/s/vmlinuz
export GLASSINE_BI_AFTER_SETFILE='truncate -s 3 "$1"'
ok "gp_put cut (both tries): 1, no file, no .new" "! gp_put $W/k $W/s/vmlinuz && [ ! -e $W/s/vmlinuz ] && [ ! -e $W/s/vmlinuz.new ]"
unset GLASSINE_BI_AFTER_SETFILE

# --- 2. glassine-bootimg, HANDOFF=uefi, the boot partition a directory -----------------
. /p/lib/glassine-state.sh
SYS=$W/sys K=$SYS/state/kernel BI=$SYS/state/bootimg BP=$W/boot
mkdir -p $SYS/state $SYS/modules $SYS/boot/initramfs $W/run $BP/glassine/sets
B=/p/sbin/glassine-bootimg
SU=0f3e26a1-5c7b-4a55-9b8d-2c4f6e8a1b3d UU=6d1a5e2b-8c4f-4b3a-a9e7-1f2d3c4b5a69
printf '#!/bin/sh\n# a stand-in for build-boot-modules.sh MODDIR OUT\nprintf "modules of %%s" "${1##*/}" > "$2"\n' > $W/bootmods; chmod +x $W/bootmods
export GLASSINE_BI_SYSTEM=$SYS GLASSINE_BI_LIB=/p/lib GLASSINE_DEPLOY_CONF=$W/none GLASSINE_BI_BOARD=$W/board.conf \
    GLASSINE_BI_CMDLINE=$W/cmdline GLASSINE_BI_LOG=$W/log GLASSINE_BI_TMP=$W/run GLASSINE_BI_NOREBOOT=1 \
    GLASSINE_BI_BOOTPART_DIR=$BP GLASSINE_BI_BOOTMODS=$W/bootmods GLASSINE_BI_HEALTH=true GLASSINE_BI_MOUNTS=$W/mounts
printf 'ROOT_LAYOUT=deployments\nHANDOFF=uefi\nROOT_PART=glassine-system\nUSERDATA_PART=glassine-userdata\nCMDLINE="panic=10 loglevel=4"\n' > $W/board.conf
kv() { gs_kv $K "$1"; }
st() { $B status 2>/dev/null | sed -n "s/^$1=//p"; }
rec() { $M get $BP "$1"; }
boot() {    # boot ID: this boot runs set ID (its release the running kernel, its modules bound)
    echo "BOOT_IMAGE=vmlinuz panic=10 loglevel=4 glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU glassine.img=$1" > $W/cmdline
    export GLASSINE_BI_UNAME=$(gs_kv $BI/$1.manifest release)
    echo "x /lib/modules/$GLASSINE_BI_UNAME x" > $W/mounts
}
mkrel() {   # mkrel REL: modules/REL with an x86 boot image of that release
    mkdir -p $SYS/modules/$1/microcode
    head -c 4096 /dev/zero > $SYS/modules/$1/vmlinuz
    printf HdrS | dd of=$SYS/modules/$1/vmlinuz bs=1 seek=514 conv=notrunc 2>/dev/null
    printf '\000\003' | dd of=$SYS/modules/$1/vmlinuz bs=1 seek=526 conv=notrunc 2>/dev/null
    printf '%s (builder@host) #1 SMP\000' "$1" | dd of=$SYS/modules/$1/vmlinuz bs=1 seek=1280 conv=notrunc 2>/dev/null
    printf 'format=1\nrelease=%s\nimage=vmlinuz\nprovides=btrfs overlayfs\n' "$1" > $SYS/modules/$1/kernel.manifest
    printf 'ucode-%s' "$1" > $SYS/modules/$1/microcode/intel-ucode.img
    printf 'amd%s' "$1" > $SYS/modules/$1/microcode/amd-ucode.img
}
mkrel 7.0.0-a; mkrel 7.1.0-b; mkrel 7.2.0-c; mkrel 7.3.0-d
echo initramfs-c1 > $SYS/boot/initramfs/c1@1.cpio.gz; printf 'format=1\ncommit=c1\nneeds=btrfs\n' > $SYS/boot/initramfs/c1@1.manifest
echo version=1 > $SYS/state/format; printf 'current=d1\n' > $SYS/state/deploy; : > $K

# the installer's boot partition: the set of 7.0.0-a, both slots seq=1 (as pc_boot.rs writes them)
printf 'modules of 7.0.0-a' > $W/m0
gp_assemble $W/i0 $W/board.conf $SYS/boot/initramfs/c1@1.cpio.gz $SYS/modules/7.0.0-a/microcode $W/m0
I0=$(gp_set_id "$(sha $SYS/modules/7.0.0-a/vmlinuz)" "$(sha $W/i0)" 'panic=10 loglevel=4')
mkdir -p $BP/glassine/sets/$I0; cp $SYS/modules/7.0.0-a/vmlinuz $BP/glassine/sets/$I0/vmlinuz; cp $W/i0 $BP/glassine/sets/$I0/initrd
gp_set_rec $BP/glassine/sets/$I0/set.rec $I0 7.0.0-a "$(sha $SYS/modules/7.0.0-a/vmlinuz)" 4096 "$(sha $W/i0)" "$(wc -c < $W/i0)" \
    "panic=10 loglevel=4 glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU glassine.img=$I0" c1@1
R0=$(sha $BP/glassine/sets/$I0/set.rec)
printf 'format=1\nseq=1\ndefault=%s\ndefault_rec=%s\nprevious=\nprevious_rec=\ntrial=\ntrial_rec=\nrecovery=714c2000398993cc\nrecovery_rec=%s\nrequest=\nunmarked=0\nstarted=\nstarted_why=\ndeploys=0\n' \
    $I0 $R0 "$(printf r | sha256sum | cut -d' ' -f1)" > $W/r0
{ cat $W/r0; echo "check=$(sha $W/r0)"; } > $W/r1; { cat $W/r1; head -c $((16384 - $(wc -c < $W/r1))) /dev/zero | tr '\000' '\n'; } > $BP/glassine/loader.a
cp $BP/glassine/loader.a $BP/glassine/loader.b
mkdir -p $BP/glassine/recovery/714c2000398993cc; echo keep > $BP/glassine/recovery/714c2000398993cc/set.rec
ok "the installer's set checks by the loader's rules (the test's own fixture)" "$M set-ok $BP $I0 $R0 && [ \"\$($M in-use $BP | head -n 1)\" = 'a 1 1' ]"
boot $I0

ok "the initrd: microcode (by name), the initramfs, the board archive, the boot modules, each at a multiple of 4" "
    { cat $SYS/modules/7.0.0-a/microcode/amd-ucode.img; head -c 2 /dev/zero; cat $SYS/modules/7.0.0-a/microcode/intel-ucode.img; head -c 3 /dev/zero
      cat $SYS/boot/initramfs/c1@1.cpio.gz; head -c 3 /dev/zero; $M board-archive $W/board.conf; cat $W/m0; } | cmp -s - $W/i0"

# refusals
cp $K $W/k0
ok "install with --dtb: refused (a kernel set has no device tree)" "! $B install 7.1.0-b --dtb x@1 --initramfs c1@1 2>$W/err && grep -q 'no device tree' $W/err"
sed -i 's/^image=.*/image=Image.gz/' $SYS/modules/7.1.0-b/kernel.manifest
ok "a kernel that isn't an EFI stub (image=Image.gz): refused" "! $B install 7.1.0-b --initramfs c1@1 2>$W/err && grep -q 'starts an EFI stub' $W/err"
sed -i 's/^image=.*/image=vmlinuz/' $SYS/modules/7.1.0-b/kernel.manifest
cp $SYS/modules/7.1.0-b/vmlinuz $W/vb; cp $SYS/modules/7.2.0-c/vmlinuz $SYS/modules/7.1.0-b/vmlinuz
ok "a vmlinuz of another release: refused" "! $B install 7.1.0-b --initramfs c1@1 2>$W/err && grep -q 'is not kernel release 7.1.0-b' $W/err && [ -z \"\$(kv candidate)\" ]"
cp $W/vb $SYS/modules/7.1.0-b/vmlinuz
echo "panic=10 glassine.img=$I0" > $W/cmdline
ok "a boot whose command line has no identities: refused, the set not written" "! $B install 7.1.0-b --initramfs c1@1 2>$W/err && grep -q 'by their identities' $W/err && [ \$(ls $BP/glassine/sets | wc -l) = 1 ]"
boot $I0
sed -i 's/^CMDLINE=.*/CMDLINE="quiet glassine.img=1"/' $W/board.conf
ok "a base command line holding an own key: refused" "! $B install 7.1.0-b --initramfs c1@1 2>$W/err && grep -q 'glassine.img=, which is added' $W/err"
sed -i 's/^CMDLINE=.*/CMDLINE="panic=10 loglevel=4"/' $W/board.conf

# install: the installer's set seeded, the candidate's set written and named as the trial
cp $BP/glassine/loader.a $W/la0
ok "install: the candidate" "$B install 7.1.0-b --initramfs c1@1 >$W/out 2>$W/err && grep -q 'kernel 7.1.0-b is ready' $W/out && [ \"\$(kv candidate)\" = 7.1.0-b ] && [ \"\$(kv tries)\" = 1 ]"
C1=$(kv candidate_img)
ok "install: the installer's set recorded as the current one (seeded=1, current = its release)" "[ \"\$(kv current_img)\" = $I0 ] && [ \"\$(kv current)\" = 7.0.0-a ] && [ \"\$(gs_kv $BI/$I0.manifest seeded)\" = 1 ] && cmp -s $BI/$I0.img $W/i0"
ok "install: the set checks by the loader's rules, the loader record names it as the trial" "$M set-ok $BP $C1 \$(gs_kv $BI/$C1.manifest set_rec) && [ \"\$(rec trial)\" = $C1 ] && [ \"\$(rec trial_rec)\" = \"\$(gs_kv $BI/$C1.manifest set_rec)\" ] && [ -z \"\$(rec request)\" ]"
ok "install: the default set untouched, the recovery's directory untouched" "[ \"\$(rec default)\" = $I0 ] && $M set-ok $BP $I0 $R0 && [ -e $BP/glassine/recovery/714c2000398993cc/set.rec ]"
ok "install: the set's command line: the base, then both identities and its id" "[ \"\$(sed -n 's/^cmdline=//p' $BP/glassine/sets/$C1/set.rec)\" = \"panic=10 loglevel=4 glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU glassine.img=$C1\" ]"
ok "install: the initrd kept on the system partition as the image record (state/bootimg)" "cmp -s $BI/$C1.img $BP/glassine/sets/$C1/initrd && [ \"\$(gs_kv $BI/$C1.manifest kernel_sha256)\" = \"\$(sha $SYS/modules/7.1.0-b/vmlinuz)\" ]"
ok "install: no .new file left on the boot partition" "[ -z \"\$(find $BP -name '*.new')\" ]"
ok "status: state=candidate" "[ \"\$(st state)\" = candidate ]"
[ -z "${BP_EXPORT:-}" ] || cp -a $BP $BP_EXPORT/install   # for a check by the loader's own code

# reboot-test: the request last
ok "reboot-test: request=trial in the record, requested in state/kernel" "$B reboot-test 2>$W/err && [ \"\$(rec request)\" = trial ] && [ \"\$(kv requested)\" = $C1 ] && [ \"\$($M in-use $BP | head -n 1 | cut -d' ' -f3)\" = 1 ]"
# the loader takes the request (record.rs next), starts the trial set; the initramfs takes the try
$M next $BP request= started=$C1 started_why=request
boot $C1; gs_update $K tries=0 requested=; rm -f $W/run/glassine-bootimg.requested
mkdir -p $W/rundir; echo d1 > $W/rundir/booted
export GLASSINE_BI_RUN_DIR=$W/rundir
ok "promote on the trial boot: accepted, the record's default = the trial set, previous = the old default" "$B promote 2>$W/err && [ \"\$(kv current)\" = 7.1.0-b ] && [ \"\$(kv current_img)\" = $C1 ] && [ \"\$(rec default)\" = $C1 ] && [ \"\$(rec previous)\" = $I0 ] && [ -z \"\$(rec trial)\" ] && [ \"\$(rec default_rec)\" = \"\$(gs_kv $BI/$C1.manifest set_rec)\" ]"
ok "accept: both slots valid and alike but for seq (written twice), unknown keys kept" "[ \"\$($M in-use $BP | head -n 1 | cut -d' ' -f3)\" = 1 ] && [ \"\$(rec started)\" = $C1 ] && [ \"\$(rec recovery)\" = 714c2000398993cc ] && [ \"\$(sed '/^seq=/d;/^check=/d' $BP/glassine/loader.a | md5sum)\" = \"\$(sed '/^seq=/d;/^check=/d' $BP/glassine/loader.b | md5sum)\" ]"
ok "accept: both sets kept (default and previous), writing cleared" "[ \$(ls $BP/glassine/sets | wc -l) = 2 ] && [ -z \"\$(kv writing)\" ] && [ \"\$(st state)\" = none ]"
[ -z "${BP_EXPORT:-}" ] || cp -a $BP $BP_EXPORT/accept

# rollback: one write, the default and the previous set swapped
ok "rollback: the record's default = the previous set again" "$B rollback >$W/out 2>$W/err && [ \"\$(rec default)\" = $I0 ] && [ \"\$(rec previous)\" = $C1 ] && [ \"\$(kv current_img)\" = $I0 ] && [ \"\$(kv previous_img)\" = $C1 ]"
boot $I0

# cancel: the trial cleared, its set removed once neither slot names it
ok "install 7.2.0-c, then cancel: the trial cleared, its set removed" "$B install 7.2.0-c --initramfs c1@1 >/dev/null 2>&1 && C2=\$(kv candidate_img) && [ -d $BP/glassine/sets/\$C2 ] && $B cancel >/dev/null 2>&1 && [ -z \"\$(rec trial)\" ] && [ ! -e $BP/glassine/sets/\$C2 ] && [ \$(ls $BP/glassine/sets | wc -l) = 2 ]"

# a failed trial: no boot after the request
$B install 7.2.0-c --initramfs c1@1 >/dev/null 2>&1; C2=$(kv candidate_img)
$B reboot-test 2>/dev/null; rm -f $W/run/glassine-bootimg.requested
$M next $BP request= started=$C2 started_why=request   # the loader took it ...
ok "a requested trial that never reached the initramfs: failed (no-boot), the trial out of the record, its set removed" "$B promote 2>$W/err && [ \"\$(kv failed_img)\" = $C2 ] && [ -z \"\$(rec trial)\" ] && [ ! -e $BP/glassine/sets/$C2 ] && [ \"\$(rec default)\" = $I0 ]"
ok "retry of the failed one: its set written again and named as the trial" "$B retry >/dev/null 2>&1 && [ \"\$(rec trial)\" = $C2 ] && $M set-ok $BP $C2 \$(gs_kv $BI/$C2.manifest set_rec)"
$B cancel >/dev/null 2>&1

# cut and failed writes during install: no candidate, nothing the record names changed
cp $BP/glassine/loader.a $W/sa; cp $BP/glassine/loader.b $W/sb
export GLASSINE_BI_AFTER_SETFILE='case $1 in */initrd.new) printf X | dd of="$1" bs=1 seek=3 conv=notrunc 2>/dev/null ;; esac'
ok "install, the initrd doesn't read back (both tries): refused, no candidate, no set directory, no .new, the record names no trial" "! $B install 7.2.0-c --initramfs c1@1 >/dev/null 2>$W/err && grep -q 'initrd: the write or its read-back failed' $W/err && [ -z \"\$(kv candidate)\" ] && [ -z \"\$(rec trial)\" ] && [ \$(ls $BP/glassine/sets | wc -l) = 2 ] && [ -z \"\$(find $BP -name '*.new')\" ]"
unset GLASSINE_BI_AFTER_SETFILE
echo 2 > $W/cnt
export GLASSINE_BI_AFTER_SLOT='n=$(cat /w/cnt); echo $((n - 1)) > /w/cnt; [ "$n" -le 0 ] || truncate -s 100 "$1"'
ok "install, the first record write cut (both tries): refused, no candidate, the default set as it was" "! $B install 7.2.0-c --initramfs c1@1 >/dev/null 2>$W/err && grep -q 'loader record could not be written' $W/err && [ -z \"\$(kv candidate)\" ] && [ \"\$($M get $BP default)\" = $I0 ]"
echo 0 > $W/cnt
ok "the next install after the cut: written (the cut slot written over)" "$B install 7.2.0-c --initramfs c1@1 >/dev/null 2>&1 && [ \"\$(rec trial)\" = \"\$(kv candidate_img)\" ]"
C2=$(kv candidate_img)
# accept whose record write is cut both times: the record's default as it was, the candidate failed
$B reboot-test 2>/dev/null; rm -f $W/run/glassine-bootimg.requested; $M next $BP request= started=$C2 started_why=request
boot $C2; gs_update $K tries=0 requested=
# the writes: settle (2) ok, the default write cut twice
echo 2 > $W/cnt
ok "accept, the record write cut both times: not accepted, the default set as it was, writing cleared, failed" "! $B promote 2>$W/err; [ \"\$($M get $BP default)\" = $I0 ] && [ -z \"\$(kv writing)\" ] && [ \"\$(kv failed_img)\" = $C2 ] && [ \"\$(kv current_img)\" = $I0 ]"
echo 0 > $W/cnt; unset GLASSINE_BI_AFTER_SLOT

# a cut after the record write (power lost before the state completed): the
# finishing boot completes it
boot $I0
$B retry >/dev/null 2>&1; $B reboot-test 2>/dev/null; rm -f $W/run/glassine-bootimg.requested; $M next $BP request= started=$C2 started_why=request
boot $C2; gs_update $K tries=0 requested=
export GLASSINE_BI_AFTER_SLOT='grep -q "^default=$(cat /w/cid)$" "$1" && kill -9 $PPID $$'
echo $C2 > $W/cid
sh -c "$B promote" 2>/dev/null
unset GLASSINE_BI_AFTER_SLOT
ok "accept cut right after the record named the set: writing stays set" "[ \"\$(kv writing)\" = $C2 ] && [ \"\$(kv writing_op)\" = accept ]"
rm -f $W/run/glassine-bootimg.started
ok "status on that boot: state=finishing, the default slot not bad" "[ \"\$(st state)\" = finishing ] && ! $B status | grep -q default_slot="
ok "the finishing boot's promote: completed, the record's default the new set" "$B promote 2>$W/err && [ -z \"\$(kv writing)\" ] && [ \"\$(kv current_img)\" = $C2 ] && [ \"\$(rec default)\" = $C2 ] && [ \"\$($M in-use $BP | head -n 1 | cut -d' ' -f3)\" = 1 ]"
ok "after it: three sets at most (default, previous; the old previous removed)" "[ \$(ls $BP/glassine/sets | wc -l) = 2 ] && [ -d $BP/glassine/sets/$C2 ] && [ -d $BP/glassine/sets/\$(rec previous) ]"

# a leftover from a cut set write is removed by the next writer
mkdir -p $BP/glassine/sets/00000000deadbeef; echo x > $BP/glassine/sets/00000000deadbeef/vmlinuz.new; echo x > $BP/glassine/splash.gspl.new
boot $C2
ok "a set directory no slot names and .new files: removed by the next install" "$B install 7.1.0-b --initramfs c1@1 >/dev/null 2>&1; [ ! -e $BP/glassine/sets/00000000deadbeef ] && [ ! -e $BP/glassine/splash.gspl.new ] && [ -e $BP/glassine/recovery/714c2000398993cc/set.rec ]"
$B cancel >/dev/null 2>&1

# no loader record: refused, nothing invented
mv $BP/glassine/loader.a $W/keep.a; mv $BP/glassine/loader.b $W/keep.b
ok "no valid loader record: install refused, nothing written to the boot partition" "! $B install 7.1.0-b --initramfs c1@1 >/dev/null 2>$W/err && grep -q 'no slot of the loader record is valid' $W/err && [ ! -e $BP/glassine/loader.a ]"
mv $W/keep.a $BP/glassine/loader.a; mv $W/keep.b $BP/glassine/loader.b

# the boot partition's device: the partition named glassine-boot on the system partition's disk
unset GLASSINE_BI_BOOTPART_DIR
. /p/lib/glassine-kernel.sh 2>/dev/null
SB=$W/sysblock; mkdir -p $SB/devices/vda/vda1 $SB/devices/vda/vda2 $SB/devices/vdb/vdb1
printf 'DEVNAME=vda1\nPARTN=1\nPARTNAME=glassine-boot\n' > $SB/devices/vda/vda1/uevent
printf "DEVNAME=vda2\nPARTN=2\nPARTNAME=glassine-system\nPARTUUID=$SU\n" > $SB/devices/vda/vda2/uevent
printf 'DEVNAME=vdb1\nPARTN=1\nPARTNAME=glassine-boot\n' > $SB/devices/vdb/vdb1/uevent
for p in vda/vda1 vda/vda2 vdb/vdb1; do ln -s devices/$p $SB/${p#*/}; done
CMDLINE=$W/cmdline GLASSINE_BI_SYSBLOCK=$SB
ok "the boot partition: glassine-boot on the system partition's disk, not another disk's" "[ \"\$(gk_ue_dev)\" = /dev/vda1 ]"
printf 'DEVNAME=vda3\nPARTN=3\nPARTNAME=glassine-boot\n' > $W/u3; mkdir -p $SB/devices/vda/vda3; cp $W/u3 $SB/devices/vda/vda3/uevent
ok "two partitions named glassine-boot on that disk: none" "! gk_ue_dev >/dev/null"

# --- 3. a real FAT file system (privileged) ----------------------------------------
if [ "${BP_PRIV:-}" = 1 ]; then
    head -c 67108864 /dev/zero > $W/fat.img; mkfs.vfat -F 32 -n GLASSINE $W/fat.img >/dev/null 2>&1
    LD=$(losetup -f); losetup $LD $W/fat.img
    mkdir -p $W/fm; mount -t vfat $LD $W/fm; mkdir -p $W/fm/glassine
    cp -a $BP/glassine/. $W/fm/glassine/; umount $W/fm
    export GLASSINE_BI_BOOTPART_DEV=$LD GLASSINE_BI_RUN_DIR=$W/rundir
    boot $(kv current_img)
    ok "FAT: install mounts the boot partition, writes the set, unmounts it" "$B install 7.1.0-b --initramfs c1@1 >/dev/null 2>$W/err && ! grep -q \"$W/rundir/boot-partition\" /proc/mounts"
    C3=$(kv candidate_img)
    mount -t vfat -o ro $LD $W/fm
    ok "FAT: the names in lower case, long (16 hex digits), read back after a remount" "[ -d $W/fm/glassine/sets/$C3 ] && [ \"\$(ls $W/fm/glassine/sets/$C3 | tr '\n' ' ')\" = 'initrd set.rec vmlinuz ' ]"
    ok "FAT: the set and the record by the loader's rules" "$M set-ok $W/fm $C3 \$(gs_kv $BI/$C3.manifest set_rec) && [ \"\$($M get $W/fm trial)\" = $C3 ] && [ \$(wc -c < $W/fm/glassine/loader.a) = 16384 ] && [ \$(wc -c < $W/fm/glassine/loader.b) = 16384 ]"
    umount $W/fm
    ok "FAT: status with nothing being written mounts nothing" "$B status >/dev/null && ! grep -q boot-partition /proc/mounts"
    $B cancel >/dev/null 2>&1
    # too little room: refused, nothing removed that a record names
    head -c 8388608 /dev/zero > $W/small.img; mkfs.vfat -n GLASSINE $W/small.img >/dev/null 2>&1
    LS=$(losetup -f); losetup $LS $W/small.img
    mount -t vfat $LS $W/fm; mkdir -p $W/fm/glassine; cp $BP/glassine/loader.a $BP/glassine/loader.b $W/fm/glassine/
    head -c 6000000 /dev/urandom > $W/fm/filler; umount $W/fm
    head -c 3000000 /dev/urandom >> $SYS/modules/7.3.0-d/vmlinuz
    export GLASSINE_BI_BOOTPART_DEV=$LS
    ok "FAT: too little free space: refused, saying how much is needed and free, no candidate" "! $B install 7.3.0-d --initramfs c1@1 >/dev/null 2>$W/err && grep -q 'KiB free, set .* needs .* KiB' $W/err && [ -z \"\$(kv candidate)\" ]"
    losetup -d $LS; losetup -d $LD
fi

echo "$fails failed"
[ $fails = 0 ]
