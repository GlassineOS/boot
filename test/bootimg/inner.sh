#!/bin/sh
set -u
W=/w; mkdir -p $W/st $W/hooks/post-promote.d $W/hooks/post-fail.d $W/mods/6.0.0-old $W/mods/7.2.3-1-sdm660 $W/mods/7.2.4-1-sdm660 $W/boot $W/run
B=/p/sbin/glassine-bootimg
export GLASSINE_BI_STATE=$W/st GLASSINE_BI_BOARD=$W/board.conf GLASSINE_BI_TEST_DEV=$W/testslot GLASSINE_BI_DEFAULT_DEV=$W/defslot GLASSINE_BI_CMDLINE=$W/cmdline \
    GLASSINE_BI_HOOKS=$W/hooks GLASSINE_BI_PACK=/p/lib/glassine-bootimg-pack GLASSINE_BI_MODULES=$W/mods \
    GLASSINE_BI_LOG=$W/log GLASSINE_BI_TMP=$W/run GLASSINE_BI_NOREBOOT=1
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
kernel() { printf 'junk Linux version %s (gcc) #1 SMP junk' "$1" | gzip > $W/boot/vmlinuz-sdm660; }
sed -e "s#^KERNEL=.*#KERNEL=$W/boot/vmlinuz-sdm660#" -e "s#^DTB=.*#DTB=$W/boot/board.dtb#" -e "s#^INITRAMFS=.*#INITRAMFS=$W/boot/initramfs#" \
    /p/conf/board.conf.example > $W/board.conf
echo dtb > $W/boot/board.dtb; echo initramfs > $W/boot/initramfs
for h in post-promote post-fail; do printf '#!/bin/sh\necho "$KEEP|$*" >> %s/%s.calls\n' $W $h > $W/hooks/$h.d/10-rec; chmod +x $W/hooks/$h.d/10-rec; done
head -c 67108864 /dev/zero > $W/testslot; { echo OLDIMAGE; head -c 1000 /dev/zero; } > $W/defslot.seed; cp $W/defslot.seed $W/defslot; truncate -s 67108864 $W/defslot
normal() { echo "panic=5 rdinit=/init glassine.img=$1 _kip_initramfs rootwait" > $W/cmdline; }
testboot() { echo "panic=5 rdinit=/init glassine.img=$1" > $W/cmdline; }
v() { sed -n "s/^$2=//p" $W/st/$1; }

normal oldid; export GLASSINE_BI_UNAME=6.0.0-old
kernel 7.2.3-1-sdm660
ok "install: wrong release refused" "! $B install 7.2.4-1-sdm660 2>/dev/null && [ ! -e $W/st/pending ]"
ok "install: missing modules refused" "! $B install 9.9.9 2>/dev/null"
ok "install 7.2.3 staged" "$B install 7.2.3-1-sdm660 >/dev/null 2>&1 && [ -e $W/st/pending ]"
ok "the default slot's kver recorded from the normal boot" "[ \"\$(v current KVER)\" = 6.0.0-old ]"
ID=$(v pending ID); SIZE=$(v pending SIZE); SHA=$(v pending SHA)
ok "the test slot holds the image" "[ \"\$(head -c $SIZE $W/testslot | sha256sum | cut -d' ' -f1)\" = $SHA ]"
ok "status pending" "[ \"\$($B status)\" = \"pending 7.2.3-1-sdm660 $ID\" ]"
ok "promote on a normal boot, untested: stays pending" "$B promote 2>/dev/null; [ -e $W/st/pending ] && [ ! -e $W/st/failed ]"
ok "reboot-test sets TRIES=1" "$B reboot-test 2>/dev/null; [ \"\$(v pending TRIES)\" = 1 ]"

