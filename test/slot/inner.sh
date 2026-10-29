#!/bin/sh
set -u
W=/w; mkdir -p $W
fails=0
ok() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi; }
cc -Os -Wall -Werror -o $W/glassine-slot /p/src/glassine-slot.c || { echo "FAIL build"; exit 1; }
I=$W/disk.img
S() { GLASSINE_SLOT_CMDLINE=$W/cmdline $W/glassine-slot --disk $I "$@" > $W/out 2>&1; }
cmdline() { echo "console=ttyMSM0 androidboot.slot_suffix=_$1 rootwait" > $W/cmdline; }
# attribute of partition N as hex, from sgdisk (not from the tool)
attr() { sgdisk -i "$1" $I | sed -n 's/^Attribute flags: //p'; }
field() { sed -n "s/^slot=$1\t.*$2=\([^\t]*\).*/\1/p" $W/out; }
# a disk like the device: boot/system per slot, two type GUIDs (boot != system)
mkdisk() {
    rm -f $I; truncate -s 64M $I
    sgdisk -o -n 1:0:+4M -c 1:boot_a -t 1:20117f86-e985-4357-b9ee-374bc1d8487d \
        -n 2:0:+8M -c 2:system_a -t 2:97d7b011-54da-4835-b3c4-917ad6e73d74 \
        -n 3:0:+4M -c 3:boot_b -t 3:20117f86-e985-4357-b9ee-374bc1d8487d \
        -n 4:0:+8M -c 4:system_b -t 4:97d7b011-54da-4835-b3c4-917ad6e73d74 \
        -n 5:0:0 -c 5:userdata $I >/dev/null
    # slot a successful + active (the device's 0x007F...), b never booted
    sgdisk -A 1:set:48 -A 1:set:49 -A 1:set:50 -A 1:set:51 -A 1:set:52 -A 1:set:53 -A 1:set:54 $I >/dev/null
}
# both tables valid per sgdisk; the entry arrays differ from $1 only in the
# attribute words of entries 1 and 3 (bytes 48..55)
only_attrs() {
    sgdisk -v $I | grep -q 'No problems found' || return 1
    dd if=$I bs=512 skip=2 count=32 2>/dev/null > $W/arr.now
    cmp -l "$1" $W/arr.now | awk '{ o = ($1 - 1) % 128; e = int(($1 - 1) / 128); if (!((e == 0 || e == 2) && o >= 48 && o < 56)) bad = 1 } END { exit bad }'
}
snap() { dd if=$I bs=512 skip=2 count=32 2>/dev/null > $W/arr.0; sha256sum $I | cut -d' ' -f1 > $W/sum.0; }
unchanged() { [ "$(sha256sum $I | cut -d' ' -f1)" = "$(cat $W/sum.0)" ]; }

mkdisk; cmdline a
ok "status: slot a successful + active, next a" "S status --porcelain && grep -qx 'booted=a' $W/out && grep -qx 'next=a' $W/out && [ \$(field a successful) = 1 ] && [ \$(field a priority) = 3 ] && [ \$(field b tries) = 0 ]"
ok "status, human" "S status && grep -q 'next boot: a' $W/out"

snap
ok "set-active b: b priority 3, active, 7 tries, not successful" "S set-active b && S status --porcelain && [ \$(field b priority) = 3 ] && [ \$(field b active) = 1 ] && [ \$(field b tries) = 7 ] && [ \$(field b successful) = 0 ] && grep -qx 'next=b' $W/out"
ok "set-active b: a keeps successful, priority 2, not active" "[ \$(field a priority) = 2 ] && [ \$(field a active) = 0 ] && [ \$(field a successful) = 1 ]"
ok "set-active: only the two attribute words changed, both tables valid (sgdisk -v)" "only_attrs $W/arr.0"
ok "set-active: sgdisk reads the same bits (b: 48 49 50 51 52 53, no 54)" "[ \"\$(attr 3)\" = 003F000000000000 ] && [ \"\$(attr 1)\" = 007A000000000000 ]"
ok "backup table = primary (sgdisk loads the backup alone)" "sgdisk -b $W/bk $I >/dev/null && dd if=$I bs=512 skip=\$((\$(stat -c %s $I) / 512 - 33)) count=32 2>/dev/null | cmp -s - $W/arr.now"

cp $I $W/keep.img
ok "set-active a --successful: a priority 3, active, successful; b priority 2" "S set-active a --successful && S status --porcelain && [ \$(field a successful) = 1 ] && [ \$(field a priority) = 3 ] && [ \$(field a active) = 1 ] && [ \$(field b priority) = 2 ] && grep -qx 'next=a' $W/out"
ok "set-active --bogus: usage" "S set-active a --bogus; [ \$? = 2 ]"
cp $W/keep.img $I
cmdline b
ok "mark-successful (the booted slot b)" "S mark-successful && S status --porcelain && [ \$(field b successful) = 1 ] && [ \$(field b tries) = 7 ]"
snap
ok "mark-successful again: nothing to change, no write" "S mark-successful && grep -q 'nothing to change' $W/out && unchanged"
ok "reset-tries b: not successful, 7 tries" "S reset-tries b && S status --porcelain && [ \$(field b successful) = 0 ] && [ \$(field b tries) = 7 ] && only_attrs $W/arr.0"

