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
ok "reboot -f recovery: glassine-reboot-clean, forced, busybox reboot -f as its init reboot" "rb -f recovery && [ \"\$(cat $C)\" = \"clean recovery init=$W/bin/busybox-reboot -f\" ]"
ok "reboot -d 5 recovery: exit 2, no reboot" "rb -d 5 recovery; [ \$? = 2 ] && [ ! -s $C ]"
ok "reboot a b: exit 2, no reboot" "rb a b; [ \$? = 2 ] && [ ! -s $C ]"
ok "reboot Boot: bad reason, exit 2, no reboot" "rb Boot; [ \$? = 2 ] && [ ! -s $C ]"
rm -f $W/run/reason
ok "reboot bootloader end to end: the reason written, then busybox reboot" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb bootloader && [ \"\$(cat $W/run/reason)\" = bootloader ] && [ \"\$(cat $C)\" = 'busybox-reboot ' ]"

# the loader's requests (menu, recovery): glassine-loader-mark first, then a plain reboot.
# The stand-in logs its calls; $W/mark.rc holds its exit for request, $W/can.rc for can-request
cat > $W/bin/mark <<EOT
#!/bin/sh
echo "mark \$*" >> $C
case \$1 in request) [ "\$2" = clear ] && exit 0; exit \$(cat $W/mark.rc) ;; can-request) exit \$(cat $W/can.rc) ;; esac
EOT
printf '#!/bin/sh\necho "init-reboot-fail $*" >> %s\nexit 1\n' $C > $W/bin/init-fail
chmod +x $W/bin/*
export GLASSINE_LOADER_MARK=$W/bin/mark
echo 0 > $W/mark.rc; echo 0 > $W/can.rc; rm -f $W/run/reason
ok "menu: the request written, then init's plain reboot, no reason file" "rc menu && [ \"\$(cat $C)\" = 'mark request menu
init-reboot ' ] && [ ! -e $W/run/reason ]"
echo 3 > $W/mark.rc
ok "menu where the loader takes none: exit 3, said, no reboot" "rc menu; [ \$? = 3 ] && [ \"\$(cat $C)\" = 'mark request menu' ] && grep -q 'not written: no reboot' $W/err"
echo 1 > $W/mark.rc
ok "menu, the request not written: exit 1, no reboot" "rc menu; [ \$? = 1 ] && [ \"\$(cat $C)\" = 'mark request menu' ]"
echo 0 > $W/mark.rc
ok "menu, the reboot doesn't start: exit 1, the request taken back" "GLASSINE_INIT_REBOOT=$W/bin/init-fail rc menu; [ \$? = 1 ] && [ \"\$(cat $C)\" = 'mark request menu
init-reboot-fail 
mark request clear' ]"
ok "menu without glassine-loader-mark: exit 3, no reboot" "GLASSINE_LOADER_MARK=$W/none rc menu; [ \$? = 3 ] && [ ! -s $C ]"
ok "recovery where the loader takes it: request=recovery, a plain reboot, no reason file" "rc recovery && [ \"\$(cat $C)\" = 'mark can-request recovery
mark request recovery
init-reboot ' ] && [ ! -e $W/run/reason ]"
echo 1 > $W/mark.rc
ok "recovery, the request not written: the bootloader's recovery reason instead" "rc recovery && [ \"\$(cat $W/run/reason)\" = recovery ] && [ \"\$(cat $C)\" = 'mark can-request recovery
mark request recovery
init-reboot ' ] && grep -q \"bootloader's own recovery request\" $W/err"
rm -f $W/run/reason; echo 3 > $W/can.rc
ok "recovery where the loader takes none (no record): the reason, as before" "rc recovery && [ \"\$(cat $W/run/reason)\" = recovery ] && [ \"\$(cat $C)\" = 'mark can-request recovery
init-reboot ' ]"
rm -f $W/run/reason; echo 0 > $W/can.rc; echo 0 > $W/mark.rc
ok "bootloader: no loader request" "rc bootloader && ! grep -q mark $C && [ \"\$(cat $W/run/reason)\" = bootloader ]"
rm -f $W/run/reason
ok "reboot menu end to end: the request, then busybox reboot" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb menu && [ \"\$(cat $C)\" = 'mark request menu
busybox-reboot ' ] && [ ! -e $W/run/reason ]"
ok "reboot -f menu: the request, then busybox reboot -f (never glassine-reboot menu)" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb -f menu && [ \"\$(cat $C)\" = 'mark request menu
busybox-reboot -f' ]"
echo 3 > $W/can.rc
ok "reboot -f recovery with no loader record: glassine-reboot recovery at once" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb -f recovery && [ \"\$(cat $C)\" = 'mark can-request recovery
glassine-reboot recovery' ] && [ ! -e $W/run/reason ]"
echo 0 > $W/can.rc
ok "reboot -f recovery with a record: the request, then busybox reboot -f" \
	"GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean rb -f recovery && [ \"\$(cat $C)\" = 'mark can-request recovery
mark request recovery
busybox-reboot -f' ]"
echo "$fails failed"
[ "$fails" = 0 ]
