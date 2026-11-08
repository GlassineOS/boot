#!/bin/sh
# End-to-end test of the deployments layout in QEMU (arm64, emulated): the
# real initramfs boots a real OpenRC system from a btrfs system partition and
# an ext4 userdata.
#
# Default: the harness builds its own base (Alpine + OpenRC + this repository
# installed) and runs four boots:
#   1  d1 boots; reset, a change after it, a user shutdown (the switch runs
#      in the shutdown runlevel)
#   2  the reset boots as the candidate with the carried state; accept;
#      hibernate
#   3  the initramfs resumes it (memory state kept); hibernate again
#   4  glassine.noresume: the image is cancelled, a fresh boot of the
#      accepted deployment
# The virt kernel has no watchdog driver, so the watchdog stop around the
# resume write is covered by test/root only.
#
# --base FILE: an outside base instead (a base's full send stream, .btrfs.zst,
# as an image builder makes it). The disk step receives it with btrfs receive
# into bases/ (so it has a received UUID, as on a device); the harness's agent
# (agent-base.sh) and its test configuration go into the first deployment's
# own build layer, never into the base; the guest runs the base's own
# glassine-deploy. Boots until the agent says DONE (at most --boots), with a
# file system check of both partitions after every boot. --base2 FILE is a
# second base's delta stream against the first: the agent receives and stages
# it on the first boot. --base2-file PATH is a file that only the second base
# has (checked on its candidate). Without --base2 the agent stops after the
# first boot. The hibernation scenarios need this repository's code in the
# base and run on the default path only. See docs/testing.md.
#
# Slow (minutes per boot, emulated) and not part of `make check`. Needs
# Docker with privileged containers, and arm64 emulation (binfmt) on a
# non-arm64 host. The outside-base mode also needs the network in the guest
# (QEMU user networking) for the live package and its replay.
#   test.sh [--base FILE [--base2 FILE] [--base2-file PATH] [--boots N] [--keep-going]] [OUTDIR]
#   exit 0 = every QTEST check passed; logs in OUTDIR (boot<N>.log, and fsck<N>.log with --base)
#   QTEST_BOOT_TIMEOUT: seconds per boot (default 1500, or 900 with --base)
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
BASE='' BASE2='' BASE2_FILE='' BOOTS=12 KEEP=0 OUTARG=''
while [ $# -gt 0 ]; do
    case $1 in
    --base|--base2|--base2-file|--boots) [ $# -ge 2 ] || { echo "test.sh: $1 needs a value" >&2; exit 2; } ;;
    esac
    case $1 in
    --base) BASE=$2; shift ;;
    --base2) BASE2=$2; shift ;;
    --base2-file) BASE2_FILE=$2; shift ;;
    --boots) BOOTS=$2; shift ;;
    --keep-going) KEEP=1 ;;
    -*) sed -n 's/^#   //p' "$0" >&2; exit 2 ;;
    *) OUTARG=$1 ;;
    esac
    shift
done
[ -n "$BASE" ] || [ -z "$BASE2$BASE2_FILE" ] || { echo "test.sh: --base2 and --base2-file need --base" >&2; exit 2; }
OUT=$(mkdir -p "${OUTARG:-$D/out}" && cd "${OUTARG:-$D/out}" && pwd)
# the disk step runs on the host's own architecture (btrfs ioctls don't pass user emulation)
case $(uname -m) in aarch64|arm64) NATIVE=arm64 ;; *) NATIVE=amd64 ;; esac

