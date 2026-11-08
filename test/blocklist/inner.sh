#!/bin/sh
# See test.sh.
set -u
W=/w; mkdir -p $W && mount -t tmpfs -o size=256m tmpfs $W
BL="python3 /p/lib/glassine-blocklist"
READER="python3 /p/test/blocklist/reader.py"
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
LOOPS=''
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1" && LOOPS="$LOOPS $LOOP"
}
# mkfs_mount NAME MKE2FS-ARGS: a 48 MiB ext4 for $W/NAME.mnt, LOOP = its device
mkfs_mount() {
    _n=$1; shift
    truncate -s 48M $W/$_n.img
    mke2fs -q -F -t ext4 "$@" $W/$_n.img || return 1
    loop $W/$_n.img || return 1
    mkdir -p $W/$_n.mnt
}

# must_mount ARGS: a mount that fails is a failure, so a check can't vanish
must_mount() { mount -t ext4 "$@" || { echo "FAIL cannot mount: $*"; fails=$((fails + 1)); return 1; }; }

echo "--- what no real file system can be made to produce"
python3 /p/test/blocklist/unit.py /p/lib/glassine-blocklist || fails=$((fails + 1))

mkfs_mount ud -b 4096; UD=$LOOP
mount -t ext4 "$UD" $W/ud.mnt || { echo "FAIL cannot mount userdata"; exit 1; }
K=$W/ud.mnt/media/glassine/kernel; mkdir -p $K
ID=0123456789abcdef

# store NAME BLOCKS: as install does: allocated, written in full, synced, immutable
store() {
    head -c $(($2 * 4096)) /dev/urandom > $W/$1.src
    printf '\000' | dd of=$W/$1.src bs=1 count=1 conv=notrunc 2>/dev/null     # a test writes X there: it must change the byte
    fallocate -l $(($2 * 4096)) $K/$1.img &&
        dd if=$W/$1.src of=$K/$1.img bs=4096 conv=notrunc,fsync 2>/dev/null && sync && chattr +i $K/$1.img
}
sha() { sha256sum < "$1" | cut -d' ' -f1; }
# record NAME OUT: NAME's record, from its map
record() { $BL map $K/$1.img | $BL encode "$2" $ID userdata "$(stat -c %s $K/$1.img)" "$(sha $W/$1.src)"; }

echo "--- the file system"
ok "userdata (ext4, 4096): passes" "$BL check-fs $K"
ok "tmpfs: refused" "! $BL check-fs $W 2>$W/e && grep -q 'on tmpfs' $W/e"
mkfs_mount k1 -b 1024
must_mount "$LOOP" $W/k1.mnt && ok "1024-byte blocks: refused" "! $BL check-fs $W/k1.mnt 2>$W/e && grep -q 'block size is 1024' $W/e"
mkfs_mount dj -b 4096
must_mount -o data=journal "$LOOP" $W/dj.mnt && ok "data=journal: refused" "! $BL check-fs $W/dj.mnt 2>$W/e && grep -q 'data=journal' $W/e"
mkfs_mount dd -b 4096; tune2fs -o journal_data $W/dd.img >/dev/null
must_mount "$LOOP" $W/dd.mnt && ok "data=journal as the file system's default: refused" "! $BL check-fs $W/dd.mnt 2>$W/e && grep -q 'data=journal' $W/e"
mkfs_mount nj -b 4096 -O ^has_journal
must_mount "$LOOP" $W/nj.mnt && ok "no journal at all: passes" "$BL check-fs $W/nj.mnt"
mkdir $W/ud.mnt/jd; chattr +j $W/ud.mnt/jd
ok "a directory with data journalling: refused" "! $BL check-fs $W/ud.mnt/jd 2>$W/e && grep -q 'data journalling' $W/e"

