#!/bin/sh
# Host test of the package replay (glassine-deploy stage): real apk in a chroot of
# the new base, real packages from Alpine's repositories, a btrfs system partition
# and an ext4 userdata as loop devices. Needs a privileged container and network.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q btrfs-progs e2fsprogs util-linux >/dev/null 2>&1; sh /p/test/replay/inner.sh'
