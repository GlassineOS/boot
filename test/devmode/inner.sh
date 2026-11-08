#!/bin/sh
# test/devmode: glassine-devmode with stubs for the network, the address
# server, the SSH server and ssh-keygen (each logs its call), a configfs and
# a UDC directory standing in for the kernel's. Runs in a plain Alpine container.
set -u
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
T=/p/sbin/glassine-devmode
W=/w; rm -rf $W; mkdir -p $W/bin $W/run/glassine $W/ud/media/glassine $W/cfg/usb_gadget $W/udc
C=$W/calls
stub() { printf '#!/bin/sh\necho "%s $*" >> %s\n%s\n' "$1" $C "${2:-}" > $W/bin/$1; chmod +x $W/bin/$1; }
stub ifconfig
stub modprobe
stub nmcli
stub mount
# udhcpd and sshd: a sleeping process whose pid goes where their config says
stub busybox-extras 'p=$(sed -n "s/^pidfile //p" "$2"); sleep 300 & echo $! > "$p"'
stub sshd 'p=$(sed -n "s/^PidFile //p" "$2"); sleep 300 & echo $! > "$p"'
stub ssh-keygen 'while [ $# -gt 1 ]; do shift; done; echo key > "$1"; echo pub > "$1.pub"'
printf 'USERDATA_MNT=%s/ud\nRUN_DIR=%s/run/glassine\n' $W $W > $W/deploy.conf
printf 'DEVMODE_ADDR=10.0.9.1\nDEVMODE_NETMASK=255.255.255.0\nDEVMODE_DHCP_START=10.0.9.2\nDEVMODE_DHCP_END=10.0.9.10\n' > $W/board.conf
: > $W/cmdline
DM=$W/ud/media/glassine/devmode R=$W/rundm
dm() {
    PATH="$W/bin:$PATH" GLASSINE_PROC_CMDLINE=$W/cmdline GLASSINE_DEVMODE_RUN=$R GLASSINE_DEVMODE_GADGET=$W/cfg/usb_gadget/glassine-devmode \
        GLASSINE_DEVMODE_UDC=$W/udc GLASSINE_BOARD_CONF=${BC:-$W/board.conf} GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEVMODE_SSHD=sshd \
        sh $T "$@" > $W/out 2>&1
}
gone() { [ -z "$(cat $W/cfg/usb_gadget/glassine-devmode/UDC 2>/dev/null)" ] && [ ! -L $W/cfg/usb_gadget/glassine-devmode/configs/c.1/ncm.usb0 ]; }
reset() { dm stop; rm -rf $R $C $W/cfg/usb_gadget/*; : > $C; }
echo d1 > $W/run/glassine/booted

: > $C
ok "no glassine.devmode=usb: exit 0, nothing started, nothing made, nothing said" "dm start && [ ! -s $C ] && [ ! -e $DM ] && [ ! -e $R ] && [ ! -s $W/out ]"
ok "status without it: off, exit 1" "dm status; [ \$? = 1 ] && grep -q 'off (no glassine.devmode=usb)' $W/out"
echo 'console=ttyS0 glassine.devmode=usb' > $W/cmdline
echo bare:b1 > $W/run/glassine/booted
ok "a bare boot: no developer folder, no SSH, said" "dm start && [ ! -s $C ] && [ ! -e $DM ] && grep -q 'a bare boot: no developer folder' $W/out"
rm $W/run/glassine/booted
ok "not a deployments boot: nothing, said" "dm start && [ ! -s $C ] && [ ! -e $DM ] && grep -q 'not a deployments boot' $W/out"
echo d1 > $W/run/glassine/booted
printf 'DEVMODE_NETMASK=255.255.255.0\n' > $W/board.conf.noaddr
ok "no DEVMODE_ADDR: nothing started, said" "BC=$W/board.conf.noaddr dm start && [ ! -s $C ] && [ ! -e $DM ] && grep -q 'has no DEVMODE_ADDR' $W/out"

mkdir -p $W/udc/dummy_udc.0
mkdir -p $DM && chmod 0755 $DM
ok "start: exit 0" "dm start"
ok "the developer folder: root:root 0700 (a looser mode fixed)" "[ \"\$(stat -c '%u:%g %a' $DM)\" = '0:0 700' ]"
ok "the host key made in the developer folder, said; no authorized_keys yet said" "[ -s $DM/ssh_host_ed25519_key ] && grep -q 'made the ed25519 host key' $W/out && grep -q 'no .*authorized_keys yet' $W/out"
ok "the USB gadget: NCM on the first UDC, the board's identity" "[ \"\$(cat $W/cfg/usb_gadget/glassine-devmode/UDC)\" = dummy_udc.0 ] && [ -L $W/cfg/usb_gadget/glassine-devmode/configs/c.1/ncm.usb0 ] && [ \"\$(cat $W/cfg/usb_gadget/glassine-devmode/idVendor)\" = 0x1d6b ]"
ok "the address on the gadget's interface" "grep -qx 'ifconfig usb0 10.0.9.1 netmask 255.255.255.0 up' $C"
ok "NetworkManager told to leave the interface alone, before the address" "[ \"\$(grep -n -m1 '^nmcli device set usb0 managed no\$' $C | cut -d: -f1)\" -lt \"\$(grep -n -m1 '^ifconfig usb0' $C | cut -d: -f1)\" ]"
ok "the address server: the board's range, on that interface only" "grep -qx 'start 10.0.9.2' $R/udhcpd.conf && grep -qx 'end 10.0.9.10' $R/udhcpd.conf && grep -qx 'interface usb0' $R/udhcpd.conf && grep -q '^busybox-extras udhcpd ' $C"
ok "the SSH server: only on DEVMODE_ADDR, keys only from the developer folder, no passwords" "grep -qx 'ListenAddress 10.0.9.1' $R/sshd_config && [ \$(grep -c '^ListenAddress' $R/sshd_config) = 1 ] && grep -qx 'AuthorizedKeysFile $DM/authorized_keys' $R/sshd_config && grep -qx 'HostKey $DM/ssh_host_ed25519_key' $R/sshd_config && grep -qx 'PasswordAuthentication no' $R/sshd_config && grep -qx 'KbdInteractiveAuthentication no' $R/sshd_config && grep -q '^sshd -f $R/sshd_config' $C"
ok "status: running" "dm status && grep -q 'running: SSH on 10.0.9.1' $W/out"
ok "start again: already running, nothing new" ": > $C; dm start && grep -q 'already running' $W/out && [ ! -s $C ]"
SP=$(cat $R/sshd.pid) UP=$(cat $R/udhcpd.pid)
ok "stop: both servers gone, the gadget removed" "dm stop && ! kill -0 $SP 2>/dev/null && ! kill -0 $UP 2>/dev/null && gone"
: > $C
ok "a second start: the host key kept" "echo mine > $DM/ssh_host_ed25519_key; dm start && [ \"\$(cat $DM/ssh_host_ed25519_key)\" = mine ] && ! grep -q ssh-keygen $C"
reset
printf 'DEVMODE_ADDR=10.0.9.1\n' > $W/board.conf.nodhcp
ok "no developer range on the board: no address server" "BC=$W/board.conf.nodhcp dm start; [ \$? = 0 ] && ! grep -q udhcpd $C && grep -q '^sshd ' $C"
reset
ok "DEVMODE_NETDEV: that interface, no USB gadget" "DEVMODE_NETDEV=veth9 dm start && grep -qx 'ifconfig veth9 10.0.9.1 netmask 255.255.255.0 up' $C && [ ! -e $W/cfg/usb_gadget/glassine-devmode ] && grep -qx 'interface veth9' $R/udhcpd.conf"
DEVMODE_NETDEV=veth9 dm stop; rm -rf $R; : > $C
rmdir $W/udc/dummy_udc.0
ok "no USB device controller: waits, then exit 1, said, the gadget removed, no server" "GLASSINE_DEVMODE_UDC_WAIT=2 dm start; [ \$? = 1 ] && grep -q 'waiting up to 2 s for a USB device controller' $W/out && grep -q 'no USB device controller after 2 s' $W/out && gone && ! grep -q '^sshd\|udhcpd' $C"
reset
# a controller that appears while start waits (the PHY binds after coldplug)
( sleep 2; mkdir -p $W/udc/late_udc.0 ) &
ok "a controller that appears late: start waits for it, then the gadget on it and SSH" "GLASSINE_DEVMODE_UDC_WAIT=20 dm start && grep -q 'waiting up to 20 s' $W/out && [ \"\$(cat $W/cfg/usb_gadget/glassine-devmode/UDC)\" = late_udc.0 ] && grep -q '^sshd -f' $C"
reset; rmdir $W/udc/late_udc.0
ok "usage" "dm frob; [ \$? = 2 ]"

echo "$fails failed"
[ $fails = 0 ]