echo "--- mapping a file"
store a 300
ok "a stored file maps" "$BL map $K/a.img > $W/a.map && [ -s $W/a.map ]"
ok "... the blocks add up to the file" "[ \$(awk '{n += \$2} END {print n}' $W/a.map) = 300 ]"
ok "not immutable: refused" "cp $K/a.img $K/b.img && sync && ! $BL map $K/b.img 2>$W/e && grep -q 'not immutable' $W/e"
rm -f $K/b.img
fallocate -l 409600 $K/un.img; sync; chattr +i $K/un.img
ok "allocated but never written (unwritten extents): refused" "! $BL map $K/un.img 2>$W/e && grep -q 'unwritten' $W/e"
chattr -i $K/un.img; rm -f $K/un.img
ok "a directory: refused" "! $BL map $K 2>/dev/null"

echo "--- the record, the raw device and the simulated reader"
truncate -s 8M $W/slot.img; loop $W/slot.img; SLOT=$LOOP
REC=$(( (8 * 1024 * 1024 - 65536) / 4096 ))
putrec() { dd if="$1" of=$SLOT bs=4096 seek=$REC count=1 conv=notrunc,fsync 2>/dev/null; }
record a $W/a.rec
ok "the record decodes to the file" "$BL decode $W/a.rec > $W/a.dec && grep -qx 'id=$ID' $W/a.dec && grep -qx 'partition=userdata' $W/a.dec && grep -qx sha256=\$(sha $W/a.src) $W/a.dec"
ok "check: the record, the file and the raw blocks agree" "$BL check $W/a.rec $K/a.img $UD"
putrec $W/a.rec
ok "the simulated reader accepts it and returns exactly the image" "$READER $SLOT $UD $W/a.out >/dev/null && cmp $W/a.out $W/a.src"
head -c 100 $W/a.rec > $W/torn; head -c 3996 /dev/zero >> $W/torn; putrec $W/torn
ok "a torn record: the simulated reader rejects it" "! $READER $SLOT $UD $W/o >/dev/null"
ok "... and so does decode" "! $BL decode $W/torn 2>/dev/null"
python3 -c "
import sys
r=bytearray(open('$W/a.rec','rb').read()); r[72]^=1; open('$W/badsha','wb').write(r)
r=bytearray(open('$W/a.rec','rb').read()); r[128:136]=(2**40).to_bytes(8,'little'); open('$W/out','wb').write(r)
r=bytearray(open('$W/a.rec','rb').read()); r[64:72]=(16*1024*1024).to_bytes(8,'little'); open('$W/big','wb').write(r)"
putrec $W/badsha; ok "a wrong sha256: rejected" "$READER $SLOT $UD $W/o | grep -q 'reject: sha256'"
putrec $W/out; ok "an extent outside the partition: rejected, nothing read" "$READER $SLOT $UD $W/o | grep -q 'outside the partition'"
putrec $W/big; ok "image_size past the limit: rejected" "$READER $SLOT $UD $W/o | grep -q 'past the limit'"
head -c 4096 /dev/zero > $W/zero; putrec $W/zero; ok "no record: the default slot boots" "$READER $SLOT $UD $W/o | grep -q 'no record'"

echo "--- the file changes after install"
store c 64; record c $W/c.rec
ok "check passes before anything happens" "$BL check $W/c.rec $K/c.img $UD"
cp $K/c.img $K/c.new; sync; chattr -i $K/c.img; mv -f $K/c.new $K/c.img; sync; chattr +i $K/c.img
ok "same bytes in other blocks: refused" "! $BL check $W/c.rec $K/c.img $UD 2>$W/e && grep -q 'no longer has the blocks' $W/e"
store d 64; record d $W/d.rec
FIRST=$($BL map $K/d.img | head -n 1 | cut -d' ' -f1)
printf X | dd of=$UD bs=4096 seek=$FIRST conv=notrunc,fsync 2>/dev/null
ok "the same blocks with other contents: refused" "! $BL check $W/d.rec $K/d.img $UD 2>$W/e && grep -q \"don't hold the image\" $W/e"
putrec $W/d.rec
ok "... and the simulated reader rejects it" "$READER $SLOT $UD $W/o | grep -q 'reject: sha256'"

