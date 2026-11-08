#!/bin/sh
# test/seed: glassine-device-seed on plain directories (GLASSINE_SEED_FAKE): a
# directory stands in for DEVICE_PART's file system and one per source
# partition. Runs in a plain Alpine container (busybox, as on the device).
set -u
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
T=/p/sbin/glassine-device-seed
d=/w; rm -rf $d; mkdir -p $d/bin $d/run
f=$d/fake
S=$f/part/glassine
# blkid: the line in SRC.blkid, as busybox prints it (it ignores -o and -s)
printf '#!/bin/sh\ncat "$1.blkid" 2>/dev/null\n' > $d/bin/blkid; chmod +x $d/bin/blkid
srcpart() { mkdir -p "$f/src/$1"; echo "$f/src/$1: UUID=\"a46c\" TYPE=\"${2:-ext4}\"" > "$f/src/$1.blkid"; }
srcpart sysa; srcpart vend vfat
# a waveform with a correct header: the file's length at offset 4
wbf() {
    n=$1
    { printf 'WBF\0'; printf "\\$(printf %o $((n & 255)))\\$(printf %o $((n >> 8 & 255)))\\$(printf %o $((n >> 16 & 255)))\\$(printf %o $((n >> 24 & 255)))"
      head -c $((n - 8)) /dev/urandom; } > "$2"
}
rnd() { mkdir -p "$(dirname "$2")"; head -c "$1" /dev/urandom > "$2"; }
mkdir -p $f/src/sysa/waveform $f/src/sysa/image $f/src/sysa/fw $f/src/vend
wbf 4096 $f/src/sysa/waveform/panel.wbf
rnd 3000 $f/src/sysa/fw/x.bin
for p in mdt b00 b01 b02; do rnd 500 $f/src/sysa/image/dsp.$p; done
rnd 200 $f/src/vend/BOARD.BIN
printf 'DEVICE_PART=devdata\n' > $d/board
printf 'release=7.3.0-test\nfirmware=gpuvendor/gpu.fw@0123456789abcdef other.fw@0123456789abcdef\n' > $d/kernel.manifest
: > $d/cmdline
list() { { echo format=1; printf '%s\n' "$@"; } > $d/list; }
L_BASE='waveform.wbf sysa:/waveform/panel.wbf wbf # the panel
firmware/vendor/a.bin sysa:/fw/x.bin
firmware/vendor/dsp.* sysa:/image/dsp.*
firmware/board.bin vend:/BOARD.BIN'
list "$L_BASE"
seed() {
    PATH="$d/bin:$PATH" GLASSINE_SEED_LIST=$d/list GLASSINE_SEED_BOARD=$d/board GLASSINE_SEED_RUN=$d/run \
        GLASSINE_SEED_FAKE=$f GLASSINE_SEED_REQUEST=$d/request GLASSINE_DEVICE_LIB=/p/lib/glassine-device.sh \
        GLASSINE_SEED_KERNEL_MANIFEST=$d/kernel.manifest GLASSINE_SEED_FW_PARAM=$d/fwpath GLASSINE_SEED_CMDLINE=$d/cmdline \
        sh $T "$@" 2>>$d/log
}
B=$d/run/device
lines() { tail -n +2 $S/manifest | wc -l; }
line() { awk -v n="$1" 'NR > 1 && $1 == n' $S/manifest; }
sha() { sha256sum < "$1" | cut -d' ' -f1; }
newlog() { : > $d/log; }
noread() { ! grep -q 'reading ' $d/log; }

# --- no device data ---
rm $d/list
ok "no list: exit 0, nothing read, nothing said, DEVICE_PART untouched" "seed && [ ! -s $d/log ] && [ ! -e $f/part ] && [ ! -e $B ]"
list
ok "a list with no entries: the same" "seed && [ ! -s $d/log ] && [ ! -e $f/part ]"
list "$L_BASE"; : > $d/board
ok "a list on a board without DEVICE_PART: exit 0, said, ignored" "seed && grep -q 'the board has no DEVICE_PART: ignored' $d/log && [ ! -e $f/part ]"
printf 'DEVICE_PART=devdata\n' > $d/board; newlog

# --- invalid lists: nothing seeded ---
for bad in 'x devdata:/a' '../x sysa:/a' 'a/./b sysa:/a' '.hidden sysa:/a' 'manifest sysa:/a' '/abs sysa:/a' 'x sysa:noslash' 'x sysa:/a/../b' 'a.* sysa:/a' 'x sysa:/a x y' 'x sysa:/a.*'; do
    list "$bad"; newlog
    ok "invalid list ($bad): exit 2, said, nothing seeded" "seed; [ \$? = 2 ] && grep -q 'the list is invalid' $d/log && [ ! -e $f/part ]"
