#!/bin/sh
# Host test of the boot partition's raw form (docs/boot-partition.md, "The raw form";
# docs/handback.md, "The loader region"; specs/012), in Alpine (busybox as on the
# device): glassine-boot-raw (the table, the regions) and the raw backend of
# lib/glassine-bootpart.sh (the loader record by slots, through glassine-loader-mark
# and glassine-deploy-accept with BOOT_FORM=raw). What they write is read back by
# raw_model.py, a port of the loader's reader (GlassineOS/loader core/src/raw.rs,
# gspl.rs, record.rs), and compared with the loader's golden bytes (golden/). A cut
# at every byte of every write sequence is judged by replaying the writes the
# library made (GLASSINE_BI_RAW_TRACE); real cuts (GLASSINE_BI_RAW_CUT: the process
# killed inside a write) are checked against the replay. Part 1: the table. Part 2:
# the regions. Part 3: the loader record. Part 4: the cuts. Part 5 (privileged): a
# loop device.
# shellcheck disable=SC2089,SC2090,SC2034  # the hooks are code, eval'd by the library
set -u
D=/p/test/bootraw
M="python3 $D/raw_model.py"
R="sh /p/sbin/glassine-boot-raw"
GB=/p/test/bootpart/golden
W=/w; mkdir -p $W/tmp $W/run $W/golden
# the loader's golden bytes, kept as hex text
G=$W/golden
for f in table-16mib loader-header-5000; do
    python3 -c 'import sys; sys.stdout.buffer.write(bytes.fromhex(open(sys.argv[1]).read()))' $D/golden/$f.hex > $G/$f.bin
done
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; [ ! -s $W/err ] || sed "s/^/     err: /" $W/err | tail -n 3; fails=$((fails + 1)); fi; : > $W/err; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
export GLASSINE_BI_TEST=1 GLASSINE_BI_LIB=/p/lib GLASSINE_BI_TMP=$W/run GLASSINE_BI_BOARD=$W/none
MiB=1048576
fresh() { rm -f "$1"; truncate -s "${2:-16777216}" "$1"; }   # fresh IMG [SIZE]: all zeros

# --- 1. the region table --------------------------------------------------------------
I=$W/p.img; fresh $I
ok "init on a partition never written: 0" "$R init $I 2>$W/err"
ok "the primary table: the loader's golden bytes (build_table, layout_16mib)" "head -c 4096 $I | cmp -s - $G/table-16mib.bin"
ok "the backup in the last 4096 bytes: the same bytes" "tail -c 4096 $I | cmp -s - $G/table-16mib.bin"
ok "nothing else written: every other byte zero" "[ \"\$(head -c \$((16 * MiB - 4096)) $I | tail -c +4097 | tr -d '\\000' | wc -c)\" = 0 ]"
ok "the loader's reader: the primary, six regions, as in 'Sizes'" "[ \"\$($M table $I | tr '\n' ' ')\" = 'primary record 65536 32768 0 probe 131072 65536 0 loader 1048576 3145728 0 splash-default 4194304 3145728 0 splash 7340032 3145728 0 override 10485760 3145728 0 ' ]"
ok "table: the same regions, the primary" "[ \"\$($R table $I | tr '\n' ' ')\" = 'copy=primary region record 65536 32768 0 region probe 131072 65536 0 region loader 1048576 3145728 0 region splash-default 4194304 3145728 0 region splash 7340032 3145728 0 region override 10485760 3145728 0 ' ]"
ok "no record, no loader, no splash after init (empty regions)" "! $M item $I record && ! $M item $I loader && ! $M item $I splash && ! $R read $I loader >/dev/null 2>&1"
cp $I $W/t0
ok "init again: refused (3), nothing written" "$R init $I 2>$W/err; [ \$? = 3 ] && cmp -s $I $W/t0 && grep -q 'holds a valid region table (the primary copy)' $W/err"
printf X | dd of=$I bs=1 seek=100 conv=notrunc 2>/dev/null
ok "the primary damaged: the loader's reader and ours take the backup" "[ \"\$($M table $I | head -n 1)\" = backup ] && [ \"\$($R table $I | head -n 1)\" = copy=backup ]"
ok "init with only the backup valid: refused (3)" "$R init $I 2>$W/err; [ \$? = 3 ] && grep -q 'the backup copy' $W/err"
printf X | dd of=$I bs=1 seek=$((16 * MiB - 4096 + 70)) conv=notrunc 2>/dev/null
ok "both copies damaged: no table (3), for the loader too" "! $M table $I && { $R table $I >/dev/null 2>$W/err; [ \$? = 3 ]; } && grep -q 'holds nothing' $W/err"
cp $W/t0 $I
# a table damaged at any byte is refused: every byte flipped, by the loader's reader;
# ours at a sample (every 97th byte, the fields of the header and the first entry)
python3 - $I > $W/flip <<'EOF'
import sys
sys.path.insert(0, '/p/test/bootraw'); import raw_model as m
img = bytearray(open(sys.argv[1], 'rb').read()); bad = 0
for i in range(4096):
    img[i] ^= 0x41
    t = m.table(img)
    if t is None or t[0] != 'backup': bad += 1
    img[i] ^= 0x41
