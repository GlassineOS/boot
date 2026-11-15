#!/bin/sh
# Host test of glassine-deploy init and glassine-first-start on real file
# systems: a btrfs system partition and a userdata as loop devices, the bare
# boot made by lib/glassine-root.sh's own gr_boot and gr_carry. Needs a
# privileged container (loop devices, mounts).
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q btrfs-progs e2fsprogs e2fsprogs-extra >/dev/null 2>&1; sh /p/test/firststart/inner.sh'
