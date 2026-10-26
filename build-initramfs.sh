#!/bin/sh
# Build the boot initramfs (initramfs/init + busybox + fsck): the image a
# device package installs for glassine-bootimg (no options), and what an image
# builder extends. Runs inside an arm64 Alpine (the caller provides it) with:
#   busybox-static busybox-extras e2fsprogs cpio gzip
#   + for --helpers: gcc musl-dev linux-headers
#
#   build-initramfs.sh [--board FILE] [--hook FILE]... [--extra DIR] [--helpers SRCDIR] OUT.cpio.gz
#
# --board FILE    the board config, as /etc/glassine-boot/board.conf. Without
#                 it the image has none; glassine-bootimg-pack adds the
#                 device's own when it builds a boot image.
# --hook FILE     a developer-mode hook, as /lib/glassine-boot/hooks.d/<name>
#                 (repeatable; sourced in name order, see initramfs/init)
# --extra DIR     copied to /lib/glassine-boot/extra (files for the hooks);
#                 keeps its own mtimes
# --helpers DIR   every DIR/*.c built static into /bin (CFLAGS: HELPER_CFLAGS)
# Reproducible: sorted entries, owner 0:0, mtimes = SOURCE_DATE_EPOCH
# (default 0) except --extra's, gzip -n.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BOARDF='' HOOKS='' EXTRA='' HELPERS=''
while [ $# -gt 1 ]; do
    case $1 in
    --board) BOARDF=$2; shift 2 ;;
    --hook) case $2 in *.sh) ;; *) echo "build-initramfs.sh: a hook is a *.sh file: $2" >&2; exit 2 ;; esac
            HOOKS="$HOOKS $2"; shift 2 ;;
    --extra) EXTRA=$2; shift 2 ;;
    --helpers) HELPERS=$2; shift 2 ;;
    *) echo "build-initramfs.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
[ $# = 1 ] || { echo "usage: build-initramfs.sh [--board FILE] [--hook FILE]... [--extra DIR] [--helpers SRCDIR] OUT.cpio.gz" >&2; exit 2; }
OUT=$1
EPOCH=${SOURCE_DATE_EPOCH:-0}
I=$(mktemp -d)
trap 'rm -rf "$I"' EXIT

mkdir -p "$I/bin" "$I/lib" "$I/dev" "$I/sbin" "$I/usr/lib"
mknod -m 600 "$I/dev/console" c 5 1
mknod -m 666 "$I/dev/null" c 1 3
cp /bin/busybox.static "$I/bin/busybox"
cp /bin/busybox-extras "$I/bin/"
cp /lib/ld-musl-aarch64.so.1 "$I/lib/"
ln -s ld-musl-aarch64.so.1 "$I/lib/libc.musl-aarch64.so.1"
install -m 755 "$HERE/initramfs/init" "$I/init"
# fsck for the default boot (preen the root fs before mounting it read-write):
# e2fsck as fsck.ext2/3/4, the dynamic binary + its libraries (Alpine has no
# static e2fsck)
cp /sbin/e2fsck "$I/sbin/"
for t in ext2 ext3 ext4; do ln -s e2fsck "$I/sbin/fsck.$t"; done
for l in $(ldd /sbin/e2fsck | sed -n 's/.* => \(\/[^ ]*\) .*/\1/p'); do
    case $l in */ld-musl*|*/libc.musl*) ;; *) cp -L "$l" "$I/usr/lib/" ;; esac
done
if [ -n "$HELPERS" ]; then
    for c in "$HELPERS"/*.c; do
        t=$(basename "$c" .c)
        # shellcheck disable=SC2086
        gcc -static ${HELPER_CFLAGS:--Os -Wall} -o "$I/bin/$t" "$c"
        strip "$I/bin/$t"
    done
fi
for a in watchdog ifconfig seq reboot head sed mount; do
    "$I/bin/busybox" --list | grep -qx "$a" || { echo "busybox.static lacks $a" >&2; exit 1; }
done
for a in telnetd udhcpd httpd; do
    chroot "$I" /bin/busybox-extras --list | grep -qx "$a" || { echo "busybox-extras lacks $a" >&2; exit 1; }
done

if [ -n "$BOARDF" ]; then
    install -D -m 644 "$BOARDF" "$I/etc/glassine-boot/board.conf"
fi
for h in $HOOKS; do
    install -D -m 644 "$h" "$I/lib/glassine-boot/hooks.d/$(basename "$h")"
done
# fixed mtimes for everything but --extra (which keeps its own)
find "$I" -exec touch -h -d "@$EPOCH" {} +
if [ -n "$EXTRA" ]; then
    mkdir -p "$I/lib/glassine-boot/extra"
    cp -a "$EXTRA/." "$I/lib/glassine-boot/extra/"
    touch -h -d "@$EPOCH" "$I/lib/glassine-boot" "$I/lib"
fi
touch -h -d "@$EPOCH" "$I"
(cd "$I" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) > "$OUT"
echo "$OUT: $(stat -c %s "$OUT") bytes${BOARDF:+, board $BOARDF}${HOOKS:+, hooks$HOOKS}${EXTRA:+, extra $EXTRA}"