print(bad)
EOF
ok "the loader's reader: the primary damaged at any of its 4096 bytes is refused, the backup used" "[ \"\$(cat $W/flip)\" = 0 ]"
flip_ok=1
for at in 0 7 8 11 12 15 16 23 24 63 64 95 96 103 104 111 112 115 116 119 120 127 $(seq 128 97 4091) 4092 4095; do
    cp $W/t0 $W/tf
    b=$(od -An -tu1 -j $at -N1 $W/tf | tr -d ' ')
    printf "\\$(printf %03o $((b ^ 0x41)))" | dd of=$W/tf bs=1 seek=$at conv=notrunc 2>/dev/null
    [ "$($R table $W/tf 2>/dev/null | head -n 1)" = copy=backup ] || { flip_ok=0; echo "  byte $at: not refused"; }
done
ok "ours: the primary damaged at any sampled byte is refused, the backup used" "[ $flip_ok = 1 ]"
fresh $W/small 8388608
ok "a partition below 16 MiB: refused (3), nothing written" "$R init $W/small 2>$W/err; [ \$? = 3 ] && [ \"\$(tr -d '\\000' < $W/small | wc -c)\" = 0 ]"
fresh $W/odd $((16 * MiB + 512))
ok "a size that isn't a multiple of 4096: refused (3)" "$R init $W/odd 2>/dev/null; [ \$? = 3 ]"
fresh $W/big $((32 * MiB))
ok "32 MiB: the same layout, the table made for 32 MiB, the backup at its end" "$R init $W/big 2>/dev/null && [ \"\$($M table $W/big | head -n 2 | tr '\n' ' ')\" = 'primary record 65536 32768 0 ' ] && head -c 4096 $W/big > $W/big.t && tail -c 4096 $W/big | cmp -s - $W/big.t"
fresh $W/fat
{ head -c 82 /dev/zero; printf 'FAT32   '; head -c 420 /dev/zero; printf '\125\252'; } | dd of=$W/fat conv=notrunc 2>/dev/null
ok "a FAT boot sector: refused (3) without --force" "$R init $W/fat 2>$W/err; [ \$? = 3 ] && grep -q 'FAT boot sector' $W/err"
ok "a FAT boot sector with --force: the raw form" "$R init --force $W/fat 2>/dev/null && [ \"\$($M table $W/fat | head -n 1)\" = primary ]"
# a table that doesn't read back: the backup copy's bytes flipped after its write
export GLASSINE_BI_AFTER_PUT='[ "$2" != 16773120 ] || printf Z | dd of="$1" bs=1 seek=16773220 conv=notrunc 2>/dev/null; :'
fresh $W/rb
ok "init whose backup doesn't read back: 1, said, the primary not written (no table for the loader)" "$R init $W/rb 2>$W/err; [ \$? = 1 ] && grep -q 'backup table' $W/err && [ \"\$(head -c 4096 $W/rb | tr -d '\\000' | wc -c)\" = 0 ] && ! $M table $W/rb"
cp $W/t0 $W/rb2; cp $W/rb2 $W/rb3
ok "init --force whose backup doesn't read back: 1, the old primary as it was, the loader reads the old table" "$R init --force $W/rb2 2>/dev/null; [ \$? = 1 ] && cmp -n 4096 $W/rb2 $W/rb3 && [ \"\$($M table $W/rb2 | head -n 1)\" = primary ]"
export GLASSINE_BI_AFTER_PUT='[ "$2" != 0 ] || printf Z | dd of="$1" bs=1 seek=100 conv=notrunc 2>/dev/null; :'
fresh $W/rb
ok "init whose primary doesn't read back: 1, said, the backup in use for the loader" "$R init $W/rb 2>$W/err; [ \$? = 1 ] && grep -q 'primary table' $W/err && [ \"\$($M table $W/rb | head -n 1)\" = backup ]"
unset GLASSINE_BI_AFTER_PUT
ok "usage: no DEV, an unknown command (2)" "$R init 2>/dev/null; [ \$? = 2 ] && { $R frob 2>/dev/null; [ \$? = 2 ]; }"