echo "--- the record helpers in ash (lib/glassine-kernel.sh)"
mkdir -p $W/tmp; export TMP=$W/tmp
export GLASSINE_DEPLOY_CONF=/nonexistent
log() { echo "$*" >> $W/log; }
die() { log "$*"; exit 1; }
. /p/lib/glassine-state.sh
. /p/lib/glassine-kernel.sh
# bootimg BLOCKS: a header v0 image of BLOCKS blocks on the slot, the record
# area empty, a pattern after it (where an AVB footer would be)
bootimg() {
    python3 - "$SLOT" "$1" <<'PY'
import os, struct, sys
slot, blocks = sys.argv[1], int(sys.argv[2])
kb = (blocks - 1) * 4096
h = bytearray(4096)
h[:8] = b'ANDROID!'
struct.pack_into('<I', h, 8, kb)
struct.pack_into('<I', h, 36, 4096)
fd = os.open(slot, os.O_WRONLY)
n = os.lseek(fd, 0, 2)
os.pwrite(fd, bytes(n), 0)
body = bytearray(os.urandom(kb))
body[8192 - 4096] = 0     # the fault injection writes X at 8192: it must change the byte
os.pwrite(fd, bytes(h) + bytes(body), 0)
os.pwrite(fd, b'\xaa' * 61440, n - 61440)
os.fsync(fd)
PY
}
region() { dd if=$SLOT bs=4096 skip=$1 count=$2 iflag=direct 2>/dev/null | sha256sum | cut -d' ' -f1; }
TOTAL=$((8 * 1024 * 1024 / 4096))
before() { R1=$(region 0 $REC); R2=$(region $((REC + 1)) $((TOTAL - REC - 1))); }
same() { [ "$(region 0 $REC)" = "$R1" ] && [ "$(region $((REC + 1)) $((TOTAL - REC - 1)))" = "$R2" ]; }
bootimg 200; before
export GLASSINE_BI_TEST=1 GLASSINE_BI_AFTER_RECORD='echo x >> $W/hits'
ok "the record's place: 64 KiB before the end, in blocks" "[ \$(gk_bl_block $SLOT) = $REC ]"
ok "an empty record area reads as none" "[ \$(gk_bl_id $SLOT) = none ]"
: > $W/hits
ok "clearing nothing writes nothing" "gk_bl_clear $SLOT && [ ! -s $W/hits ]"
ok "a record goes in" "gk_bl_put $SLOT $W/a.rec && [ -s $W/hits ]"
ok "... ash reads its id" "[ \$(gk_bl_id $SLOT) = $ID ]"
dd if=$SLOT of=$W/back bs=4096 skip=$REC count=1 iflag=direct 2>/dev/null
ok "... the full decoder reads the same record" "cmp $W/back $W/a.rec && $BL decode $W/back | grep -qx 'id=$ID'"
ok "... nothing else in the slot changed, the 60 KiB after the record included" "same"
ok "... the simulated reader accepts what ash wrote" "$READER $SLOT $UD $W/o >/dev/null && cmp $W/o $W/a.src"
head -c 12 $W/a.rec > $W/torn; head -c 4084 /dev/zero >> $W/torn; putrec $W/torn
ok "a record torn before its id reads as bad" "[ \$(gk_bl_id $SLOT) = bad ]"
ok "a record is cleared" "gk_bl_clear $SLOT && [ \$(gk_bl_id $SLOT) = none ] && same"
: > $W/hits
ok "the image is put back if the write changed it, and the write fails" "
    GLASSINE_BI_AFTER_RECORD='printf X | dd of=$SLOT bs=1 seek=8192 conv=notrunc,fsync 2>/dev/null'
    export GLASSINE_BI_AFTER_RECORD
    ! gk_bl_put $SLOT $W/a.rec && same; "
