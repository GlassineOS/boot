#!/bin/sh
# Host test of the OpenRC services' dependencies, read from OpenRC's own dependency
# tree (Alpine's openrc): a service whose stop writes a partition must be stopped
# before localmount also when OpenRC stops services in parallel (rc_parallel).
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh -c 'apk add -q openrc >/dev/null 2>&1; sh /p/test/openrc/inner.sh'
