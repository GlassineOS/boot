#!/bin/sh
set -u
apk add -q linux-lts kmod cpio gzip >/dev/null || { echo "FAIL apk add linux-lts kmod"; exit 1; }
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
B="sh /m/build-boot-modules.sh"
REL=$(ls /lib/modules)
# the tree as the kernel-artifacts contract delivers it: modules/<release>/
K=/k/modules/$REL; mkdir -p /k/modules && cp -a /lib/modules/$REL $K && rm -f $K/build $K/source
printf 'format=1\nrelease=%s\n' "$REL" > $K/kernel.manifest
x() { rm -rf /x; mkdir /x; zcat "$1" | (cd /x && cpio -id --quiet); }
mn() { b=${1##*/}; b=${b%.gz}; b=${b%.xz}; b=${b%.zst}; echo "${b%.ko}" | tr - _; }

$B $K /a.cpio.gz > /a.log 2>&1; rc=$?
cat /a.log
ok "linux-lts ($REL, $(apk --print-arch)): built" "[ $rc = 0 ]"
$B $K /b.cpio.gz >/dev/null 2>&1
ok "reproducible (built twice, the same bytes)" "cmp -s /a.cpio.gz /b.cpio.gz"
x /a.cpio.gz; L=/x/lib/glassine-boot/modules/$REL
ok "the archive holds only lib/glassine-boot/modules/<release>/" "[ \"\$(cd /x && find . -type f | sed 's|/[^/]*\$||' | sort -u)\" = './lib/glassine-boot/modules/$REL' ]"
for m in btrfs ext4 overlay nvme ahci virtio_blk virtio_pci usb_storage xhci_pci; do
    ok "$m in the load list" "tr - _ < $L/load | grep -qx $m"
done
ok "every module in the load list is there, decompressed (ELF)" "while read -r m; do [ \"\$(head -c 4 $L/\$m.ko | od -An -c | tr -d ' ')\" = '177ELF' ] || exit 1; done < $L/load"
ok "nothing in the archive the load list doesn't name" "[ \"\$(ls $L | grep -v '^load\$' | wc -l)\" = \"\$(grep -c . $L/load)\" ]"
ok "each module once" "[ \"\$(sort $L/load | uniq -d)\" = '' ]"
# every hard dependency (modules.dep) comes before the module
tr - _ < $L/load | awk '{ print NR, $0 }' > /pos
ok "every module after its dependencies (modules.dep)" "sed 's/:/ /' $K/modules.dep | while read -r p deps; do
    m=\$(mn \$p); i=\$(awk -v m=\$m '\$2 == m { print \$1 }' /pos); [ -n \"\$i\" ] || continue
    for d in \$deps; do j=\$(awk -v m=\$(mn \$d) '\$2 == m { print \$1 }' /pos); [ -n \"\$j\" ] && [ \$j -lt \$i ] || { echo \"\$m before \$d\"; exit 1; }; done
done"
# btrfs's checksums come by soft dependency: the modules (or built in) before btrfs
bp=$(awk '$2 == "btrfs" { print $1 }' /pos)
for s in $(awk '$1 == "softdep" && $2 == "btrfs" { for (i = 3; i <= NF; i++) if ($i !~ /:$/) print $i }' $K/modules.softdep); do
    ok "btrfs's soft dependency $s: before btrfs, or built in" "grep -q '^soft dependency $s: built in' /a.log || {
        for m in \$(sed -n 's/^soft dependency $s: //p' /a.log); do j=\$(awk -v m=\$(echo \$m | tr - _) '\$2 == m { print \$1 }' /pos); [ -n \"\$j\" ] && [ \$j -lt $bp ] || exit 1; done; }"
done
ok "at least one soft dependency is a module (crc32c or xxhash64)" "grep -Eq '^soft dependency (crc32c|xxhash64): [a-z]' /a.log && ! grep -Eq '^soft dependency (crc32c|xxhash64): (built in|absent)' /a.log"

# --module and a list of our own
printf '# a list\nbtrfs required\nno_such_driver\n' > /l1
$B --list /l1 --module dummy $K /c.cpio.gz > /c.log 2>&1; rc=$?
x /c.cpio.gz
ok "--list: only its names (and their dependencies); an optional name the kernel lacks: absent" "[ $rc = 0 ] && grep -qx 'no_such_driver: absent' /c.log && ! tr - _ < /x/lib/glassine-boot/modules/$REL/load | grep -qx ext4"
ok "--module: added after the list" "[ \"\$(tail -n1 /x/lib/glassine-boot/modules/$REL/load)\" = dummy ]"
printf 'btrfs required\nno_such_fs required\n' > /l2
$B --list /l2 $K /d.cpio.gz > /d.log 2>&1; rc=$?
ok "a required name the kernel lacks: the build fails, named" "[ $rc = 1 ] && grep -q 'no_such_fs (required) is neither built into' /d.log"

# a kernel with everything built in (as the Note Air's): an empty load list
F=/f/lib/modules/9.9.9-builtin; mkdir -p $F
printf 'kernel/fs/btrfs/btrfs.ko\nkernel/fs/ext4/ext4.ko\nkernel/fs/overlayfs/overlay.ko\nkernel/drivers/nvme/host/nvme.ko\n' > $F/modules.builtin
: > $F/modules.order
depmod -b /f 9.9.9-builtin
$B $F /e.cpio.gz > /e.log 2>&1; rc=$?
x /e.cpio.gz
ok "everything built in: built, an empty load list, no module" "[ $rc = 0 ] && [ ! -s /x/lib/glassine-boot/modules/9.9.9-builtin/load ] && [ \"\$(ls /x/lib/glassine-boot/modules/9.9.9-builtin)\" = load ] && grep -qx 'btrfs: built in' /e.log && grep -qx 'virtio_blk: absent' /e.log"

# refusals
printf 'format=1\nrelease=1.2.3-other\n' > $F/kernel.manifest
$B $F /g.cpio.gz > /g.log 2>&1; rc=$?
ok "a kernel.manifest naming another release: refused" "[ $rc = 1 ] && grep -q 'names release 1.2.3-other' /g.log && [ ! -e /g.cpio.gz ]"
mkdir -p /n/9.9.9-none
$B /n/9.9.9-none /h.cpio.gz > /h.log 2>&1; rc=$?
ok "no modules.dep: refused" "[ $rc = 1 ] && grep -q 'has no modules.dep' /h.log"

[ $fails = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