GLASSINE_BI_AFTER_RECORD='echo x >> $W/hits'; export GLASSINE_BI_AFTER_RECORD
gk_bl_clear $SLOT
before
ok "the record reads back wrong: the write fails, the image untouched" "
    GLASSINE_BI_AFTER_RECORD='printf X | dd of=$SLOT bs=4096 seek=$REC conv=notrunc,fsync 2>/dev/null'
    export GLASSINE_BI_AFTER_RECORD
    ! gk_bl_put $SLOT $W/a.rec && same"
GLASSINE_BI_AFTER_RECORD='echo x >> $W/hits'; export GLASSINE_BI_AFTER_RECORD
{ printf '\n'; head -c 4095 /dev/zero; } > $W/nl; putrec $W/nl
ok "a record whose first byte is a newline isn't empty" "[ \$(gk_bl_id $SLOT) = bad ]"
ok "... and it is cleared" "gk_bl_clear $SLOT && [ \$(gk_bl_id $SLOT) = none ]"
gk_bl_put $SLOT $W/a.rec
cat > $W/rd.sh <<RD
log() { :; }; die() { exit 1; }
. /p/lib/glassine-state.sh; . /p/lib/glassine-kernel.sh
gk_bl_id \$1
RD
: > $W/ids
n=0; while [ $n -lt 30 ]; do sh $W/rd.sh $SLOT >> $W/ids 2>&1 & n=$((n + 1)); done; wait
ok "thirty processes read the record at once, without a lock: each gets the id" "[ \$(grep -cx $ID $W/ids) = 30 ] && [ \$(wc -l < $W/ids) = 30 ]"
ok "... and leave no files behind" "! ls $W/tmp | grep -q glassine-bootimg.rec"
gk_bl_clear $SLOT
bootimg $((REC + 1)); before; : > $W/hits
ok "a default image that reaches the record area: refused, no write attempted" "! gk_bl_put $SLOT $W/a.rec && same && [ \$(gk_bl_id $SLOT) != $ID ] && [ ! -s $W/hits ]"
bootimg $REC; before
ok "... one that ends right before it: written" "gk_bl_put $SLOT $W/a.rec && same"
gk_bl_clear $SLOT
dd if=/dev/zero of=$SLOT bs=4096 count=1 conv=notrunc,fsync 2>/dev/null; before; : > $W/hits
ok "a slot with no boot image: refused, no write attempted" "! gk_bl_put $SLOT $W/a.rec && same && [ ! -s $W/hits ]"
bootimg 200; before; : > $W/log
ok "the image can't be put back: the write fails and says the slot can't boot" "
    GLASSINE_BI_AFTER_RECORD='printf X | dd of=$SLOT bs=1 seek=8192 conv=notrunc,fsync 2>/dev/null' GLASSINE_BI_AFTER_BODY=false
    export GLASSINE_BI_AFTER_RECORD GLASSINE_BI_AFTER_BODY
    ! gk_bl_put $SLOT $W/a.rec && grep -q 'putting it back failed' $W/log"
GLASSINE_BI_AFTER_RECORD=; GLASSINE_BI_AFTER_BODY=; export GLASSINE_BI_AFTER_RECORD GLASSINE_BI_AFTER_BODY
head -c 100 /dev/zero > $W/short
bootimg 200; before
ok "a record that isn't 4096 bytes: refused" "! gk_bl_put $SLOT $W/short && same"

umount $W/ud.mnt $W/k1.mnt $W/dj.mnt $W/dd.mnt $W/nj.mnt 2>/dev/null
for l in $LOOPS; do losetup -d "$l" 2>/dev/null; done
cd /; umount $W 2>/dev/null
[ "$fails" = 0 ] && echo "all blocklist checks passed" || echo "$fails blocklist checks FAILED"
[ "$fails" = 0 ]
