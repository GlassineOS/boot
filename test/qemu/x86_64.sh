#!/bin/sh
# The initramfs on an x86-64 PC, in QEMU: q35 under UEFI firmware (OVMF), Alpine's
# linux-lts (its storage and file system drivers are modules) started with
# -kernel/-initrd, so OVMF runs the kernel's EFI stub. The initramfs is
# build-initramfs.sh's (the deployments board below) followed by the kernel's
# boot-modules archive (build-boot-modules.sh, from the kernel's modules/<release>/
# tree as the kernel-artifacts contract lays it out): a kernel set as a PC starts it.
# The disk: GPT, a btrfs "system" partition (a small base b1, the kernel's modules
# subvolume, state/) and an ext4 "userdata" (deployment d1). The base's /sbin/init is a
# check script: it prints QTEST lines and powers off.
#   1  virtio-blk: the boot modules loaded, d1 assembled from btrfs + ext4 + overlay
#   2  the same disk on NVMe
#   3  the initramfs without the archive: no disk driver, the system partition not
#      found (the failure the archive exists for), the init powers off
# Every boot must have started under UEFI (the kernel's "efi: EFI v" line).
#
# Not part of `make check` (minutes per boot when QEMU emulates the CPU). Needs Docker
# with privileged containers and, on a non-x86-64 host, amd64 emulation (binfmt). KVM is
# used when /dev/kvm can be opened.
#   x86_64.sh [OUTDIR]     exit 0 = every QTEST check passed; logs in OUTDIR
#   QTEST_BOOT_TIMEOUT: seconds per boot (default 900)
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
case "${1:-}" in -*) sed -n 's/^#   //p' "$0" >&2; exit 2 ;; esac
OUT=$(mkdir -p "${1:-$D/out-x86_64}" && cd "${1:-$D/out-x86_64}" && pwd)
case $(uname -m) in aarch64|arm64) NATIVE=arm64 ;; *) NATIVE=amd64 ;; esac
rm -f "$OUT"/boot*.log
TO=${QTEST_BOOT_TIMEOUT:-900}

# --- the files: kernel, initramfs, boot modules, base (an x86-64 container) ----------
docker run --rm --platform linux/amd64 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh -euc '
apk add -q linux-lts kmod busybox-static busybox-extras e2fsprogs e2fsprogs-extra cpio gzip >/dev/null
KREL=$(ls /lib/modules)
cp /boot/vmlinuz-lts /out/vmlinuz
W=/w; mkdir -p $W/k/modules
# the kernel tree as kernel-export delivers it (docs/kernel-artifacts.md): modules/<release>/
cp -a /lib/modules/$KREL $W/k/modules/$KREL; rm -f $W/k/modules/$KREL/build $W/k/modules/$KREL/source
printf "ROOT_PART=system\nROOT_FSTYPE=btrfs\nROOT_LAYOUT=deployments\nUSERDATA_PART=userdata\nUSERDATA_PREFIX=media/glassine\nDEFAULT_ROLE_MATCH=\n" > $W/board.conf
sh /p/build-initramfs.sh --board $W/board.conf /out/initramfs-only.cpio.gz
sh /p/build-boot-modules.sh $W/k/modules/$KREL /out/boot-modules.cpio.gz
# the kernel set: the initramfs, then its kernel'"'"'s boot modules
cat /out/initramfs-only.cpio.gz /out/boot-modules.cpio.gz > /out/initramfs.cpio.gz
# the base: busybox and a check script as /sbin/init
B=$W/base; mkdir -p $B/bin $B/sbin $B/etc $B/var $B/tmp $B/proc $B/sys $B/dev $B/run $B/lib/modules $B/lib/firmware/updates
cp /bin/busybox.static $B/bin/busybox
for a in $($B/bin/busybox --list); do [ -e $B/bin/$a ] || ln -s busybox $B/bin/$a; done
install -m 755 /p/test/qemu/x86_64-init.sh $B/sbin/init
tar -C $B --numeric-owner -cf /out/base.tar .
tar -C $W/k/modules/$KREL -cf /out/modules.tar .
echo "$KREL" > /out/krel
echo "files: kernel $KREL"
'