# the bootloader's choice when b ran out of tries: a (successful) boots
sgdisk -A 3:clear:51 -A 3:clear:52 -A 3:clear:53 $I >/dev/null
ok "next: b without tries and not successful -> a" "S status --porcelain && grep -qx 'next=a' $W/out"
sgdisk -A 1:clear:54 $I >/dev/null
ok "next: neither bootable -> none" "S status --porcelain && grep -qx 'next=' $W/out"

# refusals
mkdisk; : > $W/cmdline; snap
ok "mark-successful without a booted slot: exit 3, no write" "S mark-successful; [ \$? = 3 ] && unchanged"
ok "mark-successful b, named: works without the cmdline" "S mark-successful b && grep -q done $W/out"
ok "usage: exit 2" "S set-active c; [ \$? = 2 ] && S frob; [ \$? = 2 ]"
rm -f $I; truncate -s 16M $I; sgdisk -o -n 1:0:0 -c 1:userdata $I >/dev/null; snap
ok "no boot_a/boot_b: exit 3, no write" "S set-active a; [ \$? = 3 ] && unchanged"
mkdisk; printf 'X' | dd of=$I bs=1 seek=$((512 + 30)) conv=notrunc 2>/dev/null; snap
ok "a broken primary header: rebuilt from the backup, both valid" "S set-active b && grep -q 'primary GPT is broken' $W/out && sgdisk -v $I | grep -q 'No problems found'"
mkdisk; printf 'X' | dd of=$I bs=1 seek=$((1024 + 128 * 4 + 60)) conv=notrunc 2>/dev/null; snap
ok "a broken primary entry array: rebuilt from the backup, both valid, the entry restored" "S set-active b && sgdisk -v $I | grep -q 'No problems found' && sgdisk -p $I | grep -q system_b"
# the copies differ beyond the slot attributes (a renamed partition in the primary only)
mkdisk; cp $I $W/orig.img; sgdisk -c 5:other $I >/dev/null
dd if=$W/orig.img of=$I bs=512 skip=$(($(stat -c %s $I) / 512 - 33)) seek=$(($(stat -c %s $I) / 512 - 33)) count=33 conv=notrunc 2>/dev/null; snap
ok "the copies differ beyond the slot attributes: exit 3, no write" "S set-active b; [ \$? = 3 ] && grep -q 'differ' $W/out && unchanged"

# cut writes: the bootloader reads the primary, or the backup when the primary
# is broken; the tool reads the same and rebuilds a broken copy from the other
for c in backup-array backup primary-array; do
    mkdisk; cmdline a
    ok "cut after $c: exit 1" "GLASSINE_SLOT_TEST_CUT=$c S set-active b; [ \$? = 1 ]"
    case $c in
    primary-array) want=b ;;   # the primary is broken: the backup (new) counts
    *) want=a ;;
    esac
    ok "cut after $c: next boot = $want" "S status --porcelain && grep -qx 'next=$want' $W/out"
    ok "cut after $c: a re-run completes, both tables valid" "S set-active b && S status --porcelain && grep -qx 'next=b' $W/out && sgdisk -v $I | grep -q 'No problems found'"
done
# a backup that is gone entirely (zeroed): rebuilt from the primary
mkdisk; dd if=/dev/zero of=$I bs=512 seek=$(($(stat -c %s $I) / 512 - 33)) count=33 conv=notrunc 2>/dev/null
ok "a zeroed backup GPT: set-active rebuilds it, both valid" "S set-active b && sgdisk -v $I | grep -q 'No problems found'"
# a zeroed primary: rebuilt from the backup
mkdisk; dd if=/dev/zero of=$I bs=512 seek=1 count=33 conv=notrunc 2>/dev/null
ok "a zeroed primary GPT: status reads the backup" "S status --porcelain && grep -qx 'next=a' $W/out"
ok "a zeroed primary GPT: set-active rebuilds it, both valid, names kept" "S set-active b && sgdisk -v $I | grep -q 'No problems found' && sgdisk -p $I | grep -q system_b"
# both broken: refused
mkdisk; dd if=/dev/zero of=$I bs=512 seek=1 count=1 conv=notrunc 2>/dev/null; dd if=/dev/zero of=$I bs=512 seek=$(($(stat -c %s $I) / 512 - 1)) count=1 conv=notrunc 2>/dev/null; snap
ok "both GPT copies broken: exit 3, no write" "S set-active b; [ \$? = 3 ] && unchanged"

# busy: another glassine-slot (a lock on the disk)
mkdisk
ok "busy: exit 6" "flock $I sh -c 'GLASSINE_SLOT_CMDLINE=$W/cmdline $W/glassine-slot --disk $I set-active b > $W/out 2>&1; [ \$? = 6 ]'"

mkdisk
ok "a read-back mismatch: exit 1, says so" "GLASSINE_SLOT_TEST_CUT=readback S set-active b; [ \$? = 1 ] && grep -q 'read-back mismatch' $W/out"

echo "$fails failed"
[ $fails = 0 ]
