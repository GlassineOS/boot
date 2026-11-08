#!/bin/sh
# The disk step for an outside base (test.sh --base; build.sh disk runs this
# with QTEST_BASE=1): a GPT disk with a btrfs "system" partition and an ext4
# "userdata" partition, as build.sh's, but
#   - the base is the outside one, received from /in/base.btrfs.zst with btrfs
#     receive into bases/ (read-only, a received UUID, named by the stream), as
#     glassine-deploy receive does on a device; nothing in it is changed
#   - the modules of the harness's kernel are a modules/<release> subvolume
#   - deployment d1 on it is the candidate (2 tries, no current yet), so the
#     first boot is judged by the base's boot-success step
#   - d1's own build layer (the layer below its upper, read-only once it
#     exists: docs/deployments.md) holds what the test adds: the agent
#     (agent-base.sh) as /usr/local/sbin/qtest-agent, its OpenRC service and
#     the runlevel link, two health checks, the base's deploy.conf with the
#     test disk's devices and a shorter ACCEPT_AFTER, and a migrate list that
#     names all of these, so every switch carries them into the next
#     deployment like any other setting
#   - /in/base2.btrfs.zst (optional, a delta against the base) is copied to
#     userdata's qtest/ for the agent to receive in the guest
#   build-base.sh WORKDIR KERNEL-RELEASE    (WORKDIR: a mounted tmpfs)
set -eu
W=$1 KREL=$2
R=/p OUT=${OUT:-/out}
ACCEPT_AFTER=40

# --- the system partition: the received base, the modules, state/ ---------------
truncate -s 2400M $W/sys.img; mkfs.btrfs -q -L system $W/sys.img
mkdir -p $W/sys && mount -t btrfs -o loop $W/sys.img $W/sys
mkdir -p $W/sys/bases $W/sys/modules $W/sys/state
zstd -dcq /in/base.btrfs.zst | btrfs -q receive $W/sys/bases
B1=$(ls $W/sys/bases)
[ "$(echo "$B1" | wc -l)" = 1 ] || { echo "disk: the stream held more than one subvolume: $B1" >&2; exit 1; }
BD=$W/sys/bases/$B1
[ "$(btrfs property get -ts "$BD" ro)" = ro=true ] || { echo "disk: $B1 is not read-only" >&2; exit 1; }
btrfs subvolume show "$BD" | grep -q 'Received UUID:[[:space:]]*[0-9a-f]' || { echo "disk: $B1 has no received UUID" >&2; exit 1; }
btrfs -q subvolume create $W/sys/modules/$KREL
mkdir -p $W/m && tar -C $W/m -xf $OUT/modules.tar && cp -a $W/m/. $W/sys/modules/$KREL/ && rm -rf $W/m
btrfs property set -ts $W/sys/modules/$KREL ro true
echo version=1 > $W/sys/state/format
printf 'current=\nprevious=\ncandidate=d1\ntries=2\nstaged=\n' > $W/sys/state/deploy

# --- userdata: d1 and its build layer -----------------------------------------------
truncate -s 1400M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 -L userdata $W/ud.img
mkdir -p $W/ud && mount -t ext4 -o loop $W/ud.img $W/ud
D=$W/ud/media/glassine/deployments/d1; mkdir -p $D/build $D/switch $D/work
printf 'base=%s\nkind=install\ncreated=qtest\n' "$B1" > $D/meta
L=$D/build
# ldir PATH: a directory of the layer, each level with the base's owner and mode
# (the merged directory takes the top layer's), 0:0 0755 where the base has none
ldir() {
    _a=''
    for _c in $(echo "${1#/}" | tr '/' ' '); do
        _a=$_a/$_c
        [ -d "$L$_a" ] && continue
        mkdir "$L$_a"
        if [ -d "$BD$_a" ]; then
            chown "$(stat -c %u:%g "$BD$_a")" "$L$_a"; chmod "$(stat -c %a "$BD$_a")" "$L$_a"
        else
            chown 0:0 "$L$_a"; chmod 755 "$L$_a"
        fi
    done
}
ldir /usr/local/sbin
install -m 755 -o 0 -g 0 $R/test/qemu/agent-base.sh $L/usr/local/sbin/qtest-agent
ldir /etc/init.d
cat > $L/etc/init.d/qtest <<'EOF'
#!/sbin/openrc-run
# test/qemu: the agent, once the system is up
depend() { after *; }
start() { setsid /usr/local/sbin/qtest-agent </dev/null >/dev/console 2>&1 & }
EOF
chmod 755 $L/etc/init.d/qtest
ldir /etc/runlevels/default
ln -s /etc/init.d/qtest $L/etc/runlevels/default/qtest
ldir /etc/glassine-bootimg/health.d
# the accept step's health checks: the agent's service is up, and a candidate the
# agent marked to fail (userdata's qtest/fail names it) is never healthy
printf '#!/bin/sh\nrc-service qtest status >/dev/null 2>&1 || { echo qtest not started; exit 1; }\n' > $L/etc/glassine-bootimg/health.d/50-qtest
cat > $L/etc/glassine-bootimg/health.d/60-qtest-fail <<'EOF'
#!/bin/sh
f=/run/glassine/userdata/qtest/fail
[ -s $f ] && [ "$(cat $f)" = "$(cat /run/glassine/booted 2>/dev/null)" ] && { echo "qtest: this candidate is set to fail"; exit 1; }
exit 0
EOF
# the base's own checks of its graphical session cannot pass without a panel (out of
# scope here): the layer replaces them by name with a pass that says so
for h in "$BD"/etc/glassine-bootimg/health.d/*desktop*; do
    [ -e "$h" ] || continue
    printf '#!/bin/sh\n# test/qemu: no panel in the VM; the base has a check of its session here\nexit 0\n' > "$L/etc/glassine-bootimg/health.d/${h##*/}"
    echo "disk: health check ${h##*/} of the base replaced (no panel in the VM)"
