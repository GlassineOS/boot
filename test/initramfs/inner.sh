#!/bin/sh
set -u
S=/stub; mkdir -p $S
for c in mount umount mknod watchdog telnetd httpd udhcpd ifconfig switch_root e2fsck killall dmesg sleep; do
    printf '#!/bin/sh\necho "%s $*" >> /calls\n' $c > $S/$c
done
for c in reboot poweroff; do printf '#!/bin/sh\necho "%s $*" >> /calls\nkill -9 $PPID\n' $c > $S/$c; done
chmod +x $S/*
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
EX=/m/conf/board.conf.example
ADDR=$(sed -n 's/^DEVMODE_ADDR=//p' $EX)
run() {     # run NAME CMDLINE [BOARD]: the init with that cmdline + board; its calls in /calls
    rm -rf /www /tmp/hk-* /dev/kmsg; : > /calls; : > /kmsg.$1
    mkfifo /dev/kmsg                    # each log line opens + truncates it: a reader appends
    # read-write: the reader is a writer too, so it never sees EOF between log
    # lines (a reader that closed in between made a log line SIGPIPE the init)
    cat 0<>/dev/kmsg >> /kmsg.$1 & r=$!
    echo "$2" > /cmdline
    PATH=$S:/usr/sbin:/usr/bin:/sbin:/bin GLASSINE_INIT_CMDLINE=/cmdline GLASSINE_INIT_BOARD=${3:-$EX} \
        GLASSINE_INIT_HOOKS=/hooks timeout 20 sh /m/initramfs/init >/dev/null 2>&1
    kill $r 2>/dev/null; wait $r 2>/dev/null
    cp /calls /calls.$1
    ls /www/cgi-bin > /eps.$1 2>/dev/null
    for f in sourced waited pre; do [ -e /tmp/hk-$f ] && echo $f; done > /hk.$1
}
listens() { grep -qE '^(telnetd|httpd|udhcpd) ' /calls.$1; }
mkdir -p /hooks

# --- developer mode, the example board ---
run test-off "panic=5 rdinit=/init glassine.return=3"
ok "test role, devmode off: no telnetd/httpd/udhcpd" "! listens test-off"
ok "test role, devmode off: default boot tried" "grep -q 'default: preparing' /kmsg.test-off"
ok "test role, devmode off: back to the default slot (reboot)" "grep -q '^reboot -f' /calls.test-off"
ok "test role, devmode off: logs devmode 0" "grep -q 'devmode 0' /kmsg.test-off"

run daily-off "panic=5 rdinit=/init glassine.return=3 _kip_initramfs"
ok "default role, devmode off: no listeners" "! listens daily-off"
ok "default role, devmode off: failed default boot powers off (no loop)" "grep -q '^poweroff -f' /calls.daily-off && ! grep -q '^reboot' /calls.daily-off"

run img-off "panic=5 rdinit=/init glassine.return=3 glassine.img=0123456789abcdef"
ok "staged-image ID, not staged, devmode off: no listeners" "! listens img-off"

for v in 0 1 yes tcp; do
    run "dev-$v" "panic=5 rdinit=/init glassine.return=3 glassine.devmode=$v"
    ok "glassine.devmode=$v: off, no listeners" "! listens dev-$v && grep -q 'devmode 0' /kmsg.dev-$v"
done

run test-on "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb"
ok "test role, devmode on: telnetd + httpd on the board address" "grep -qx 'telnetd -b $ADDR:23 -l /bin/sh' /calls.test-on && grep -qx 'httpd -p $ADDR:80 -h /www' /calls.test-on"
ok "test role, devmode on: standard endpoints" "for e in dmesg status prev run stay back default; do grep -qx \$e /eps.test-on || exit 1; done"
ok "test role, devmode on: no default boot by itself (waits for the host)" "! grep -q 'default: preparing' /kmsg.test-on"
ok "test role, devmode on: auto-return after glassine.return" "grep -q '^reboot -f' /calls.test-on"

run daily-on "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb _kip_initramfs"
ok "default role, devmode on: failed default boot stays reachable" "grep -q '^telnetd ' /calls.daily-on && ! grep -q '^poweroff' /calls.daily-on"

# --- hooks ---
cat > /hooks/10-a.sh <<'EOF2'
touch /tmp/hk-sourced
hk_ep() { glassine_endpoint marker 'echo hook'; }
hk_wait() { touch /tmp/hk-waited; }
hk_pre() { touch /tmp/hk-pre; }
glassine_hook endpoints hk_ep
glassine_hook wait hk_wait
glassine_hook pre-switch-root hk_pre
glassine_hook no-such-stage hk_ep
EOF2
cat > /hooks/20-b.sh <<'EOF2'
hk_ep2() { glassine_endpoint marker2 'echo hook2'; }
glassine_hook endpoints hk_ep2
EOF2
echo 'touch /tmp/hk-wrongname' > /hooks/30-not-a-hook.txt
for c in "panic=5 rdinit=/init glassine.return=3" "panic=5 rdinit=/init glassine.return=3 _kip_initramfs" \
         "panic=5 rdinit=/init glassine.return=3 glassine.devmode=yes"; do
    n=hk-off-$(echo "$c" | cksum | cut -c1-6)
    run "$n" "$c"
    ok "hooks present, devmode off ($c): never sourced, no hook endpoint" "[ ! -s /hk.$n ] && ! grep -q 'hook:' /kmsg.$n && ! grep -qx marker /eps.$n"
done
run hk-on "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb"
ok "devmode on: hooks sourced in name order" "grep -q sourced /hk.hk-on && [ \"\$(grep -o 'hook: /hooks/[^ ]*' /kmsg.hk-on | head -2 | tr '\n' ' ')\" = 'hook: /hooks/10-a.sh hook: /hooks/20-b.sh ' ]"
ok "devmode on: two hooks on one stage both run" "grep -qx marker /eps.hk-on && grep -qx marker2 /eps.hk-on && grep -qx dmesg /eps.hk-on"
ok "devmode on: the wait stage runs while waiting for the host" "grep -q waited /hk.hk-on"
ok "devmode on: an unknown stage is logged, not fatal" "grep -q 'unknown stage no-such-stage' /kmsg.hk-on && grep -q '^telnetd ' /calls.hk-on"
ok "devmode on: only *.sh files are hooks" "[ ! -e /tmp/hk-wrongname ]"
rm -f /hooks/*
run hk-none "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb"
ok "devmode on, no hooks: services start, nothing sourced" "grep -q '^telnetd ' /calls.hk-none && ! grep -q 'hook:' /kmsg.hk-none"

# --- another board ---
cat > /other.conf <<'EOF2'
ROOT_PART=rootfs
ROOT_FSTYPE=btrfs
DEFAULT_ROLE_MATCH='glassine\.slot=a'
DEVMODE_ADDR=10.0.5.1
DEVMODE_NETMASK=255.255.0.0
USB_VENDOR=0x1234
EOF2
run o-default "panic=5 rdinit=/init glassine.return=3 glassine.slot=a" /other.conf
ok "other board: its role word = default role" "grep -q 'role: default' /kmsg.o-default"
ok "other board: looks for its own root partition" "grep -q 'root partition rootfs not found' /kmsg.o-default"
run o-test "panic=5 rdinit=/init glassine.return=3 _kip_initramfs" /other.conf
ok "other board: another board's role word = test role" "grep -q 'role: test' /kmsg.o-test"
run o-dev "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb" /other.conf
ok "other board, devmode on: its address" "grep -qx 'telnetd -b 10.0.5.1:23 -l /bin/sh' /calls.o-dev && grep -qx 'httpd -p 10.0.5.1:80 -h /www' /calls.o-dev"
ok "other board, devmode on: no DHCP range = no udhcpd" "! grep -q '^udhcpd' /calls.o-dev"
printf 'ROOT_PART=rootfs\n' > /nodev.conf
run o-noaddr "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb" /nodev.conf
ok "board without DEVMODE_ADDR: devmode refused, no listeners" "! listens o-noaddr && grep -q 'no DEVMODE_ADDR' /kmsg.o-noaddr"

# --- the deployments layout ---
printf 'ROOT_PART=rootfs\nROOT_FSTYPE=btrfs\nROOT_LAYOUT=deployments\nUSERDATA_PART=userdata\n' > /dep.conf
run dep-nolib "panic=5 rdinit=/init glassine.return=3 _kip_initramfs" /dep.conf
ok "deployments layout, no library: said, no root" "grep -q 'has no glassine-root.sh' /kmsg.dep-nolib && grep -q 'none configured' /kmsg.dep-nolib"
export GLASSINE_INIT_LIB=/m/lib
run dep "panic=5 rdinit=/init glassine.return=3 _kip_initramfs" /dep.conf
ok "deployments layout: library sourced, looks for its root partition" "! grep -q 'glassine-root.sh' /kmsg.dep && grep -q 'root partition rootfs not found' /kmsg.dep"
run dep-img "panic=5 rdinit=/init glassine.return=3 glassine.test glassine.img=0123456789abcdef" /dep.conf
ok "deployments layout, glassine.img= with no root partition found: no kernel trial, no plain-layout peek" "grep -q 'image 0123456789abcdef: no kernel trial' /kmsg.dep-img && ! grep -q 'staged by glassine-bootimg\\|not staged' /kmsg.dep-img"
# the partitions by their identity (glassine.system=, glassine.userdata=: a PC) or by
# their GPT name (no key: the Note Air), in a sysfs stand-in
SB=/sysblock; mkdir -p $SB/vda1 $SB/vda2 $SB/vda3 $SB/vdb1
printf 'MAJOR=254\nDEVNAME=vda1\nPARTN=1\nPARTNAME=rootfs\nPARTUUID=11111111-1111-4111-8111-111111111111\n' > $SB/vda1/uevent
printf 'MAJOR=254\nDEVNAME=vda2\nPARTN=2\nPARTNAME=pc-system\nPARTUUID=0f3e26a1-5c7b-4a55-9b8d-2c4f6e8a1b3d\n' > $SB/vda2/uevent
printf 'MAJOR=254\nDEVNAME=vda3\nPARTN=3\nPARTNAME=pc-data\nPARTUUID=6d1a5e2b-8c4f-4b3a-a9e7-1f2d3c4b5a69\n' > $SB/vda3/uevent
printf 'MAJOR=254\nDEVNAME=vdb1\nPARTN=1\nPARTNAME=other\nPARTUUID=22222222-2222-4222-8222-222222222222\n' > $SB/vdb1/uevent
export GLASSINE_INIT_SYSBLOCK=$SB
SU=0f3e26a1-5c7b-4a55-9b8d-2c4f6e8a1b3d UU=6d1a5e2b-8c4f-4b3a-a9e7-1f2d3c4b5a69
run key-ok "panic=5 rdinit=/init glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU" /dep.conf
ok "glassine.system=PARTUUID=: the partition with that identity, whatever its name" "grep -q \"root partition glassine.system=PARTUUID=$SU is /dev/vda2\" /kmsg.key-ok"
ok "glassine.userdata=PARTUUID=: found too (not reported missing)" "! grep -q 'userdata .* not found' /kmsg.key-ok"
run key-upper "panic=5 rdinit=/init glassine.system=PARTUUID=$(echo $SU | tr a-f A-F)" /dep.conf
ok "an identity in upper case: compared in lower case" "grep -q 'is /dev/vda2' /kmsg.key-upper"
run key-none "panic=5 rdinit=/init glassine.system=PARTUUID=33333333-3333-4333-8333-333333333333" /dep.conf
ok "an identity no partition has: not found, the partition with the board's name (rootfs) not taken" "grep -q 'root partition glassine.system=PARTUUID=33333333-3333-4333-8333-333333333333 not found' /kmsg.key-none && ! grep -q 'is /dev/vda1' /kmsg.key-none"
run key-bad "panic=5 rdinit=/init glassine.system=LABEL=rootfs" /dep.conf
ok "a key that isn't PARTUUID=<uuid>: no partition taken, no fallback to the name" "grep -q 'glassine.system=LABEL=rootfs is not PARTUUID=<uuid>: no partition taken' /kmsg.key-bad && ! grep -q 'is /dev/vda1' /kmsg.key-bad"
run key-short "panic=5 rdinit=/init glassine.system=PARTUUID=0f3e26a1" /dep.conf
ok "a PARTUUID that isn't a whole identity (a prefix): refused" "grep -q 'is not PARTUUID=<uuid>' /kmsg.key-short && ! grep -q 'is /dev/vda2' /kmsg.key-short"
run key-twice "panic=5 rdinit=/init glassine.system=PARTUUID=$SU glassine.system=PARTUUID=$SU" /dep.conf
ok "a key given twice: no partition taken" "grep -q 'glassine.system= is given more than once' /kmsg.key-twice && ! grep -q 'is /dev/' /kmsg.key-twice"
run key-word "panic=5 rdinit=/init xglassine.system=PARTUUID=$SU" /dep.conf
ok "a key matched as a whole word only: xglassine.system= is no key, the board's name is taken" "grep -q 'root partition rootfs is /dev/vda1' /kmsg.key-word"
run key-noud "panic=5 rdinit=/init glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=44444444-4444-4444-8444-444444444444" /dep.conf
ok "a userdata identity no partition has: userdata not found (no fallback to the name)" "grep -q 'userdata glassine.userdata=PARTUUID=44444444-4444-4444-8444-444444444444 not found' /kmsg.key-noud"
cp $SB/vda2/uevent $SB/vdb1/uevent; sed -i 's/vda2/vdb1/' $SB/vdb1/uevent
run key-clone "panic=5 rdinit=/init glassine.system=PARTUUID=$SU" /dep.conf
ok "two partitions carry the identity (a cloned disk): none taken" "grep -q 'PARTUUID=$SU: 2 partitions carry it: none taken' /kmsg.key-clone && ! grep -q 'is /dev/' /kmsg.key-clone"
run name "panic=5 rdinit=/init" /dep.conf
ok "no key: the partition by the board's name (the Note Air)" "grep -q 'root partition rootfs is /dev/vda1' /kmsg.name"
printf 'ROOT_PART=pc-system\nROOT_FSTYPE=btrfs\nUSERDATA_PART=pc-data\n' > /plain.conf
run key-plain "panic=5 rdinit=/init glassine.system=PARTUUID=22222222-2222-4222-8222-222222222222" /plain.conf
ok "the plain layout: the keys are not read, the board's name is" "grep -q 'root partition pc-system is /dev/vda2' /kmsg.key-plain"
run once-bad "panic=5 rdinit=/init glassine.deploy.once=../d1" /dep.conf
ok "glassine.deploy.once= that isn't a deployment id: dropped, said" "grep -q 'glassine.deploy.once=../d1 is not a deployment id: no deployment request' /kmsg.once-bad"
run once-twice "panic=5 rdinit=/init glassine.deploy.once=d1 glassine.deploy.once=d2" /dep.conf
ok "glassine.deploy.once= given twice: no request" "grep -q 'glassine.deploy.once= is given more than once' /kmsg.once-twice"
# a kernel whose uevent has no PARTUUID= (6.12): the identity read from the disk's GPT
apk add -q sgdisk >/dev/null 2>&1
GU=5a0c3e7d-1b2f-4c6a-8d9e-0f1a2b3c4d5e
SB2=/sysblock2; mkdir -p $SB2/devices/vdz/queue $SB2/devices/vdz/vdz1 /devdir
head -c 4194304 /dev/zero > /devdir/vdz
sgdisk -o -n 1:2048:+1M -c 1:pc-system -u 1:$(echo $GU | tr a-f A-F) /devdir/vdz >/dev/null
printf 'MAJOR=254\nDEVNAME=vdz\nDEVTYPE=disk\n' > $SB2/devices/vdz/uevent; echo 512 > $SB2/devices/vdz/queue/logical_block_size
printf 'MAJOR=254\nDEVNAME=vdz1\nDEVTYPE=partition\nPARTN=1\nPARTNAME=pc-system\n' > $SB2/devices/vdz/vdz1/uevent; echo 2048 > $SB2/devices/vdz/vdz1/start
ln -s devices/vdz/vdz1 $SB2/vdz1; ln -s devices/vdz $SB2/vdz
export GLASSINE_INIT_SYSBLOCK=$SB2 GLASSINE_INIT_DEVDIR=/devdir
run gpt "panic=5 rdinit=/init glassine.system=PARTUUID=$GU" /dep.conf
ok "no PARTUUID= in the uevent: the identity read from the disk's GPT entry" "grep -q 'root partition glassine.system=PARTUUID=$GU is /dev/vdz1' /kmsg.gpt"
echo 4096 > $SB2/devices/vdz/vdz1/start
run gpt-start "panic=5 rdinit=/init glassine.system=PARTUUID=$GU" /dep.conf
ok "the GPT entry's first block isn't the partition's start: not taken" "grep -q 'PARTUUID=$GU not found' /kmsg.gpt-start"
unset GLASSINE_INIT_SYSBLOCK GLASSINE_INIT_LIB GLASSINE_INIT_DEVDIR

# --- boot modules (an archive appended for this kernel, for another, none) ---
cat > $S/uname <<'EOF2'
#!/bin/sh
[ "$1" = -r ] && { echo 9.9.9-test; exit 0; }
exec /bin/uname "$@"
EOF2
cat > $S/insmod <<'EOF2'
#!/bin/sh
echo "insmod $*" >> /calls
case $1 in */bad.ko) echo "insmod: can't insert '$1': invalid module format" >&2; exit 1 ;;
*/loaded.ko) echo "insmod: can't insert '$1': File exists" >&2; exit 1 ;; esac
EOF2
chmod +x $S/uname $S/insmod
mkdir -p /ml/modules/9.9.9-test
printf 'crc\nbad\nbtrfs\nloaded\nnvme\n' > /ml/modules/9.9.9-test/load
export GLASSINE_INIT_LIB=/ml
run mod "panic=5 rdinit=/init glassine.return=3" /other.conf
ok "boot modules: loaded in the archive's order, before the root partition is looked for" "[ \"\$(sed -n 's|^insmod /ml/modules/9.9.9-test/||p' /calls.mod | tr '\\n' ' ')\" = 'crc.ko bad.ko btrfs.ko loaded.ko nvme.ko ' ] && [ \"\$(grep -n 'boot modules:' /kmsg.mod | cut -d: -f1)\" -lt \"\$(grep -n 'root partition rootfs not found' /kmsg.mod | cut -d: -f1)\" ]"
ok "boot modules: a failure logged by name, an already loaded one counted, the boot goes on" "grep -q 'boot modules: 4 of 5 loaded, failed: bad' /kmsg.mod && grep -q 'root partition rootfs not found' /kmsg.mod"
mv /ml/modules/9.9.9-test /ml/modules/1.0.0-other
run mod-other "panic=5 rdinit=/init glassine.return=3" /other.conf
ok "boot modules for another release: none loaded, said" "! grep -q '^insmod' /calls.mod-other && grep -q 'boot modules: the archive is for 1.0.0-other and this kernel is 9.9.9-test: none loaded' /kmsg.mod-other"
rm -rf /ml/modules
run mod-none "panic=5 rdinit=/init glassine.return=3" /other.conf
ok "no boot modules (a kernel with its drivers built in): no step, nothing logged" "! grep -q '^insmod' /calls.mod-none && ! grep -q 'boot modules' /kmsg.mod-none"
unset GLASSINE_INIT_LIB
rm -f $S/uname $S/insmod

# --- no board config ---
run noboard "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb" /does-not-exist
ok "no board config: said, no listeners, no root to boot: powers off" "grep -q 'no board config' /kmsg.noboard && ! listens noboard && grep -q 'none configured' /kmsg.noboard && grep -q '^poweroff -f' /calls.noboard"

ok "the test overrides are dropped when the init is PID 1" "[ \"\$(grep -n 'unset GLASSINE_INIT_CMDLINE GLASSINE_INIT_BOARD GLASSINE_INIT_HOOKS GLASSINE_INIT_LIB GLASSINE_INIT_SYSBLOCK GLASSINE_INIT_DEVDIR' /m/initramfs/init | cut -d: -f1)\" -lt \"\$(grep -n '^CMDF=' /m/initramfs/init | cut -d: -f1)\" ]"

[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; for f in /kmsg.*; do echo "--- $f"; cat $f; done; exit 1; }
