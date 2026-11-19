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
# it (done here in the initramfs until a boot loader takes over the try counter,
# docs/deployments.md): a candidate with tries left uses one; a candidate with
# none left is failed (state failed=<id>) and current boots; no current: previous. Prints the id (empty: nothing to boot). Writes
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
# /lib/modules/<krel>, and its firmware/ on /lib/firmware/updates (searched before
# /lib/firmware), both read-only; 1 (and nothing mounted) if the kernel has none.
# The base needs no knowledge of the release: the mount points are made through the
# merged root NEWROOT.rw, since NEWROOT itself is the locked (read-only) view.
gr_modules() {
    [ -d "$1/modules/$3" ] || return 1
    mkdir -p "$2.rw/lib/modules/$3" || return 1
    mount --bind "$1/modules/$3" "$2/lib/modules/$3" || return 1
    mount -o remount,bind,ro "$2/lib/modules/$3" || { umount "$2/lib/modules/$3"; return 1; }
    [ -d "$1/modules/$3/firmware" ] || return 0
    if mkdir -p "$2.rw/lib/firmware/updates" && mount --bind "$1/modules/$3/firmware" "$2/lib/firmware/updates"; then
        mount -o remount,bind,ro "$2/lib/firmware/updates" && return 0
        umount "$2/lib/firmware/updates"
    fi
    gr_log "$3's firmware not bound on /lib/firmware/updates (its modules are)"
    return 0
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
    [ -z "${5:-}" ] || gr_modules "$1" "$4" "$5" || gr_log "no modules for $5 (booting without)"
    return 0
}

# gr_assemble_bare SYSMNT BASE NEWROOT [KREL]: no userdata: the base + a tmpfs
# upper (nothing carried, nothing kept), so a broken userdata never blocks a boot
gr_assemble_bare() {
    [ -d "$1/bases/$2" ] || return 1
    mkdir -p "$3.tmp" && mount -t tmpfs -o mode=0755 tmpfs "$3.tmp" || return 1
    gr_mount_overlay "$3.rw" "$1/bases/$2" "$3.tmp/upper" "$3.tmp/work" || return 1
    gr_bind_locked "$3.rw" "$3" || return 1
    [ -z "${4:-}" ] || gr_modules "$1" "$3" "$4" || gr_log "no modules for $4 (booting without)"
    return 0
}

# The person's storage (docs/deployments.md, "The person's storage"): directories
# under the userdata prefix, outside the deployments, bound into the booted
# deployment by the boot (gr_boot), never by glassine-deploy's views. NAME:PATH,
# PATH relative to the root.
GR_STORAGE_DIRS='home:home flatpak:var/lib/flatpak'

# gr_vartmp NEWROOT: /var/tmp a bind of itself, made shared (Flatpak's sandboxes
# see mounts made under it later); its files stay in the deployment's /var.
# Sets GR_VARTMP (shared, or failed).
gr_vartmp() {
    GR_VARTMP=failed
    [ -d "$1/var/tmp" ] || mkdir -p "$1.rw/var/tmp" || { gr_log "/var/tmp: cannot create it, not shared"; return 0; }
    mount --bind "$1/var/tmp" "$1/var/tmp" || { gr_log "/var/tmp: cannot bind it, not shared"; return 0; }
    if mount --make-shared "$1/var/tmp"; then GR_VARTMP=shared
    else umount "$1/var/tmp"; gr_log "/var/tmp: cannot make it shared"; fi
    return 0
}