done
list "x sysa:/a" "x sysa:/b"
ok "a name twice: invalid" "seed; [ \$? = 2 ]"
printf 'format=2\nx sysa:/a\n' > $d/list
ok "a newer list format: exit 3, nothing seeded" "seed; [ \$? = 3 ] && grep -q 'newer than this tool' $d/log && [ ! -e $f/part ]"
printf 'x sysa:/a\n' > $d/list
ok "no format line: invalid" "seed; [ \$? = 2 ]"

# --- the first seed ---
list "$L_BASE"; newlog
ok "first seed: exit 0, bound" "seed && [ -f $B/waveform.wbf ]"
ok "first seed: copies match their sources (a directory, a rename, a split image, a vfat source)" "cmp -s $S/waveform.wbf $f/src/sysa/waveform/panel.wbf && cmp -s $S/firmware/vendor/a.bin $f/src/sysa/fw/x.bin && cmp -s $S/firmware/board.bin $f/src/vend/BOARD.BIN && for p in mdt b00 b01 b02; do cmp -s $S/firmware/vendor/dsp.\$p $f/src/sysa/image/dsp.\$p || exit 1; done"
ok "manifest: format=1, one line per resolved file with its source and sha256" "[ \"\$(head -n1 $S/manifest)\" = format=1 ] && [ \$(lines) = 7 ] && [ \"\$(line firmware/vendor/dsp.b01)\" = \"firmware/vendor/dsp.b01 sysa:/image/dsp.b01 \$(sha $S/firmware/vendor/dsp.b01)\" ] && [ \"\$(line waveform.wbf)\" = \"waveform.wbf sysa:/waveform/panel.wbf \$(sha $S/waveform.wbf)\" ]"
ok "first seed: no temp files" "! find $S -name '.*' | grep -q ."
ok "the firmware path: the seed's firmware/, no newline" "[ \"\$(cat $d/fwpath)\" = $B/firmware ] && [ \$(wc -c < $d/fwpath) = $(( ${#B} + 9 )) ]"
ok "status: complete, every entry ok" "seed status > $d/st && [ \$(grep -c ' ok ' $d/st) = 4 ]"

# --- later boots ---
newlog; mv $f/src/sysa $f/src/gone
ok "bound and complete: nothing read, even with a source gone" "seed && noread"
rm $B; newlog; : > $d/fwpath
ok "not bound (the next boot): verified, bound, nothing read, the firmware path set again" "seed && [ -f $B/waveform.wbf ] && noread && [ \"\$(cat $d/fwpath)\" = $d/run/device/firmware ]"
echo 'quiet firmware_class.path=/elsewhere' > $d/cmdline; : > $d/fwpath; rm $B
ok "firmware_class.path on the command line: the parameter is left alone" "seed && [ ! -s $d/fwpath ]"
: > $d/cmdline; mv $f/src/gone $f/src/sysa

# a damaged copy: copied again in the same run; its source gone: the file goes, the rest bound
rm $B; echo x >> $S/firmware/vendor/a.bin; newlog
ok "a damaged copy, source there: copied again, only that one read" "seed && cmp -s $S/firmware/vendor/a.bin $f/src/sysa/fw/x.bin && [ \$(grep -c 'reading ' $d/log) = 1 ]"
rm $B; echo x >> $S/firmware/vendor/a.bin; mv $f/src/sysa/fw/x.bin $d/x.saved; newlog
ok "a damaged copy, source gone: exit 1, the copy removed, the rest bound, its line kept" "seed; [ \$? = 1 ] && [ ! -e $S/firmware/vendor/a.bin ] && [ -f $B/waveform.wbf ] && [ -n \"\$(line firmware/vendor/a.bin)\" ] && grep -q 'firmware/vendor/a.bin: sysa:/fw/x.bin could not be read' $d/log && grep -q 'left out: firmware/vendor/a.bin' $d/log"
ok "status names what is missing, exit 1" "seed status > $d/st; [ \$? = 1 ] && grep -q '^firmware/vendor/a.bin missing' $d/st"
newlog
ok "retried at the next run (still bound, incomplete)" "seed; [ \$? = 1 ] && grep -q 'reading sysa:/fw/x.bin' $d/log"
mv $d/x.saved $f/src/sysa/fw/x.bin; newlog
ok "the source back: copied" "seed && cmp -s $S/firmware/vendor/a.bin $f/src/sysa/fw/x.bin"