# --- 2. the regions ------------------------------------------------------------------
python3 -c "import sys; open(sys.argv[1], 'wb').write(bytes((i * 7 + 3) % 256 for i in range(5000)))" $W/l5000
ok "loader: written (0)" "$R loader $I $W/l5000 2>$W/err"
ok "loader: the header is the loader's golden bytes (loader_header)" "dd if=$I bs=4096 skip=256 count=1 2>/dev/null | cmp -s - $G/loader-header-5000.bin"
ok "loader: the image after its header; the parent's checks pass (check_header, the image's CRC)" "$M item $I loader | cmp -s - $W/l5000"
ok "read loader: the image" "$R read $I loader | cmp -s - $W/l5000"
head -c 20000 /dev/urandom > $W/l20000
ok "a larger loader over it: the loader reads the new one" "$R loader $I $W/l20000 2>/dev/null && $M item $I loader | cmp -s - $W/l20000"
ok "a smaller one again: the new one (the bytes after it ignored)" "$R loader $I $W/l5000 2>/dev/null && $M item $I loader | cmp -s - $W/l5000"
cp $I $W/i1
head -c 3141633 /dev/zero > $W/lbig; : > $W/lempty
ok "a loader of 3141633 bytes, an empty one: refused (3), nothing written" "$R loader $I $W/lbig 2>/dev/null; [ \$? = 3 ] && { $R loader $I $W/lempty 2>/dev/null; [ \$? = 3 ]; } && cmp -s $I $W/i1"
head -c 3141632 /dev/urandom > $W/lmax
ok "a loader of 3141632 bytes (the largest): written, read back" "$R loader $I $W/lmax 2>/dev/null && $M item $I loader | cmp -s - $W/lmax"
$R loader $I $W/l5000 2>/dev/null
cp $I $W/i1
export GLASSINE_BI_AFTER_PUT='[ "$2" != 1048576 ] || [ "$3" = 4096 -a "$(od -An -tu1 -N1 -j 1048576 "$1" | tr -d " ")" = 0 ] || printf Z | dd of="$1" bs=1 seek=$((1048576 + 4200)) conv=notrunc 2>/dev/null'
ok "a loader whose bytes don't read back (a flipped byte): 1, no loader for the parent (its CRC fails)" "$R loader $I $W/l20000 2>$W/err; [ \$? = 1 ] && grep -q \"doesn't read back\" $W/err && ! $M item $I loader"
unset GLASSINE_BI_AFTER_PUT
cp $W/i1 $I
# the splash store
$M splash $W/s1.gspl 120 80; $M splash $W/s2.gspl 64 40; $M splash $W/leave.gspl 0 0 1
for r in splash-default splash override; do
    ok "$r: a format-2 image written, the loader's reader takes it" "$R $r $I $W/s1.gspl 2>/dev/null && $M item $I $r | cmp -s - $W/s1.gspl && $R read $I $r | cmp -s - $W/s1.gspl"
done
ok "a smaller image over it: the new one" "$R splash $I $W/s2.gspl 2>/dev/null && $M item $I splash | cmp -s - $W/s2.gspl"
ok "leave the screen: refused (3) for splash, written for the override" "$R splash $I $W/leave.gspl 2>/dev/null; [ \$? = 3 ] && $R override $I $W/leave.gspl 2>/dev/null && $M item $I override | cmp -s - $W/leave.gspl"
cp $I $W/i2
python3 - $W/s1.gspl $W <<'EOF'
import struct, sys, zlib
b = bytearray(open(sys.argv[1], 'rb').read()); d = sys.argv[2]
def fix(x):
    struct.pack_into('<I', x, 52, zlib.crc32(bytes(x[0:52])) & 0xffffffff); return x
v1 = bytearray(b); struct.pack_into('<H', v1, 8, 1); open(d + '/v1.gspl', 'wb').write(fix(v1))
pc = bytearray(b); pc[100] ^= 1; open(d + '/pcrc.gspl', 'wb').write(pc)
hc = bytearray(b); hc[20] ^= 1; open(d + '/hcrc.gspl', 'wb').write(hc)
ln = bytearray(b) + b'x'; open(d + '/len.gspl', 'wb').write(ln)
lay = bytearray(b); struct.pack_into('<I', lay, 28, 9); open(d + '/lay.gspl', 'wb').write(fix(lay))
EOF
bad_ok=1
for f in v1 pcrc hcrc len lay; do
    $R splash $I $W/$f.gspl 2>/dev/null; [ $? = 3 ] || { bad_ok=0; echo "  $f.gspl not refused"; }
