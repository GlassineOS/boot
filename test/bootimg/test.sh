#!/bin/sh
# Host test of glassine-bootimg's state machine (install / reboot-test / promote /
# fail / deferred / retry / rollback) in an Alpine container (busybox sh as on
# the device): both slots are 64 MiB files, /proc/cmdline a file, the
# kernel a gzip with a "Linux version" string, health forced by GLASSINE_BI_HEALTH.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q python3 >/dev/null 2>&1; sh /p/test/bootimg/inner.sh'
