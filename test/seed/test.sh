#!/bin/sh
# Host test of glassine-device-seed and lib/glassine-device.sh on plain
# directories (GLASSINE_SEED_FAKE stands in for the partitions). Only busybox
# tools in the container, as on the device.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh /p/test/seed/inner.sh
