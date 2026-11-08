#!/bin/sh
# Host test of glassine-device-seed and lib/glassine-device.sh on plain
# directories (GLASSINE_SEED_FAKE stands in for the partitions) and one vfat
# image on a loop device (privileged). busybox tools for the tool, as on the
# device; python3, dosfstools and mtools only make the test's inputs.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q python3 dosfstools mtools >/dev/null 2>&1; sh /p/test/seed/inner.sh'
