#!/bin/sh
set -u
W=/w; mkdir -p $W/run $W/sys $W/ud
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
P=media/glassine
cat > $W/deploy.conf <<CONF
SYSTEM_DEV=$W/system.img
SYSTEM_MNT=$W/sysmnt
USERDATA_DEV=$W/userdata.img
USERDATA_MNT=$W/udmnt
USERDATA_PREFIX=$P
RUN_DIR=$W/run
CONF
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh
st() { $G status --porcelain | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }

# --- the shutdown hook (glassine-switch-hook), on a stub glassine-deploy --------
H=/p/sbin/glassine-switch-hook
HW=$W/hook; mkdir -p $HW/ps $HW/run
printf '#!/bin/sh\ncase $1 in\nstatus) printf "v\\tx\\n%%s\\n" "$(cat %s/status)" ;;\nswitch) echo switch >> %s/calls; exit $(cat %s/rc) ;;\nesac\n' $HW $HW $HW > $HW/deploy; chmod +x $HW/deploy
printf 'RUN_DIR=%s/run\nSWITCH_MIN_CAPACITY=30\n' $HW > $HW/conf
hook() { : > $HW/calls; GLASSINE_DEPLOY_CONF=$HW/conf GLASSINE_DEPLOY=$HW/deploy GLASSINE_POWER_SUPPLY=$HW/ps sh $H "$@" > $HW/out 2>&1; }
psu() { rm -rf $HW/ps/*; for x in "$@"; do n=${x%%:*}; mkdir -p $HW/ps/$n; v=${x#*:}; echo ${v%%=*} > $HW/ps/$n/type; [ "${v%%=*}" = Battery ] && echo ${v#*=} > $HW/ps/$n/capacity || echo ${v#*=} > $HW/ps/$n/online; done; }
echo 0 > $HW/rc
printf 'system_fs=btrfs\tstaged=\n' > $HW/status; psu bat:Battery=80
ok "hook: nothing staged: no switch" "hook && [ ! -s $HW/calls ]"
printf 'system_fs=btrfs\tstaged=r1\n' > $HW/status
ok "hook: staged, shutdown not started by the user: stays staged" "hook && [ ! -s $HW/calls ] && grep -q 'not started by the user' $HW/out"
ok "hook --user-shutdown: marks this shutdown" "hook --user-shutdown && [ -e $HW/run/user-shutdown ]"
psu bat:Battery=20 usb:USB=0
ok "hook: user shutdown, battery 20 %, no charger: stays staged, mark kept" "hook && [ ! -s $HW/calls ] && grep -q 'battery 20 %, below 30' $HW/out && [ -e $HW/run/user-shutdown ]"
psu bat:Battery=20 usb:USB=1
ok "hook: battery 20 % but the charger online: switches" "hook && grep -qx switch $HW/calls && grep -q 'charger usb' $HW/out && [ ! -e $HW/run/user-shutdown ]"
hook --user-shutdown; psu bat:Battery=30 ac:Mains=0
ok "hook: battery at the threshold: switches" "hook && grep -qx switch $HW/calls"
hook --user-shutdown; psu
ok "hook: no battery (a board without one): switches" "hook && grep -qx switch $HW/calls && grep -q 'no battery' $HW/out"
hook --user-shutdown; psu bat:Battery=x
ok "hook: unreadable capacity: stays staged" "hook && [ ! -s $HW/calls ]"
psu bat:Battery=90; echo 5 > $HW/rc
ok "hook: the switch fails: its exit code, said" "hook; [ \$? = 5 ] && grep -q 'switch failed (exit 5): r1 stays staged' $HW/out"
ok "hook: a stray argument: usage, exit 2" "hook --now; [ \$? = 2 ]"

# --- the boot-success step (glassine-deploy-accept), on a stub -----------------
A=/p/sbin/glassine-deploy-accept
AW=$W/acc; mkdir -p $AW/run $AW/health $AW/bin
printf '#!/bin/sh\ncase $1 in\nstatus) printf "v\\tx\\n%%s\\n" "$(cat %s/status)" ;;\naccept) echo "accept $2" >> %s/calls ;;\nesac\n' $AW $AW > $AW/deploy; chmod +x $AW/deploy
printf '#!/bin/sh\n[ "$1" = --crashed ] && cat %s/crashed 2>/dev/null\nexit 0\n' $AW > $AW/bin/rc-status; chmod +x $AW/bin/rc-status
printf 'RUN_DIR=%s/run\nACCEPT_AFTER=120\nACCEPT_HEALTH_DIR=%s/health\n' $AW $AW > $AW/conf
acc() { : > $AW/calls; PATH=$AW/bin:$PATH GLASSINE_DEPLOY_CONF=$AW/conf GLASSINE_DEPLOY=$AW/deploy GLASSINE_ACCEPT_UPTIME=$AW/uptime sh $A > $AW/out 2>&1; }
echo '130.0 1.0' > $AW/uptime; echo c1 > $AW/run/booted
printf 'type=status\tcandidate=c1\ttries=1\n' > $AW/status
printf '#!/bin/sh\nexit 0\n' > $AW/health/10-ok; chmod +x $AW/health/10-ok
ok "accept: the booted candidate, healthy, up long enough: accepted" "acc && grep -qx 'accept c1' $AW/calls"
for kb in trial finishing; do
    echo $kb > $AW/run/kernel-boot
    ok "accept: a kernel $kb boot (the initramfs's kernel-boot): no deployment accept" "acc && [ ! -s $AW/calls ] && grep -q 'a kernel $kb boot' $AW/out"
done
: > $AW/run/kernel-boot
ok "accept: kernel-boot empty: accepted as before" "acc && grep -qx 'accept c1' $AW/calls"
echo c1 > $AW/run/deploy-once
ok "accept: the candidate started by request for this start only (deploy-once): not accepted, said" "acc && [ ! -s $AW/calls ] && grep -q 'c1 runs by request for this start only: no deployment accept' $AW/out"
: > $AW/run/deploy-once
ok "accept: deploy-once empty: accepted as before" "acc && grep -qx 'accept c1' $AW/calls"
printf 'type=status\tcandidate=\ttries=0\n' > $AW/status
ok "accept: the booted one is not the candidate: nothing" "acc && [ ! -s $AW/calls ]"
echo bare:b1 > $AW/run/booted
ok "accept: a bare boot: nothing" "acc && [ ! -s $AW/calls ]"
echo c1 > $AW/run/booted; printf 'type=status\tcandidate=c1\ttries=1\n' > $AW/status
printf '#!/bin/sh\necho epdd not running\nexit 1\n' > $AW/health/20-bad; chmod +x $AW/health/20-bad
ok "accept: a health check fails: not accepted, its reason logged" "! acc && [ ! -s $AW/calls ] && grep -q 'c1 not accepted: epdd not running (tries left: 1)' $AW/out"
rm $AW/health/20-bad; echo sway > $AW/crashed
ok "accept: a crashed service: not accepted" "! acc && [ ! -s $AW/calls ] && grep -q 'crashed: sway' $AW/out"
rm $AW/crashed; printf '#!/bin/sh\nsleep 120\n' > $AW/health/30-slow; chmod +x $AW/health/30-slow
printf '#!/bin/sh\nexit 124\n' > $AW/bin/timeout; chmod +x $AW/bin/timeout
ok "accept: a health check that times out: not accepted" "! acc && grep -q '30-slow: timed out' $AW/out"
rm $AW/health/30-slow $AW/bin/timeout
echo '10.0 1.0' > $AW/uptime
acc & ap=$!
sleep 1
ok "accept: waits while uptime < ACCEPT_AFTER" "[ ! -s $AW/calls ] && kill -0 $ap"
echo '130.0 1.0' > $AW/uptime
ok "accept: then accepts once it is up long enough" "wait $ap && grep -qx 'accept c1' $AW/calls"
printf '#!/bin/sh\ncase $1 in\nstatus) printf "v\\tx\\n%%s\\n" "$(cat %s/status)" ;;\naccept) echo "accept $2" >> %s/calls; [ -e %s/busy ] && exit 6; exit 0 ;;\nesac\n' $AW $AW $AW > $AW/deploy
: > $AW/busy; acc & ap=$!
sleep 1
ok "accept: busy (exit 6): keeps trying" "kill -0 $ap && grep -qx 'accept c1' $AW/calls"
rm $AW/busy
ok "accept: busy, then free: accepted" "wait $ap && [ \$(grep -c 'accept c1' $AW/calls) -ge 2 ]"
printf 'ACCEPT_BUSY_S=0\n' >> $AW/conf; : > $AW/busy
ok "accept: busy past ACCEPT_BUSY_S: not accepted, logged" "! acc && grep -q 'accept c1 failed (exit 6)' $AW/out"
rm $AW/busy
sed -i '/^ACCEPT_BUSY_S=/d' $AW/conf
# the boot slot (SLOT_TOOL): a stub glassine-slot with a status file
printf '#!/bin/sh\ncase $1 in\nstatus) cat %s/slot ;;\nmark-successful) echo mark >> %s/calls; exit $(cat %s/slotrc 2>/dev/null || echo 0) ;;\nesac\n' $AW $AW $AW > $AW/slottool; chmod +x $AW/slottool
printf 'booted=b\nnext=b\nslot=a\tpriority=2\tactive=0\ttries=0\tsuccessful=1\tunbootable=0\nslot=b\tpriority=3\tactive=1\ttries=6\tsuccessful=0\tunbootable=0\n' > $AW/slot
ok "slot: no SLOT_TOOL: the slot is left alone" "acc && ! grep -qx mark $AW/calls"
printf 'SLOT_TOOL=%s\n' $AW/slottool >> $AW/conf
ok "slot: the booted candidate, healthy: slot marked, then accepted" "acc && [ \"\$(tr '\\n' ' ' < $AW/calls)\" = 'mark accept c1 ' ]"
printf 'type=status\tcandidate=\ttries=0\n' > $AW/status
ok "slot: a boot of the current deployment, healthy: slot marked, nothing accepted" "acc && grep -qx mark $AW/calls && ! grep -q accept $AW/calls && grep -q 'boot slot marked successful' $AW/out"
printf '#!/bin/sh\necho epdd not running\nexit 1\n' > $AW/health/20-bad; chmod +x $AW/health/20-bad
ok "slot: unhealthy: the slot is not marked" "! acc && [ ! -s $AW/calls ] && grep -q 'boot slot not marked successful: epdd not running' $AW/out"
rm $AW/health/20-bad
echo 3 > $AW/slotrc
ok "slot: glassine-slot fails: logged, the boot is still fine" "acc && grep -q 'marking the boot slot successful failed (exit 3)' $AW/out"
rm $AW/slotrc
sed -i 's/tries=6\tsuccessful=0/tries=7\tsuccessful=1/' $AW/slot
ok "slot: already successful and no candidate: nothing at all" "acc && [ ! -s $AW/calls ] && [ ! -s $AW/out ]"
echo bare:b1 > $AW/run/booted; sed -i 's/tries=7\tsuccessful=1/tries=6\tsuccessful=0/' $AW/slot
ok "slot: a bare boot: the slot is not marked" "acc && [ ! -s $AW/calls ]"
echo c1 > $AW/run/booted; sed -i '/^SLOT_TOOL=/d' $AW/conf

# --- the library -------------------------------------------------------------
printf 'a=1\nb=2\n' > $W/kv
ok "gs_kv reads a key" "[ \"\$(gs_kv $W/kv b)\" = 2 ]"
ok "gs_kv missing key = empty" "[ -z \"\$(gs_kv $W/kv c)\" ]"
ok "gs_kv missing file = empty, exit 0" "[ -z \"\$(gs_kv $W/nofile a)\" ]"
gs_set $W/kv b 3
ok "gs_set replaces one key, keeps the rest" "[ \"\$(gs_kv $W/kv b)\" = 3 ] && [ \"\$(gs_kv $W/kv a)\" = 1 ] && [ \$(grep -c '^b=' $W/kv) = 1 ]"
ok "gs_set leaves no temp file" "[ -z \"\$(ls $W | grep 'kv.tmp')\" ]"
ok "gs_format_ok 1" "gs_format_ok 1"
ok "gs_format_ok refuses 2, empty, junk" "! gs_format_ok 2 && ! gs_format_ok '' && ! gs_format_ok x1"

# --- status: nothing there ---------------------------------------------------
ok "status, no devices: exit 0, migrated=no, hibernated=unknown" "$G status --porcelain >/dev/null && [ \"\$(st migrated)\" = no ] && [ \"\$(st system_fs)\" = none ] && [ \"\$(st hibernated)\" = unknown ]"
ok "porcelain first line" "[ \"\$($G status --porcelain | head -n 1)\" = 'glassine-deploy 1' ]"
ok "porcelain record starts with type=status" "$G status --porcelain | sed -n 2p | grep -q '^type=status	'"
ok "porcelain paths" "[ \"\$(st swapfile)\" = $P/swap/hibernate ] && [ \"\$(st guard)\" = $P/swap/hibernate.guard ] && [ \"\$(st userdata_prefix)\" = $P ]"
ok "human output: key: value lines" "$G status | grep -q '^migrated: no$'"
ok "usage: exit 2" "$G bogus 2>/dev/null; [ \$? = 2 ]"

# --- status: an ext4 system partition (today's layout): never mounted --------
head -c 8388608 /dev/zero > $W/system.img; mke2fs -q -F -t ext4 $W/system.img
ok "ext4 system: migrated=no, system_fs=ext4" "[ \"\$(st migrated)\" = no ] && [ \"\$(st system_fs)\" = ext4 ]"

# --- status: a migrated system (top level as a directory) --------------------
export GLASSINE_DEPLOY_FAKE_MOUNTS=1
mkdir -p $W/sysmnt/state
echo version=1 > $W/sysmnt/state/format
printf 'current=d2\nprevious=d1\ncandidate=\ntries=0\n' > $W/sysmnt/state/deploy
printf 'current=7.3.0-dev\nprevious=7.2.3-1\n' > $W/sysmnt/state/kernel
ok "migrated: tables" "[ \"\$(st migrated)\" = yes ] && [ \"\$(st format)\" = 1 ] && [ \"\$(st current)\" = d2 ] && [ \"\$(st previous)\" = d1 ] && [ \"\$(st kernel_current)\" = 7.3.0-dev ]"
echo version=2 > $W/sysmnt/state/format
ok "newer format: exit 3, both versions printed, no tables" "$G status --porcelain >$W/o 2>/dev/null; [ \$? = 3 ] && grep -q 'format=2	supported=1' $W/o && ! grep -q 'current=' $W/o"
echo version=x > $W/sysmnt/state/format
ok "junk format: exit 3" "$G status --porcelain >/dev/null 2>&1; [ \$? = 3 ]"
echo version=1 > $W/sysmnt/state/format

# --- hibernation: the swap file on an ext4 userdata image ---------------------
unset GLASSINE_DEPLOY_FAKE_MOUNTS
head -c 33554432 /dev/zero > $W/userdata.img; mke2fs -q -F -t ext4 -b 4096 $W/userdata.img
ok "userdata without a swap file: hibernated=no" "[ \"\$(st hibernated)\" = no ]"
head -c 1048576 /dev/zero > $W/swap; mkswap $W/swap >/dev/null 2>&1
debugfs -w -R "mkdir /media" $W/userdata.img 2>/dev/null; debugfs -w -R "mkdir /$P" $W/userdata.img 2>/dev/null
debugfs -w -R "mkdir /$P/swap" $W/userdata.img 2>/dev/null; debugfs -w -R "write $W/swap /$P/swap/hibernate" $W/userdata.img >/dev/null 2>&1
B=$(gs_dev_block $W/userdata.img $P/swap/hibernate)
ok "gs_dev_block finds the first block" "[ -n \"\$B\" ] && [ \"\$B\" -gt 0 ]"
ok "a plain swap file: SWAPSPACE2, hibernated=no" "[ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ] && [ \"\$(st hibernated)\" = no ]"
printf 'S1SUSPEND\000' | dd of=$W/userdata.img bs=1 seek=$((B * 4096 + 4086)) conv=notrunc 2>/dev/null
ok "a hibernate image: hibernated=yes (unmounted, debugfs)" "[ \"\$(st hibernated)\" = yes ]"
gs_invalidate_dev $W/userdata.img $B
ok "gs_invalidate_dev: SWAPSPACE2 back, hibernated=no" "[ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ] && [ \"\$(st hibernated)\" = no ]"
ok "the file read through the fs sees it too" "debugfs -R 'dump /$P/swap/hibernate $W/back' $W/userdata.img 2>/dev/null; [ \"\$(gs_sig_file $W/back)\" = SWAPSPACE2 ]"
ok "gs_invalidate_dev on a swap file is a no-op" "gs_invalidate_dev $W/userdata.img \$B && [ \"\$(gs_sig_dev $W/userdata.img \$B)\" = SWAPSPACE2 ]"
head -c 33554432 /dev/zero > $W/ud1k.img; mke2fs -q -F -t ext4 -b 1024 $W/ud1k.img
ok "gs_dev_block refuses a 1 KiB block size" "! gs_dev_block $W/ud1k.img $P/swap/hibernate"

# --- hibernation: userdata mounted (file mode) --------------------------------
export GLASSINE_DEPLOY_FAKE_MOUNTS=1
mkdir -p $W/udmnt/$P/swap; cp $W/swap $W/udmnt/$P/swap/hibernate
printf 'S1SUSPEND\000' | dd of=$W/udmnt/$P/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "mounted: hibernated=yes" "[ \"\$(st hibernated)\" = yes ]"
gs_invalidate_file $W/udmnt/$P/swap/hibernate
ok "gs_invalidate_file: hibernated=no, size unchanged" "[ \"\$(st hibernated)\" = no ] && [ \$(wc -c < $W/udmnt/$P/swap/hibernate) = 1048576 ]"

# --- list / select / rollback (fake mounts) ----------------------------------
U=$W/udmnt/$P
for d in d1 d2 d3 d4; do mkdir -p $U/deployments/$d/build; printf 'base=v3.22.%s\nkernel=7.3.0-dev\ncreated=2026-10-2%s\n' ${d#d} ${d#d} > $U/deployments/$d/meta; done
echo failed=1 >> $U/deployments/d3/meta
echo x > $U/deployments/notadir
printf 'current=d2\nprevious=d1\ncandidate=\ntries=0\nextra=keep\n' > $W/sysmnt/state/deploy
D=$W/sysmnt/state/deploy
lst() { $G list --porcelain | grep "	id=$1	" | tr '\t' '\n' | sed -n "s/^$2=//p"; }
ok "list: header + 4 records" "[ \"\$($G list --porcelain | head -n 1)\" = 'glassine-deploy 1' ] && [ \$($G list --porcelain | grep -c '^type=deployment	') = 4 ]"
ok "list: states current/previous/failed/kept" "[ \"\$(lst d2 state)\" = current ] && [ \"\$(lst d1 state)\" = previous ] && [ \"\$(lst d3 state)\" = failed ] && [ \"\$(lst d4 state)\" = kept ]"
ok "list: meta fields + size" "[ \"\$(lst d4 base)\" = v3.22.4 ] && [ \"\$(lst d4 created)\" = 2026-10-24 ] && [ -n \"\$(lst d4 size_kib)\" ]"
ok "list: human table" "$G list | grep -q '^d4 *kept'"
mkdir -p $W/sysmnt/bases/v3.22.2
ok "list: base_present yes for d2, no for d4" "[ \"\$(lst d2 base_present)\" = yes ] && [ \"\$(lst d4 base_present)\" = no ]"
rmdir $W/sysmnt/bases/v3.22.2; rmdir $W/sysmnt/bases 2>/dev/null || :
for n in 1 2 3 4; do mkdir -p $W/sysmnt/bases/v3.22.$n; done     # select needs the base
# the bases' versions as an Alpine base holds them: usr/lib/os-release, etc/os-release
# a relative link to it; v3.22.3 only an etc/os-release file, v3.22.4 a quoted value
for n in 1 2 4; do mkdir -p $W/sysmnt/bases/v3.22.$n/usr/lib $W/sysmnt/bases/v3.22.$n/etc; printf 'NAME="Alpine Linux"\nID=alpine\nVERSION_ID=3.24.%s\nPRETTY_NAME="Alpine Linux v3.24"\n' $n > $W/sysmnt/bases/v3.22.$n/usr/lib/os-release; ln -s ../usr/lib/os-release $W/sysmnt/bases/v3.22.$n/etc/os-release; done
mkdir -p $W/sysmnt/bases/v3.22.3/etc; printf 'ID=alpine\nVERSION_ID=3.24.3\n' > $W/sysmnt/bases/v3.22.3/etc/os-release
sed -i 's/^VERSION_ID=.*/VERSION_ID="3.24.4"/' $W/sysmnt/bases/v3.22.4/usr/lib/os-release
ok "list: version from the base's os-release (a quoted value unquoted; etc/os-release without usr/lib)" "[ \"\$(lst d4 version)\" = 3.24.4 ] && [ \"\$(lst d3 version)\" = 3.24.3 ] && [ \"\$(lst d4 base)\" = v3.22.4 ]"
echo failed=d1 >> $W/sysmnt/state/deploy
ok "list: a failed deployment that is also previous shows failed" "[ \"\$(lst d1 state)\" = failed ]"
ok "status: failed=" "$G status --porcelain | grep -q '	failed=d1'"
sed -i '/^failed=d1$/d' $W/sysmnt/state/deploy

# --- publish: the loader's deployment list (glassine-loader-mark deploys, a stub) ----
MK=$W/markstub
printf '#!/bin/sh\ncase $1 in\nhas-record) [ -e %s/norec ] && exit 3; exit 0 ;;\ndeploys) cat > %s/list; echo "locked=${GLASSINE_LOADER_MARK_LOCKED:-}" > %s/lenv ;;\nesac\n' $W $W $W > $MK; chmod +x $MK
export GLASSINE_LOADER_MARK=$MK
L3=$(printf 'd1 previous 3.24.1\nd3 failed 3.24.3\nd4 kept 3.24.4')
ok "publish: previous, failed, kept as '<id> <state> <version>' (no date), the current one left out, under the state lock" "$G publish && [ \"\$(cat $W/list)\" = \"$L3\" ] && grep -qx locked=1 $W/lenv"
mv $W/sysmnt/bases/v3.22.4 $W/v3.22.4.away
ok "publish: a deployment whose base is gone (it can't start) left out" "$G publish && ! grep -q '^d4 ' $W/list && grep -q '^d3 failed' $W/list"
mv $W/v3.22.4.away $W/sysmnt/bases/v3.22.4
# the label never holds the base id, and a version that is unknown or not plain is left out
ok "publish: no base id in a label" "! grep -q 'v3\\.22' $W/list"
B5=20261119-b56f7a79be473e08; mkdir -p $U/deployments/d5 $W/sysmnt/bases/$B5/usr/lib $W/sysmnt/bases/$B5/etc
printf 'created=2026-11-19T08:00:00Z\nbase=%s\n' $B5 > $U/deployments/d5/meta
d5label() { $G publish && sed -n "s/^d5 kept//p" $W/list; }
ok "publish: a base without an os-release: no label (the loader shows the id)" "[ -z \"\$(d5label)\" ] && grep -qx 'd5 kept' $W/list"
ln -s /etc/os-release $W/sysmnt/bases/$B5/etc/os-release
ok "publish: an os-release that links out of the base is not followed" "[ -z \"\$(d5label)\" ]"
rm $W/sysmnt/bases/$B5/etc/os-release
printf 'VERSION_ID=%s\n' "$(printf '9%.0s' $(seq 1 33))" > $W/sysmnt/bases/$B5/usr/lib/os-release
ok "publish: a version over 32 characters left out" "[ -z \"\$(d5label)\" ]"
printf 'VERSION_ID=3.24 edge\n' > $W/sysmnt/bases/$B5/usr/lib/os-release
ok "publish: a version with a space left out" "[ -z \"\$(d5label)\" ]"
printf 'VERSION_ID=\047%s\047\n' "$(printf '9%.0s' $(seq 1 32))" > $W/sysmnt/bases/$B5/usr/lib/os-release
ok "publish: a version of 32 characters: the label" "l=\$(d5label) && [ \"\$l\" = \" \$(printf '9%.0s' \$(seq 1 32))\" ]"
printf 'base=%s\n' $B5 > $U/deployments/d5/meta; rm $W/sysmnt/bases/$B5/usr/lib/os-release
ok "publish: no version, no created time: no label (the loader shows the id)" "$G publish && grep -qx 'd5 kept' $W/list"
rm -rf $U/deployments/d5 $W/sysmnt/bases/$B5
# the image version of the base manifest comes before the os-release's VERSION_ID
B6=20261120-38363f5cd5d9a23c; mkdir -p $W/sysmnt/bases/$B6/usr/lib $W/sysmnt/bases/$B6/usr/share/glassine
printf 'ID=alpine\nVERSION_ID=3.24.4\n' > $W/sysmnt/bases/$B6/usr/lib/os-release
M6=$W/sysmnt/bases/$B6/usr/share/glassine/base.manifest
printf 'format=1\nbase=%s\nversion=2026.11.20\nlocks=\nneeds=\nfeatures=\n' $B6 > $M6
mkdir -p $U/deployments/d6; printf 'created=2026-11-20T08:15:42Z\nbase=%s\n' $B6 > $U/deployments/d6/meta
d6label() { $G publish && sed -n "s/^d6 kept//p" $W/list; }
ok "publish: the base manifest's image version, not the os-release's VERSION_ID" "[ \"\$(d6label)\" = ' 2026.11.20' ]"
ok "list: version is the image version" "[ \"\$(lst d6 version)\" = 2026.11.20 ]"
sed -i 's/^version=.*/version=2026.11 edge/' $M6
ok "publish: an image version that is not plain: the os-release's VERSION_ID (the same as d4's: with the time)" "[ \"\$(d6label)\" = ' 3.24.4 08:15' ]"
mv $M6 $M6.f; ln -s /usr/share/glassine/base.manifest $M6
ok "publish: a base manifest that is a link is not followed: the os-release's VERSION_ID" "[ \"\$(d6label)\" = ' 3.24.4 08:15' ]"
rm $M6; sed 's/^version=.*/version=2026.11.20/' $M6.f > $M6; rm $M6.f
# equal labels apart: the created time to the minute, then to the second; others unchanged
mkdir -p $U/deployments/d7 $U/deployments/d8 $U/deployments/d9
printf 'created=2026-11-20T09:30:05Z\nbase=%s\n' $B6 > $U/deployments/d7/meta
printf 'created=2026-11-20T09:30:59Z\nbase=%s\n' $B6 > $U/deployments/d8/meta
printf 'created=2026-11-21T10:00:00Z\nbase=%s\n' $B6 > $U/deployments/d9/meta
mkdir -p $U/deployments/da; printf 'created=2026-11-02T07:45:10Z\nbase=v3.22.4\n' > $U/deployments/da/meta
ok "publish: equal labels get the created time, HH:MM, or HH:MM:SS where the minute matches too" "$G publish && grep -qx 'd6 kept 2026.11.20 08:15' $W/list && grep -qx 'd7 kept 2026.11.20 09:30:05' $W/list && grep -qx 'd8 kept 2026.11.20 09:30:59' $W/list && grep -qx 'd9 kept 2026.11.20 10:00' $W/list"
ok "publish: a distribution version that clashes: the time too; one without a created time stays as it is" "grep -qx 'da kept 3.24.4 07:45' $W/list && grep -qx 'd4 kept 3.24.4' $W/list && grep -qx 'd1 previous 3.24.1' $W/list"
ok "publish: every label distinct" "[ -z \"\$(cut -d' ' -f3- $W/list | grep . | sort | uniq -d)\" ]"
printf 'format=1\nbase=%s\nversion=%s\n' $B6 "$(printf '9%.0s' $(seq 1 32))" > $M6
ok "publish: the longest label: 32 + 1 + 8 characters, within the record's 64" "$G publish && l=\$(sed -n 's/^d7 kept //p' $W/list) && [ \"\$l\" = \"\$(printf '9%.0s' \$(seq 1 32)) 09:30:05\" ] && [ \${#l} -eq 41 ]"
rm -rf $U/deployments/d6 $U/deployments/d7 $U/deployments/d8 $U/deployments/d9 $U/deployments/da $W/sysmnt/bases/$B6
sed -i 's/^current=d2$/current=dx/' $D
rm -f $W/list
ok "publish: the current deployment not on userdata: the record's list left as it was, said" "$G publish 2>$W/err && [ ! -e $W/list ] && grep -q 'dx is not on userdata' $W/err"
sed -i 's/^current=dx$/current=d2/' $D
: > $W/norec
ok "publish: a board without a loader record: nothing" "$G publish && [ ! -e $W/list ]"
rm -f $W/norec
$G select d4 >/dev/null
ok "select publishes the list: the candidate after the previous one" "[ \"\$(sed -n 2p $W/list)\" = 'd4 candidate 3.24.4' ] && grep -qx locked=1 $W/lenv"
ok "select d4: candidate=d4 tries=2, current kept, other keys kept" "[ \"\$(gs_kv \$D candidate)\" = d4 ] && [ \"\$(gs_kv \$D tries)\" = 2 ] && [ \"\$(gs_kv \$D current)\" = d2 ] && [ \"\$(gs_kv \$D extra)\" = keep ]"
ok "list: d4 is the candidate" "[ \"\$(lst d4 state)\" = candidate ]"
$G select d2 >/dev/null
ok "select current: candidate cleared" "[ -z \"\$(gs_kv \$D candidate)\" ] && [ \"\$(gs_kv \$D tries)\" = 0 ]"
cp $D $W/before
ok "select unknown id: exit 1, state unchanged" "$G select d9 2>/dev/null; [ \$? = 1 ] && cmp -s $D $W/before"
ok "select a bad id: exit 2" "$G select ../d1 2>/dev/null; [ \$? = 2 ] && cmp -s $D $W/before"
ok "select needs exactly one id: exit 2" "$G select 2>/dev/null; [ \$? = 2 ]"
$G rollback >/dev/null
ok "rollback: candidate = previous" "[ \"\$(gs_kv \$D candidate)\" = d1 ] && [ \"\$(gs_kv \$D tries)\" = 2 ]"
gs_update $D candidate= tries=0 previous=
ok "rollback without a previous: exit 1" "$G rollback 2>/dev/null; [ \$? = 1 ]"
gs_set $D previous d1; cp $D $W/before

# one trial at a time: a kernel candidate (docs/kernel-artifacts.md)
KF=$W/sysmnt/state/kernel
printf 'current=7.0.0\ncandidate=7.1.0\ncandidate_img=abcd\ntries=1\nrequested=abcd\n' > $KF
ok "a kernel candidate: select refuses, exit 8, names glassine-bootimg cancel, nothing changed" "$G select d4 2>$W/err; [ \$? = 8 ] && grep -q 'glassine-bootimg cancel' $W/err && cmp -s $D $W/before && [ \"\$(gs_kv $KF candidate_img)\" = abcd ]"
ok "rollback: the kernel candidate cancelled first, said, then the previous selected" "$G rollback >/dev/null 2>$W/err && grep -q 'kernel candidate 7.1.0 is cancelled first' $W/err && [ -z \"\$(gs_kv $KF candidate)\$(gs_kv $KF candidate_img)\$(gs_kv $KF tries)\$(gs_kv $KF requested)\" ] && [ \"\$(gs_kv $KF current)\" = 7.0.0 ] && [ \"\$(gs_kv \$D candidate)\" = d1 ]"
cp $W/before $D; rm $KF

# refusals must leave the state alone
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "hibernated: select refuses, exit 4, state unchanged" "$G select d4 2>/dev/null </dev/null; [ \$? = 4 ] && cmp -s $D $W/before && [ \"\$(st hibernated)\" = yes ]"
ok "--discard-hibernation without --yes, no terminal: exit 1, image kept" "$G select d4 --discard-hibernation 2>/dev/null </dev/null; [ \$? = 1 ] && cmp -s $D $W/before && [ \"\$(st hibernated)\" = yes ]"
ok "--discard-hibernation --yes: invalidated, then selected" "$G select d4 --discard-hibernation --yes >/dev/null && [ \"\$(st hibernated)\" = no ] && [ \"\$(gs_kv \$D candidate)\" = d4 ]"
cp $D $W/before
: > $W/run/switching
ok "a stale switch marker (no lock holder): removed, select goes on" "$G select d1 >/dev/null 2>&1 && [ ! -e $W/run/switching ] && [ \"\$(gs_kv \$D candidate)\" = d1 ]"
cp $W/before $D
( exec 9>>$W/sysmnt/state/.lock; flock -n 9 && : > $W/held && sleep 5 ) &
while [ ! -e $W/held ]; do sleep 0.1; done
ok "lock held: exit 6, unchanged" "$G select d1 2>/dev/null; [ \$? = 6 ] && cmp -s $D $W/before"
wait; rm -f $W/held
mkdir -p $W/shim; printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' > $W/shim/dd; chmod +x $W/shim/dd
ok "a cut write (dd fails): exit 1, old file intact, no temp file" "PATH=$W/shim:\$PATH $G select d1 2>$W/err; [ \$? = 1 ] && grep -q 'cannot write' $W/err && cmp -s $D $W/before && [ -z \"\$(ls -a $W/sysmnt/state | grep tmp)\" ]"
echo version=2 > $W/sysmnt/state/format
ok "newer format: select, list, rollback exit 3, unchanged" "$G select d1 2>/dev/null; a=\$?; $G list >/dev/null 2>&1; b=\$?; $G rollback 2>/dev/null; c=\$?; [ \$a\$b\$c = 333 ] && cmp -s $D $W/before"
echo version=1 > $W/sysmnt/state/format

# --- hibernate-invalidate -----------------------------------------------------
ok "invalidate, nothing hibernated: exit 0" "$G hibernate-invalidate >/dev/null"
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "invalidate without --yes, no terminal: exit 1, kept" "$G hibernate-invalidate 2>/dev/null </dev/null; [ \$? = 1 ] && [ \"\$(st hibernated)\" = yes ]"
ok "invalidate --yes (mounted): hibernated=no" "$G hibernate-invalidate --yes >/dev/null && [ \"\$(st hibernated)\" = no ]"
unset GLASSINE_DEPLOY_FAKE_MOUNTS
printf 'S1SUSPEND\000' | dd of=$W/userdata.img bs=1 seek=$((B * 4096 + 4086)) conv=notrunc 2>/dev/null
ok "invalidate --yes (unmounted, raw): hibernated=no" "[ \"\$(st hibernated)\" = yes ] && $G hibernate-invalidate --yes >/dev/null && [ \"\$(st hibernated)\" = no ]"

# --- list on unmounted userdata (debugfs) -------------------------------------
debugfs -w -R "mkdir /$P/deployments" $W/userdata.img 2>/dev/null
for d in d1 d2; do debugfs -w -R "mkdir /$P/deployments/$d" $W/userdata.img 2>/dev/null; debugfs -w -R "write $U/deployments/$d/meta /$P/deployments/$d/meta" $W/userdata.img >/dev/null 2>&1; done
ok "list (debugfs): 2 records, meta read, no size" "[ \$($G list --porcelain | grep -c '^type=deployment	') = 2 ] && [ \"\$(lst d2 base)\" = v3.22.2 ] && [ -z \"\$(lst d2 size_kib)\" ]"
ok "select on an ext4 (unmigrated) system: exit 1, says not migrated" "$G select d1 2>$W/err; [ \$? = 1 ] && grep -q 'not migrated' $W/err"
ok "select an unknown id on an unmigrated system: says not migrated" "$G select d9 2>$W/err; [ \$? = 1 ] && grep -q 'not migrated' $W/err"

# --- the account merge (lib/glassine-accounts.sh) -----------------------------
. /p/lib/glassine-accounts.sh
AO=$W/acct/old AN=$W/acct/new AT=$W/acct/out; mkdir -p $AO $AN $AT
printf 'root:x:0:0:root:/root:/bin/sh\nmessagebus:x:100:101::/:/sbin/nologin\npolkitd:x:101:102::/:/sbin/nologin\navahi:x:102:103::/:/sbin/nologin\nuser:x:1000:1000::/home/user:/bin/ash\nguest:x:1001:1001::/home/guest:/bin/ash\n' > $AO/passwd
printf 'root:x:0:root\nwheel:x:10:root,user\nvideo:x:27:user,avahi\nmessagebus:x:101:\npolkitd:x:102:\navahi:x:103:\nuser:x:1000:\nguest:x:1001:\n' > $AO/group
printf 'root:$6$rootpw:1::::::\nuser:$6$userpw:1::::::\nguest:$6$guestpw:1::::::\nmessagebus:!old:1::::::\n' > $AO/shadow
printf 'user:100000:65536\n' > $AO/subuid
printf 'root:x:0:0:root:/root:/bin/sh\nmessagebus:x:101:102::/:/sbin/nologin\npolkitd:x:100:101::/:/sbin/nologin\n' > $AN/passwd
printf 'root:x:0:root\nwheel:x:10:root\nvideo:x:27\nmessagebus:x:102:\npolkitd:x:101:\nsambashare:x:1001:\nshadow:x:42:\n' > $AN/group
printf 'root:*:1::::::\nmessagebus:!:1::::::\npolkitd:!:1::::::\n' > $AN/shadow; chown 0:42 $AN/shadow; chmod 640 $AN/shadow
echo 'carried:x:1:1::/:/bin/false' > $AT/passwd
ga_merge $AO $AN $AT $W/acct/map > $W/acct/report
pw() { awk -F: -v n="$1" '$1 == n' $AT/passwd; }
gr() { awk -F: -v n="$1" '$1 == n' $AT/group; }
sh_() { awk -F: -v n="$1" '$1 == n { print $2 }' $AT/shadow; }
ok "merge: the new base's system accounts, as the base has them" "[ \"\$(pw messagebus)\" = 'messagebus:x:101:102::/:/sbin/nologin' ] && [ \"\$(pw polkitd)\" = 'polkitd:x:100:101::/:/sbin/nologin' ]"
ok "merge: user kept with its uid and gid" "[ \"\$(pw user)\" = 'user:x:1000:1000::/home/user:/bin/ash' ] && [ \"\$(gr user)\" = 'user:x:1000:' ]"
ok "merge: a gid taken in the new base: the next free one, the primary group follows" "[ \"\$(gr guest)\" = 'guest:x:1002:' ] && [ \"\$(pw guest)\" = 'guest:x:1001:1002::/home/guest:/bin/ash' ]"
ok "merge: memberships carried for users that exist (avahi is gone)" "[ \"\$(gr wheel)\" = 'wheel:x:10:root,user' ] && [ \"\$(gr video)\" = 'video:x:27:user' ]"
ok "merge: a system account the new base lacks is not carried, and reported" "[ -z \"\$(pw avahi)\" ] && [ -z \"\$(gr avahi)\" ] && grep -q 'not carried.* avahi' $W/acct/report"
ok "merge: the carried passwd copy is replaced" "! grep -q '^carried:' $AT/passwd"
ok "merge: passwords by name (old first, else the base's)" "[ \"\$(sh_ root)\" = '\$6\$rootpw' ] && [ \"\$(sh_ user)\" = '\$6\$userpw' ] && [ \"\$(sh_ messagebus)\" = '!old' ] && [ \"\$(sh_ polkitd)\" = '!' ] && [ \$(wc -l < $AT/shadow) = \$(wc -l < $AT/passwd) ]"
ok "merge: shadow keeps the base's owner and mode, passwd/group 0644 root" "[ \"\$(stat -c '%u:%g %a' $AT/shadow)\" = '0:42 640' ] && [ \"\$(stat -c '%u:%g %a' $AT/passwd)\" = '0:0 644' ] && [ \"\$(stat -c '%u:%g %a' $AT/group)\" = '0:0 644' ]"
ok "merge: subuid carried" "[ \"\$(cat $AT/subuid)\" = 'user:100000:65536' ] && [ ! -e $AT/subgid ]"
ok "merge: the ID map (swapped system IDs, the moved group)" "[ \"\$(tr '\n' ,  < $W/acct/map)\" = 'g 1001 1002,g 101 102,g 102 101,u 100 101,u 101 100,' ]"
ok "merge: the moved IDs of kept accounts are named (only the guest group; system IDs are not)" "[ \"\$(ga_kept_moves $W/acct/map)\" = 'gid 1001 -> 1002' ] && : > $W/acct/empty0 && [ -z \"\$(ga_kept_moves $W/acct/empty0)\" ]"
ok "merge: no temp files left" "[ -z \"\$(ls $AT | grep '\.ga')\" ]"
R2=$W/acct/tree; mkdir -p $R2/d
echo a > $R2/d/mb; chown 100:101 $R2/d/mb
echo b > $R2/d/pk; chown 101:102 $R2/d/pk
echo c > $R2/d/us; chown 1000:1000 $R2/d/us
echo d > "$R2/d/with space"; chown 1001:1001 "$R2/d/with space"
echo e > $R2/d/suid; chown 100:101 $R2/d/suid; chmod 4755 $R2/d/suid
ln -s mb $R2/d/link; chown -h 101:102 $R2/d/link
nlf="$R2/d/$(printf 'a\nb')"; trf="$R2/d/trail "
echo n > "$nlf"; chown 100:101 "$nlf"
echo t > "$trf"; chown 101:102 "$trf"
ln $R2/d/pk $R2/d/pk-hard
ga_remap $W/acct/map $R2 > $W/acct/rep2
own() { stat -c %u:%g "$R2/d/$1"; }
ok "remap: by the map in one pass (swapped IDs stay right)" "[ \$(own mb) = 101:102 ] && [ \$(own pk) = 100:101 ] && [ \$(own us) = 1000:1000 ]"
ok "remap: names with spaces, links themselves" "[ \"\$(own 'with space')\" = 1001:1002 ] && [ \$(own link) = 100:101 ] && [ \$(own mb) = 101:102 ]"
ok "remap: setuid kept" "[ \$(stat -c %a $R2/d/suid) = 4755 ] && [ \$(own suid) = 101:102 ]"
ok "remap: a newline in a name, a trailing space: just names" "[ \"\$(stat -c %u:%g \"\$nlf\")\" = 101:102 ] && [ \"\$(stat -c %u:%g \"\$trf\")\" = 100:101 ] && [ -e $R2/d/mb ]"
ok "remap: a hard link is one file (the swap is applied once)" "[ \$(own pk-hard) = 100:101 ] && [ \$(own pk) = 100:101 ]"
ok "remap: count (files, a hard link once)" "grep -q 'owners remapped: 7' $W/acct/rep2"
ok "remap with an empty map: nothing" ": > $W/acct/empty && ga_remap $W/acct/empty $R2 | grep -q 'remapped: 0'"
# a failure after shadow.ga exists: it never was readable by others, and nothing is left
mkdir -p $W/shimc $W/acct/o5; cp -p $AN/* $W/acct/o5/ 2>/dev/null; echo 'carried:x:1:1::/:/bin/false' > $W/acct/o5/passwd; echo 'x.ga is theirs' > $W/acct/o5/x.ga
printf '#!/bin/sh\ncase "$2" in *passwd.ga) stat -c %%a "${2%%passwd.ga}shadow.ga" > %s/shmode; exit 1 ;; esac\nexec /bin/chown "$@"\n' $W/acct > $W/shimc/chown; chmod +x $W/shimc/chown
um=$(umask); umask 022
PATH=$W/shimc:$PATH ga_merge $AO $AN $W/acct/o5 $W/acct/m5 >/dev/null 2>&1
# shellcheck disable=SC2034  # read in the eval of ok()
rc5=$?
# shellcheck disable=SC2034  # read in the eval of ok()
um2=$(umask); umask $um
ok "merge: a failure after shadow.ga exists: it was 0600 meanwhile, nothing is left, the old files and a user's own *.ga stay, the caller's umask is back" "[ \$rc5 != 0 ] && [ \"\$(cat $W/acct/shmode)\" = 600 ] && [ -z \"\$(ls $W/acct/o5 | grep -E '^(passwd|group|shadow|subuid|subgid|report)\.ga|\.ga2\$')\" ] && grep -q '^carried:' $W/acct/o5/passwd && [ -e $W/acct/o5/x.ga ] && [ \"\$um2\" = 0022 ]"
ok "merge: a base without passwd: refused" "! ga_merge $AO $W/acct/none $W/acct/o2 $W/acct/m2 2>/dev/null"
# a build layer that holds only what the replay changed: each file by itself
BU=$W/acct/build BL=$W/acct/lower NE=$W/acct/ne; mkdir -p $BU $BL
cp -p $AN/passwd $AN/group $AN/shadow $BL/
printf '%s\nnewsvc:x:200:200::/:/sbin/nologin\n' "$(cat $AN/passwd)" > $BU/passwd
ga_lower $NE $BU $BL
ok "lower: passwd from the build layer, group and shadow from the base, shadow's owner kept" "grep -q '^newsvc:' $NE/passwd && cmp -s $NE/group $AN/group && cmp -s $NE/shadow $AN/shadow && [ \"\$(stat -c %u:%g $NE/shadow)\" = 0:42 ] && [ ! -e $NE/subuid ]"
AT2=$W/acct/out2; mkdir -p $AT2
ga_merge $AO $NE $AT2 $W/acct/map2 > $W/acct/report2
ok "merge over a build layer with only passwd: the base's groups stay, the new account is there" "grep -q '^wheel:' $AT2/group && grep -q '^root:x:0:' $AT2/group && grep -q '^newsvc:' $AT2/passwd && ! grep -q 'not carried.*root' $W/acct/report2 && [ \"\$(stat -c %a $AT2/shadow)\" = 640 ]"
rm -f $BU/passwd; printf '%s\nadm2:x:300:\n' "$(cat $AN/group)" > $BU/group
ga_lower $NE $BU $BL
ok "lower: only group changed in the build layer: its edit is used, passwd from the base" "grep -q '^adm2:' $NE/group && cmp -s $NE/passwd $AN/passwd"
mkdir -p $W/acct/po; cp -p $AN/passwd $W/acct/po/
ok "merge: NEW with a passwd but no group file: refused, nothing written" "! ga_merge $AO $W/acct/po $W/acct/o3 $W/acct/m3 2>/dev/null && [ ! -e $W/acct/o3/group ]"
mkdir -p $W/acct/pg; cp -p $AN/passwd $W/acct/pg/; : > $W/acct/pg/group
ok "merge: NEW with an empty group file: refused" "! ga_merge $AO $W/acct/pg $W/acct/o4 $W/acct/m4 2>/dev/null"
printf 'wheel:x:10:\n' > $W/acct/pg/group
ok "merge: NEW with a group file without gid 0: refused" "! ga_merge $AO $W/acct/pg $W/acct/o4 $W/acct/m4 2>/dev/null"

# --- packages: derived from world + installed db against the base ---------------
export GLASSINE_DEPLOY_FAKE_MOUNTS=1
PB=$W/sysmnt/bases/pb; PV=$W/pview
mkdir -p $PB/etc/apk $PB/lib/apk/db $PV/etc/apk $PV/lib/apk/db $U/deployments/pk
echo base=pb > $U/deployments/pk/meta
printf 'alpine-base sway\nfirefox\n' > $PB/etc/apk/world
printf 'alpine-base\nsway\nretroarch\nvim>=9.1\n' > $PV/etc/apk/world
printf 'P:sway\nV:1.10-r0\nA:aarch64\n\nP:musl\nV:1.2.5-r10\n\nP:mesa\nV:25.1.9-r106\n\nP:firefox\nV:142.0-r0\n\n' > $PB/lib/apk/db/installed
printf 'P:sway\nV:1.10-r0\n\nP:musl\nV:1.2.5-r11\n\nP:mesa\nV:25.1.9-r100\n\nP:retroarch\nV:1.21-r0\n\n' > $PV/lib/apk/db/installed
printf '#!/bin/sh\n[ "$1" = version ] || exit 1\ncase "$3:$4" in 1.2.5-r11:1.2.5-r10) echo ">" ;; 25.1.9-r100:25.1.9-r106) echo "<" ;; *) echo "=" ;; esac\n' > $W/apkstub; chmod +x $W/apkstub
echo pk > $W/run/booted
pk() { GLASSINE_DEPLOY_ROOT=$PV GLASSINE_DEPLOY_APK=$W/apkstub $G packages pk --porcelain; }
ok "packages: header, added world entries (constraints kept)" "pk > $W/pk && head -n 1 $W/pk | grep -qx 'glassine-deploy 1' && grep -qx 'type=package	change=added	entry=retroarch' $W/pk && grep -qx 'type=package	change=added	entry=vim>=9.1' $W/pk"
ok "packages: removed world entries" "grep -qx 'type=package	change=removed	entry=firefox' $W/pk && [ \$(grep -c 'change=removed' $W/pk) = 1 ]"
ok "packages: raised and lowered versions" "grep -qx 'type=package	change=raised	name=musl	version=1.2.5-r11	base_version=1.2.5-r10' $W/pk && grep -qx 'type=package	change=lowered	name=mesa	version=25.1.9-r100	base_version=25.1.9-r106' $W/pk"
ok "packages: unchanged and new packages are not version records" "! grep -q 'name=sway' $W/pk && ! grep -q 'name=retroarch' $W/pk"
ok "packages without apk: changed" "GLASSINE_DEPLOY_ROOT=$PV GLASSINE_DEPLOY_APK=$W/none $G packages pk --porcelain | grep -q 'change=changed	name=musl'"
ok "packages: human output" "GLASSINE_DEPLOY_ROOT=$PV GLASSINE_DEPLOY_APK=$W/apkstub $G packages pk | grep -qx 'raised   musl 1.2.5-r11 (base 1.2.5-r10)'"
ok "packages: an unknown deployment: exit 1; a bad id: exit 2" "$G packages zz 2>/dev/null; a=\$?; $G packages ../x 2>/dev/null; [ \$a\$? = 12 ]"
rm -f $W/run/booted
ok "packages of a deployment that is not running, userdata not mounted: refused" "mv $W/udmnt $W/udmnt.x; $G packages pk 2>$W/err; r=\$?; mv $W/udmnt.x $W/udmnt; [ \$r = 1 ]"

# --- clean-up and remove (fake mounts) -------------------------------------------
rm -rf $U/deployments $U/deployments.removing; mkdir -p $W/sysmnt/bases/gb
mkd() { for d in "$@"; do mkdir -p $U/deployments/$d/build $U/deployments/$d/switch/etc $U/deployments/$d/work; printf 'base=gb\nkind=reset\ncarry=none\n' > $U/deployments/$d/meta; echo x > $U/deployments/$d/switch/etc/f; done; }
mkd c p n s f bt mt k1 k2 oldf
echo failed=1 >> $U/deployments/oldf/meta
printf 'current=c\nprevious=p\ncandidate=n\ntries=1\nstaged=s\nfailed=f\n' > $D
echo bt > $W/run/booted
# the mounted one as the running system's mountinfo shows an overlay (the paths it
# was mounted with), and a decoy whose id only starts with k1
printf '%s\n' '36 25 0:31 / /run/glassine/root rw,relatime shared:9 - overlay overlay rw,lowerdir=/sysroot/media/glassine/deployments/mt/build:/sysroot/bases/gb,upperdir=/sysroot/media/glassine/deployments/mt/switch,workdir=/sysroot/media/glassine/deployments/mt/work' \
    '37 25 0:32 / /run/x rw - overlay overlay rw,upperdir=/u/deployments/k1x/switch,workdir=/u/deployments/k1x/work' > $W/mi
export GLASSINE_DEPLOY_MOUNTINFO=$W/mi
deps() { ls $U/deployments | tr '\n' ' '; }
ok "accept: the clean-up keeps current, previous, candidate, staged, the last failed one, the booted and the mounted one; the rest goes (the old previous by the count of 1)" "$G accept n >$W/out 2>$W/err && [ \"\$(deps)\" = 'bt c f mt n s ' ] && grep -q 'clean-up: removed k1 k2 oldf$' $W/out && grep -q 'deployment p removed: count (this device keeps 1)' $W/out && grep -q 'deployment mt is mounted; not removed' $W/err"
ok "accept: the state is the accept's (previous = the old current), nothing else touched" "[ \"\$(gs_kv \$D current)\" = n ] && [ \"\$(gs_kv \$D previous)\" = c ] && [ \"\$(gs_kv \$D staged)\" = s ] && [ \"\$(gs_kv \$D failed)\" = f ] && [ -z \"\$(gs_kv \$D candidate)\" ]"
ok "accept publishes the list after its clean-up: previous c, failed f, kept bt and mt (no version, no date: no label); not the current n nor the staged s" "[ \"\$(tr '\\n' ' ' < $W/list)\" = 'c previous f failed bt kept mt kept ' ] && grep -qx locked=1 $W/lenv"
ok "clean-up: nothing left in deployments.removing; list shows the mounted one as kept" "[ -z \"\$(ls -A $U/deployments.removing)\" ] && [ \"\$(lst mt state)\" = kept ] && [ \"\$(lst f state)\" = failed ]"
# a switch (carry=none) is a clean-up point too; an rm that is cut off leaves the
# removal out of deployments/, and the next clean-up finishes it
mkd k3; rm -f $W/run/booted
mkdir -p $W/shimrm; printf '#!/bin/sh\ncase "$*" in *deployments.removing/*) exit 1 ;; esac\nexec /bin/rm "$@"\n' > $W/shimrm/rm; chmod +x $W/shimrm/rm
ok "switch: candidate set, then the clean-up; a cut delete: k3 out of the list, its rest in deployments.removing, the switch still exit 0" "PATH=$W/shimrm:\$PATH $G switch >$W/out 2>$W/err && [ \"\$(gs_kv \$D candidate)\" = s ] && [ ! -e $U/deployments/k3 ] && [ -e $U/deployments.removing/k3/meta ] && grep -q 'k3 is gone from the list' $W/err && ! $G list --porcelain | grep -q 'id=k3	'"
ok "the cut switch's clean-up also removed bt (no longer booted), kept the rest" "[ \"\$(deps)\" = 'c f mt n s ' ]"
ok "the next clean-up (a reset) finishes the cut removal" "$G reset --full --yes >/dev/null 2>&1 && [ -z \"\$(ls -A $U/deployments.removing)\" ] && R1=\$(gs_kv \$D staged) && [ -n \"\$R1\" ] && [ -e $U/deployments/\$R1/meta ]"
# shellcheck disable=SC2034  # read in the eval of ok()
R1=$(gs_kv $D staged)
ok "a reset that replaces a staged one: the old one goes the same way, s stays as the candidate" "sleep 1; $G reset --full --yes >/dev/null 2>&1 && [ ! -e $U/deployments/\$R1 ] && [ -e $U/deployments/s ] && [ \"\$(gs_kv \$D candidate)\" = s ]"
ok "no current deployment on userdata: the clean-up does nothing, says so" "mkd k4 && mv $U/deployments/n $W/n.away && $G switch >/dev/null 2>$W/err; mv $W/n.away $U/deployments/n; [ -e $U/deployments/k4 ] && grep -q 'clean-up skipped' $W/err"
# --- remove ID --------------------------------------------------------------------
gs_update $D candidate=s tries=2 staged=; R2=''
for d in "$U"/deployments/*; do case ${d##*/} in c|f|mt|n|s|k4) ;; *) R2=${d##*/} ;; esac; done
[ -z "$R2" ] || gs_update $D staged="$R2"
echo k4 > $W/run/booted
cp $D $W/before
for x in "n current" "s candidate" "$R2 staged" "k4 running" "mt mounted"; do
    set -- $x
    ok "remove: the $2 deployment: refused, nothing changed" "$G remove $1 --yes </dev/null 2>$W/err; [ \$? = 1 ] && grep -q '$2' $W/err && [ -e $U/deployments/$1/meta ] && cmp -s $D $W/before"
done
ok "remove: an unknown id: exit 1; a bad id: exit 2" "$G remove zz --yes 2>/dev/null; a=\$?; $G remove ../c --yes 2>/dev/null; [ \$a\$? = 12 ] && cmp -s $D $W/before"
ok "remove: the previous one without --yes, no terminal: asks, names the lost rollback, nothing removed" "$G remove c </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'Rollback to c is lost' $W/err && [ -e $U/deployments/c/meta ] && cmp -s $D $W/before"
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "remove: hibernated: exit 4, nothing removed" "$G remove c --yes </dev/null 2>/dev/null; [ \$? = 4 ] && [ -e $U/deployments/c/meta ] && cmp -s $D $W/before"
gs_invalidate_file $U/swap/hibernate
ok "remove --yes: the previous one: gone, previous= cleared, the rest of the state kept" "$G remove c --yes >/dev/null && [ ! -e $U/deployments/c ] && [ -z \"\$(gs_kv \$D previous)\" ] && [ \"\$(gs_kv \$D current)\" = n ] && [ \"\$(gs_kv \$D failed)\" = f ] && [ -z \"\$(ls -A $U/deployments.removing)\" ]"
ok "remove: the last failed one, without asking: gone, failed= cleared" "$G remove f </dev/null >/dev/null && [ ! -e $U/deployments/f ] && [ -z \"\$(gs_kv \$D failed)\" ]"
mkd k5
ok "remove: a cut delete: exit 1, said, out of the list; the next remove finishes it" "PATH=$W/shimrm:\$PATH $G remove k5 </dev/null 2>$W/err; [ \$? = 1 ] && grep -q 'k5 is gone from the list' $W/err && [ ! -e $U/deployments/k5 ] && rm -f $W/run/booted && $G remove k4 </dev/null >/dev/null && [ -z \"\$(ls -A $U/deployments.removing)\" ] && [ ! -e $U/deployments/k4 ]"
# --- stage: the replay's space check ------------------------------------------------
mkdir -p $W/sysmnt/bases/gb/etc; echo 'root:x:0:0:root:/root:/bin/sh' > $W/sysmnt/bases/gb/etc/passwd
dd if=/dev/zero of=$U/deployments/n/build/blob bs=1k count=8192 2>/dev/null
mkdir -p $W/shimdf; printf '#!/bin/sh\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"\necho "ud 100000 80000 20000 80%% /x"\n' > $W/shimdf/df; chmod +x $W/shimdf/df
gs_update $D candidate= tries=0 staged=; rm -rf $U/deployments/s $U/deployments/$R2; cp $D $W/before; ls $U/deployments > $W/dbefore
ok "stage: less free space than the replay needs: exit 5, said with both numbers, nothing staged" "PATH=$W/shimdf:\$PATH GLASSINE_DEPLOY_APK=$W/apkstub $G stage gb --yes </dev/null 2>$W/err; [ \$? = 5 ] && grep -q 'KiB needed, 20000 KiB free; nothing staged' $W/err && cmp -s $D $W/before && ls $U/deployments | cmp -s - $W/dbefore"
ok "stage --no-replay: no space check" "PATH=$W/shimdf:\$PATH $G stage gb --no-replay --yes </dev/null >/dev/null 2>&1 && [ -n \"\$(gs_kv \$D staged)\" ]"
unset GLASSINE_DEPLOY_MOUNTINFO

# --- receive --boot: device trees and initramfs into boot/ -------------------------
BW=$W/bootin; mkdir -p $BW; SB=$W/sysmnt/boot
mkbf() {    # mkbf KIND LABEL CONTENT [MANIFEST-EXTRA]: a file named by its content + its manifest, in $BW; prints its path
    printf '%s' "$3" > $BW/x; _s=$(sha256sum $BW/x | cut -d ' ' -f 1); _n=$2@$(printf '%.16s' $_s)
    if [ $1 = dtb ]; then mv $BW/x $BW/$_n.dtb; printf 'format=1\ndevice=%s\nsha256=%s\n%s' $2 $_s "${4:-}" > $BW/$_n.manifest; echo $BW/$_n.dtb
    else mv $BW/x $BW/$_n.cpio.gz; printf 'format=1\ncommit=%s0000000000000000000000000000\nsha256=%s\nstate_format=1\nneeds=\nfeatures=\n%s' $2 $_s "${4:-}" > $BW/$_n.manifest; echo $BW/$_n.cpio.gz; fi
}
nonew() { [ -z "$(find $SB -name '*.new' 2>/dev/null)" ]; }
IR=$(mkbf initramfs 0123456789ab initramfs-one); IRN=$(basename $IR .cpio.gz)
DT=$(mkbf dtb example-board dtb-one); DTN=$(basename $DT .dtb)
ok "receive --boot: an initramfs: boot/initramfs/, its file and manifest, nothing .new" "$G receive $IR --boot >$W/out && cmp -s $IR $SB/initramfs/$IRN.cpio.gz && cmp -s ${IR%.cpio.gz}.manifest $SB/initramfs/$IRN.manifest && grep -q 'received boot/initramfs/$IRN' $W/out && nonew"
ok "receive --boot: a device tree: boot/dtb/" "$G receive $DT --boot --sha256 \$(sha256sum $DT | cut -d ' ' -f 1) >/dev/null && cmp -s $DT $SB/dtb/$DTN.dtb && cmp -s ${DT%.dtb}.manifest $SB/dtb/$DTN.manifest"
ok "receive --boot: the same name again: a no-op, said" "$G receive $IR --boot >$W/out && grep -q 'is there already' $W/out"
ok "receive --boot: needs no btrfs-progs" "! command -v btrfs >/dev/null"
cp -R $SB $W/sbsave
same() { diff -r $W/sbsave $SB >/dev/null; }
X=$BW/fedcba987654@$(sha256sum $IR | cut -c1-16)
cp $IR $X.cpio.gz; cp ${IR%.cpio.gz}.manifest $X.manifest
ok "receive --boot: the name's commit is not the manifest's: refused, nothing changed" "$G receive $X.cpio.gz --boot 2>$W/err; [ \$? = 1 ] && grep -q 'is not the manifest.s commit' $W/err && same"
Y=$BW/0123456789ab@0000000000000000; cp $IR $Y.cpio.gz; cp ${IR%.cpio.gz}.manifest $Y.manifest
ok "receive --boot: the name's id is not the content's: refused, nothing changed" "$G receive $Y.cpio.gz --boot 2>$W/err; [ \$? = 1 ] && grep -q 'is not the content' $W/err && same"
Z=$(mkbf initramfs 0123456789ab initramfs-two); sed -i 's/^sha256=.*/sha256=00/' ${Z%.cpio.gz}.manifest
ok "receive --boot: the manifest's sha256 is not the file's: refused, nothing changed" "$G receive $Z --boot 2>$W/err; [ \$? = 1 ] && grep -q 'its manifest says 00' $W/err && same"
V=$(mkbf dtb other-device dtb-two); VI=$(basename $V .dtb | cut -d@ -f2)
mv $V $BW/example-board@$VI.dtb; mv $BW/other-device@$VI.manifest $BW/example-board@$VI.manifest; V=$BW/example-board@$VI.dtb
ok "receive --boot: a device tree whose manifest names another device: refused" "$G receive $V --boot 2>$W/err; [ \$? = 1 ] && grep -q 'not the manifest.s device' $W/err && same"
Q=$(mkbf initramfs 0123456789ab initramfs-three); rm ${Q%.cpio.gz}.manifest
ok "receive --boot: no manifest beside it: refused" "$G receive $Q --boot 2>$W/err; [ \$? = 1 ] && grep -q 'no manifest' $W/err && same"
Q=$(mkbf initramfs 0123456789ab initramfs-four); sed -i 's/^format=1/format=2/' ${Q%.cpio.gz}.manifest
ok "receive --boot: a newer manifest format: exit 3" "$G receive $Q --boot 2>/dev/null; [ \$? = 3 ] && same"
ok "receive --boot: a wrong --sha256: refused" "$G receive $IR --boot --sha256 00 2>$W/err; [ \$? = 1 ] && grep -q 'expected 00' $W/err && same"
ok "receive --boot: stdin, --modules, another kind of file: usage (exit 2)" "$G receive - --boot </dev/null 2>/dev/null; a=\$?; $G receive $IR --boot --modules 2>/dev/null; b=\$?; $G receive $W/kv --boot 2>/dev/null; [ \$a\$b\$? = 222 ] && same"
cp $SB/initramfs/$IRN.cpio.gz $W/f.save; printf 'other' > $SB/initramfs/$IRN.cpio.gz
ok "receive --boot: the name is there with other bytes: refused, never replaced" "$G receive $IR --boot 2>$W/err; [ \$? = 1 ] && grep -q 'there with other bytes' $W/err && [ \"\$(cat $SB/initramfs/$IRN.cpio.gz)\" = other ]"
cp $W/f.save $SB/initramfs/$IRN.cpio.gz
I2=$(mkbf initramfs 0123456789ab initramfs-five); I2N=$(basename $I2 .cpio.gz)
export GLASSINE_DEPLOY_TEST=1
ok "receive --boot: a read-back mismatch: exit 1, no file, no manifest, no .new" "GLASSINE_DEPLOY_AFTER_BOOTNEW='printf x >> \"\$1\"' $G receive $I2 --boot 2>$W/err; [ \$? = 1 ] && grep -q 'read-back does not match' $W/err && [ ! -e $SB/initramfs/$I2N.cpio.gz ] && [ ! -e $SB/initramfs/$I2N.manifest ] && nonew"
ok "receive --boot: a cut write (killed before the rename): .new left, no file, no manifest" "GLASSINE_DEPLOY_AFTER_BOOTNEW='kill -9 \$\$' $G receive $I2 --boot 2>/dev/null; [ ! -e $SB/initramfs/$I2N.cpio.gz ] && [ ! -e $SB/initramfs/$I2N.manifest ] && ! nonew"
ok "receive --boot: the next receive sweeps the cut .new and completes" "$G receive $I2 --boot >$W/out && grep -q 'a cut receive' $W/out && cmp -s $I2 $SB/initramfs/$I2N.cpio.gz && [ -e $SB/initramfs/$I2N.manifest ] && nonew"
rm $SB/initramfs/$I2N.manifest
ok "receive --boot: the file there without its manifest (cut after the file): the manifest is completed" "$G receive $I2 --boot >/dev/null && cmp -s ${I2%.cpio.gz}.manifest $SB/initramfs/$I2N.manifest && nonew"
ok "receive --boot: a cut manifest write: the file stays, the manifest is not there, a receive again completes it" "GLASSINE_DEPLOY_AFTER_BOOTNEW='case \$1 in *.manifest.new) kill -9 \$\$ ;; esac' $G receive $(mkbf dtb example-board dtb-three) --boot 2>/dev/null; D3=\$(ls $SB/dtb/*.dtb | grep -v $DTN); [ -e \"\$D3\" ] && [ ! -e \"\${D3%.dtb}.manifest\" ] && $G receive $BW/\$(basename \$D3) --boot >/dev/null && [ -e \"\${D3%.dtb}.manifest\" ] && nonew"
unset GLASSINE_DEPLOY_TEST
printf 'S1SUSPEND\000' | dd of=$U/swap/hibernate bs=1 seek=4086 conv=notrunc 2>/dev/null
ok "receive --boot: hibernated: exit 4, nothing written" "$G receive $(mkbf dtb example-board dtb-four) --boot </dev/null 2>/dev/null; [ \$? = 4 ] && [ \$(ls $SB/dtb/*.dtb | wc -l) = 2 ]"
gs_invalidate_file $U/swap/hibernate

# --- the partitions by the command line's identities (a PC; 010 FR-051) -------
# A deploy.conf that names neither partition; a sysfs stand-in with the
# installation's userdata (vda3) and a second disk's partition of the same name
# (vdb3, an install medium): only the one the command line names is read or written.
SU=0f3e26a1-5c7b-4a55-9b8d-2c4f6e8a1b3d UU=6d1a5e2b-8c4f-4b3a-a9e7-1f2d3c4b5a69 OU=22222222-2222-4222-8222-222222222222
PW=$W/pc; mkdir -p $PW/sb/vda2 $PW/sb/vda3 $PW/sb/vdb3 $PW/dev $PW/sys/state
cp -a $W/sysmnt/state/. $PW/sys/state/
for i in pcud decoy; do
    head -c 33554432 /dev/zero > $PW/$i.img; mke2fs -q -F -t ext4 -b 4096 $PW/$i.img
    for d in /media /$P /$P/swap /$P/deployments /$P/deployments/$i; do debugfs -w -R "mkdir $d" $PW/$i.img 2>/dev/null; done
    printf 'base=v3.22.1\n' > $PW/meta; debugfs -w -R "write $PW/meta /$P/deployments/$i/meta" $PW/$i.img >/dev/null 2>&1
    debugfs -w -R "write $W/swap /$P/swap/hibernate" $PW/$i.img >/dev/null 2>&1
    b=$(gs_dev_block $PW/$i.img $P/swap/hibernate)
    printf 'S1SUSPEND\000' | dd of=$PW/$i.img bs=1 seek=$((b * 4096 + 4086)) conv=notrunc 2>/dev/null
done
: > $PW/sys.img
ln -s $PW/sys.img $PW/dev/vda2; ln -s $PW/pcud.img $PW/dev/vda3; ln -s $PW/decoy.img $PW/dev/vdb3
pcpart() { printf 'DEVNAME=%s\nPARTN=%s\nPARTNAME=%s\nPARTUUID=%s\n' $1 $2 $3 $4 > $PW/sb/$1/uevent; }
pcpart vda2 2 glassine-system $SU; pcpart vda3 3 glassine-userdata $UU; pcpart vdb3 3 glassine-userdata $OU
printf 'SYSTEM_DEV=\nSYSTEM_MNT=%s/sys\nUSERDATA_DEV=\nUSERDATA_MNT=%s/noud\nUSERDATA_PREFIX=%s\nRUN_DIR=%s/run\n' $PW $PW $P $W > $PW/conf
pc() { GLASSINE_DEPLOY_CONF=$PW/conf GLASSINE_DEPLOY_CMDLINE=$PW/cmdline GLASSINE_BI_SYSBLOCK=$PW/sb GLASSINE_BI_DEVDIR=$PW/dev $G "$@"; }
cmd() { echo "BOOT_IMAGE=vmlinuz quiet $*" > $PW/cmdline; }
pcsum() { cat $PW/sys/state/deploy $PW/pcud.img $PW/decoy.img | sha256sum; }
cmd "glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU"
ok "pc: neither partition in deploy.conf: userdata is the one the command line names, not the other disk's of the same name" "pc list --porcelain > $PW/o && grep -q '	id=pcud	' $PW/o && ! grep -q decoy $PW/o"
ok "pc: status reads the hibernate image through that partition" "pc status --porcelain | grep -q '	hibernated=yes'"
ok "pc: a write (hibernate-invalidate) lands on that partition only" "pc hibernate-invalidate --yes >/dev/null && [ \"\$(gs_sig_dev $PW/pcud.img \$(gs_dev_block $PW/pcud.img $P/swap/hibernate))\" = SWAPSPACE2 ] && [ \"\$(gs_sig_dev $PW/decoy.img \$(gs_dev_block $PW/decoy.img $P/swap/hibernate))\" = S1SUSPEND ]"
cmd "glassine.system=PARTUUID=$(echo $SU | tr a-f A-F) glassine.userdata=PARTUUID=$(echo $UU | tr a-f A-F)"
ok "pc: the identities in upper case: compared in lower case" "pc list --porcelain | grep -q '	id=pcud	'"
pcrefuse() {    # pcrefuse NAME MESSAGE: list, select and a write refused with MESSAGE, nothing written
    _s=$(pcsum)
    ok "pc: $1: list refused" "pc list 2>$PW/err; [ \$? = 1 ] && grep -qF -- \"$2\" $PW/err"
    ok "pc: $1: status not refused, reads what it can, the reason on stderr" "pc status --porcelain >$PW/o 2>$PW/err && grep -q '	migrated=yes	' $PW/o && grep -qF -- \"$2\" $PW/err"
    ok "pc: $1: select, hibernate-invalidate and remove refused, nothing written" "pc select pcud --yes 2>/dev/null; a=\$?; pc hibernate-invalidate --yes 2>/dev/null; b=\$?; pc remove pcud --yes 2>/dev/null; [ \$a\$b\$? = 111 ] && [ \"\$(pcsum)\" = \"$_s\" ]"
}
printf 'S1SUSPEND\000' | dd of=$PW/pcud.img bs=1 seek=$(($(gs_dev_block $PW/pcud.img $P/swap/hibernate) * 4096 + 4086)) conv=notrunc 2>/dev/null
cmd "glassine.system=PARTUUID=$SU"
pcrefuse "no glassine.userdata=" "USERDATA_DEV is not set (deploy.conf) and this boot's command line has no glassine.userdata=PARTUUID=<uuid>"
cmd "glassine.userdata=PARTUUID=$UU"
pcrefuse "no glassine.system=" "SYSTEM_DEV is not set (deploy.conf) and this boot's command line has no glassine.system=PARTUUID=<uuid>"
cmd "glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU glassine.userdata=PARTUUID=$OU"
pcrefuse "glassine.userdata= twice" "glassine.userdata= is given more than once"
cmd "glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=${UU%-*}"
pcrefuse "a part of an identity" "glassine.userdata=PARTUUID=${UU%-*} on this boot's command line is not PARTUUID=<uuid>"
cmd "glassine.system=PARTUUID=$SU glassine.userdata=$UU"
pcrefuse "no PARTUUID=" "glassine.userdata=$UU on this boot's command line is not PARTUUID=<uuid>"
cmd "glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=33333333-3333-4333-8333-333333333333"
pcrefuse "an identity no partition carries" "no partition carries PARTUUID=33333333-3333-4333-8333-333333333333"
cmd "xglassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU"
pcrefuse "only whole words" "has no glassine.system=PARTUUID=<uuid>"
pcpart vdb3 3 glassine-userdata $UU
cmd "glassine.system=PARTUUID=$SU glassine.userdata=PARTUUID=$UU"
pcrefuse "two partitions carry the identity (a cloned disk)" "2 partitions carry PARTUUID=$UU"
pcpart vdb3 3 glassine-userdata $OU
# deploy.conf names a partition too: the same one (through another path) is fine,
# another one is refused; without the key the name is used (a fixed-name board)
sed -i "s|^USERDATA_DEV=.*|USERDATA_DEV=$PW/pcud.img|" $PW/conf
ok "pc: deploy.conf and the command line name the same partition: used" "pc list --porcelain | grep -q '	id=pcud	'"
sed -i "s|^USERDATA_DEV=.*|USERDATA_DEV=$PW/decoy.img|" $PW/conf
pcrefuse "deploy.conf names another partition than the command line" "USERDATA_DEV=$PW/decoy.img (deploy.conf) is not the partition this boot's glassine.userdata=PARTUUID=$UU names ($PW/dev/vda3)"
sed -i "s|^SYSTEM_DEV=.*|SYSTEM_DEV=$PW/sys.img|" $PW/conf
cmd ""
ok "pc: deploy.conf names both, no key on the command line: its names used" "pc list --porcelain > $PW/o && grep -q '	id=decoy	' $PW/o"
ok "pc: no command line to read at all: deploy.conf's names" "GLASSINE_DEPLOY_CONF=$PW/conf GLASSINE_DEPLOY_CMDLINE=$PW/none $G list --porcelain | grep -q '	id=decoy	'"
printf 'SYSTEM_DEV=\nUSERDATA_DEV=\n' > $PW/conf
ok "pc: init needs neither partition: not refused for a missing key" "pc init $PW/nomnt 2>$PW/err; ! grep -q 'command line' $PW/err"
# the library on its own: the boot partition's disk refuses a system identity two partitions carry
. /p/lib/glassine-bootpart.sh
pcpart vdb3 3 glassine-userdata $SU
cmd "glassine.system=PARTUUID=$SU"
ok "gp_boot_dev: two partitions carry the system partition's identity: refused" "! GLASSINE_BI_SYSBLOCK=$PW/sb gp_boot_dev $PW/cmdline glassine-boot > $PW/o && grep -q '2 partitions carry PARTUUID=$SU' $PW/o"

echo "$fails failed"
[ $fails = 0 ]
