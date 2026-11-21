#!/bin/sh
# Inside the container (test.sh): the services installed as on a system, the
# dependency tree cached, then read.
set -u
fail=0
mkdir -p /run/openrc
# as on a system, not in a container: OpenRC drops the services a container
# lacks (localmount: keyword -docker), and everything that needs them, otherwise
sed -i '/^rc_sys=/d' /etc/rc.conf; echo 'rc_sys=""' >> /etc/rc.conf
for f in /p/openrc/*; do install -m755 "$f" /etc/init.d/; done
/usr/libexec/rc/bin/rc-depend -u >/dev/null 2>&1
T=/run/openrc/deptree
# needs SERVICE DEP: SERVICE's ineed list in the tree names DEP
needs() {
    n=$(sed -n "s/^depinfo_\([0-9]*\)_service='$1'\$/\1/p" "$T")
    [ -n "$n" ] && grep -qx "depinfo_${n}_ineed_[0-9]*='$2'" "$T"
}
# localmount's stop stops a service that needs it and waits, with rc_parallel
# too; `after *` only orders a stop that has already begun
for s in glassine-deploy-accept glassine-bootimg-promote; do
    if needs "$s" localmount; then echo "ok   $s needs localmount (its stop writes a partition first)"
    else echo "FAIL $s needs localmount (its stop writes a partition first)"; fail=1; fi
done
# the check itself: need and after told apart
if needs glassine-first-start localmount && ! needs glassine-devmode localmount; then
    echo "ok   the check tells need (glassine-first-start) from after (glassine-devmode)"
else echo "FAIL the check tells need (glassine-first-start) from after (glassine-devmode)"; fail=1; fi
exit $fail
