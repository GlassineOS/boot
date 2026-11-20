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
	GLASSINE_INIT_REBOOT=$W/bin/init-reboot GLASSINE_REBOOT=$W/bin/glassine-reboot \
	GLASSINE_SHUTDOWN_RECORD=$W/run/glassine/shutdown
SR=$W/run/glassine/shutdown
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

# --- the shutdown record (docs/deployments.md "Runtime directory") ------------------
# init's reboot stand-in also logs the record it sees when it is called
printf '#!/bin/sh\necho "init-reboot $* [$(cat %s 2>/dev/null)]" >> %s\n' $SR $C > $W/bin/init-rec
printf '#!/bin/sh\necho "init-reboot-fail $* [$(cat %s 2>/dev/null)]" >> %s\nexit 1\n' $SR $C > $W/bin/init-recfail
printf '#!/bin/sh\necho "busybox-reboot $* [$(cat %s 2>/dev/null)]" >> %s\n' $SR $C > $W/bin/busybox-reboot
printf '#!/bin/sh\necho "busybox-poweroff $* [$(cat %s 2>/dev/null)]" >> %s\n' $SR $C > $W/bin/busybox-poweroff
printf '#!/bin/sh\necho "busybox-halt $* [$(cat %s 2>/dev/null)]" >> %s\n' $SR $C > $W/bin/busybox-halt
printf '#!/bin/sh\necho "glassine-reboot $* [$(cat %s 2>/dev/null)]" >> %s\n' $SR $C > $W/bin/glassine-reboot
printf '#!/bin/sh\necho "glassine-reboot-fail $*" >> %s\nexit 1\n' $C > $W/bin/glassine-reboot-fail
chmod +x $W/bin/*
export GLASSINE_INIT_REBOOT=$W/bin/init-rec GLASSINE_BUSYBOX_POWEROFF=$W/bin/busybox-poweroff GLASSINE_BUSYBOX_HALT=$W/bin/busybox-halt
unset GLASSINE_REBOOT_CLEAN
rm -rf $W/run/glassine $W/run/reason; echo 0 > $W/mark.rc; echo 3 > $W/can.rc
po() { : > $C; _po=$1; shift; sh "/p/sbin/$_po" "$@" 2> $W/err; }
ok "record: reboot (no reason) writes next=restart before busybox reboot, the directory made" "po reboot && [ \"\$(cat $C)\" = 'busybox-reboot  [next=restart]' ] && [ \"\$(cat $SR)\" = next=restart ] && [ ! -e $SR.new ]"
echo next=other > $SR
ok "record: reboot (no reason) keeps a record a caller wrote first" "po reboot -f && [ \"\$(cat $C)\" = 'busybox-reboot -f [next=other]' ]"
rm -f $SR
ok "record: poweroff writes next=poweroff, then busybox poweroff with the same arguments" "po poweroff -d 2 && [ \"\$(cat $C)\" = 'busybox-poweroff -d 2 [next=poweroff]' ]"
echo next=menu > $SR
ok "record: poweroff keeps a record a caller wrote first" "po poweroff && [ \"\$(cat $C)\" = 'busybox-poweroff  [next=menu]' ]"
rm -f $SR
ok "record: poweroff -f (forced): still written" "po poweroff -f && [ \"\$(cat $C)\" = 'busybox-poweroff -f [next=poweroff]' ]"
rm -f $SR
ok "record: halt writes next=poweroff, then busybox halt" "po halt && [ \"\$(cat $C)\" = 'busybox-halt  [next=poweroff]' ]"
rm -rf $W/run/glassine; : > $W/run/glassine
ok "record: /run/glassine not writable (a file there): poweroff and reboot go on all the same" "po poweroff && grep -q '^busybox-poweroff' $C && po reboot && grep -q '^busybox-reboot' $C && [ ! -s $W/err ]"
rm -f $W/run/glassine; mkdir -p $W/run/glassine
echo next=restart > $SR
ok "record: reboot-clean bootloader overwrites a record with next=bootloader before its reboot" "rc bootloader && [ \"\$(cat $C)\" = 'init-reboot  [next=bootloader]' ] && [ \"\$(cat $SR)\" = next=bootloader ]"
rm -f $SR $W/run/reason
ok "record: reboot-clean, the reboot doesn't start: exit 1, the record removed" "GLASSINE_INIT_REBOOT=$W/bin/init-recfail rc bootloader; [ \$? = 1 ] && [ \"\$(cat $C)\" = 'init-reboot-fail  [next=bootloader]' ] && [ ! -e $SR ]"
rm -f $W/run/reason
ok "record: reboot-clean with a bad reason (exit 2): no record" "rc 'a b'; [ \$? = 2 ] && [ ! -e $SR ]"
rm $W/runlevels/shutdown/glassine-reboot-reason
ok "record: reboot-clean refused (no glassine-reboot-reason in the runlevel, exit 1): no record" "rc recovery; [ \$? = 1 ] && [ ! -e $SR ]"
ln -s /etc/init.d/glassine-reboot-reason $W/runlevels/shutdown/glassine-reboot-reason
echo 0 > $W/can.rc
ok "record: reboot-clean menu: the request, next=menu, then the reboot" "rc menu && [ \"\$(cat $C)\" = 'mark request menu
init-reboot  [next=menu]' ]"
rm -f $SR
echo 3 > $W/mark.rc
ok "record: reboot-clean menu refused by the loader (exit 3): no record" "rc menu; [ \$? = 3 ] && [ ! -e $SR ]"
echo 0 > $W/mark.rc
ok "record: reboot-clean menu, the reboot doesn't start: the request taken back, the record removed" "GLASSINE_INIT_REBOOT=$W/bin/init-recfail rc menu; [ \$? = 1 ] && [ ! -e $SR ] && tail -n 1 $C | grep -qx 'mark request clear'"
ok "record: reboot-clean recovery (a loader request): next=recovery" "rc recovery && [ \"\$(tail -n 1 $C)\" = 'init-reboot  [next=recovery]' ]"
rm -f $SR $W/run/reason
ok "record: reboot-clean without a reason: next=restart, as reboot" "rc && [ \"\$(cat $C)\" = 'init-reboot  [next=restart]' ]"
echo next=other > $SR
ok "record: reboot-clean without a reason keeps a record that is there" "rc && [ \"\$(cat $SR)\" = next=other ]"
rm -f $SR; echo 3 > $W/can.rc
ok "record: reboot -f bootloader (forced): next=bootloader before glassine-reboot" "GLASSINE_REBOOT_FORCE=1 rc bootloader && [ \"\$(cat $C)\" = 'glassine-reboot bootloader [next=bootloader]' ]"
rm -f $SR
ok "record: forced, glassine-reboot fails: exit 1, the record removed" "GLASSINE_REBOOT=$W/bin/glassine-reboot-fail GLASSINE_REBOOT_FORCE=1 rc bootloader; [ \$? = 1 ] && [ ! -e $SR ]"
echo 0 > $W/can.rc; rm -f $W/run/reason $SR
ok "record: reboot recovery end to end (sbin/reboot -> reboot-clean -> busybox): next=recovery" "GLASSINE_REBOOT_CLEAN=/p/sbin/glassine-reboot-clean po reboot recovery && [ \"\$(tail -n 1 $C)\" = 'busybox-reboot  [next=recovery]' ]"

# --- the cold shutdown step: glassine-mount-ro's keep_screen -----------------------
# the service's functions with stubs for the tool; start's read-only part needs the
# boot libraries, which this container lacks: only what comes before it is judged
printf '#!/bin/sh\necho "store $*" >> %s\nexit $(cat %s/store.rc)\n' $C $W > $W/bin/store
printf '#!/bin/sh\necho "store $*" >> %s\nsleep 30\n' $C > $W/bin/store-hang
chmod +x $W/bin/*
echo 0 > $W/store.rc
mro() { : > $C; ( ebegin() { :; }; eend() { echo "eend $1" >> $W/eend; return "$1"; }; . /p/openrc/glassine-mount-ro; start ) > $W/mro.out 2>&1; }
export GLASSINE_SCREEN_KEEP=$W/run/screen-keep GLASSINE_SPLASH_STORE=$W/bin/store GLASSINE_DEPLOY_CONF=$W/none
rm -f $W/run/screen-keep
ok "shutdown step: no screen-keep: the splash store not called" "mro; ! grep -q store $C"
: > $W/run/screen-keep
ok "shutdown step: screen-keep: glassine-splash-store override --leave --wait 5" "mro; [ \"\$(cat $C)\" = 'store override --leave --wait 5' ]"
echo 1 > $W/store.rc; rm -f $W/eend
ok "shutdown step: the store fails: said, the step goes on to the read-only part" "mro; grep -q 'store override' $C && grep -qx 'eend 1' $W/eend && [ \$(wc -l < $W/eend) -ge 2 ]"
echo 0 > $W/store.rc
ok "shutdown step: the tool not installed: nothing" "GLASSINE_SPLASH_STORE=$W/none mro; [ ! -s $C ]"
export t0; t0=$(date +%s)
ok "shutdown step: a store that hangs is ended by the timeout" "GLASSINE_SPLASH_TIMEOUT=2 GLASSINE_SPLASH_STORE=$W/bin/store-hang mro; [ \$((\$(date +%s) - t0)) -lt 10 ] && grep -q store $C"
mkdir -p /run/glassine; : > /run/glassine/restarting
ok "shutdown step: a soft restart runs (restarting): no override" "mro; [ ! -s $C ]"
rm -f /run/glassine/restarting
echo "$fails failed"
[ "$fails" = 0 ]
