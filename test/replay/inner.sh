#!/bin/sh
set -u
W=/w; mkdir -p $W && mount -t tmpfs -o size=1g tmpfs $W
G=/p/sbin/glassine-deploy
. /p/lib/glassine-state.sh
. /p/lib/glassine-root.sh
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
P=media/glassine
loop() {
    LOOP=$(losetup -f) || return 1
    [ -b "$LOOP" ] || mknod "$LOOP" b 7 "${LOOP#/dev/loop}" || return 1
    losetup "$LOOP" "$1"
}
truncate -s 512M $W/sys.img; mkfs.btrfs -q $W/sys.img
truncate -s 256M $W/ud.img; mke2fs -q -F -t ext4 $W/ud.img
loop $W/sys.img; SD=$LOOP; loop $W/ud.img; UDEV=$LOOP
mkdir -p $W/sysmnt $W/udmnt $W/run
mount -t btrfs "$SD" $W/sysmnt && mount -t ext4 "$UDEV" $W/udmnt || { echo "FAIL cannot mount"; exit 1; }
S=$W/sysmnt U=$W/udmnt/$P
mkdir -p $S/bases $S/state $U/deployments
cat > $W/deploy.conf <<CONF
SYSTEM_DEV=$SD
SYSTEM_MNT=$S
USERDATA_DEV=$UDEV
USERDATA_MNT=$W/udmnt
USERDATA_PREFIX=$P
RUN_DIR=$W/run
CONF
export GLASSINE_DEPLOY_CONF=$W/deploy.conf GLASSINE_DEPLOY_LIB=/p/lib/glassine-state.sh
st() { $G status --porcelain | sed -n 2p | tr '\t' '\n' | sed -n "s/^$1=//p"; }

# two bases: a small real Alpine with less; b2 only differs by a marker
btrfs -q subvolume create $S/bases/b1; X=$S/bases/b1
mkdir -p $X/etc/apk/keys; cp -a /etc/apk/keys/. $X/etc/apk/keys/; cp /etc/apk/repositories $X/etc/apk/
apk --root $X --initdb --no-progress -q add alpine-baselayout busybox busybox-binsh apk-tools alpine-keys musl less >/dev/null 2>&1 || { echo "FAIL the base does not build"; exit 1; }
printf 'root:*:1::::::\n' > $X/etc/shadow; mkdir -p $X/usr/share/glassine; echo /etc/hostname > $X/usr/share/glassine/migrate.list
btrfs property set -ts $X ro true
btrfs -q subvolume snapshot $X $S/bases/b2; echo two > $S/bases/b2/etc/base-marker; btrfs property set -ts $S/bases/b2 ro true
echo version=1 > $S/state/format
printf 'current=c1\nprevious=\ncandidate=\ntries=0\n' > $S/state/deploy
D=$U/deployments/c1; mkdir -p $D/build $D/switch $D/work; printf 'base=b1\nkind=install\n' > $D/meta

