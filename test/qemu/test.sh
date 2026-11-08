#!/bin/sh
# End-to-end test of the deployments layout in QEMU (arm64, emulated): the
# real initramfs boots a real OpenRC system from a btrfs system partition and
# an ext4 userdata, through four boots:
#   1  d1 boots; reset, a change after it, a user shutdown (the switch runs
#      in the shutdown runlevel)
#   2  the reset boots as the candidate with the carried state; accept;
#      hibernate
#   3  the initramfs resumes it (memory state kept); hibernate again
#   4  glassine.noresume: the image is cancelled, a fresh boot of the
#      accepted deployment; a full reset, a user shutdown
#   5  the full reset as the candidate: home and Flatpak's data kept; then
#      flatpak/ on userdata made a file
#   6  the storage step can't make flatpak/: logged, reported, the boot goes on;
#      a device-data list from here on (boots 1-6 have none: no step, the
#      board's DEVICE_PART untouched)
#   7  the initramfs finds no seed, the seed service fills it (a pattern, a
#      rename, directories, a vfat source), the firmware path; hibernate
#      refused while DEVICE_PART is read-write; a copy damaged
#   8  the initramfs binds nothing, the service repairs it; a source changed,
#      refreshed, gone; a grown list, its fill cut off after the manifest's
#      rename (a power cut)
#   9  complete after the cut; a shorter list, a name the kernel provides, a
#      gap in a split image, a source on DEVICE_PART; a refresh cut off before
#      the manifest's rename
#  10  the cut refresh done again at boot; a developer key put in devmode/
#  11  glassine.devmode=usb (dm0, a dummy interface, for the USB gadget): the
#      developer folder, its host key, SSH only on DEVMODE_ADDR, with the key,
#      not with another key or a password; a reset, a user shutdown
#  12  glassine.devmode=usb: the reset's deployment, the same host key, SSH
# Boots 1-10 have no glassine.devmode: no SSH, no address server, no folder made.
# The sources must read the same after every boot (only the test changes them).
# Every boot checks the person's storage (home/, flatpak/ bound from
# userdata, /var/tmp shared, d1's own /home hidden and reported).
# The virt kernel has no watchdog driver, so the watchdog stop around the
# resume write is covered by test/root only.
# Slow (minutes per boot, emulated) and not part of `make check`. Needs
# Docker with privileged containers, and arm64 emulation (binfmt) on a
# non-arm64 host.
#   test.sh [OUTDIR]    exit 0 = every QTEST check passed; logs in OUTDIR
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
OUT=$(mkdir -p "${1:-$D/out}" && cd "${1:-$D/out}" && pwd)
docker run --rm --privileged --platform linux/arm64 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh files
# the disk step runs on the host's own architecture (btrfs ioctls don't pass user emulation)
case $(uname -m) in aarch64|arm64) NATIVE=arm64 ;; *) NATIVE=amd64 ;; esac
docker run --rm --privileged --platform linux/$NATIVE -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh disk
boot() {    # boot N EXTRA-CMDLINE: one boot, until the guest powers off
    echo "--- boot $1 ${2:-}"
    docker run --rm --platform linux/$NATIVE -v "$OUT":/out alpine:3.22 sh -c "apk add -q qemu-system-aarch64 >/dev/null && \
        timeout 1500 qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 768 -nographic -no-reboot \
        -kernel /out/Image -initrd /out/initramfs.cpio.gz \
        -append 'console=ttyAMA0 rdinit=/init panic=10 ${2:-}' \
        -drive if=none,id=d,file=/out/disk.img,format=raw -device virtio-blk-pci,drive=d \
        " > "$OUT/boot$1.log" 2>&1 || echo "(qemu exit $?)"
    grep -a 'QTEST\|glassine-switch:\|glassine-deploy-accept:\|glassine-hibernate:\|glassine-boot:' "$OUT/boot$1.log" | sed 's/\r$//'
}
boot 1
boot 2
boot 3
boot 4 glassine.noresume
boot 5
boot 6
boot 7
boot 8
boot 9
boot 10
boot 11 glassine.devmode=usb
boot 12 glassine.devmode=usb
pass=$(cat "$OUT"/boot*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$OUT"/boot*.log | grep -ac 'QTEST FAIL' || true)
done=$(grep -ac 'QTEST DONE' "$OUT/boot12.log" || true)
sw=$(cat "$OUT/boot1.log" "$OUT/boot4.log" | grep -ac 'glassine-switch: .* boots next' || true)
echo "qemu: $pass ok, $fail FAIL, switch at shutdown: $sw, done: $done"
[ "$fail" = 0 ] && [ "$done" = 1 ] && [ "$sw" = 2 ] && [ "$pass" -ge 71 ]
