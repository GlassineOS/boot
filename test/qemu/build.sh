#!/bin/sh
# Builds the test/qemu guest in two steps (test.sh runs both):
#   build.sh files   arm64 container: Alpine's virt kernel, our initramfs
#                    (unchanged, plus a test shim that loads the virt kernel's
#                    modules first), the base tree (Alpine + OpenRC + this
#                    repository installed) and the modules tree, as tar files
#   build.sh disk    privileged container of the host's own architecture
#                    (btrfs ioctls don't pass user emulation): a GPT disk with a btrfs "system"
#                    partition (base b1, modules subvolume, state/), an ext4
#                    "userdata" partition (deployment d1), and for device data
#                    an empty ext4 "devdata" (the board's DEVICE_PART) and two
#                    source partitions, ext4 "srcext" and vfat "srcvfat"
# Output in $OUT: Image, initramfs.cpio.gz, disk.img.
set -eu
R=/p                                  # this repository, read-only
OUT=${OUT:-/out}
W=/w; mkdir -p $W $OUT && mount -t tmpfs -o size=2200m tmpfs $W
if [ "${1:-}" = disk ]; then
    apk add -q btrfs-progs e2fsprogs sgdisk coreutils tar dosfstools mtools python3 >/dev/null
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
DEVICE_PART=devdata
EOF
sh build-initramfs.sh --board $W/board.conf $W/base.cpio.gz >/dev/null
S=$W/shim; mkdir -p $S/mods
: > $S/load.list
for m in virtio_blk ext4 btrfs overlay vfat nls_cp437 nls_iso8859_1 nls_utf8; do
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
mkdir -p $B/etc/glassine $B/usr/share/glassine $B/etc/glassine-bootimg
# the board keys as the image builder installs them (the seed tool reads DEVICE_PART)
cp $W/board.conf $B/etc/glassine-bootimg/board.conf
cat > $B/etc/glassine/deploy.conf <<'EOF'
SYSTEM_DEV=/dev/vda1
USERDATA_DEV=/dev/vda2
ACCEPT_AFTER=40
HIBERNATE_RESERVE_MB=64
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
for s in devfs dmesg sysfs glassine-device-seed; do ln -s /etc/init.d/$s $B/etc/runlevels/sysinit/$s; done
for s in localmount hostname bootmisc; do ln -s /etc/init.d/$s $B/etc/runlevels/boot/$s; done
ln -s /etc/init.d/qtest $B/etc/runlevels/default/qtest
ln -s /etc/init.d/glassine-deploy-accept $B/etc/runlevels/default/glassine-deploy-accept
for s in killprocs mount-ro glassine-switch; do ln -s /etc/init.d/$s $B/etc/runlevels/shutdown/$s; done
mkdir -p $B/lib/modules $B/lib/firmware $B/run   # no lib/modules/<release>: gr_modules makes it, as for an images base
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
mkdir -p $W/sys && mount -t btrfs -o loop $W/sys.img $W/sys
mkdir -p $W/sys/bases $W/sys/modules $W/sys/state
btrfs -q subvolume create $W/sys/bases/b1
tar -C $W/sys/bases/b1 --numeric-owner --xattrs -xf $OUT/base.tar
btrfs property set -ts $W/sys/bases/b1 ro true
btrfs -q subvolume create $W/sys/modules/$KREL
tar -C $W/sys/modules/$KREL -xf $OUT/modules.tar
mkdir -p $W/sys/modules/$KREL/firmware/qtest; echo fw > $W/sys/modules/$KREL/firmware/qtest/a.fw
# its record: the firmware list the seed's names are checked against
printf 'format=1\nrelease=%s\nfirmware=qtest/a.fw@%s\n' "$KREL" "$(sha256sum $W/sys/modules/$KREL/firmware/qtest/a.fw | cut -c1-16)" \
    > $W/sys/modules/$KREL/kernel.manifest
btrfs property set -ts $W/sys/modules/$KREL ro true
echo version=1 > $W/sys/state/format
printf 'current=d1\nprevious=\ncandidate=\ntries=0\nstaged=\n' > $W/sys/state/deploy
umount $W/sys