# the running deployment: its merged root, as the running system sees it
R=$W/root; gr_mount_overlay $R "$S/bases/b1" $D/switch $D/work || { echo "FAIL no overlay"; exit 1; }
echo c1 > $W/run/booted; export GLASSINE_DEPLOY_ROOT=$R
mount --bind /dev $R/dev; mount -t proc proc $R/proc; cp /etc/resolv.conf $R/etc/resolv.conf
ua() { chroot $R /sbin/apk --no-progress --cache-dir /var/cache/apk "$@" >/dev/null 2>&1; }
newest() { for i in "$U"/deployments/*; do [ "${i##*/}" = c1 ] || echo "${i##*/}"; done; }
clear_staged() { for i in $(newest); do rm -rf "${U:?}/deployments/$i"; done; gs_update $S/state/deploy staged= candidate= tries=0; }
nomnt() { ! grep -q "replay\." /proc/mounts && ! for i in "$W"/run/replay.*; do [ -e "$i" ] && echo x; done | grep -q x; }

ok "nothing changed: stage has an empty build layer, no replay" "$G stage b2 --yes >$W/o 2>&1 && ! grep -q replaying $W/o && [ -z \"\$(ls -A $U/deployments/\$(st staged)/build)\" ]"
clear_staged

mkdir -p $R/var/cache/apk; ua update; ua add tree; ua del less
ok "the user's change on the running system" "[ -x $R/usr/bin/tree ] && ! grep -qx 'P:less' $R/lib/apk/db/installed"
ok "stage: replays add and remove" "$G stage b2 --yes >$W/o 2>&1 && grep -q 'add tree' $W/o && grep -q 'remove less' $W/o"
N=$(st staged); B=$U/deployments/$N/build
ok "stage: the package is in the build layer, the live root untouched" "[ -x $B/usr/bin/tree ] && [ -e $R/usr/bin/tree ] && nomnt"
ok "stage: the world of the build layer" "grep -qw tree $B/etc/apk/world && ! grep -qw less $B/etc/apk/world"
ok "stage: no resolv.conf or empty /run left in the build layer" "[ ! -e $B/run/resolv.conf ] && [ -z \"\$(ls -A $B/run 2>/dev/null)\" ]"
ok "packages of the staged deployment: derived the same" "$G packages $N --porcelain | grep -q 'change=added	entry=tree' && $G packages $N --porcelain | grep -q 'change=removed	entry=less'"
ok "switch: the candidate's root has the replay on the new base" "$G switch >/dev/null 2>&1 && [ \"\$(st candidate)\" = $N ] && gr_merged_ro $S $U/deployments/$N $W/v && [ -x $W/v/usr/bin/tree ] && ! grep -qx 'P:less' $W/v/lib/apk/db/installed && [ \"\$(cat $W/v/etc/base-marker)\" = two ]"
umount $W/v 2>/dev/null; clear_staged

ok "--no-replay: the bare base" "$G stage b2 --no-replay --yes >/dev/null 2>&1 && [ -z \"\$(ls -A $U/deployments/\$(st staged)/build)\" ]"
clear_staged

ok "offline: the cached package and lists do it" "unshare -n $G stage b2 --yes >$W/o 2>&1 && [ -x $U/deployments/\$(st staged)/build/usr/bin/tree ]"
clear_staged

cp $R/etc/apk/world $W/world; echo nonesuch-package-x >> $R/etc/apk/world
ok "a package that no longer resolves: exit 7, nothing staged, nothing left" "$G stage b2 --yes >$W/o 2>&1; [ \$? = 7 ] && [ -z \"\$(st staged)\" ] && [ -z \"\$(newest)\" ] && nomnt && grep -q 'without NAME' $W/o"
ok "--without NAME: staged without it" "$G stage b2 --without nonesuch-package-x --yes >$W/o 2>&1 && grep -q 'leaving out nonesuch-package-x' $W/o && [ -x $U/deployments/\$(st staged)/build/usr/bin/tree ]"
clear_staged; cp $W/world $R/etc/apk/world

echo '@mine http://127.0.0.1:9/nothing' >> $R/etc/apk/repositories
ok "a repository the user added comes along" "$G stage b2 --yes >$W/o 2>&1 && grep -qF '@mine http://127.0.0.1:9/nothing' $U/deployments/\$(st staged)/build/etc/apk/repositories"
clear_staged; sed -i '/@mine/d' $R/etc/apk/repositories

cp $R/lib/apk/db/installed $W/inst
sed -i '/^P:busybox$/,/^$/s/^V:.*/V:99.0-r0/' $R/lib/apk/db/installed
ok "a version that would go down: exit 7, named, nothing staged" "$G stage b2 --yes >$W/o 2>&1; [ \$? = 7 ] && grep -q 'goes down: busybox 99.0-r0' $W/o && [ -z \"\$(st staged)\" ] && nomnt"
ok "--accept-downgrades: staged" "$G stage b2 --accept-downgrades --yes >/dev/null 2>&1 && [ -n \"\$(st staged)\" ]"
clear_staged; cp $W/inst $R/lib/apk/db/installed

umount $R/proc $R/dev $R; umount $S $W/udmnt; losetup -d $SD; losetup -d $UDEV; cd /; umount $W
echo "$fails failed"
[ "$fails" = 0 ]