done
chmod 755 $L/etc/glassine-bootimg/health.d/*
# Bluetooth: the virt kernel has none, and bluetoothd exits at once without the
# kernel's management interface, which OpenRC counts as crashed, and a crashed
# service keeps the boot-success step from accepting any deployment. So in this VM
# the service refuses to start where the kernel has no Bluetooth (a failed start,
# not a crash); the agent lists it as needing hardware the VM lacks.
ldir /etc/conf.d
cat > $L/etc/conf.d/bluetooth <<'EOF'
# test/qemu: no Bluetooth in the virt kernel
start_pre() { [ -d /sys/class/bluetooth ] || { eerror "no Bluetooth in this kernel (test/qemu)"; return 1; }; }
EOF
chmod 644 $L/etc/conf.d/bluetooth
ldir /etc/glassine/migrate.d
# the base's own deploy.conf, then the test disk's devices and a shorter wait
{ cat "$BD/etc/glassine/deploy.conf" 2>/dev/null || :
  printf '# test/qemu\nSYSTEM_DEV=/dev/vda1\nUSERDATA_DEV=/dev/vda2\nACCEPT_AFTER=%s\n' $ACCEPT_AFTER; } > $L/etc/glassine/deploy.conf
chmod 644 $L/etc/glassine/deploy.conf
cat > $L/etc/glassine/migrate.d/qtest.list <<'EOF'
# test/qemu: the agent and its configuration go with every switch
/etc/glassine/migrate.d/
/etc/glassine/deploy.conf
/etc/init.d/qtest
/etc/runlevels/default/qtest
/etc/glassine-bootimg/health.d/
/etc/conf.d/bluetooth
/usr/local/sbin/qtest-agent
EOF
chmod 644 $L/etc/glassine/migrate.d/qtest.list
mkdir -p $W/ud/qtest && echo 0 > $W/ud/qtest/stage
echo "$B1" > $W/ud/qtest/base1
[ ! -e /in/base2.btrfs.zst ] || cp /in/base2.btrfs.zst $W/ud/qtest/base2.btrfs.zst
printf '%s\n' "${QTEST_BASE2_FILE:-}" > $W/ud/qtest/base2-file
echo "disk: base $B1, layer: $(cd $L && find . ! -type d | sort | tr '\n' ' ')"
umount $W/ud
umount $W/sys

# --- the disk: GPT with named partitions ----------------------------------------
rm -f $OUT/disk.img; truncate -s 3900M $OUT/disk.img
sgdisk -o -n 1:2048:+2400M -c 1:system -n 2:0:+1400M -c 2:userdata $OUT/disk.img >/dev/null
s1=$(sgdisk -i 1 $OUT/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
s2=$(sgdisk -i 2 $OUT/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
dd if=$W/sys.img of=$OUT/disk.img bs=512 seek="$s1" conv=notrunc,sparse status=none
dd if=$W/ud.img of=$OUT/disk.img bs=512 seek="$s2" conv=notrunc,sparse status=none
rm -f $OUT/modules.tar
echo "disk: $(du -h $OUT/disk.img | cut -f1) used"
cd /; umount $W
