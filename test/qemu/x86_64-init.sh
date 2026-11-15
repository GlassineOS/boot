#!/bin/sh
# /sbin/init of test/qemu/x86_64.sh's base: checks what the initramfs left (the boot
# modules loaded, the deployment assembled from the btrfs system partition, the ext4
# userdata and the overlay), one QTEST line each, then powers off.
exec > /dev/console 2>&1
fails=0
ok() { if eval "$2"; then echo "QTEST ok $1"; else echo "QTEST FAIL $1"; fails=$((fails + 1)); fi; }
KR=$(uname -r)
DISK=$(sed -n 's/.*qtest\.disk=\([^ ]*\).*/\1/p' /proc/cmdline)
ok "the boot modules loaded, none failed" "dmesg | grep -q 'glassine-boot: boot modules: [0-9]* of [0-9]* loaded\$'"
for m in btrfs ext4 overlay $DISK; do
    ok "module $m loaded" "grep -q '^$m ' /proc/modules"
done
ok "btrfs's checksum soft dependencies came before it (crc32c driver loaded)" "grep -q '^crc32c' /proc/modules || grep -q 'crc32c' /proc/crypto"
ok "the system partition (btrfs) mounted at /run/glassine/system" "awk '\$2 == \"/run/glassine/system\" && \$3 == \"btrfs\"' /proc/mounts | grep -q ."
ok "userdata (ext4) mounted at /run/glassine/userdata" "awk '\$2 == \"/run/glassine/userdata\" && \$3 == \"ext4\"' /proc/mounts | grep -q ."
ok "/ is the deployment's overlay, read-only" "awk '\$2 == \"/\" && \$1 == \"overlay\" && \$4 ~ /^ro/' /proc/mounts | grep -q ."
ok "deployment d1 booted" "[ \"\$(cat /run/glassine/booted)\" = d1 ]"
ok "the kernel's modules subvolume bound on /lib/modules/$KR" "[ -f /lib/modules/$KR/modules.dep ] && awk '\$2 == \"/lib/modules/$KR\"' /proc/mounts | grep -q ."
echo "QTEST checks: $fails failed"
[ $fails = 0 ] && echo "QTEST DONE"
sync
poweroff -f
