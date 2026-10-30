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
ok "deployments layout: no staged-image peek (it would come before the resume step)" "grep -q 'no staged-image test boot in the deployments layout' /kmsg.dep-img"
unset GLASSINE_INIT_LIB

# --- no board config ---
run noboard "panic=5 rdinit=/init glassine.return=3 glassine.devmode=usb" /does-not-exist
ok "no board config: said, no listeners, no root to boot: powers off" "grep -q 'no board config' /kmsg.noboard && ! listens noboard && grep -q 'none configured' /kmsg.noboard && grep -q '^poweroff -f' /calls.noboard"

ok "the test overrides are dropped when the init is PID 1" "[ \"\$(grep -n 'unset GLASSINE_INIT_CMDLINE GLASSINE_INIT_BOARD GLASSINE_INIT_HOOKS' /m/initramfs/init | cut -d: -f1)\" -lt \"\$(grep -n '^CMDF=' /m/initramfs/init | cut -d: -f1)\" ]"

[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; for f in /kmsg.*; do echo "--- $f"; cat $f; done; exit 1; }