# the test boot: a second kernel arrives (apk overwrites /boot) -> deferred
testboot $ID; export GLASSINE_BI_UNAME=7.2.3-1-sdm660
ok "status testing" "[ \"\$($B status)\" = \"testing 7.2.3-1-sdm660 $ID\" ]"
kernel 7.2.4-1-sdm660
ok "install during the test boot = deferred, exit 0" "$B install 7.2.4-1-sdm660 >/dev/null 2>&1 && [ \"\$(v deferred KVER)\" = 7.2.4-1-sdm660 ] && [ \"\$(v pending ID)\" = $ID ]"
ok "status shows deferred" "$B status | grep -q 'deferred 7.2.4-1-sdm660'"
GLASSINE_BI_HEALTH=true $B promote 2>/dev/null
ok "promote: the default slot = the TESTED image (not the newer /boot kernel)" "[ \"\$(head -c $SIZE $W/defslot | sha256sum | cut -d' ' -f1)\" = $SHA ]"
ok "promote: current state = 7.2.3" "[ \"\$(v current KVER)\" = 7.2.3-1-sdm660 ] && [ \"\$(v current ID)\" = $ID ]"
ok "promote: previous default image saved for rollback" "head -c 8 $W/st/prev.img | grep -q OLDIMAGE && [ \"\$(v prev KVER)\" = 6.0.0-old ]"
ok "post-promote hook: KEEP = new + previous + deferred" "grep -qx '6.0.0-old 7.2.3-1-sdm660 7.2.4-1-sdm660|6.0.0-old 7.2.3-1-sdm660 7.2.4-1-sdm660' $W/post-promote.calls"
ok "deferred 7.2.4 staged after the verdict" "[ \"\$(v pending KVER)\" = 7.2.4-1-sdm660 ] && [ ! -e $W/st/deferred ]"
ID2=$(v pending ID)
ok "status pending 7.2.4 (this boot is no longer its test)" "[ \"\$($B status)\" = \"pending 7.2.4-1-sdm660 $ID2\" ]"

# 7.2.4's test boot hangs: watchdog -> normal boot of the default slot (7.2.3)
$B reboot-test 2>/dev/null
normal $ID; export GLASSINE_BI_UNAME=7.2.3-1-sdm660
$B promote 2>/dev/null
ok "hung test boot -> failed, default slot untouched" "[ -e $W/st/failed ] && [ ! -e $W/st/pending ] && [ \"\$(head -c $SIZE $W/defslot | sha256sum | cut -d' ' -f1)\" = $SHA ]"
ok "status failed" "[ \"\$($B status)\" = \"failed 7.2.4-1-sdm660 $ID2\" ]"
ok "post-fail hook: KEEP = current + previous (not the failed one)" "tail -n1 $W/post-fail.calls | grep -qx '6.0.0-old 7.2.3-1-sdm660|6.0.0-old 7.2.3-1-sdm660'"
ok "notice for the user" "grep -q 'failed its test boot' $W/run/glassine-bootimg.notice"
ok "retry -> pending again, TRIES=0" "$B retry 2>/dev/null && [ \"\$(v pending TRIES)\" = 0 ] && [ ! -e $W/st/failed ]"

# its test boot again, but unhealthy
$B reboot-test 2>/dev/null; testboot $ID2; export GLASSINE_BI_UNAME=7.2.4-1-sdm660
GLASSINE_BI_HEALTH='echo "desktop"; false' $B promote 2>/dev/null
ok "unhealthy test boot -> failed with the reason, default slot untouched" "grep -q 'REASON=health: desktop' $W/st/failed && [ \"\$(head -c $SIZE $W/defslot | sha256sum | cut -d' ' -f1)\" = $SHA ]"

