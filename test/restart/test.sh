#!/bin/sh
# Host test of the soft restart (specs/013): the restart step's decision and
# phases (glassine-deploy restart), the boot-success step's healthy record, the
# hibernate interlock, and the soft start itself (initramfs/soft) run as PID 1 of
# its own PID and mount namespaces, on a real btrfs system partition and ext4
# userdata (loop devices) with overlayfs on top. Needs a privileged container.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.24 sh -c 'apk add -q btrfs-progs e2fsprogs e2fsprogs-extra busybox-static util-linux-misc >/dev/null 2>&1; sh /p/test/restart/inner.sh'