# a changed source: not taken without a refresh
rm $S/firmware/vendor/a.bin $B; rnd 3000 $f/src/sysa/fw/x.bin; newlog
# shellcheck disable=SC2034  # read in the check below
OLDSHA=$(line firmware/vendor/a.bin | cut -d' ' -f3)
ok "a source that gives other bytes: left out, said, the recorded sha kept" "seed; [ \$? = 1 ] && [ ! -e $S/firmware/vendor/a.bin ] && grep -q 'now gives other bytes' $d/log && [ \"\$(line firmware/vendor/a.bin | cut -d' ' -f3)\" = \$OLDSHA ]"
newlog
ok "refresh --now: the new bytes taken" "seed refresh --now && cmp -s $S/firmware/vendor/a.bin $f/src/sysa/fw/x.bin && [ \"\$(line firmware/vendor/a.bin | cut -d' ' -f3)\" = \$(sha $f/src/sysa/fw/x.bin) ]"

# a grown list (a base update), then a shorter one (an older deployment)
rnd 100 $f/src/sysa/fw/new.bin; list "$L_BASE" "firmware/new.bin sysa:/fw/new.bin"; newlog
ok "a grown list: the new file copied, nothing else read" "seed && cmp -s $S/firmware/new.bin $f/src/sysa/fw/new.bin && [ \$(grep -c 'reading ' $d/log) = 1 ]"
list "$L_BASE"; rm $B; newlog
ok "a shorter list: complete, nothing removed" "seed && [ -f $S/firmware/new.bin ] && [ -n \"\$(line firmware/new.bin)\" ] && [ -f $B/firmware/new.bin ]"

# split images that fail as a whole
mkdir -p $f/src/sysa/gap; for p in mdt b00 b02; do rnd 50 $f/src/sysa/gap/g.$p; done
mkdir -p $f/src/sysa/nomdt; rnd 50 $f/src/sysa/nomdt/n.b00
list "$L_BASE" "firmware/g.* sysa:/gap/g.*" "firmware/n.* sysa:/nomdt/n.*"; newlog
ok "a split image with a gap, one with no .mdt: refused as a whole, nothing of either added" "seed; [ \$? = 1 ] && grep -q 'firmware/g.\\*: the parts of sysa:/gap/g.\\* have a gap (00 02)' $d/log && grep -q 'firmware/n.\\*: no sysa:/nomdt/n.mdt' $d/log && ! ls $S/firmware | grep -q '^[gn]\\.' && [ -z \"\$(line firmware/g.mdt)\$(line firmware/g.b00)\" ]"
rm -rf $f/src/sysa/nomdt; rnd 50 $f/src/sysa/gap/g.b01; list "$L_BASE" "firmware/g.* sysa:/gap/g.*"; newlog
ok "the gap filled: the image taken" "seed && [ -f $S/firmware/g.b01 ] && [ \$(line firmware/g.mdt | wc -l) = 1 ]"
for p in mdt b00; do rnd 60 $f/src/sysa/gap/g.$p; done; rm $f/src/sysa/gap/g.b01 $f/src/sysa/gap/g.b02
newlog
ok "a split image refreshed with fewer parts: its old parts go with it" "seed refresh --now && [ ! -e $S/firmware/g.b01 ] && [ -z \"\$(line firmware/g.b01)\" ] && cmp -s $S/firmware/g.b00 $f/src/sysa/gap/g.b00"

# a name the running kernel's own firmware provides
rnd 10 $f/src/sysa/fw/gpu.fw; list "$L_BASE" "firmware/gpuvendor/gpu.fw sysa:/fw/gpu.fw"; newlog
ok "a name the kernel provides: refused, named, not copied" "seed; [ \$? = 1 ] && grep -q 'firmware/gpuvendor/gpu.fw: the kernel 7.3.0-test provides firmware gpuvendor/gpu.fw itself; refused' $d/log && [ ! -e $S/firmware/gpuvendor/gpu.fw ]"
list "$L_BASE"

# refresh without --now: the request; the next start refreshes even though bound
wbf 6144 $f/src/sysa/waveform/panel.wbf; newlog
ok "refresh: only the request, the seed unchanged" "seed refresh >/dev/null && [ -e $d/request ] && [ \$(wc -c < $S/waveform.wbf) = 4096 ]"
mv $f/src/sysa $f/src/gone
ok "the request with a source gone: kept, the copies stay, bound" "seed; [ \$? = 1 ] && [ -e $d/request ] && [ -f $B/waveform.wbf ] && [ \$(wc -c < $S/waveform.wbf) = 4096 ]"
mv $f/src/gone $f/src/sysa
ok "the requested refresh at start: done, the request cleared" "seed && [ ! -e $d/request ] && [ \$(wc -c < $B/waveform.wbf) = 6144 ]"
ok "refresh --later: usage" "seed refresh --later; [ \$? = 2 ]"