# rollback to the image before the last promote
normal $ID; export GLASSINE_BI_UNAME=7.2.3-1-sdm660
ok "rollback: the default slot = the previous image" "$B rollback 2>/dev/null && head -c 8 $W/defslot | grep -q OLDIMAGE && [ \"\$(v current KVER)\" = 6.0.0-old ]"
# a promote without room for the rollback copy
kernel 7.2.4-1-sdm660; $B install 7.2.4-1-sdm660 >/dev/null 2>&1; ID3=$(v pending ID); $B reboot-test 2>/dev/null
testboot $ID3; export GLASSINE_BI_UNAME=7.2.4-1-sdm660; : > $W/post-promote.calls
GLASSINE_BI_HEALTH=true GLASSINE_BI_MINFREE_KB=999999999 $B promote 2>/dev/null
ok "no room: promoted, no prev.img, KEEP = the new kernel only" "[ \"\$(v current KVER)\" = 7.2.4-1-sdm660 ] && [ ! -e $W/st/prev.img ] && grep -qx '7.2.4-1-sdm660|7.2.4-1-sdm660' $W/post-promote.calls"
ok "no room: rollback refused" "! $B rollback 2>/dev/null"
ok "no temp files left in /run" "[ -z \"\$(ls $W/run | grep -v notice)\" ]"
# health.d: the generic checks + the packages' scripts (no GLASSINE_BI_HEALTH override)
mkdir -p $W/hooks/health.d; echo "250.00 100.00" > $W/uptime; echo "/dev/mmcblk0p50 / ext4 rw,noatime 0 0" > $W/mounts
printf '#!/bin/sh\nexit 0\n' > $W/hooks/health.d/10-pass
printf '#!/bin/sh\necho "panel link dead"; echo second line; exit 1\n' > $W/hooks/health.d/20-panel
printf '#!/bin/sh\nexit 1\n' > $W/hooks/health.d/30-quiet
printf '#!/bin/sh\necho never; exit 1\n' > $W/hooks/health.d/40-not-executable
chmod +x $W/hooks/health.d/10-pass $W/hooks/health.d/20-panel $W/hooks/health.d/30-quiet
export GLASSINE_BI_UPTIME=$W/uptime GLASSINE_BI_MOUNTS=$W/mounts
normal $ID3; export GLASSINE_BI_UNAME=7.2.4-1-sdm660
kernel 7.2.3-1-sdm660; $B install 7.2.3-1-sdm660 >/dev/null 2>&1; ID4=$(v pending ID); $B reboot-test 2>/dev/null
testboot $ID4; export GLASSINE_BI_UNAME=7.2.3-1-sdm660
$B promote 2>/dev/null
ok "health.d: failing scripts -> failed, reason = first line, else the name" "grep -qx 'REASON=health: panel link dead 30-quiet' $W/st/failed"
ok "health.d: default slot untouched" "[ \"\$(v current ID)\" = $ID3 ]"
rm $W/hooks/health.d/20-panel $W/hooks/health.d/30-quiet; $B retry 2>/dev/null
printf '#!/bin/sh\nsleep 30\n' > $W/hooks/health.d/50-hangs; chmod +x $W/hooks/health.d/50-hangs
GLASSINE_BI_HEALTH_TIMEOUT=1 $B promote 2>/dev/null
ok "health.d: a hanging script times out = unhealthy" "grep -qx 'REASON=health: 50-hangs: timed out' $W/st/failed"
rm $W/hooks/health.d/50-hangs; $B retry 2>/dev/null
echo "50.00 10.00" > $W/uptime; $B promote 2>/dev/null
ok "health: generic uptime check still applies" "grep -q 'REASON=health: uptime<90s' $W/st/failed"
$B retry 2>/dev/null; echo "250.00 100.00" > $W/uptime; echo "/dev/mmcblk0p50 / ext4 ro 0 0" > $W/mounts; $B promote 2>/dev/null
ok "health: generic root-rw check still applies" "grep -q 'REASON=health: root-not-rw' $W/st/failed"
$B retry 2>/dev/null; echo "/dev/mmcblk0p50 / ext4 rw,noatime 0 0" > $W/mounts; $B promote 2>/dev/null
ok "health.d: passing (and non-executable) scripts -> promoted" "[ \"\$(v current ID)\" = $ID4 ] && [ ! -e $W/st/failed ]"
rm -rf $W/hooks/health.d; normal $ID4; kernel 7.2.4-1-sdm660; $B install 7.2.4-1-sdm660 >/dev/null 2>&1; ID5=$(v pending ID); $B reboot-test 2>/dev/null
testboot $ID5; export GLASSINE_BI_UNAME=7.2.4-1-sdm660; $B promote 2>/dev/null
ok "no health.d: the generic checks only -> promoted" "[ $ID5 != $ID4 ] && [ \"\$(v current ID)\" = $ID5 ]"
unset GLASSINE_BI_UPTIME GLASSINE_BI_MOUNTS
# the boot image carries board.conf for the initramfs (a second cpio archive in the ramdisk)
python3 - $W/testslot $W/rd <<'EOP'
import struct, sys
b = open(sys.argv[1], 'rb').read()
ks, _, rs = struct.unpack_from('<3I', b, 8); ps = struct.unpack_from('<I', b, 36)[0]
off = ps + (ks + ps - 1) // ps * ps
open(sys.argv[2], 'wb').write(b[off:off + rs])
EOP
mkdir -p $W/rdx && (cd $W/rdx && tail -c +13 $W/rd | cpio -i -d 2>/dev/null)
ok "boot image: the initramfs first, unchanged" "head -c 10 $W/rd | grep -qx initramfs"
ok "boot image: board.conf at /etc/glassine-boot/board.conf in the ramdisk" "cmp -s $W/rdx/etc/glassine-boot/board.conf $W/board.conf"

