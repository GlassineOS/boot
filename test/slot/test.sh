#!/bin/sh
# Host test of glassine-slot in an Alpine container: the disk is an image file
# with a GPT made by sgdisk (an independent writer and checker of the tables).
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q build-base linux-headers sgdisk >/dev/null 2>&1; sh /p/test/slot/inner.sh'
