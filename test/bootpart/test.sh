#!/bin/sh
# Host test of the uefi hand-off (inner.sh): lib/glassine-bootpart.sh and
# glassine-bootimg with HANDOFF=uefi, judged by loader_model.py (the loader's
# reader) and the installer's golden bytes, in an Alpine container (busybox sh
# as on the device); privileged, for the part on a real FAT file system.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q python3 dosfstools sgdisk >/dev/null 2>&1; BP_PRIV=1 sh /p/test/bootpart/inner.sh'