# another board: no role word (glassine.test marks the test slot), no slots configured
cp $W/board.conf $W/board.conf.keep
sed -i "s/^DEFAULT_ROLE_MATCH=.*/DEFAULT_ROLE_MATCH=''/" $W/board.conf
echo "panic=5 glassine.img=$(v pending ID 2>/dev/null) _kip_initramfs" > $W/cmdline
ok "board without a role word: a plain boot is not the test slot" "$B status | grep -qv '^testing'"
kernel 7.2.4-1-sdm660; $B install 7.2.4-1-sdm660 >/dev/null 2>&1; ID6=$(v pending ID)
echo "panic=5 glassine.img=$ID6 glassine.test" > $W/cmdline
ok "board without a role word: glassine.test = the test slot" "[ \"\$($B status)\" = \"testing 7.2.4-1-sdm660 $ID6\" ]"
sed -i 's/^TEST_DEV=.*//; s/^DEFAULT_DEV=.*//' $W/board.conf
ok "board without slots: install refused (env overrides off)" "! env -u GLASSINE_BI_TEST_DEV -u GLASSINE_BI_DEFAULT_DEV $B install 7.2.4-1-sdm660 2>&1 | grep -q staged && env -u GLASSINE_BI_TEST_DEV -u GLASSINE_BI_DEFAULT_DEV $B install 7.2.4-1-sdm660 2>&1 | grep -q 'no TEST_DEV/DEFAULT_DEV'"
cp $W/board.conf.keep $W/board.conf; rm -f $W/st/pending
# no board.conf: pack writes nothing (an image without board.conf would power off at its default boot)
. $W/board.conf.keep
ok "pack without board.conf: fails, no image" "! python3 /p/lib/glassine-bootimg-pack $W/nonexistent.conf $KERNEL $DTB $INITRAMFS $W/nb.img >/dev/null 2>&1 && [ ! -e $W/nb.img ]"
ok "install without board.conf: refused, slots untouched" "S=\$(sha256sum $W/testslot); ! GLASSINE_BI_BOARD=$W/nonexistent.conf $B install 7.2.4-1-sdm660 >/dev/null 2>&1 && [ \"\$S\" = \"\$(sha256sum $W/testslot)\" ]"
ok "status line parseable with nothing pending" "$B status | grep -qE '^(none|failed|promoted) '"
ok "usage exit 2" "$B 2>/dev/null; [ \$? = 2 ]"

echo "--- log"; cat $W/log
[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
