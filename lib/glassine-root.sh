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

# --- the boot (initramfs, docs/boot.md) ----------------------------------------
# gr_resume, then gr_boot, then (after the pre-switch-root hooks) gr_carry. The
# initramfs replaces gr_log with its kernel log and gr_wd_stop/gr_wd_start with
# its watchdog; GR_SYSPOWER and GR_TMP are for the host test.
GR_SYSPOWER=/sys/power
GR_TMP=/run/glassine-root
gr_log() { echo "glassine-root: $*" >&2; }
gr_wd_stop() { :; }
gr_wd_start() { :; }

# gr_would_pick STATEDIR: what gr_pick would boot, without writing anything
gr_would_pick() {
    _gr_s=$1/deploy
    _gr_cur=$(gs_kv "$_gr_s" current)
    _gr_cand=$(gs_kv "$_gr_s" candidate)
    _gr_t=$(gs_kv "$_gr_s" tries)
    case "$_gr_t" in ''|*[!0-9]*) _gr_t=0 ;; esac
    if [ -n "$_gr_cand" ] && [ "$_gr_cand" != "$_gr_cur" ] && [ "$_gr_t" -gt 0 ]; then
        echo "$_gr_cand"
    elif [ -n "$_gr_cur" ]; then echo "$_gr_cur"
    else gs_kv "$_gr_s" previous; fi
}

# The guard file (<prefix>/swap/hibernate.guard, written by the hibernate
# wrapper right before `echo disk`, gs_write), key=value:
#   mount_count  last_mount   userdata's ext4 "Mount count" / "Last mount time"
#                             at the hibernate (rule 4): gs_guard_mounts writes
#                             both, so the wrapper and the initramfs format
#                             them the same way (UTC, C locale)
#   deployment                the deployment it hibernated in (rule 7)
#   krel  kver                uname -r / uname -v of the hibernating kernel (rule 7)
# A missing key is a mismatch.