if [ -z "$BASE" ]; then
docker run --rm --privileged --platform linux/arm64 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh files
docker run --rm --privileged --platform linux/$NATIVE -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh disk
boot() {    # boot N EXTRA-CMDLINE: one boot, until the guest powers off
    echo "--- boot $1 ${2:-}"
    docker run --rm --platform linux/$NATIVE -v "$OUT":/out alpine:3.22 sh -c "apk add -q qemu-system-aarch64 >/dev/null && \
        timeout ${QTEST_BOOT_TIMEOUT:-1500} qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 2 -m 768 -nographic -no-reboot \
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
exit
fi

# --- an outside base --------------------------------------------------------------
abs() { (cd "$(dirname "$1")" && echo "$PWD/${1##*/}"); }
[ -r "$BASE" ] || { echo "test.sh: cannot read $BASE" >&2; exit 2; }
[ -z "$BASE2" ] || [ -r "$BASE2" ] || { echo "test.sh: cannot read $BASE2" >&2; exit 2; }
case $BASE2_FILE in ''|/*) ;; *) echo "test.sh: --base2-file needs an absolute path" >&2; exit 2 ;; esac
case $BOOTS in ''|*[!0-9]*) echo "test.sh: --boots needs a number" >&2; exit 2 ;; esac
IN="-v $(abs "$BASE"):/in/base.btrfs.zst:ro"
[ -z "$BASE2" ] || IN="$IN -v $(abs "$BASE2"):/in/base2.btrfs.zst:ro"
rm -f "$OUT"/boot*.log "$OUT"/fsck*.log
t0=$(date +%s)
docker run --rm --privileged --platform linux/arm64 -e QTEST_BASE=1 -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh files
t1=$(date +%s)
# shellcheck disable=SC2086  # IN: -v options, no spaces inside one
docker run --rm --privileged --platform linux/$NATIVE -e QTEST_BASE=1 -e "QTEST_BASE2_FILE=$BASE2_FILE" \
    $IN -v "$P":/p:ro -v "$OUT":/out alpine:3.22 sh /p/test/qemu/build.sh disk
t2=$(date +%s)
echo "time files $((t1 - t0)) s, disk $((t2 - t1)) s"
TO=${QTEST_BOOT_TIMEOUT:-900}
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo "--- boot $n"
    b0=$(date +%s)
    rc=0
    docker run --rm --platform linux/$NATIVE -v "$OUT":/out alpine:3.22 sh -c "apk add -q qemu-system-aarch64 >/dev/null && \
        timeout $TO qemu-system-aarch64 -M virt -cpu cortex-a57 -smp 4 -m 1536 -nographic -no-reboot \
        -kernel /out/Image -initrd /out/initramfs.cpio.gz \
        -append 'console=ttyAMA0 rdinit=/init panic=10' \
        -drive if=none,id=d,file=/out/disk.img,format=raw -device virtio-blk-pci,drive=d \
        -nic user,model=virtio-net-pci \
        " > "$OUT/boot$n.log" 2>&1 || rc=$?
    b1=$(date +%s)
    grep -a 'QTEST\|glassine-switch:\|glassine-deploy-accept:\|glassine-boot:\|glassine-deploy:' "$OUT/boot$n.log" | sed 's/\r$//'
    # FR-004: a boot that doesn't power off within its time limit fails
    if [ $rc = 0 ]; then
        echo "QTEST ok boot $n: powered off by itself ($((b1 - b0)) s)" | tee "$OUT/fsck$n.log"
    else
        echo "QTEST FAIL boot $n: powered off by itself (qemu exit $rc after $((b1 - b0)) s; 124 = the limit of $TO s)" | tee "$OUT/fsck$n.log"
    fi
    # both file systems as the next boot finds them (a clean power-off)
    docker run --rm --privileged --platform linux/$NATIVE -v "$P":/p:ro -v "$OUT":/out alpine:3.22 \
        sh /p/test/qemu/build.sh fsck "$n" >> "$OUT/fsck$n.log" 2>&1 || :
    grep -a 'QTEST' "$OUT/fsck$n.log" | sed 1d
    [ "$(grep -ac 'QTEST .* after boot' "$OUT/fsck$n.log")" = 2 ] ||
        echo "QTEST FAIL after boot $n: the file system check ran (see fsck$n.log)" | tee -a "$OUT/fsck$n.log"
    grep -aq 'QTEST DONE' "$OUT/boot$n.log" && break
    if grep -aq 'QTEST FAIL' "$OUT/boot$n.log" "$OUT/fsck$n.log" && [ $KEEP = 0 ]; then
        echo "stopping after boot $n: a check failed"; break
    fi
    [ $rc = 0 ] || break
done
pass=$(cat "$OUT"/boot*.log "$OUT"/fsck*.log | grep -ac 'QTEST ok' || true)
fail=$(cat "$OUT"/boot*.log "$OUT"/fsck*.log | grep -ac 'QTEST FAIL' || true)
done=$(cat "$OUT"/boot*.log | grep -ac 'QTEST DONE' || true)
echo "qemu (outside base): $n boots, $pass ok, $fail FAIL, done: $done, $(( $(date +%s) - t0 )) s"
[ "$fail" = 0 ] && [ "$done" = 1 ]