done
ok "format 1, a payload or header CRC that fails, a wrong length, an unknown layout: refused (3), nothing written" "[ $bad_ok = 1 ] && cmp -s $I $W/i2"
$M splash $W/huge.gspl 2048 1536
ok "an image larger than its region (3 MiB): refused (3) with a message, nothing written" "$R splash $I $W/huge.gspl 2>$W/err; [ \$? = 3 ] && grep -q 'the region splash holds 3145728' $W/err && cmp -s $I $W/i2"
$M splash $W/max.gspl 2048 1535
ok "an image that fills its region but 64 KiB (2048x1535 grey8): written, read back" "$R splash-default $I $W/max.gspl 2>/dev/null && $M item $I splash-default | cmp -s - $W/max.gspl"
$R splash-default $I $W/s1.gspl 2>/dev/null; $R override $I $W/s2.gspl 2>/dev/null
ok "clear override: no override for the loader, the other images as they were" "$R clear $I override 2>/dev/null && ! $M item $I override && $M item $I splash | cmp -s - $W/s2.gspl && $M item $I splash-default | cmp -s - $W/s1.gspl"
ok "clear record: refused (3); the record is written by slots" "$R clear $I record 2>/dev/null; [ \$? = 3 ]"
fresh $W/none
ok "a region write on a partition with no table: refused (3)" "$R splash $W/none $W/s1.gspl 2>/dev/null; [ \$? = 3 ] && [ \"\$(tr -d '\\000' < $W/none | wc -c)\" = 0 ]"

# --- 3. the loader record ------------------------------------------------------------
# glassine-loader-mark on a raw board (BOOT_FORM=raw, no HANDOFF): the boot partition
# a 16 MiB file; the installer's golden slots seeded, then the loader's own count
MI=$W/mark.img MR=$W/markrun MS=$W/marksys MW=$W/markbin
mkdir -p $MR $MS/state $MW $W/markhealth
RUNSET=1abb421e678cbd3b
printf 'ROOT_LAYOUT=deployments\nBOOT_FORM=raw\nHANDOFF=\nCMDLINE="panic=10 loglevel=4"\n' > $MW/board.raw
printf 'ROOT_LAYOUT=deployments\nBOOT_FORM=raw\nHANDOFF=uefi\n' > $MW/board.rawuefi
printf 'ROOT_LAYOUT=deployments\nBOOT_FORM=fat32\n' > $MW/board.bogus
printf 'ROOT_LAYOUT=deployments\nHANDOFF=\n' > $MW/board.none
echo "BOOT_IMAGE=vmlinuz glassine.img=$RUNSET" > $MW/cmdline
printf '#!/bin/sh\ncase $1 in\nstatus) printf "v\\tx\\n%%s\\n" "$(cat %s/status)" ;;\nesac\n' $MW > $MW/deploy; chmod +x $MW/deploy
printf '#!/bin/sh\nexit 0\n' > $MW/rc-status; chmod +x $MW/rc-status
printf 'type=status\tcandidate=\ttries=0\n' > $MW/status
printf 'RUN_DIR=%s\nACCEPT_AFTER=0\nACCEPT_HEALTH_DIR=%s\n' $MR $W/markhealth > $MW/conf
echo '130.0 1.0' > $MW/uptime
menv() { env PATH=$MW:$PATH GLASSINE_DEPLOY_CONF=$MW/conf GLASSINE_DEPLOY=$MW/deploy GLASSINE_ACCEPT_UPTIME=$MW/uptime \
    GLASSINE_LOADER_MARK=/p/sbin/glassine-loader-mark GLASSINE_BI_SYSTEM=$MS GLASSINE_BI_CMDLINE=$MW/cmdline \
    GLASSINE_BI_BOARD=${MBOARD:-$MW/board.raw} GLASSINE_BI_RUN_DIR=$MR ${MDEV-GLASSINE_BI_BOOTPART_DEV=$MI} \
    ${MSB:+GLASSINE_BI_SYSBLOCK=$MSB GLASSINE_BI_DEVDIR=$W/dev} "$@"; }
