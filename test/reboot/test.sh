#!/bin/sh
# Host test of glassine-reboot-clean and the glassine-reboot-reason service with
# stubs for init's reboot and glassine-reboot.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh /p/test/reboot/inner.sh