# cut-off writes (a power cut: the tool killed at once, no cleanup)
cut() { ( export "GLASSINE_SEED_$1=kill -9 \$\$; exit 99" GLASSINE_SEED_TEST=1; seed refresh --now ); }
wbf 8192 $f/src/sysa/waveform/panel.wbf
cut BEFORE_MANIFEST
ok "cut before the manifest's rename: the new file in place, the old manifest, a temp manifest: the seed doesn't verify" "[ \$(wc -c < $S/waveform.wbf) = 8192 ] && [ -e $S/.manifest.new ] && ! GLASSINE_DEVICE_LIB= sh -c '. /p/lib/glassine-device.sh; gd_verify $S'"
rm -f $B; newlog
ok "the next run: the cut refresh's request stands, so it is done again: the new bytes, complete, no temp file" "[ -e $d/request ] && seed && [ ! -e $d/request ] && [ \$(wc -c < $B/waveform.wbf) = 8192 ] && [ ! -e $S/.manifest.new ] && grep -q 'refresh asked for' $d/log"
wbf 2048 $f/src/sysa/waveform/panel.wbf
cut AFTER_MANIFEST
rm -f $B; newlog
ok "cut after the manifest's rename: the new seed verifies; the request stands until a run finishes" "[ -e $d/request ] && GLASSINE_DEVICE_LIB= sh -c '. /p/lib/glassine-device.sh; gd_verify $S' && seed && [ ! -e $d/request ] && [ \$(wc -c < $B/waveform.wbf) = 2048 ]"
# a changed source after a cut-off write without a request (a cut fill at start)
wbf 4096 $f/src/sysa/waveform/panel.wbf; rm -f $S/waveform.wbf $B; newlog
ok "a fill (no refresh) whose source now differs from the recorded bytes: left out, the rest verified and bound" "seed; [ \$? = 1 ] && [ ! -e $S/waveform.wbf ] && [ -f $B/firmware/board.bin ] && grep -q 'waveform.wbf: sysa:/waveform/panel.wbf now gives other bytes' $d/log"
wbf 2048 $f/src/sysa/waveform/panel.wbf; seed refresh --now >/dev/null 2>&1

# a write that fails (cp stops after 100 bytes of the temp file): no temp file
# left, the old copy verified and bound
cpfail() {
    printf '#!/bin/sh\ncase $2 in */glassine/*.new) head -c 100 "$1" > "$2"; exit 1 ;; esac\nexec %s "$@"\n' \
        "$(command -v cp)" > $d/bin/cp; chmod +x $d/bin/cp
}
cpfail; wbf 4096 $f/src/sysa/waveform/panel.wbf; newlog
ok "a failed write: exit 1, said, no temp file, the old copy bound" "seed refresh --now; [ \$? = 1 ] && grep -q 'writing the seed failed' $d/log && ! find $S -name '.*' | grep -q . && [ \$(wc -c < $B/waveform.wbf) = 2048 ] && seed status >/dev/null"
rm $d/bin/cp

# the read-write mount is refused: mounted read-only again and bound
: > $f/rw_fails; newlog
ok "a refused read-write mount: exit 1, said, bound again" "seed refresh --now; [ \$? = 1 ] && grep -q 'cannot mount devdata read-write' $d/log && [ -f $B/waveform.wbf ]"
rm $f/rw_fails

# no manifest (cut before the first manifest): no seed, made again
rm $B $S/manifest; : > $S/.manifest.new; newlog
ok "no manifest: copied again, the stray temp file gone" "seed && [ -f $S/manifest ] && [ ! -e $S/.manifest.new ]"
# a file the manifest doesn't name: removed before binding
rm $B; echo stray > $S/stray
ok "a file the manifest doesn't name: removed, then bound" "seed && [ ! -e $S/stray ] && [ -f $B/waveform.wbf ]"

# the journal needs recovery: replayed, then verified
rm $B; : > $f/needs_recovery; newlog
ok "the journal: replayed, then verified" "seed && [ ! -e $f/needs_recovery ] && grep -q replaying $d/log"

# a source that isn't a waveform: not copied
rm -rf $f/part $B; head -c 4096 /dev/zero > $f/src/sysa/waveform/panel.wbf; newlog
ok "a bad waveform: not copied, said" "seed; [ \$? = 1 ] && [ ! -e $S/waveform.wbf ] && grep -q \"is not a valid 'wbf' file\" $d/log"
# util-linux's blkid output; a file system the seed doesn't read
wbf 4096 $f/src/sysa/waveform/panel.wbf
echo '/dev/sda5: LABEL="system" SEC_TYPE="ext2" TYPE="ext3" PARTLABEL="sysa" PTTYPE="dos"' > $f/src/sysa.blkid
rm -rf $f/part $B; newlog
ok "util-linux blkid output read" "seed"
echo '/dev/sda5: UUID="a46c" TYPE="squashfs"' > $f/src/sysa.blkid
rm -rf $f/part $B; newlog
ok "an unknown file system: not read, said" "seed; [ \$? = 1 ] && grep -q \"file system 'squashfs' not read\" $d/log && [ ! -e $S/waveform.wbf ]"

echo "$fails failed"
[ $fails = 0 ]