mark() { menv sh /p/sbin/glassine-loader-mark "$@"; }
mstart() {  # a fresh start: the table, the golden slots, the loader's count (unmarked 2)
    fresh $MI; $R init $MI 2>/dev/null
    $M seed $MI $GB/loader.a $GB/loader.b
    $M next $MI unmarked=2 started=$RUNSET started_why=default zz_unknown=keep "$@"
    rm -f $MR/loader-marked $MR/health-failed $MR/kernel-boot $MR/deploy-once $MR/limit-start; echo d1 > $MR/booted
    cp $MI $W/m0
}
rec() { $M item $MI record | sed -n "s/^$1=//p"; }
slot() { $M item $MI record | head -n 1; }
mstart
ok "the golden slots and the loader's count: slot b in use, seq 2, both valid" "[ \"\$(slot)\" = 'b 2 1' ] && [ \"\$(rec unmarked)\" = 2 ]"
ok "read record: the record in use, as the loader reads it (and its check line)" "$M item $MI record | tail -n +2 > $W/rr.model && $R read $MI record | sed '\$d' | cmp -s - $W/rr.model"
ok "has-record on a raw board: 0; BOOT_FORM empty with no HANDOFF: 3" "mark has-record && MBOARD=$MW/board.none mark has-record; [ \$? = 3 ]"
ok "BOOT_FORM=raw with HANDOFF=uefi, an unknown BOOT_FORM: 1, said, nothing written" "MBOARD=$MW/board.rawuefi mark healthy 2>$W/err; [ \$? = 1 ] && grep -q 'FAT' $W/err && { MBOARD=$MW/board.bogus mark healthy 2>/dev/null; [ \$? = 1 ]; } && cmp -s $MI $W/m0"
ok "healthy: the loader reads unmarked=0 in slot a, seq 3, every other key kept" "mark healthy 2>$W/err && [ \"\$(slot)\" = 'a 3 1' ] && [ \"\$(rec unmarked)\" = 0 ] && [ \"\$(rec zz_unknown)\" = keep ] && [ \"\$(rec default)\" = $RUNSET ] && [ -e $MR/loader-marked ]"
ok "healthy: only the other slot written (slot b and every other byte as they were)" "python3 -c \"
import sys; a=open('$MI','rb').read(); b=open('$W/m0','rb').read()
d=[i for i in range(len(a)) if a[i]!=b[i]]; sys.exit(0 if d and min(d)>=65536 and max(d)<65536+16384 else 1)\""
ok "healthy again: unmarked is 0 already, nothing written" "cp $MI $W/m1 && mark healthy 2>/dev/null && cmp -s $MI $W/m1"
mstart
rm -f $MR/loader-marked
ok "shutdown: one off the count (2 -> 1), the loader reads it" "mark shutdown 2>/dev/null && [ \"\$(rec unmarked)\" = 1 ] && [ \"\$(slot)\" = 'a 3 1' ]"
mstart drew=1 display_failed=2
ok "display-retry: display_failed and drew cleared, unmarked as it was" "mark display-retry 2>$W/err && [ -z \"\$(rec display_failed)\" ] && [ -z \"\$(rec drew)\" ] && [ \"\$(rec unmarked)\" = 2 ] && grep -q 'display_failed=2 cleared' $W/err"
# the Note Air's record under its parent: no default (the baseline), the loader's
# count with started empty (core/src/plan.rs handback: started = the default's id)
mstart default= default_rec= previous= previous_rec= recovery= recovery_rec= started= started_why=default
ok "under a parent: healthy on a baseline start: unmarked=0" "mark healthy 2>/dev/null && [ \"\$(rec unmarked)\" = 0 ]"
mstart default= default_rec= previous= previous_rec= recovery= recovery_rec= started= started_why=default
echo "BOOT_IMAGE=vmlinuz glassine.img=feedfacefeedface" > $MW/cmdline
ok "under a parent: shutdown on a baseline start (an image id neither slot names): one off (2 -> 1)" "mark shutdown 2>/dev/null && [ \"\$(rec unmarked)\" = 1 ]"
mstart default= default_rec= previous= previous_rec= recovery= recovery_rec= started= started_why=default
echo "BOOT_IMAGE=vmlinuz glassine.img=$RUNSET" > $MW/cmdline
ok "under a parent: a baseline start, but this boot runs the set the other slot names: nothing written" "mark shutdown 2>/dev/null && cmp -s $MI $W/m0"
mstart default= default_rec= previous= previous_rec= recovery= recovery_rec= started= started_why=default
echo "BOOT_IMAGE=vmlinuz" > $MW/cmdline
ok "under a parent: shutdown on a baseline start with no glassine.img=: one off" "mark shutdown 2>/dev/null && [ \"\$(rec unmarked)\" = 1 ]"
echo "BOOT_IMAGE=vmlinuz glassine.img=$RUNSET" > $MW/cmdline
mstart default= default_rec= previous= previous_rec= recovery= recovery_rec= started= started_why=default trial=abcdefabcdefabcd
echo "BOOT_IMAGE=vmlinuz glassine.img=abcdefabcdefabcd" > $MW/cmdline
ok "under a parent: a baseline start, but this boot runs the record's trial set: nothing written" "mark shutdown 2>/dev/null && cmp -s $MI $W/m0"
echo "BOOT_IMAGE=vmlinuz glassine.img=$RUNSET" > $MW/cmdline
mstart default= default_rec= started= started_why=request
ok "under a parent: started empty but not by default (a request): nothing written" "mark shutdown 2>/dev/null && cmp -s $MI $W/m0"
mstart
ok "glassine-deploy-accept on a raw board: the healthy mark written" "menv sh /p/sbin/glassine-deploy-accept > $W/out 2>&1 && [ \"\$(rec unmarked)\" = 0 ] && grep -q 'healthy mark written (unmarked 2 -> 0)' $W/out"
# only slot a valid, slot b never written (zeros): the write goes to b
fresh $MI; $R init $MI 2>/dev/null; $M seed $MI $GB/loader.a -
python3 - $MI <<'EOF'
import sys
sys.path.insert(0, '/p/test/bootraw'); import raw_model as m
m.main(['next', sys.argv[1], 'unmarked=2'])
EOF
ok "slot b zeros (never written): not valid, the loader's write went to it" "[ \"\$(slot)\" = 'b 2 1' ]"
# slot a with unmarked=2 (the golden record changed), slot b zeros
fresh $MI; $R init $MI 2>/dev/null
python3 - $MI $GB/loader.a <<'EOF'
import sys, struct
sys.path.insert(0, '/p/test/bootraw'); import raw_model as m, loader_model as lm
img = open(sys.argv[1], 'rb').read(); off, _ = m.region(img, 'record')
rec = lm.read_slot(open(sys.argv[2], 'rb').read())[1]
rec = [(k, '2' if k == 'unmarked' else v) for k, v in rec]
b = lm.text(rec).encode(); b += b'\n' * (16384 - len(b))
with open(sys.argv[1], 'r+b') as f: f.seek(off); f.write(b)
EOF
cp $MI $W/m0
ok "only slot a valid, slot b zeros: healthy writes slot b (seq 2), the loader reads it, both valid" "mark healthy 2>/dev/null && [ \"\$(slot)\" = 'b 2 1' ] && [ \"\$(rec unmarked)\" = 0 ]"
cp $W/m0 $MI; printf 'format=1\nseq=1\n' | dd of=$MI bs=1 seek=$((65536 + 16384)) conv=notrunc 2>/dev/null
ok "slot b cut over zeros (a record's start, then zeros): not valid, written over" "mark healthy 2>/dev/null && [ \"\$(slot)\" = 'b 2 1' ] && [ \"\$(rec unmarked)\" = 0 ]"
cp $W/m0 $MI; printf '\000' | dd of=$MI bs=1 seek=$((65536 + 300)) conv=notrunc 2>/dev/null; cp $MI $W/m0n
ok "the only slot that may be valid holds a NUL byte: refused, nothing written" "! mark healthy 2>/dev/null && cmp -s $MI $W/m0n"
fresh $MI; cp $MI $W/m0
ok "a partition never written (no table): healthy 1, said, nothing written" "! mark healthy 2>$W/err && grep -q 'holds nothing' $W/err && cmp -s $MI $W/m0"
$R init $MI 2>/dev/null; cp $MI $W/m0
ok "a table and an empty record region: healthy 1, no record made" "! mark healthy 2>$W/err && grep -q 'no slot of the loader record is valid' $W/err && cmp -s $MI $W/m0"
ok "has-record does not need the partition (board key only)" "MDEV='' GLASSINE_BI_BOOTPART_DEV= mark has-record"
mstart
export GLASSINE_BI_AFTER_PUT='[ "$2" = 65536 ] && printf Z | dd of="$1" bs=1 seek=65600 conv=notrunc 2>/dev/null; :'
ok "the mark's slot doesn't read back (a flipped byte, both tries): 1, the loader reads the old count" "! mark healthy 2>$W/err && grep -q 'healthy mark not written' $W/err && [ \"\$(rec unmarked)\" = 2 ] && [ ! -e $MR/loader-marked ]"
unset GLASSINE_BI_AFTER_PUT
mstart
echo 1 > $W/cnt
export GLASSINE_BI_AFTER_PUT='n=$(cat /w/cnt); echo $((n - 1)) > /w/cnt; [ "$n" -le 0 ] || printf Z | dd of="$1" bs=1 seek=65600 conv=notrunc 2>/dev/null; :'
ok "the mark's slot doesn't read back once: the retry writes it" "mark healthy 2>/dev/null && [ \"\$(rec unmarked)\" = 0 ]"
unset GLASSINE_BI_AFTER_PUT
mstart
{ flock 8; LOCK_WAIT=0 mark healthy 2>$W/err; lr=$?; flock -u 8; } 8<$MI
ok "the device locked by another writer (glassine-boot-raw): 1 after waiting, nothing written" "[ $lr = 1 ] && grep -q 'locked by another writer' $W/err && cmp -s $MI $W/m0"
# found by its GPT name, on a device with one disk (no glassine.system= on the command line)
mkdir -p $W/dev $W/sb/devices/xd/xd1 $W/sb/devices/xd/xd2
mstart; cp $MI $W/dev/xd1
printf 'DEVNAME=xd1\nPARTN=1\nPARTNAME=glassine-boot\n' > $W/sb/devices/xd/xd1/uevent
printf 'DEVNAME=xd2\nPARTN=2\nPARTNAME=userdata\n' > $W/sb/devices/xd/xd2/uevent
ln -sf devices/xd/xd1 $W/sb/xd1; ln -sf devices/xd/xd2 $W/sb/xd2
ok "found by GPT name (the one partition named glassine-boot): the mark written there" "MDEV='' MSB=$W/sb mark healthy 2>/dev/null && [ \"\$($M item $W/dev/xd1 record | sed -n 's/^unmarked=//p')\" = 0 ]"
ok "find: the device of the partition named glassine-boot" "[ \"\$(GLASSINE_BI_SYSBLOCK=$W/sb GLASSINE_BI_DEVDIR=$W/dev $R find)\" = $W/dev/xd1 ]"
printf 'DEVNAME=xd2\nPARTN=2\nPARTNAME=glassine-boot\n' > $W/sb/devices/xd/xd2/uevent
ok "two partitions named glassine-boot: not found, nothing written" "cp $W/dev/xd1 $W/x1 && ! MDEV='' MSB=$W/sb mark healthy 2>$W/err && grep -q '2 partitions named glassine-boot' $W/err && cmp -s $W/dev/xd1 $W/x1 && ! GLASSINE_BI_SYSBLOCK=$W/sb GLASSINE_BI_DEVDIR=$W/dev $R find 2>/dev/null"