# gr_resume_refusal SYSDEV UDDEV PREFIX MAY: why the image must not be resumed
# (empty = resume). Reads userdata with debugfs only; mounts the system
# partition read-only without a log replay (rule 1), and unmounts it again.
gr_resume_refusal() {
    [ "$4" = resume ] || { echo "no resume on this boot ($4)"; return 0; }
    _gr_g=$(debugfs -R "cat /$3/swap/hibernate.guard" "$2" 2>/dev/null)
    [ -n "$_gr_g" ] || { echo "no guard file"; return 0; }
    for _gr_k in mount_count:"Mount count" last_mount:"Last mount time"; do
        _gr_v=$(printf '%s\n' "$_gr_g" | sed -n "s/^${_gr_k%%:*}=//p" | head -n 1)
        [ -n "$_gr_v" ] && [ "$_gr_v" = "$(gs_dumpe2fs "$2" "${_gr_k#*:}")" ] ||
            { echo "userdata was mounted since the hibernate (${_gr_k%%:*})"; return 0; }
    done
    _gr_v=$(printf '%s\n' "$_gr_g" | sed -n 's/^krel=//p' | head -n 1)
    [ -n "$_gr_v" ] && [ "$_gr_v" = "$(uname -r)" ] || { echo "another kernel release hibernated"; return 0; }
    _gr_v=$(printf '%s\n' "$_gr_g" | sed -n 's/^kver=//p' | head -n 1)
    [ -n "$_gr_v" ] && [ "$_gr_v" = "$(uname -v)" ] || { echo "another kernel build hibernated"; return 0; }
    _gr_v=$(printf '%s\n' "$_gr_g" | sed -n 's/^deployment=//p' | head -n 1)
    [ -n "$_gr_v" ] || { echo "the guard names no deployment"; return 0; }
    mkdir -p "$GR_TMP/peek" && mount -t btrfs -o ro,rescue=nologreplay "$1" "$GR_TMP/peek" 2>/dev/null ||
        { echo "cannot read the system partition's state"; return 0; }
    _gr_p=$(gr_would_pick "$GR_TMP/peek/state")
    umount "$GR_TMP/peek"
    [ "$_gr_p" = "$_gr_v" ] || { echo "state/ boots $_gr_p, the session ran $_gr_v"; return 0; }
}

# gr_resume SYSDEV UDDEV PREFIX MAY: before anything mounts either partition
# read-write. A hibernate image on userdata is resumed when MAY = resume and
# every check passes (the kernel does not return then); otherwise it is
# invalidated (rule 5), the only write before the mounts. MAY: resume, or a
# word saying why not (noresume, test-role). 0 = no image left (none,
# invalidated, or a block size other than 4096: the wrapper never hibernates
# there); 1 = an image that could not be invalidated: mount nothing read-write.
gr_resume() {
    _gr_sw=$3/swap/hibernate
    debugfs -R "stat /$_gr_sw" "$2" 2>/dev/null | grep -q '^Inode:' || return 0
    _gr_b=$(gs_dev_block "$2" "$_gr_sw") || { gr_log "hibernate file: no 4096-byte block, no resume"; return 0; }
    [ "$(gs_sig_dev "$2" "$_gr_b")" = "$GS_SIG_HIBERNATE" ] || return 0
    _gr_why=$(gr_resume_refusal "$1" "$2" "$3" "$4")
    if [ -z "$_gr_why" ]; then
        _gr_mm=$(stat -L -c '%t %T' "$2") && _gr_mm=$(printf '%d:%d' 0x${_gr_mm% *} 0x${_gr_mm#* })
        gr_log "resuming the hibernated session (block $_gr_b, $_gr_mm)"
        gr_wd_stop
        echo "$_gr_b" > "$GR_SYSPOWER/resume_offset" && echo "$_gr_mm" > "$GR_SYSPOWER/resume"
        gr_wd_start
        _gr_why="the kernel did not resume it"
    fi
    gr_log "hibernated session not resumed: $_gr_why; invalidating it"
    gs_invalidate_dev "$2" "$_gr_b" && [ "$(gs_sig_dev "$2" "$_gr_b")" != "$GS_SIG_HIBERNATE" ] && return 0
    gr_log "cannot invalidate the hibernate image"
    return 1
}

# gr_boot SYSDEV UDDEV PREFIX NEWROOT KREL: after gr_resume. The system
# partition read-write at NEWROOT.sys with its state locked (fd 9, until
# gr_carry), userdata checked and mounted at NEWROOT.ud, the deployment picked
# (gr_pick: a try used) and assembled at NEWROOT. One that does not assemble is
# skipped (a candidate is marked failed) for current, then previous. Without
# userdata (UDDEV empty or not mountable) or any deployment: bare, on the
# current deployment's base or else the last base by name. A state format
# newer than this code, or a held lock: the state is read, never written.
# Sets GR_BOOTED (the id, or bare:<base>). 1 = nothing bootable, nothing left
# mounted.
gr_boot() {
    _gr_sm=$4.sys _gr_um=$4.ud GR_BOOTED='' _gr_ud=''
    mkdir -p "$_gr_sm" && mount -t btrfs -o rw,noatime "$1" "$_gr_sm" || { gr_log "cannot mount $1"; return 1; }
    _gr_f=$(gs_format_version "$_gr_sm")
    [ "$_gr_f" != none ] || { gr_log "the system partition has no state/ (not migrated)"; umount "$_gr_sm"; return 1; }
    _gr_rw=1
    gs_format_ok "$_gr_f" || { gr_log "state format $_gr_f is newer than this initramfs: state read only"; _gr_rw=0; }
    [ $_gr_rw = 0 ] || gs_lock "$_gr_sm/state" || { gr_log "state is locked: read only"; _gr_rw=0; }
    if [ -n "$2" ] && [ -e "$2" ]; then
        e2fsck -p "$2" >/dev/null 2>&1; _gr_rc=$?
        [ $_gr_rc -lt 4 ] || gr_log "e2fsck -p $2: exit $_gr_rc (mounting anyway)"
        if mkdir -p "$_gr_um" && mount -t ext4 -o rw,noatime "$2" "$_gr_um"; then _gr_ud=$_gr_um/$3
        else gr_log "userdata does not mount: bare boot"; fi
    fi
    _gr_st=$_gr_sm/state/deploy
    if [ -n "$_gr_ud" ]; then
        if [ $_gr_rw = 1 ]; then _gr_id=$(gr_pick "$_gr_sm/state"); else _gr_id=$(gr_would_pick "$_gr_sm/state"); fi
        for _gr_try in "$_gr_id" "$(gs_kv "$_gr_st" current)" "$(gs_kv "$_gr_st" previous)"; do
            [ -n "$_gr_try" ] || continue
            if gr_assemble "$_gr_sm" "$_gr_ud" "$_gr_try" "$4" "$5"; then GR_BOOTED=$_gr_try; return 0; fi
            gr_log "deployment $_gr_try does not assemble"
            [ $_gr_rw = 1 ] && [ "$_gr_try" = "$(gs_kv "$_gr_st" candidate)" ] &&
                gs_update "$_gr_st" candidate= tries=0 "failed=$_gr_try"
        done
    fi
    _gr_base=''
    [ -z "$_gr_ud" ] || _gr_base=$(gs_kv "$_gr_ud/deployments/$(gs_kv "$_gr_st" current)/meta" base)
    [ -n "$_gr_base" ] && [ -d "$_gr_sm/bases/$_gr_base" ] || _gr_base=$(ls -1 "$_gr_sm/bases" 2>/dev/null | sort | tail -n 1)
    if [ -n "$_gr_base" ] && gr_assemble_bare "$_gr_sm" "$_gr_base" "$4" "$5"; then
        gr_log "bare boot on base $_gr_base (nothing kept)"
        GR_BOOTED=bare:$_gr_base; return 0
    fi
    gr_log "nothing to boot"
    gr_boot_umount "$4"
    return 1
}

# gr_boot_umount NEWROOT: undo gr_boot (and gr_carry), the lock released
gr_boot_umount() {
    exec 9>&-                   # the lock file is open on $1.sys
    gr_umount "$1"
    umount "$1.ud" 2>/dev/null; umount "$1.sys" 2>/dev/null
}

# gr_carry NEWROOT: right before switch_root. A tmpfs on NEWROOT/run (the init
# system keeps a mounted /run), the system partition, userdata and the merged
# overlay moved to /run/glassine/{system,userdata,root} (deploy.conf's
# SYSTEM_MNT, USERDATA_MNT), a bare boot's tmpfs to /run/glassine/bare, the
# booted deployment in /run/glassine/booted (for the boot-success service's
# accept); the state lock released, so the system's glassine-deploy can take it.
gr_carry() {
    _gr_r=$1/run/glassine
    # a base without /run: made in the overlay underneath (/ is read-only)
    [ -d "$1/run" ] || mkdir -p "$1.rw/run" || return 1
    mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$1/run" || return 1
    mkdir -p "$_gr_r/system" "$_gr_r/userdata" "$_gr_r/root" || return 1
    mount --move "$1.sys" "$_gr_r/system" || return 1
    if mountpoint -q "$1.ud"; then mount --move "$1.ud" "$_gr_r/userdata" || return 1; fi
    mount --move "$1.rw" "$_gr_r/root" || return 1
    if mountpoint -q "$1.tmp"; then mkdir -p "$_gr_r/bare" && mount --move "$1.tmp" "$_gr_r/bare" || return 1; fi
    echo "$GR_BOOTED" > "$_gr_r/booted"
    exec 9>&-
}