# gr_storage UDDIR NEWROOT: each GR_STORAGE_DIRS entry: UDDIR/NAME (created on
# first use, root:root 0755) bound on NEWROOT/PATH (its mount point made through
# the merged root NEWROOT.rw when the deployment has none). The deployment's own
# directory is hidden by the bind, never moved or deleted. A directory that
# can't be created, or a bind that fails, is logged and left out: the boot goes
# on with the deployment's own directory, and nothing is written into UDDIR.
# Never fails. Sets GR_STORAGE: key=value lines for /run/glassine/storage
# (gr_carry): NAME=bound|failed, NAME_error=<why>, vartmp=shared|failed.
gr_storage() {
    GR_STORAGE=''
    for _gr_e in $GR_STORAGE_DIRS; do
        _gr_n=${_gr_e%%:*} _gr_p=${_gr_e#*:} _gr_why=''
        _gr_src=$1/$_gr_n
        if [ ! -d "$_gr_src" ]; then
            if mkdir "$_gr_src" 2>/dev/null; then
                chown 0:0 "$_gr_src" && chmod 0755 "$_gr_src" || _gr_why="cannot set the owner and mode of $_gr_n/"
            else _gr_why="cannot create $_gr_n/ on userdata"; fi
        fi
        if [ -z "$_gr_why" ] && [ ! -d "$2/$_gr_p" ]; then
            mkdir -p "$2.rw/$_gr_p" 2>/dev/null || _gr_why="cannot create the mount point /$_gr_p"
        fi
        [ -n "$_gr_why" ] || mount --bind "$_gr_src" "$2/$_gr_p" || _gr_why="the bind on /$_gr_p failed"
        if [ -z "$_gr_why" ]; then
            GR_STORAGE="$GR_STORAGE$_gr_n=bound
"
        else
            gr_log "/$_gr_p: $_gr_why; the deployment's own /$_gr_p stays (tried again at the next boot)"
            GR_STORAGE="$GR_STORAGE$_gr_n=failed
${_gr_n}_error=$_gr_why
"
        fi
    done
    gr_vartmp "$2"
    GR_STORAGE="${GR_STORAGE}vartmp=$GR_VARTMP
"
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

# gr_shutdown_ro DEV: at power-off, after OpenRC's mount-ro: DEV's file system
# read-only, and with it every mount and bind of it. In the deployments layout
# userdata is no longer in the mount table by then (localmount's stop unmounts
# /run/glassine/*, while the overlay's upper layer keeps the file system alive),
# so mount-ro never reaches it and its ext4 journal would need a replay at the
# next boot. Mounting DEV again gets that same live file system; remounting
# the new mount read-only makes the file system read-only (ext4 clean), then
# the mount goes. A file system that is not alive (a bare boot never mounted
# userdata) is left alone: no mount, no write. 0 = read-only or not in use;
# 1 = still writable (said).
gr_shutdown_ro() {
    _gr_k=$(readlink -f "$1" 2>/dev/null) && [ -b "$_gr_k" ] || return 0
    _gr_k=${_gr_k##*/}
    if [ -d "/sys/fs/ext4/$_gr_k" ]; then _gr_t=ext4
    elif ls -d /sys/fs/btrfs/*/devices/"$_gr_k" >/dev/null 2>&1; then _gr_t=btrfs
    else return 0; fi
    sync
    mkdir -p "$GR_TMP/ro" || { gr_log "$1: cannot make $GR_TMP/ro, left writable"; return 1; }
    # read-write, as the live file system is (an ext4 already read-only refuses
    # it: then ro below; btrfs turns a read-only one read-write for it, and the
    # remount turns it back)
    if mount -t "$_gr_t" "$1" "$GR_TMP/ro" 2>/dev/null; then
        mount -o remount,ro "$GR_TMP/ro"; _gr_rc=$?
        umount "$GR_TMP/ro" 2>/dev/null || umount -l "$GR_TMP/ro"
        [ $_gr_rc = 0 ] && return 0
        gr_log "$1: cannot remount read-only (still in use), left writable"; return 1
    fi
    mount -t "$_gr_t" -o ro "$1" "$GR_TMP/ro" 2>/dev/null && { umount "$GR_TMP/ro"; return 0; }
    gr_log "$1: cannot mount it again, left writable"; return 1
}

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

# gr_kernel_mode SYSDEV IMG: what this boot of image IMG (its glassine.img=)
# is to the kernel records (gs_kernel_boot: trial, finishing or empty), read
# before gr_resume from the system partition mounted read-only without a log
# replay (rule 1). A state format newer than this code: empty (FR-011).
gr_kernel_mode() {
    [ -n "$2" ] || return 0
    mkdir -p "$GR_TMP/peek" && mount -t btrfs -o ro,rescue=nologreplay "$1" "$GR_TMP/peek" 2>/dev/null || return 0
    gs_format_ok "$(gs_format_version "$GR_TMP/peek")" && gs_kernel_boot "$GR_TMP/peek/state/kernel" "$2"
    umount "$GR_TMP/peek"
    return 0
}

# gr_resume SYSDEV UDDEV PREFIX MAY: before anything mounts either partition
# read-write. A hibernate image on userdata is resumed when MAY = resume and
# every check passes (the kernel does not return then); otherwise it is
# invalidated (rule 5), the only write before the mounts. MAY: resume, or a
# word saying why not (noresume, test-role). GR_ONCE_REQ: a deployment request
# that a resume drops (said before the resume write). 0 = no image left (none,
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
        [ -z "${GR_ONCE_REQ:-}" ] || gr_log "deployment request $GR_ONCE_REQ dropped: the hibernated session comes first"
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

# gr_boot SYSDEV UDDEV PREFIX NEWROOT KREL [IMG] [ONCE]: after gr_resume. The system
# partition read-write at NEWROOT.sys with its state locked (fd 9, until
# gr_carry), userdata checked and mounted at NEWROOT.ud, the deployment picked
# (gr_pick: a try used) and assembled at NEWROOT. IMG is this boot's
# glassine.img=: when state/kernel makes it a kernel trial or a finishing boot
# (gs_kernel_boot, GR_KBOOT), the current deployment boots with no pick and no
# deployment try, and a trial takes its kernel try (tries=0, requested
# cleared, one write; FR-011). One that does not assemble is
# skipped (a candidate is marked failed) for current, then previous. Without
# userdata (UDDEV empty or not mountable) or any deployment: bare, on the
# current deployment's base or else the last base by name. A state format
# newer than this code, or a held lock: the state is read, never written.
# A hibernate guard left on userdata (the image was invalidated) is removed.
# A deployment gets the person's storage (gr_storage), a bare boot only the
# shared /var/tmp (nothing from userdata).
# ONCE is the one-shot deployment request (glassine.deploy.once=, 010 FR-042 to
# FR-047): that deployment boots in place of the pick, for this start only, with
# no state written and no try used or given back. A trial or finishing boot takes
# none; one that names a deployment that isn't there, is staged or doesn't
# assemble is dropped with a message, and the ordinary pick runs (nothing is
# marked failed).
# Sets GR_BOOTED (the id, or bare:<base>), GR_KBOOT, GR_ONCE (ONCE, when it
# booted) and GR_STORAGE. 1 = nothing bootable, nothing left mounted.
gr_boot() {
    _gr_sm=$4.sys _gr_um=$4.ud GR_BOOTED='' GR_KBOOT='' GR_ONCE='' GR_STORAGE='' GR_TRY='' GR_NOTE='' _gr_ud=''
    mkdir -p "$_gr_sm" && mount -t btrfs -o rw,noatime "$1" "$_gr_sm" || { gr_log "cannot mount $1"; return 1; }
    _gr_f=$(gs_format_version "$_gr_sm")
    [ "$_gr_f" != none ] || { gr_log "the system partition has no state/ (not migrated)"; umount "$_gr_sm"; return 1; }
    _gr_rw=1
    gs_format_ok "$_gr_f" || { gr_log "state format $_gr_f is newer than this initramfs: state read only"; _gr_rw=0; }
    [ $_gr_rw = 0 ] || gs_lock "$_gr_sm/state" || { gr_log "state is locked: read only"; _gr_rw=0; }
    ! gs_format_ok "$_gr_f" || GR_KBOOT=$(gs_kernel_boot "$_gr_sm/state/kernel" "${6:-}")
    if [ "$GR_KBOOT" = trial ]; then
        if [ $_gr_rw = 1 ] && gs_update "$_gr_sm/state/kernel" tries=0 requested=; then
            gr_log "kernel trial of image $6: its try taken"
        else gr_log "kernel trial of image $6: its try could not be taken (the state is read only, or its write failed)"; fi
    fi
    if [ -n "$2" ] && [ -e "$2" ]; then
        e2fsck -p "$2" >/dev/null 2>&1; _gr_rc=$?
        [ $_gr_rc -lt 4 ] || gr_log "e2fsck -p $2: exit $_gr_rc (mounting anyway)"
        if mkdir -p "$_gr_um" && mount -t ext4 -o rw,noatime "$2" "$_gr_um"; then _gr_ud=$_gr_um/$3
            # gr_resume left no image: a guard still here belongs to none
            rm -f "$_gr_ud/swap/hibernate.guard"
            # a soft restart that turned cold left why (gr_soft_cold_note): said once
            if [ -e "$_gr_ud/restart.cold" ]; then
                GR_NOTE=$(head -n 1 "$_gr_ud/restart.cold" 2>/dev/null)
                case $GR_NOTE in ''|*[!a-z-]*) GR_NOTE=unknown ;; esac
                rm -f "$_gr_ud/restart.cold"
            fi
        else gr_log "userdata does not mount: bare boot"; fi
    fi
    GR_SOFT=0
    gr_boot_pick "$@"
}

# gr_soft_boot PREFIX NEWROOT KREL [ONCE]: the assembly of a soft start (specs/013):
# the same pick and assembly as gr_boot, on the system partition and userdata that
# stayed mounted through the restart (NEWROOT.sys, NEWROOT.ud: mounts of the live
# file systems, made by the restart step: no fsck, no mount count, no journal
# replay, FR-023). No kernel trial (a restart that would be one is cold), no
# command-line request (FR-018); ONCE is the restart's own (FR-013). Differences
# from a cold start: the candidate's try is not written here but by gr_carry right
# before the hand-over (GR_TRY, FR-015), and where the pick would end in a bare
# boot nothing is assembled (FR-014: the restart turns cold). 1 = nothing
# assembled, nothing of it left mounted (the two mounts stay), 2 = the same, and
# the state can't be written (a newer format, a held lock).
gr_soft_boot() {
    _gr_sm=$2.sys _gr_um=$2.ud GR_BOOTED='' GR_KBOOT='' GR_ONCE='' GR_STORAGE='' GR_TRY='' GR_NOTE='' _gr_ud=''
    mountpoint -q "$_gr_sm" || { gr_log "soft start: the system partition is not at $_gr_sm"; return 1; }
    mountpoint -q "$_gr_um" || { gr_log "soft start: userdata is not at $_gr_um"; return 1; }
    _gr_ud=$_gr_um/$1
    _gr_f=$(gs_format_version "$_gr_sm")
    gs_format_ok "$_gr_f" || { gr_log "soft start: state format $_gr_f is not this initramfs's"; return 2; }
    gs_lock "$_gr_sm/state" || { gr_log "soft start: the state is locked"; return 2; }
    _gr_rw=1 GR_SOFT=1
    gr_boot_pick "$_gr_sm" "$_gr_um" "$1" "$2" "$3" '' "${4:-}"
}

# gr_boot_pick SYSDEV UDDEV PREFIX NEWROOT KREL [IMG] [ONCE]: gr_boot's pick,
# assembly and storage, with the system partition at NEWROOT.sys and userdata's
# prefix at _gr_ud (empty: not mounted), _gr_rw and GR_SOFT set by the caller
gr_boot_pick() {
    _gr_st=$_gr_sm/state/deploy
    _gr_o=${7:-}
    if [ -n "$_gr_o" ]; then
        if [ -z "$_gr_ud" ]; then gr_log "deployment request $_gr_o dropped: userdata is not mounted"
        elif [ -n "$GR_KBOOT" ]; then gr_log "deployment request $_gr_o dropped: a kernel $GR_KBOOT boot takes none"
        elif [ ! -r "$_gr_ud/deployments/$_gr_o/meta" ]; then gr_log "deployment request $_gr_o dropped: there is no such deployment (the ordinary pick runs)"
        elif [ "$_gr_o" = "$(gs_kv "$_gr_st" staged)" ]; then gr_log "deployment request $_gr_o dropped: it is staged (the ordinary pick runs)"
        elif gr_assemble "$_gr_sm" "$_gr_ud" "$_gr_o" "$4" "$5"; then
            gr_log "deployment $_gr_o by request, for this start only (no pick, state/deploy not written)"
            GR_BOOTED=$_gr_o GR_ONCE=$_gr_o
            gr_storage "$_gr_ud" "$4"
            return 0
        else gr_log "deployment request $_gr_o dropped: it does not assemble (the ordinary pick runs)"
        fi
    fi
    if [ -n "$_gr_ud" ]; then
        if [ -n "$GR_KBOOT" ]; then
            _gr_id=$(gs_kv "$_gr_st" current)
            gr_log "kernel $GR_KBOOT boot: the current deployment ${_gr_id:-(none)}, no pick"
        elif [ "$GR_SOFT" = 1 ]; then _gr_id=$(gr_pick_soft "$_gr_sm/state")
        elif [ $_gr_rw = 1 ]; then _gr_id=$(gr_pick "$_gr_sm/state"); else _gr_id=$(gr_would_pick "$_gr_sm/state"); fi
        for _gr_try in "$_gr_id" "$(gs_kv "$_gr_st" current)" "$(gs_kv "$_gr_st" previous)"; do
            [ -n "$_gr_try" ] || continue
            if gr_assemble "$_gr_sm" "$_gr_ud" "$_gr_try" "$4" "$5"; then
                GR_BOOTED=$_gr_try
                # a soft start's try, written by gr_carry (FR-015): what gr_pick
                # writes at a cold start, so the state ends the same byte for byte
                if [ "$GR_SOFT" = 1 ] && [ "$_gr_try" = "$(gs_kv "$_gr_st" candidate)" ] && [ "$_gr_try" != "$(gs_kv "$_gr_st" current)" ]; then
                    _gr_t=$(gs_kv "$_gr_st" tries)
                    case "$_gr_t" in ''|*[!0-9]*) _gr_t=0 ;; esac
                    [ "$_gr_t" -gt 0 ] && GR_TRY="tries=$((_gr_t - 1))"
                fi
                gr_storage "$_gr_ud" "$4"
                return 0
            fi
            gr_log "deployment $_gr_try does not assemble"
            [ $_gr_rw = 1 ] && [ "$_gr_try" = "$(gs_kv "$_gr_st" candidate)" ] &&
                gs_update "$_gr_st" candidate= tries=0 "failed=$_gr_try"
        done
    fi
    if [ "$GR_SOFT" = 1 ]; then
        gr_log "soft start: no deployment assembles (a cold start would boot bare): the restart turns cold"
        exec 9>&-
        return 1
    fi
    _gr_base=''
    [ -z "$_gr_ud" ] || _gr_base=$(gs_kv "$_gr_ud/deployments/$(gs_kv "$_gr_st" current)/meta" base)
    [ -n "$_gr_base" ] && [ -d "$_gr_sm/bases/$_gr_base" ] || _gr_base=$(ls -1 "$_gr_sm/bases" 2>/dev/null | sort | tail -n 1)
    if [ -n "$_gr_base" ] && gr_assemble_bare "$_gr_sm" "$_gr_base" "$4" "$5"; then
        gr_log "bare boot on base $_gr_base (nothing kept)"
        GR_BOOTED=bare:$_gr_base
        gr_vartmp "$4"
        GR_STORAGE="vartmp=$GR_VARTMP
"
        return 0
    fi
    gr_log "nothing to boot"
    gr_boot_umount "$4"
    return 1
}

# gr_pick_soft STATEDIR: gr_pick for a soft start: the same choice and the same
# failed mark, but the candidate's try is left to gr_carry (GR_TRY, FR-015)
gr_pick_soft() {
    _gr_s=$1/deploy
    _gr_cur=$(gs_kv "$_gr_s" current)
    _gr_cand=$(gs_kv "$_gr_s" candidate)
    _gr_t=$(gs_kv "$_gr_s" tries)
    case "$_gr_t" in ''|*[!0-9]*) _gr_t=0 ;; esac
    if [ -n "$_gr_cand" ] && [ "$_gr_cand" != "$_gr_cur" ]; then
        [ "$_gr_t" -gt 0 ] && { echo "$_gr_cand"; return 0; }
        gs_update "$_gr_s" candidate= tries=0 "failed=$_gr_cand" || return 1
    fi
    if [ -n "$_gr_cur" ]; then echo "$_gr_cur"; else gs_kv "$_gr_s" previous; fi
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
# accept), GR_KBOOT in /run/glassine/kernel-boot (that service skips a kernel
# trial or finishing boot), GR_ONCE in /run/glassine/deploy-once (a deployment
# started by request: that service accepts nothing), GR_STORAGE in
# /run/glassine/storage (what glassine-deploy status reports); the state lock
# released, so the system's glassine-deploy can take it.
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
    echo "${GR_KBOOT:-}" > "$_gr_r/kernel-boot"
    echo "${GR_ONCE:-}" > "$_gr_r/deploy-once"
    printf '%s' "${GR_STORAGE:-}" > "$_gr_r/storage"
    # how this start came (013 FR-008): kind, the outgoing deployment, the soft
    # starts in this kernel run, the start's time on /proc/uptime; what a soft
    # restart's switch did; why the soft restart before this cold start turned cold
    read -r _gr_up _gr_x < /proc/uptime || _gr_up=''
    {
        echo "kind=${GR_RS_KIND:-cold}"
        echo "from=${GR_RS_FROM:-}"
        echo "count=${GR_RS_COUNT:-0}"
        echo "at=$_gr_up"
        [ -z "${GR_RS_SWITCH:-}" ] || printf '%s\n' "$GR_RS_SWITCH"
        [ -z "${GR_NOTE:-}" ] || echo "cold_reason=$GR_NOTE"
    } > "$_gr_r/restart" || return 1
    # the kernel run's files a soft start carries (FR-024)
    if [ -n "${GR_CARRY_FROM:-}" ]; then
        for _gr_c in kernel-boot loader-marked health-failed limit-done; do
            [ ! -e "$GR_CARRY_FROM/$_gr_c" ] || cp "$GR_CARRY_FROM/$_gr_c" "$_gr_r/$_gr_c" || return 1
        done
    fi
    # the kept assembly (FR-025), or why there is none
    if [ -n "${GR_KEEP_SRC:-}" ]; then
        gr_keep "$GR_KEEP_SRC" "$_gr_r/kept" || { rm -rf "$_gr_r/kept"; echo no-assembly > "$_gr_r/kept.none"; }
    else echo "${GR_KEEP_NONE:-no-assembly}" > "$_gr_r/kept.none"
    fi
    # a soft start's try, the last write before the hand-over (FR-015)
    if [ -n "${GR_TRY:-}" ]; then
        gs_update "$_gr_r/system/state/deploy" "$GR_TRY" || return 1
        gr_log "deployment $GR_BOOTED: its try taken ($GR_TRY)"
    fi
    exec 9>&-
}

# gr_keep SRC DEST: the kept assembly (013 FR-025): of the image at SRC (the
# initramfs's root, or a soft start's stage, which holds the same files) what a soft
# start runs: /init, /soft, busybox, the boot libraries and board.conf; not the boot
# modules, the developer hooks or their files (steps of a cold start only). DEST/.complete
# last, so a cut copy is never taken. Kept in /run (a tmpfs: memory) for the kernel run.
gr_keep() {
    rm -rf "$2" && mkdir -p "$2/bin" "$2/lib/glassine-boot" || return 1
    cp "$1/init" "$1/soft" "$2/" && cp "$1/bin/busybox" "$2/bin/busybox" &&
        cp "$1"/lib/glassine-boot/glassine-*.sh "$2/lib/glassine-boot/" || return 1
    if [ -r "$1/etc/glassine-boot/board.conf" ]; then
        mkdir -p "$2/etc/glassine-boot" && cp "$1/etc/glassine-boot/board.conf" "$2/etc/glassine-boot/" || return 1
    fi
    : > "$2/.complete"
}

# gr_umount_strict DIR SECONDS: every mount at or below DIR unmounted, deepest
# first, none lazily (013 FR-022), retried for up to SECONDS; GR_FEED (a command,
# may be empty) runs between tries. 1 = a mount stayed (GR_WHY names it).
gr_umount_strict() {
    _gr_n=0
    while :; do
        _gr_left=''
        for _gr_m in $(awk -v r="$1" '$2 == r || index($2, r "/") == 1 { print $2 }' /proc/mounts | sort -r); do
            _gr_m=$(printf '%b' "$_gr_m")
            umount "$_gr_m" 2>/dev/null || _gr_left="$_gr_left $_gr_m"
        done
        [ -n "$_gr_left" ] || return 0
        [ "$_gr_n" -lt "$2" ] || { GR_WHY="still mounted:$_gr_left"; return 1; }
        ${GR_FEED:-:}
        sleep 1; _gr_n=$((_gr_n + 1))
    done
}

# gr_procs_left: GR_LEFT = the processes other than this shell and the kernel's
# threads (PF_KTHREAD in /proc/PID/stat), as "PID:COMM" words; empty when none is
# left. No command substitution (its own subshell would count): builtins only.
gr_procs_left() {
    GR_LEFT=''
    for _gr_p in /proc/[0-9]*; do
        _gr_i=${_gr_p#/proc/}
        [ "$_gr_i" != "$$" ] || continue
        read -r _gr_s < "$_gr_p/stat" 2>/dev/null || continue
        _gr_c=${_gr_s#*\(}; _gr_c=${_gr_c%\)*}
        # the fields after the command name's closing parenthesis; flags is the 7th
        set -f; set -- ${_gr_s##*) }; set +f
        [ $# -ge 7 ] || continue
        # a zombie holds nothing (its parent, this shell, reaps it); a kernel thread
        [ "$1" != Z ] || continue
        [ $(( $7 & 0x00200000 )) = 0 ] || continue
        GR_LEFT="$GR_LEFT $_gr_i:$_gr_c"
    done
    GR_LEFT=${GR_LEFT# }
}

# gr_procs_end SECONDS: every process but PID 1 and the kernel's threads ended
# (013 FR-020, FR-022): killed, waited for up to SECONDS; GR_FEED between tries.
# 1 = some remain (GR_WHY names them: one in uninterruptible sleep, one the kill
# can't reach).
gr_procs_end() {
    _gr_n=0
    while :; do
        kill -9 -1 2>/dev/null
        gr_procs_left
        [ -n "$GR_LEFT" ] || return 0
        [ "$_gr_n" -lt "$1" ] || { GR_WHY="processes left: $GR_LEFT"; return 1; }
        ${GR_FEED:-:}
        sleep 1; _gr_n=$((_gr_n + 1))
    done
}
