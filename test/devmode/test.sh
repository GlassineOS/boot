#!/bin/sh
# Host test of glassine-devmode (developer access in the booted system) with
# stubs for the network, the address server, the SSH server and ssh-keygen.
#   test.sh            exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
P=$(cd "$D/../.." && pwd)
docker run --rm -v "$P":/p:ro alpine:3.22 sh /p/test/devmode/inner.sh