# --- 4. cuts at every byte of every write ------------------------------------------------
# replay IMG0 NAME CMD...: CMD run once with the trace on, over a copy of IMG0 (as $T);
# every cut of its writes judged by the loader's reader (old, none or new)
T=$W/cut.img
replay() {
    _i0=$1 _n=$2; shift 2
    rm -rf $W/trace; mkdir -p $W/trace; cp "$_i0" $T
    GLASSINE_BI_RAW_TRACE=$W/trace "$@" >/dev/null 2>&1 || { echo "  the traced run failed"; return 1; }
    $M replay "$_i0" $W/trace "$_n" > $W/replay 2>$W/err || return 1
    cp $T $W/after
}
# realcut IMG0 K CMD...: CMD over a copy of IMG0 killed after K bytes of its writes;
# the partition is the replay's state at K
realcut() {
    _i0=$1 _k=$2; shift 2
    cp "$_i0" $T; echo "$_k" > $W/budget
    GLASSINE_BI_RAW_CUT=$W/budget "$@" >/dev/null 2>&1
    $M state "$_i0" $W/trace "$_k" $W/want && cmp -s $T $W/want
}
fresh $W/z0
ok "init over zeros, cut at every byte: no table or the new one, never another" "replay $W/z0 table $R init $T && grep -q 'bad=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
rc_ok=1
for k in 0 1 32767 32768 32769 53247 53248 53249 57343 57344 57345 61439; do realcut $W/z0 $k $R init $T || { rc_ok=0; echo "  cut at $k differs from the replay"; }; done
ok "init over zeros killed at the steps' edges: the partition is the replay's" "[ $rc_ok = 1 ]"
# an old, other table over the same partition (one region elsewhere), a record in it
cp $W/z0 $W/o0
sh -c '. /p/lib/glassine-bootpart.sh; GP_TMP=/w/run; GR_LAYOUT="record 2097152 32768
loader 3145728 1048576"; gr_table_bytes 16777216 /w/ot'
dd if=$W/ot of=$W/o0 conv=notrunc 2>/dev/null; dd if=$W/ot of=$W/o0 bs=4096 seek=4095 conv=notrunc 2>/dev/null
ok "the old table is valid for the loader" "[ \"\$($M table $W/o0 | sed -n 2p)\" = 'record 2097152 32768 0' ]"
ok "init --force over another table, cut at every byte: the old table or the new one" "replay $W/o0 table $R init --force $T && grep -q 'bad=0' $W/replay && grep -q 'none=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
rc_ok=1
for k in 0 57344 57345 61439 61440 61441 65535; do realcut $W/o0 $k $R init --force $T || { rc_ok=0; echo "  cut at $k differs from the replay"; }; done
ok "init --force killed between and inside the two copies: the partition is the replay's" "[ $rc_ok = 1 ]"
# the loader region over none, over a larger and over a smaller old loader
fresh $W/l0; $R init $W/l0 2>/dev/null
ok "loader over an empty region, cut at every byte: no loader or the new one" "replay $W/l0 loader $R loader $T $W/l5000 && grep -q 'bad=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
cp $W/l0 $W/l1; $R loader $W/l1 $W/l20000 2>/dev/null
ok "a smaller loader over a larger one, cut at every byte: the old, none or the new" "replay $W/l1 loader $R loader $T $W/l5000 && grep -q 'bad=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
rc_ok=1
for k in 0 1 4095 4096 4097 12287 12288 12289 16383; do realcut $W/l1 $k $R loader $T $W/l5000 || { rc_ok=0; echo "  cut at $k differs from the replay"; }; done
ok "the loader write killed at every step's edges: the partition is the replay's, and no other loader" "[ $rc_ok = 1 ]"
cp $W/l0 $W/l2; $R loader $W/l2 $W/l5000 2>/dev/null
ok "a larger loader over a smaller one, cut at every byte: the old, none or the new" "replay $W/l2 loader $R loader $T $W/l20000 && grep -q 'bad=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
# the splash regions
cp $W/l0 $W/s0; $R splash $W/s0 $W/s1.gspl 2>/dev/null
ok "an image over another, cut at every byte: the old, none or the new" "replay $W/s0 splash $R splash $T $W/s2.gspl && grep -q 'bad=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
cp $W/l0 $W/s3; $R override $W/s3 $W/s1.gspl 2>/dev/null
ok "the override's removal, cut at every byte: the override or none" "replay $W/s3 override $R clear $T override && grep -q 'bad=0' $W/replay && grep -q 'new=0' $W/replay"
echo "     $(cat $W/replay)"
# the record's slot: the healthy mark
mstart; cp $MI $W/r0
ok "the healthy mark, cut at every byte of its slot: the old record or the new, by the loader's rules" "replay $W/r0 record env GLASSINE_BI_BOOTPART_DEV=$T GLASSINE_DEPLOY_CONF=$MW/conf GLASSINE_BI_SYSTEM=$MS GLASSINE_BI_CMDLINE=$MW/cmdline GLASSINE_BI_BOARD=$MW/board.raw GLASSINE_BI_RUN_DIR=$MR sh /p/sbin/glassine-loader-mark healthy && grep -q 'bad=0' $W/replay && grep -q 'none=0' $W/replay && grep -q 'final=new' $W/replay"
echo "     $(cat $W/replay)"
rc_ok=1
for k in 0 1 100 8191 16383; do
    rm -f $MR/loader-marked
    realcut $W/r0 $k env GLASSINE_BI_BOOTPART_DEV=$T GLASSINE_DEPLOY_CONF=$MW/conf GLASSINE_BI_SYSTEM=$MS GLASSINE_BI_CMDLINE=$MW/cmdline GLASSINE_BI_BOARD=$MW/board.raw GLASSINE_BI_RUN_DIR=$MR sh /p/sbin/glassine-loader-mark healthy || { rc_ok=0; echo "  cut at $k differs from the replay"; }
    # inside the record: the old count; in the newlines after it: the new record whole
    want=2; [ $k -lt 8191 ] || want=0
    [ "$($M item $T record | sed -n 's/^unmarked=//p')" = $want ] || { rc_ok=0; echo "  cut at $k: unmarked is not $want"; }
