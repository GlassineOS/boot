#!/bin/sh
# Host test of the initramfs init: the real init runs in an Alpine container
# (busybox sh), with stubs for mount, the USB servers, reboot/poweroff/
# switch_root and sleep; each stub logs its call. Checks: developer mode off =
# nothing listens on USB and the init boots on; developer mode on = the USB
# services on the board's address, hooks sourced and their stages run; hooks
# are never sourced without developer mode; a second board config (other
# root partition, role word, address, no DHCP) and a missing one. (There is
# no root partition in a container: the default boot itself fails at "not
# found", which is the failure path the checks follow.)
#   test.sh       exit 0 = all checks pass
set -eu
D=$(cd "$(dirname "$0")" && pwd)
M=$(cd "$D/../.." && pwd)
docker run --rm -v "$M":/m:ro alpine:3.22 sh /m/test/initramfs/inner.sh
