#!/bin/sh
# Host test of lib/glassine-root.sh and glassine-deploy reset/accept on real
# file systems: a btrfs system partition and an ext4 userdata as loop devices,
# overlayfs on top. Needs a privileged container (loop devices, mounts); only
# busybox tools in the container, as on the device and in the recovery.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q btrfs-progs e2fsprogs e2fsprogs-extra zstd >/dev/null 2>&1; sh /p/test/root/inner.sh'
