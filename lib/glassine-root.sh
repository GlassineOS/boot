# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-root.sh: assemble the root of a deployment (a btrfs base on the
# system partition + its layers on userdata). Sourced by the boot initramfs
# (interim: the kernel boots directly, no loader) and by glassine-deploy, after
# glassine-state.sh. busybox ash only.
#
# A deployment <id> (userdata, <prefix>/deployments/<id>/):
#   meta     key=value: base=<base-id> created=… kind=… (failed=1 once it failed)
#   build/   the layer built for it (packages replayed, carried state); read-only
#            once the deployment exists
#   switch/  the layer the shutdown switch writes, then the live upper: every
#            runtime write of that deployment lands here
#   work/    overlayfs' work directory (same file system as switch/)
# The merged root = overlay(lower = build + bases/<base>, upper = switch).
# Locked: / is a read-only bind of that overlay; /etc, /var, /usr/local, /opt
# are read-write binds of the same merged overlay's directories, so a write
# there still goes through the overlay (copy-up, whiteouts; the base stays
# untouched). Unlock = remount the / bind read-write.

GR_RW_DIRS='etc var usr/local opt'

# gr_pick STATEDIR: the deployment to boot, and the state update that goes with
# it (interim, until the loader does it, A14): a candidate with tries left uses
# one; a candidate with none left is failed (state failed=<id>) and current
# boots; no current: previous. Prints the id (empty: nothing to boot). Writes
# state/deploy, so the caller has the system partition read-write and locked.
gr_pick() {
    _gr_s=$1/deploy
    _gr_cur=$(gs_kv "$_gr_s" current)
    _gr_cand=$(gs_kv "$_gr_s" candidate)
    _gr_t=$(gs_kv "$_gr_s" tries)
    case "$_gr_t" in ''|*[!0-9]*) _gr_t=0 ;; esac
    if [ -n "$_gr_cand" ] && [ "$_gr_cand" != "$_gr_cur" ]; then
        if [ "$_gr_t" -gt 0 ]; then
            gs_update "$_gr_s" "tries=$((_gr_t - 1))" || return 1
            echo "$_gr_cand"; return 0
        fi
        gs_update "$_gr_s" candidate= tries=0 "failed=$_gr_cand" || return 1
    fi
    if [ -n "$_gr_cur" ]; then echo "$_gr_cur"; else gs_kv "$_gr_s" previous; fi
}

# gr_lowers SYSMNT DEPDIR: the overlay lowerdir of a deployment (build, if it
# has one, over its base); 1 if the base is missing
gr_lowers() {
    _gr_b=$(gs_kv "$2/meta" base)
    [ -n "$_gr_b" ] && [ -d "$1/bases/$_gr_b" ] || return 1
    if [ -d "$2/build" ]; then echo "$2/build:$1/bases/$_gr_b"; else echo "$1/bases/$_gr_b"; fi
}

# gr_mount_overlay MERGED LOWERS UPPER WORK: the overlay, read-write (the lock
# is the per-mount flag of the binds, never the superblock's)
gr_mount_overlay() {
    mkdir -p "$1" "$3" "$4" || return 1
    mount -t overlay overlay -o "lowerdir=$2,upperdir=$3,workdir=$4" "$1"
}

# gr_bind_locked MERGED NEWROOT: / read-only + the writable directories
gr_bind_locked() {
    mkdir -p "$2" || return 1
    mount --bind "$1" "$2" || return 1
    mount -o remount,bind,ro "$2" || { umount "$2"; return 1; }
    for _gr_d in $GR_RW_DIRS; do
        [ -d "$1/$_gr_d" ] || continue
        mount --bind "$1/$_gr_d" "$2/$_gr_d" || return 1
    done
}

# gr_modules SYSMNT NEWROOT KREL: modules/<krel> (a subvolume) on
# /lib/modules/<krel>; 1 (and nothing mounted) if the kernel has none
gr_modules() {
    [ -d "$1/modules/$3" ] || return 1
    [ -d "$2/lib/modules/$3" ] || return 1
    mount --bind "$1/modules/$3" "$2/lib/modules/$3" && mount -o remount,bind,ro "$2/lib/modules/$3"
}

# gr_assemble SYSMNT UDDIR ID NEWROOT [KREL]: the deployment's root, locked, at
# NEWROOT. SYSMNT = the system partition's top level, UDDIR = <userdata>/<prefix>.
# The merged overlay itself is kept at NEWROOT.rw (moved along by the caller,
# or unmounted with gr_umount).
gr_assemble() {
    _gr_d=$2/deployments/$3
    [ -r "$_gr_d/meta" ] || { echo "glassine-root: no deployment $3" >&2; return 1; }
    _gr_l=$(gr_lowers "$1" "$_gr_d") || { echo "glassine-root: $3: its base is missing" >&2; return 1; }
    gr_mount_overlay "$4.rw" "$_gr_l" "$_gr_d/switch" "$_gr_d/work" || return 1
    gr_bind_locked "$4.rw" "$4" || { gr_umount "$4"; return 1; }
    [ -z "${5:-}" ] || gr_modules "$1" "$4" "$5" || echo "glassine-root: no modules for $5 (booting without)" >&2
    return 0
}

# gr_assemble_bare SYSMNT BASE NEWROOT [KREL]: no userdata: the base + a tmpfs
# upper (nothing carried, nothing kept), so a broken userdata never blocks a boot
gr_assemble_bare() {
    [ -d "$1/bases/$2" ] || return 1
    mkdir -p "$3.tmp" && mount -t tmpfs -o mode=0755 tmpfs "$3.tmp" || return 1
    gr_mount_overlay "$3.rw" "$1/bases/$2" "$3.tmp/upper" "$3.tmp/work" || return 1
    gr_bind_locked "$3.rw" "$3" || return 1
    [ -z "${4:-}" ] || gr_modules "$1" "$3" "$4" || echo "glassine-root: no modules for $4 (booting without)" >&2
    return 0
}

# gr_umount NEWROOT: everything gr_assemble* mounted, innermost first
gr_umount() {
    for _gr_m in $(awk -v r="$1" '$2 == r || index($2, r "/") == 1 || $2 == r ".rw" || $2 == r ".tmp" { print $2 }' /proc/mounts | sort -r); do
        umount "$_gr_m" 2>/dev/null || umount -l "$_gr_m"
    done
}

# gr_unlock / gr_lock ROOT: the / bind read-write / read-only again
gr_unlock() { mount -o remount,bind,rw "$1"; }
gr_lock() { mount -o remount,bind,ro "$1"; }

# gr_merged_ro SYSMNT DEPDIR DIR: a read-only view of a deployment (all its
# layers, no upper) at DIR, for copying its state while it is not running
gr_merged_ro() {
    _gr_l=$(gr_lowers "$1" "$2") || return 1
    [ -d "$2/switch" ] && _gr_l="$2/switch:$_gr_l"
    mkdir -p "$3" && mount -t overlay overlay -o "ro,lowerdir=$_gr_l" "$3"
}
