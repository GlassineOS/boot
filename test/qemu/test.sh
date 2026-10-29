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
#      accepted deployment
# The virt kernel has no watchdog driver, so the watchdog stop around the
# resume write is covered by test/root only.
# Slow (minutes per boot, emulated) and not part of `make check`. Needs
# Docker with privileged containers and arm64 emulation (binfmt).
#   test.sh [OUTDIR]    exit 0 = every QTEST check passed; logs in OUTDIR
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
OUT=$(mkdir -p "${1:-$D/out}" && cd "${1:-$D/out}" && pwd)
docker run --rm --privileged --platform linux/arm64 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh files
docker run --rm --privileged --platform linux/amd64 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh disk
boot() {    # boot N EXTRA-CMDLINE: one boot, until the guest powers off
    echo "--- boot $1 ${2:-}"
    docker run --rm -v "$OUT":/out alpine:3.22 sh -c "apk add -q qemu-system-aarch64 >/dev/null && \
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
pass=$(cat "$OUT"/boot*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$OUT"/boot*.log | grep -ac 'QTEST FAIL' || true)
done=$(grep -ac 'QTEST DONE' "$OUT/boot4.log" || true)
sw=$(grep -ac 'glassine-switch: .* boots next' "$OUT/boot1.log" || true)
echo "qemu: $pass ok, $fail FAIL, switch at shutdown: $sw, done: $done"
[ "$fail" = 0 ] && [ "$done" = 1 ] && [ "$sw" = 1 ] && [ "$pass" -ge 25 ]
