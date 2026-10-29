#!/bin/sh
# Host test of glassine-deploy and lib/glassine-state.sh in an Alpine container
# (busybox sh as on the device). The partitions are files: userdata an ext4
# image (debugfs/dumpe2fs work on files), the system partition's top level a
# plain directory (GLASSINE_DEPLOY_FAKE_MOUNTS: no loop mounts needed).
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q e2fsprogs e2fsprogs-extra >/dev/null 2>&1; sh /p/test/deploy/inner.sh'
