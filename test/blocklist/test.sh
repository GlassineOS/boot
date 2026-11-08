#!/bin/sh
# Host test of the block-list hand-off's library (lib/glassine-blocklist and the
# record helpers of lib/glassine-kernel.sh) on a real ext4 file system on a loop
# device, read back through the raw device, and by a simulated bootloader reader.
# Needs a privileged container (loop devices, mounts).
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm --privileged -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q python3 e2fsprogs e2fsprogs-extra >/dev/null 2>&1; sh /p/test/blocklist/inner.sh; a=$?; echo "--- the commands (commands.sh)"; sh /p/test/blocklist/commands.sh; b=$?; [ "$a" = 0 ] && [ "$b" = 0 ]'
