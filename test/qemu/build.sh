#!/bin/sh
# Builds the test/qemu guest in two steps (test.sh runs both):
#   build.sh files   arm64 container: Alpine's virt kernel, our initramfs
#                    (unchanged, plus a test shim that loads the virt kernel's
#                    modules first), the base tree (Alpine + OpenRC + this
#                    repository installed) and the modules tree, as tar files
#   build.sh disk    privileged native container (btrfs ioctls don't pass
#                    arm64 user emulation): a GPT disk with a btrfs "system"
#                    partition (base b1, modules subvolume, state/) and an ext4
#                    "userdata" partition (deployment d1)
# Output in $OUT: Image, initramfs.cpio.gz, disk.img.
set -eu
R=/p                                  # this repository, read-only
OUT=${OUT:-/out}
W=/w; mkdir -p $W $OUT && mount -t tmpfs -o size=2200m tmpfs $W
if [ "${1:-}" = disk ]; then
    apk add -q btrfs-progs e2fsprogs sgdisk coreutils tar >/dev/null
else
apk add -q linux-virt kmod e2fsprogs e2fsprogs-extra coreutils tar \
    busybox-static busybox-extras cpio gzip build-base linux-headers >/dev/null
KREL=$(ls /lib/modules | head -n 1)
cp /boot/vmlinuz-virt $OUT/Image

# --- the initramfs: build-initramfs.sh's image + the shim appended -----------
cp -a $R $W/src && cd $W/src
cat > $W/board.conf <<'EOF'
ROOT_PART=system
ROOT_FSTYPE=btrfs
ROOT_LAYOUT=deployments
USERDATA_PART=userdata
USERDATA_PREFIX=media/glassine
DEFAULT_ROLE_MATCH=''
EOF
sh build-initramfs.sh --board $W/board.conf $W/base.cpio.gz >/dev/null
S=$W/shim; mkdir -p $S/mods
: > $S/load.list
for m in virtio_blk ext4 btrfs overlay; do
    modprobe -S "$KREL" --show-depends $m | sed -n 's/^insmod \([^ ]*\).*/\1/p'
done | awk '!seen[$0]++' | while read -r k; do
    b=${k##*/}; b=${b%.gz}; b=${b%.zst}
    case $k in *.gz) gzip -dc "$k" ;; *.zst) zstd -qdc "$k" ;; *) cat "$k" ;; esac > $S/mods/$b
    echo "$b" >> $S/load.list