done
ok "the mark killed inside its slot: the partition is the replay's; the loader reads the old count, or the new one once its record is whole" "[ $rc_ok = 1 ]"

# --- 5. a loop device (privileged) -------------------------------------------------
if [ "${BR_PRIV:-}" = 1 ]; then
    fresh $W/loop.img
    LD=$(losetup -f); losetup $LD $W/loop.img
    ok "a block device: init, the loader, a splash image, read back through O_DIRECT" "$R init $LD 2>/dev/null && $R loader $LD $W/l5000 2>/dev/null && $R splash $LD $W/s1.gspl 2>/dev/null && $R read $LD loader | cmp -s - $W/l5000"
    $M seed $LD $GB/loader.a $GB/loader.b; $M next $LD unmarked=2 started=$RUNSET started_why=default
    rm -f $MR/loader-marked
    printf 'DEVNAME=%s\nPARTN=1\nPARTNAME=glassine-boot\n' "${LD#/dev/}" > $W/sb/devices/xd/xd1/uevent
    printf 'DEVNAME=xd2\nPARTN=2\nPARTNAME=userdata\n' > $W/sb/devices/xd/xd2/uevent
    ok "a block device found by GPT name: the healthy mark, the loader reads unmarked=0" "env PATH=$MW:\$PATH GLASSINE_DEPLOY_CONF=$MW/conf GLASSINE_BI_SYSTEM=$MS GLASSINE_BI_CMDLINE=$MW/cmdline GLASSINE_BI_BOARD=$MW/board.raw GLASSINE_BI_RUN_DIR=$MR GLASSINE_BI_SYSBLOCK=$W/sb GLASSINE_BI_DEVDIR=/dev sh /p/sbin/glassine-loader-mark healthy 2>$W/err && [ \"\$($M item $LD record | sed -n 's/^unmarked=//p')\" = 0 ] && [ \"\$($M item $LD loader | sha256sum)\" = \"\$(sha256sum < $W/l5000)\" ]"
    [ ! -d /dump ] || { cp $W/loop.img /dump/loop.img; }
    losetup -d $LD
fi
[ ! -d /dump ] || { cp $I /dump/regions.img; cp $W/z0 /dump/zeros.img; cp $W/o0 /dump/oldtable.img; cp $W/l1 /dump/loader20000.img; cp $W/r0 /dump/record.img; cp $W/after /dump/after.img; }

echo "$fails failed"
[ $fails = 0 ]