# --- userdata -----------------------------------------------------------------
truncate -s 900M $W/ud.img; mke2fs -q -F -t ext4 -b 4096 -L userdata $W/ud.img
mkdir -p $W/ud && mount -t ext4 -o loop $W/ud.img $W/ud
D=$W/ud/media/glassine/deployments/d1; mkdir -p $D/build $D/switch $D/work
mkdir -p $D/build/home && echo own > $D/build/home/own-file    # hidden by the storage bind
printf 'base=b1\nkind=install\ncreated=qtest\n' > $D/meta
mkdir -p $W/ud/qtest && echo 0 > $W/ud/qtest/stage

# --- device data: DEVICE_PART (no seed yet) and the source partitions ---------------
# a waveform: a header whose 32-bit length at offset 4 is the file's size
wbf() {
    { printf 'WBF\0'; printf "\\$(printf %o $(($1 & 255)))\\$(printf %o $(($1 >> 8 & 255)))\\$(printf %o $(($1 >> 16 & 255)))\\$(printf %o $(($1 >> 24 & 255)))"
      head -c $(($1 - 8)) /dev/urandom; } > "$2"
}
mkdir -p $W/dd $W/sx/waveform $W/sx/fw $W/sx/image
echo keep > $W/dd/other
wbf 4096 $W/sx/waveform/panel.wbf
head -c 3000 /dev/urandom > $W/sx/fw/x.bin; head -c 100 /dev/urandom > $W/sx/fw/y.bin
# split images (test/seed/mkmdt.py): dsp needs b00 and b02 (index 1 has no file
# bytes, its b01 is not needed); gap needs b00 and b01, and only b00 is there
python3 $R/test/seed/mkmdt.py $W/sx/image/dsp.mdt 32 1,0,4096,500,500 1,0,0,0,500 1,0,8192,500,500
for p in b00 b01 b02; do head -c 500 /dev/urandom > $W/sx/image/dsp.$p; done
python3 $R/test/seed/mkmdt.py $W/sx/image/gap.mdt 32 1,0,4096,50,50 1,0,8192,50,50
head -c 50 /dev/urandom > $W/sx/image/gap.b00
mke2fs -q -F -t ext4 -L devdata -d $W/dd $W/dd.img 64M
mke2fs -q -F -t ext4 -L srcext -d $W/sx $W/sx.img 32M
truncate -s 32M $W/sv.img; mkfs.vfat -n SRCVFAT $W/sv.img >/dev/null
head -c 200 /dev/urandom > $W/BOARD.BIN; mcopy -i $W/sv.img $W/BOARD.BIN ::/BOARD.BIN
# what each partition reads as now: devdata untouched while no list names files,
# the sources never written by the seed (SC-003)
sha256sum $W/dd.img | cut -d' ' -f1 > $W/ud/qtest/devdata.sum
cat $W/sx.img $W/sv.img | sha256sum | cut -d' ' -f1 > $W/ud/qtest/src.sum
umount $W/ud

# --- the disk: GPT with named partitions ----------------------------------------
rm -f $OUT/disk.img; truncate -s 2600M $OUT/disk.img
sgdisk -o -n 1:2048:+1400M -c 1:system -n 2:0:+900M -c 2:userdata -n 3:0:+64M -c 3:devdata \
    -n 4:0:+32M -c 4:srcext -n 5:0:+32M -c 5:srcvfat $OUT/disk.img >/dev/null
n=1
for img in sys ud dd sx sv; do
    s=$(sgdisk -i $n $OUT/disk.img | sed -n 's/^First sector: \([0-9]*\).*/\1/p')
    dd if=$W/$img.img of=$OUT/disk.img bs=512 seek="$s" conv=notrunc,sparse status=none
    n=$((n + 1))
done
rm -f $OUT/base.tar $OUT/modules.tar
echo "disk: $(du -h $OUT/disk.img | cut -f1) used"
cd /; umount $W
