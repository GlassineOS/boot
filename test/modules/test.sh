#!/bin/sh
# Host test of build-boot-modules.sh on a real kernel's modules tree: Alpine's
# linux-lts of the container's own architecture (x86-64 or arm64), laid out as
# modules/<release>/, plus small trees made with depmod (everything built in, a
# release that doesn't match its kernel.manifest). See docs/testing.md.
#   test.sh       exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
M=$(cd "$D/../.." && pwd)
docker run --rm ${PLATFORM:+--platform $PLATFORM} -v "$M":/m:ro alpine:3.22 sh /m/test/modules/inner.sh
