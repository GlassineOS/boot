#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Build one kernel's boot-modules archive (docs/boot.md, "Boot modules"): the modules the
# initramfs loads before it looks for the system partition, taken from the kernel's own
# modules/<release>/ tree (docs/kernel-artifacts.md), with their dependencies
# (modules.dep) and soft dependencies (modules.softdep), decompressed, in load order.
# A kernel set's initramfs is the initramfs file followed by this archive (the kernel
# unpacks concatenated archives in order), so the initramfs itself stays the same for
# every kernel. Runs in an Alpine of any architecture with: kmod cpio gzip (+ xz or
# zstd for modules compressed that way).
#
#   build-boot-modules.sh [--list FILE] [--module NAME]... MODDIR OUT.cpio.gz
#
# MODDIR          the kernel's modules/<release>/ (its name is the release; a
#                 kernel.manifest in it must name the same one)
# --list FILE     the names to load (default: conf/boot-modules; "NAME [required]")
# --module NAME   one more name (repeatable; not required), after the list's
#
# The archive holds lib/glassine-boot/modules/<release>/<module>.ko and load (the
# module names in load order, one per line). A name the kernel builds in adds nothing; a
# kernel that builds everything in gives an archive with an empty load list. A required
# name the kernel has neither built in nor as a module fails the build (exit 1).
# Reproducible: sorted entries, owner 0:0, mtimes = SOURCE_DATE_EPOCH (default 0),
# gzip -n. Prints one line per name: loaded (with its modules), built in, or absent.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LIST=$HERE/conf/boot-modules EXTRA=''
die() { echo "build-boot-modules.sh: $*" >&2; exit 1; }
while [ $# -gt 2 ]; do
    case $1 in
    --list) LIST=$2; shift 2 ;;
    --module) EXTRA="$EXTRA $2"; shift 2 ;;
    *) echo "build-boot-modules.sh: unknown option $1" >&2; exit 2 ;;
    esac
done
[ $# = 2 ] || { echo "usage: build-boot-modules.sh [--list FILE] [--module NAME]... MODDIR OUT.cpio.gz" >&2; exit 2; }
MODDIR=$(cd "$1" && pwd) || die "no $1"
OUT=$2
EPOCH=${SOURCE_DATE_EPOCH:-0}
REL=${MODDIR##*/}
[ -r "$LIST" ] || die "no list $LIST"
[ -f "$MODDIR/modules.dep" ] || die "$MODDIR has no modules.dep (not a kernel's modules tree, or depmod never ran)"
if [ -f "$MODDIR/kernel.manifest" ]; then
    mr=$(sed -n 's/^release=//p' "$MODDIR/kernel.manifest")
    [ "$mr" = "$REL" ] || die "$MODDIR/kernel.manifest names release $mr, the directory $REL"
fi
command -v modprobe >/dev/null && modprobe --version 2>/dev/null | grep -q kmod || die "needs kmod's modprobe"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
# modprobe's view: <root>/lib/modules/<release> = MODDIR, no configuration of the host's
mkdir -p "$W/root/lib/modules" "$W/conf" "$W/a/lib/glassine-boot/modules/$REL"
ln -s "$MODDIR" "$W/root/lib/modules/$REL"
O=$W/a/lib/glassine-boot/modules/$REL
: > "$W/order"; : > "$W/visited"; : > "$W/softdone"
norm() { echo "$1" | tr - _; }
# the soft dependencies of module $1 of kind $2 (pre or post), from modules.softdep
softdeps() {
    awk -v m="$(norm "$1")" -v k="$2:" '
        $1 == "softdep" { n = $2; gsub(/-/, "_", n); if (n != m) next
            on = 0; for (i = 3; i <= NF; i++) { if ($i ~ /:$/) { on = ($i == k); continue } if (on) print $i } }' \
        "$MODDIR/modules.softdep" 2>/dev/null || :
}
# path P of the tree: its pre soft dependencies, P, its post ones (each module once)
add_path() {
    local _b _s
    _b=${1##*/}; _b=${_b%.gz}; _b=${_b%.xz}; _b=${_b%.zst}; _b=$(norm "${_b%.ko}")
    if ! grep -qxF "$_b" "$W/softdone"; then
        echo "$_b" >> "$W/softdone"
        for _s in $(softdeps "$_b" pre); do want "$_s" 0 soft; done
        grep -qxF "$1" "$W/order" || echo "$1" >> "$W/order"
        for _s in $(softdeps "$_b" post); do want "$_s" 0 soft; done
    fi
}
# want NAME REQUIRED [soft]: NAME (a module name or an alias) and its dependencies
want() {
    local _n _d _p _q _x
    _n=$(norm "$1")
    grep -qxF "$_n" "$W/visited" && return 0
    echo "$_n" >> "$W/visited"
    if ! _d=$(modprobe -d "$W/root" -S "$REL" -C "$W/conf" --show-depends "$1" 2>/dev/null); then
        [ "$2" = 0 ] || die "$1 (required) is neither built into $REL nor one of its modules"
        echo "${3:+soft dependency }$1: absent"; return 0
    fi
    _p=$(echo "$_d" | sed -n 's/^insmod \([^ ]*\).*/\1/p')
    if [ -z "$_p" ]; then echo "${3:+soft dependency }$1: built in"; return 0; fi
    for _q in $_p; do add_path "$_q"; done
    echo "${3:+soft dependency }$1: $(for _q in $_p; do _x=${_q##*/}; printf '%s ' "${_x%%.ko*}"; done | sed 's/ $//')"
}
sed 's/#.*//' "$LIST" | awk 'NF { print $1, ($2 == "required") ? 1 : 0 }' > "$W/list"
while read -r n r; do want "$n" "$r"; done < "$W/list"
for n in $EXTRA; do want "$n" 0; done

: > "$O/load"
while read -r p; do
    b=${p##*/}
    case $p in
    *.ko.gz) gzip -dc "$p" > "$O/${b%.gz}" ;;
    *.ko.xz) xz -dc "$p" > "$O/${b%.xz}" ;;
    *.ko.zst) zstd -qdc "$p" > "$O/${b%.zst}" ;;
    *.ko) cp "$p" "$O/$b" ;;
    *) die "$p: not a module file" ;;
    esac || die "$p: cannot decompress it"
    b=${b%.gz}; b=${b%.xz}; b=${b%.zst}
    echo "${b%.ko}" >> "$O/load"
done < "$W/order"
find "$W/a" -exec touch -h -d "@$EPOCH" {} +
(cd "$W/a" && find . | LC_ALL=C sort | cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) > "$OUT"
echo "$OUT: $(stat -c %s "$OUT") bytes, release $REL, $(grep -c . "$O/load" || :) modules: $(tr '\n' ' ' < "$O/load" | sed 's/ $//')"