# --- the disk (the host's own architecture: btrfs ioctls don't pass user emulation) ---
docker run --rm --privileged --platform linux/$NATIVE -v "$OUT":/out alpine:3.22 sh -euc '
apk add -q btrfs-progs e2fsprogs sgdisk tar coreutils >/dev/null
KREL=$(cat /out/krel)
W=/w; mkdir -p $W && mount -t tmpfs -o size=1200m tmpfs $W
truncate -s 600M $W/sys.img; mkfs.btrfs -q -L system $W/sys.img
mkdir -p $W/sys && mount -t btrfs -o loop $W/sys.img $W/sys
mkdir -p $W/sys/bases $W/sys/modules $W/sys/state
btrfs -q subvolume create $W/sys/bases/b1
tar -C $W/sys/bases/b1 --numeric-owner -xf /out/base.tar
btrfs property set -ts $W/sys/bases/b1 ro true
btrfs -q subvolume create $W/sys/modules/$KREL
tar -C $W/sys/modules/$KREL -xf /out/modules.tar
btrfs property set -ts $W/sys/modules/$KREL ro true
echo version=1 > $W/sys/state/format
printf "current=d1\nprevious=\ncandidate=\ntries=0\nstaged=\n" > $W/sys/state/deploy
umount $W/sys
truncate -s 200M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 -L userdata $W/ud.img
mkdir -p $W/ud && mount -t ext4 -o loop $W/ud.img $W/ud
d=$W/ud/media/glassine/deployments/d1; mkdir -p $d/build $d/switch $d/work
printf "base=b1\nkind=install\ncreated=qtest\n" > $d/meta
umount $W/ud
rm -f /out/disk.img; truncate -s 840M /out/disk.img
sgdisk -o -n 1:2048:+600M -c 1:system -n 2:0:+200M -c 2:userdata /out/disk.img >/dev/null
n=1
for img in sys ud; do
    s=$(sgdisk -i $n /out/disk.img | sed -n "s/^First sector: \([0-9]*\).*/\1/p")
    dd if=$W/$img.img of=/out/disk.img bs=512 seek="$s" conv=notrunc,sparse status=none
    n=$((n + 1))
done
rm -f /out/base.tar /out/modules.tar
umount $W
echo "disk: $(du -h /out/disk.img | cut -f1) used"
'

KVM='' ACCEL='-accel tcg -cpu max'
if [ -c /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then KVM='--device /dev/kvm'; ACCEL='-accel kvm -cpu host'
else echo "no usable /dev/kvm: QEMU emulates the CPU (TCG)"; fi
boot() {    # boot N DISK-DEVICE INITRAMFS EXTRA-CMDLINE: one boot under OVMF, until it powers off
    echo "--- boot $1 ($2, $3)"
    b0=$(date +%s) rc=0
    # shellcheck disable=SC2086  # KVM: one option and its value, or nothing
    docker run --rm $KVM --platform linux/amd64 -v "$OUT":/out alpine:3.22 sh -c "apk add -q qemu-system-x86_64 ovmf >/dev/null && \
        cp /usr/share/OVMF/OVMF_VARS.fd /tmp/vars.fd && \
        timeout $TO qemu-system-x86_64 -M q35 $ACCEL -smp 2 -m 1024 -nographic -no-reboot \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file=/tmp/vars.fd \
        -kernel /out/vmlinuz -initrd /out/$3 \
        -append 'console=ttyS0 rdinit=/init panic=10 $4' \
        -drive if=none,id=d,file=/out/disk.img,format=raw $2 \
        " > "$OUT/boot$1.log" 2>&1 || rc=$?
    grep -a 'QTEST\|glassine-boot:' "$OUT/boot$1.log" | sed 's/\r$//'
    if grep -aq 'efi: EFI v' "$OUT/boot$1.log"; then echo "QTEST ok boot $1: started by UEFI firmware" | tee -a "$OUT/boot$1.log"
    else echo "QTEST FAIL boot $1: started by UEFI firmware (no \"efi: EFI v\" line)" | tee -a "$OUT/boot$1.log"; fi
    if [ $rc = 0 ]; then echo "QTEST ok boot $1: powered off by itself ($(($(date +%s) - b0)) s)" | tee -a "$OUT/boot$1.log"
    else echo "QTEST FAIL boot $1: powered off by itself (qemu exit $rc; 124 = the limit of $TO s)" | tee -a "$OUT/boot$1.log"; fi
}
ck() {      # ck N PATTERN WHAT: a line the boot must have printed
    if grep -aq "$2" "$OUT/boot$1.log"; then echo "QTEST ok boot $1: $3" | tee -a "$OUT/boot$1.log"
    else echo "QTEST FAIL boot $1: $3" | tee -a "$OUT/boot$1.log"; fi
}
boot 1 '-device virtio-blk-pci,drive=d' initramfs.cpio.gz qtest.disk=virtio_blk
ck 1 'QTEST DONE' 'the check script ran to its end'
boot 2 '-device nvme,serial=qtest,drive=d' initramfs.cpio.gz qtest.disk=nvme
ck 2 'QTEST DONE' 'the check script ran to its end'
boot 3 '-device virtio-blk-pci,drive=d' initramfs-only.cpio.gz ''
ck 3 'root partition system not found' 'without the boot modules: the system partition is not found'
ck 3 'default boot FAILED' 'without the boot modules: the default boot fails (and powers off)'
if grep -aq 'glassine-boot: boot modules' "$OUT/boot3.log"; then echo "QTEST FAIL boot 3: no boot-modules step without the archive" | tee -a "$OUT/boot3.log"
else echo "QTEST ok boot 3: no boot-modules step without the archive" | tee -a "$OUT/boot3.log"; fi
pass=$(cat "$OUT"/boot*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$OUT"/boot*.log | grep -ac 'QTEST FAIL' || true)
echo "qemu x86_64 (UEFI): $pass ok, $fail FAIL"
[ "$fail" = 0 ] && [ "$pass" -ge 20 ]