done
cp $S/load.list $S/mods/
mkdir -p $S/x/lib/qtest && cp $S/mods/* $S/x/lib/qtest/
# the shim is PID 1 for a moment: load the modules, then the real init (exec
# keeps PID 1); the real init comes out of the first archive as /init.glassine
zcat $W/base.cpio.gz | (mkdir -p $W/b && cd $W/b && cpio -id --quiet)
cp $W/b/init $S/x/init.glassine
cat > $S/x/init <<'EOF'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc 2>/dev/null
while read -r m; do /bin/busybox insmod /lib/qtest/$m; done < /lib/qtest/load.list
/bin/busybox umount /proc
exec /init.glassine
EOF
chmod 755 $S/x/init $S/x/init.glassine
(cd $S/x && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) > $W/shim.cpio.gz
cat $W/base.cpio.gz $W/shim.cpio.gz > $OUT/initramfs.cpio.gz

# --- the base tree --------------------------------------------------------------
B=$W/base; mkdir -p $B
mkdir -p $B/etc/apk && cp -a /etc/apk/keys $B/etc/apk/ && cp /etc/apk/repositories $B/etc/apk/
apk add -q --root $B --initdb alpine-base e2fsprogs e2fsprogs-extra >/dev/null
make -s glassine-reboot >/dev/null && make -s DESTDIR=$B install >/dev/null
cat > $B/etc/inittab <<'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::shutdown:/sbin/openrc shutdown
EOF
# the base's own line for / (docs/boot.md): without "ro" OpenRC's root
# service remounts the locked / read-write; without "bind" its remount of the
# fstab entries makes the whole overlay read-only (/etc and /var too)
echo 'overlay / overlay bind,ro 0 0' > $B/etc/fstab
echo qtest > $B/etc/hostname
mkdir -p $B/etc/glassine $B/usr/share/glassine
cat > $B/etc/glassine/deploy.conf <<'EOF'
SYSTEM_DEV=/dev/vda1
USERDATA_DEV=/dev/vda2
ACCEPT_AFTER=40
EOF
# a health check for the accept step: the agent's own service is up
mkdir -p $B/etc/glassine-bootimg/health.d
printf '#!/bin/sh\nrc-service qtest status >/dev/null 2>&1 || { echo qtest not started; exit 1; }\n' > $B/etc/glassine-bootimg/health.d/50-qtest
chmod 755 $B/etc/glassine-bootimg/health.d/50-qtest
printf '/etc/qtest/\n/etc/hostname\n' > $B/usr/share/glassine/migrate.list
install -m 755 $R/test/qemu/agent.sh $B/usr/sbin/qtest-agent
cat > $B/etc/init.d/qtest <<'EOF'
#!/sbin/openrc-run
depend() { after *; }
start() { setsid /usr/sbin/qtest-agent </dev/null >/dev/console 2>&1 & }
EOF
chmod 755 $B/etc/init.d/qtest
for s in devfs dmesg sysfs; do ln -s /etc/init.d/$s $B/etc/runlevels/sysinit/$s; done
for s in localmount hostname bootmisc; do ln -s /etc/init.d/$s $B/etc/runlevels/boot/$s; done
ln -s /etc/init.d/qtest $B/etc/runlevels/default/qtest
ln -s /etc/init.d/glassine-deploy-accept $B/etc/runlevels/default/glassine-deploy-accept
for s in killprocs mount-ro glassine-switch; do ln -s /etc/init.d/$s $B/etc/runlevels/shutdown/$s; done
mkdir -p $B/lib/modules/$KREL $B/run
tar -C $B --numeric-owner --xattrs -cf $OUT/base.tar .
tar -C /lib/modules/$KREL -cf $OUT/modules.tar .
echo "$KREL" > $OUT/krel
echo "files: kernel $KREL"
cd /; umount $W
exit 0
fi

# --- the system partition (disk step) --------------------------------------------
KREL=$(cat $OUT/krel)
truncate -s 1400M $W/sys.img; mkfs.btrfs -q -L system $W/sys.img
mkdir -p $W/sys && mount -o loop $W/sys.img $W/sys
mkdir -p $W/sys/bases $W/sys/modules $W/sys/state
btrfs -q subvolume create $W/sys/bases/b1
tar -C $W/sys/bases/b1 --numeric-owner --xattrs -xf $OUT/base.tar
btrfs property set -ts $W/sys/bases/b1 ro true
btrfs -q subvolume create $W/sys/modules/$KREL
tar -C $W/sys/modules/$KREL -xf $OUT/modules.tar
btrfs property set -ts $W/sys/modules/$KREL ro true
echo version=1 > $W/sys/state/format
printf 'current=d1\nprevious=\ncandidate=\ntries=0\nstaged=\n' > $W/sys/state/deploy
umount $W/sys

# --- userdata -----------------------------------------------------------------
truncate -s 900M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 -L userdata $W/ud.img
mkdir -p $W/ud && mount -o loop $W/ud.img $W/ud
D=$W/ud/media/glassine/deployments/d1; mkdir -p $D/build $D/switch $D/work
printf 'base=b1\nkind=install\ncreated=qtest\n' > $D/meta
mkdir -p $W/ud/qtest && echo 0 > $W/ud/qtest/stage
umount $W/ud

# --- the disk: GPT with named partitions ----------------------------------------
rm -f $OUT/disk.img; truncate -s 2400M $OUT/disk.img
sgdisk -o -n 1:2048:+1400M -c 1:system -n 2:0:+900M -c 2:userdata $OUT/disk.img >/dev/null
s1=$(sgdisk -i 1 $OUT/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
s2=$(sgdisk -i 2 $OUT/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
dd if=$W/sys.img of=$OUT/disk.img bs=512 seek="$s1" conv=notrunc,sparse status=none
dd if=$W/ud.img of=$OUT/disk.img bs=512 seek="$s2" conv=notrunc,sparse status=none
rm -f $OUT/base.tar $OUT/modules.tar
echo "disk: $(du -h $OUT/disk.img | cut -f1) used"
cd /; umount $W
