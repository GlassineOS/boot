#!/bin/sh
# Host test of the raw form (inner.sh): glassine-boot-raw and the raw backend of
# lib/glassine-bootpart.sh (glassine-loader-mark with BOOT_FORM=raw), judged by
# raw_model.py (a port of the loader's reader) and the loader's golden bytes, in an
# Alpine container (busybox as on the device); privileged, for the part on a loop
# device.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro ${BR_DUMP:+-v "$BR_DUMP":/dump} alpine:3.22 sh -c 'apk add -q python3 >/dev/null 2>&1; BR_PRIV=1 sh /p/test/bootraw/inner.sh'
