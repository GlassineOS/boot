#!/bin/sh
# test/reboot: reboot hands a reason to glassine-reboot-clean; that leaves the
# reason for the shutdown's last service and hands the shutdown to init;
# glassine-reboot-reason (its start, as openrc-run calls it) reboots with that
# reason. busybox's reboot, init's reboot and glassine-reboot are stubs that log
# their call. Runs in a plain Alpine container.
set -u
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
W=/w; rm -rf $W; mkdir -p $W/bin $W/run $W/runlevels/shutdown
C=$W/calls
printf '#!/bin/sh\necho "init-reboot $*" >> %s\n' $C > $W/bin/init-reboot
printf '#!/bin/sh\necho "glassine-reboot $*" >> %s\n' $C > $W/bin/glassine-reboot
chmod +x $W/bin/*
export GLASSINE_REBOOT_REASON_FILE=$W/run/reason GLASSINE_RUNLEVELS=$W/runlevels \
	GLASSINE_INIT_REBOOT=$W/bin/init-reboot GLASSINE_REBOOT=$W/bin/glassine-reboot
rc() { : > $C; sh /p/sbin/glassine-reboot-clean "$@" 2> $W/err; }
# the service's start as openrc-run runs it: its functions, then start
svc() { : > $C; ( ebegin() { :; }; ewarn() { echo "$*" >> $W/warn; }; . /p/openrc/glassine-reboot-reason; start ) 2>&1; }

ok "no reason: a plain reboot, no reason file" "rc && [ \"\$(cat $C)\" = 'init-reboot ' ] && [ ! -e $W/run/reason ]"
ok "a reason without the service in the shutdown runlevel: exit 1, said, no reboot" \
	"rc recovery; [ \$? = 1 ] && [ ! -s $C ] && grep -q 'not in the shutdown runlevel' $W/err && [ ! -e $W/run/reason ]"
ln -s /etc/init.d/glassine-reboot-reason $W/runlevels/shutdown/glassine-reboot-reason
ok "a bad reason: exit 2, no reboot" "rc 'rec overy'; [ \$? = 2 ] && [ ! -s $C ]"
ok "recovery: the reason written, then init's plain reboot" "rc recovery && [ \"\$(cat $W/run/reason)\" = recovery ] && [ \"\$(cat $C)\" = 'init-reboot ' ]"
ok "the shutdown's last service: reboots with that reason" "svc; [ \"\$(cat $C)\" = 'glassine-reboot recovery' ]"
rm -f $W/run/reason
ok "the service without a reason file: nothing (init's reboot or power-off follows)" "svc; [ ! -s $C ]"
printf 'a b\n' > $W/run/reason
ok "the service with a bad reason in the file: ignored, warned" "rm -f $W/warn; svc; [ ! -s $C ] && grep -q 'bad reboot reason' $W/warn"

# reboot: busybox reboot without a reason, glassine-reboot-clean with one
printf '#!/bin/sh\necho "busybox-reboot $*" >> %s\n' $C > $W/bin/busybox-reboot
printf '#!/bin/sh\necho "clean $* init=$GLASSINE_INIT_REBOOT" >> %s\n' $C > $W/bin/clean
chmod +x $W/bin/*
export GLASSINE_BUSYBOX_REBOOT=$W/bin/busybox-reboot GLASSINE_REBOOT_CLEAN=$W/bin/clean
rb() { : > $C; sh /p/sbin/reboot "$@" 2> $W/err; }
ok "reboot: busybox reboot" "rb && [ \"\$(cat $C)\" = 'busybox-reboot ' ]"
ok "reboot -d 5 -n: busybox reboot, options kept (5 is no reason)" "rb -d 5 -n && [ \"\$(cat $C)\" = 'busybox-reboot -d 5 -n' ]"
ok "reboot bootloader: glassine-reboot-clean, its init reboot = busybox" \
	"rb bootloader && [ \"\$(cat $C)\" = \"clean bootloader init=$W/bin/busybox-reboot\" ]"
ok "reboot -f recovery: glassine-reboot at once" "rb -f recovery && [ \"\$(cat $C)\" = 'glassine-reboot recovery' ]"
ok "reboot -d 5 recovery: exit 2, no reboot" "rb -d 5 recovery; [ \$? = 2 ] && [ ! -s $C ]"
ok "reboot a b: exit 2, no reboot" "rb a b; [ \$? = 2 ] && [ ! -s $C ]"
ok "reboot Boot: bad reason, exit 2, no reboot" "rb Boot; [ \$? = 2 ] && [ ! -s $C ]"
rm -f $W/run/reason
ok "reboot bootloader end to end: the reason written, then busybox reboot" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb bootloader && [ \"\$(cat $W/run/reason)\" = bootloader ] && [ \"\$(cat $C)\" = 'busybox-reboot ' ]"
echo "$fails failed"
[ "$fails" = 0 ]
