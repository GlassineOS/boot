# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-state.sh: shared helpers for the deployment state on the system
# partition and for the hibernate guard on userdata. Sourced (not run) by
# glassine-deploy, the boot initramfs and the hibernate wrapper, so all of
# them read and write the same files the same way. busybox ash only: no
# bash-isms, no util-linux (it runs in the initramfs and in recovery).
#
# Files (paths relative to their file system, see glassine-deploy):
#   system:   state/format (version=N), state/deploy, state/kernel   key=value
#             (state/kernel's keys: docs/kernel-artifacts.md)
#   userdata: <prefix>/swap/hibernate (swap file), <prefix>/swap/hibernate.guard
#
# Writes are atomic: temp file in the same directory, data synced, renamed,
# then a sync so the rename is on disk (the initramfs reads the guard with
# debugfs, which sees only the disk). Nothing here mounts anything.

GS_FORMAT_SUPPORTED=1
# the 10-byte signatures at byte 4086 of a swap file's first page
GS_SIG_OFF=4086
GS_SIG_SWAP=SWAPSPACE2
GS_SIG_HIBERNATE=S1SUSPEND

# gs_kv FILE KEY: the value of KEY (first match); empty if the file or key is missing
gs_kv() {
    [ -r "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | head -n 1
}

# gs_write FILE < content: atomic replace of FILE
gs_write() {
    _gs_t="$1.tmp.$$"
    dd of="$_gs_t" conv=fsync 2>/dev/null || { rm -f "$_gs_t"; return 1; }
    mv -f "$_gs_t" "$1" || { rm -f "$_gs_t"; return 1; }
    sync
}

# gs_update FILE KEY=VALUE…: replace several keys of a key=value file in one
# atomic write (other keys are kept)
gs_update() {
    _gs_f=$1; shift
    _gs_re=''
    for _gs_a in "$@"; do _gs_re="$_gs_re${_gs_re:+|}^${_gs_a%%=*}="; done
    { [ -r "$_gs_f" ] && grep -Ev "$_gs_re" "$_gs_f"; printf '%s\n' "$@"; } | gs_write "$_gs_f"
}

# gs_set FILE KEY VALUE: rewrite one key of a key=value file atomically
gs_set() { gs_update "$1" "$2=$3"; }

# gs_lock STATEDIR: take state/.lock (flock, fd 9, held until exit); 1 if busy
gs_lock() {
    exec 9>>"$1/.lock" || return 1
    flock -n 9
}

# gs_format_version SYSDIR: the state format of a mounted system partition
# (top level at SYSDIR); "none" when it has no state/ (not migrated)
gs_format_version() {
    [ -e "$1/state/format" ] || { echo none; return 0; }
    _gs_v=$(gs_kv "$1/state/format" version)
    echo "${_gs_v:-invalid}"
}

# gs_format_ok VERSION: 0 if this code can read and write that format
gs_format_ok() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "$1" -le "$GS_FORMAT_SUPPORTED" ]
}

# --- the kernel state (state/kernel, docs/kernel-artifacts.md) ---------------
# gs_img_id CMDLINEFILE: the glassine.img= of a kernel command line (the image
# a boot runs), empty if none
gs_img_id() {
    sed -n 's/.*glassine[._]img=\([0-9a-f]*\).*/\1/p' "$1" 2>/dev/null | head -n 1
}

# gs_kernel_candidate FILE: the kernel candidate (its release, else its image
# id), empty when none is set
gs_kernel_candidate() {
    _gs_c=$(gs_kv "$1" candidate)
    [ -n "$_gs_c" ] || _gs_c=$(gs_kv "$1" candidate_img)
    echo "$_gs_c"
}

# gs_kernel_boot FILE IMG: what a boot of image IMG is to state/kernel FILE
# (FR-011): `finishing` (IMG is `writing`: a default-slot write started and
# its state write didn't happen), `trial` (IMG is `candidate_img`), or empty
gs_kernel_boot() {
    [ -n "$2" ] && [ -r "$1" ] || return 0
    if [ "$2" = "$(gs_kv "$1" writing)" ]; then echo finishing
    elif [ "$2" = "$(gs_kv "$1" candidate_img)" ]; then echo trial
    fi
}

# gs_kernel_cancel FILE: drop the kernel candidate (glassine-bootimg cancel);
# the default boot and the image files are left alone
gs_kernel_cancel() { gs_update "$1" candidate= candidate_img= tries= requested=; }

# gs_kernel_refusal FILE CMDLINEFILE KREL: why the next boot could run another
# kernel image than this boot (KREL = uname -r), or skip the resume; empty if
# it can't. glassine-hibernate refuses then: the initramfs would not resume the
# session under another kernel, or on a trial or finishing boot.
gs_kernel_refusal() {
    [ -r "$1" ] || return 0
    _gs_run=$(gs_img_id "$2")
    _gs_v=$(gs_kv "$1" writing)
    [ -z "$_gs_v" ] || { echo "a write of the default boot slot is unfinished (image $_gs_v)"; return 0; }
    _gs_v=$(gs_kv "$1" candidate_img)
    [ -n "$_gs_v" ] && [ "$_gs_run" = "$_gs_v" ] && { echo "this boot is a kernel trial (image $_gs_v)"; return 0; }
    _gs_v=$(gs_kv "$1" current_img)
    if [ -n "$_gs_v" ]; then
        [ "$_gs_run" = "$_gs_v" ] || echo "the next boot runs kernel image $_gs_v, this boot runs ${_gs_run:-an unknown image}"
        return 0
    fi
    _gs_v=$(gs_kv "$1" current)
    [ -z "$_gs_v" ] || [ "$_gs_v" = "$3" ] || echo "the next boot runs kernel $_gs_v, this boot runs $3"
}

# --- the hibernate swap file ------------------------------------------------
# Two ways to reach it: through the mounted file (FILE mode, the running
# system or a recovery that mounted userdata), or on the unmounted partition
# (DEV mode, the initramfs before any mount): debugfs finds the block, the
# signature is read and written on the device itself. Never mix them: a raw
# device write under a mounted file system bypasses its page cache.

# gs_dev_block DEV RELPATH: the device block of the file's first page; refuses
# (exit 1) unless the file system block size is 4096 (= the page size)
gs_dev_block() {
    _gs_bs=$(dumpe2fs -h "$1" 2>/dev/null | sed -n 's/^Block size: *//p')
    [ "$_gs_bs" = 4096 ] || return 1
    _gs_b=$(debugfs -R "bmap /$2 0" "$1" 2>/dev/null | tail -n 1)
    case "$_gs_b" in ''|0|*[!0-9]*) return 1 ;; esac
    echo "$_gs_b"
}

# gs_sig_file FILE / gs_sig_dev DEV BLOCK: the signature (trailing NULs dropped)
gs_sig_file() {
    dd if="$1" bs=1 skip=$GS_SIG_OFF count=10 2>/dev/null | tr -d '\000'
}
gs_sig_dev() {
    dd if="$1" bs=1 skip=$(($2 * 4096 + GS_SIG_OFF)) count=10 2>/dev/null | tr -d '\000'
}

# gs_invalidate_file FILE / gs_invalidate_dev DEV BLOCK: put the swap signature
# back (rule 5), so the image can never be resumed. A no-op if it is not a
# hibernate image.
gs_invalidate_file() {
    [ "$(gs_sig_file "$1")" = "$GS_SIG_HIBERNATE" ] || return 0
    printf '%s' "$GS_SIG_SWAP" | dd of="$1" bs=1 seek=$GS_SIG_OFF conv=notrunc,fsync 2>/dev/null || return 1
    sync
}
gs_invalidate_dev() {
    [ "$(gs_sig_dev "$1" "$2")" = "$GS_SIG_HIBERNATE" ] || return 0
    printf '%s' "$GS_SIG_SWAP" | dd of="$1" bs=1 seek=$(($2 * 4096 + GS_SIG_OFF)) conv=notrunc 2>/dev/null || return 1
    sync
    [ -b "$1" ] && blockdev --flushbufs "$1"
    return 0
}

# --- the guard file ----------------------------------------------------------
# gs_dumpe2fs DEV FIELD: one superblock field (leading spaces dropped), times
# in UTC and the C locale: the running system (its own TZ) and the initramfs
# (none) must print the same string
gs_dumpe2fs() {
    TZ=UTC0 LC_ALL=C dumpe2fs -h "$1" 2>/dev/null | sed -n "s/^$2: *//p" | head -n 1
}
# gs_guard_mounts DEV: the guard's userdata lines (rule 4), for the hibernate
# wrapper: mount_count=… and last_mount=…
gs_guard_mounts() {
    echo "mount_count=$(gs_dumpe2fs "$1" 'Mount count')"
    echo "last_mount=$(gs_dumpe2fs "$1" 'Last mount time')"
}
# gs_guard_file FILE KEY / gs_guard_dev DEV RELPATH KEY: one key of the guard
gs_guard_file() { gs_kv "$1" "$2"; }
gs_guard_dev() {
    debugfs -R "cat /$2" "$1" 2>/dev/null | sed -n "s/^$3=//p" | head -n 1
}

# --- soft restart (specs/013, docs/deployments.md "Restart") -------------------
# The reasons are fixed words (013 FR-006); a shell words them.

# gs_kernel_word FILE CMDLINEFILE KREL: why the next cold start could run another
# kernel image than this kernel run, as a word: kernel (another image is selected,
# or a write of the default slot is unfinished), kernel-trial (this boot is a
# kernel trial), kernel-candidate (a kernel candidate waits for its trial); empty
# if the next cold start runs the running image. The rule gs_kernel_refusal
# applies for the hibernate step, plus the candidate (004: a kernel waiting for
# its trial keeps a staged deployment staged, so it keeps a restart cold too).
gs_kernel_word() {
    [ -r "$1" ] || return 0
    _gs_run=$(gs_img_id "$2")
    [ -z "$(gs_kv "$1" writing)" ] || { echo kernel; return 0; }
    _gs_v=$(gs_kv "$1" candidate_img)
    [ -n "$_gs_v" ] && [ "$_gs_run" = "$_gs_v" ] && { echo kernel-trial; return 0; }
    [ -z "$(gs_kernel_candidate "$1")" ] || { echo kernel-candidate; return 0; }
    _gs_v=$(gs_kv "$1" current_img)
    if [ -n "$_gs_v" ]; then
        [ "$_gs_run" = "$_gs_v" ] || echo kernel
        return 0
    fi
    _gs_v=$(gs_kv "$1" current)
    [ -z "$_gs_v" ] || [ "$_gs_v" = "$3" ] || echo kernel
}

# gs_covers SYSDIR BASEDIR KREL: does the running kernel KREL cover a deployment
# on the base at BASEDIR (docs/kernel-artifacts.md, "Which combinations boot")?
# Prints nothing when it does, else a word: modules (no modules/KREL on the system
# partition at SYSDIR), not-covered (the base's manifest needs a feature the
# kernel's manifest doesn't provide; a base without a manifest needs nothing).
gs_covers() {
    [ -d "$1/modules/$3" ] || { echo modules; return 0; }
    _gs_need=$(gs_kv "$2/usr/share/glassine/base.manifest" needs)
    [ -n "$_gs_need" ] || return 0
    _gs_prov=" $(gs_kv "$1/modules/$3/kernel.manifest" provides) "
    for _gs_n in $_gs_need; do
        case "$_gs_prov" in *" $_gs_n "*) ;; *) echo not-covered; return 0 ;; esac
    done
}

# gs_power_ok PSDIR MIN: a charger online, or a battery at MIN percent or more; no
# battery at all (a board without one) = ok. Sets GS_POWER_WHY. The shutdown
# switch's rule (glassine-switch-hook), shared with `glassine-deploy restart
# --check`, so both say the same.
gs_power_ok() {
    _gs_bat=''
    for _gs_p in "$1"/*; do
        [ -r "$_gs_p/type" ] || continue
        case $(cat "$_gs_p/type") in
        Mains|USB|USB_*|Wireless) [ "$(cat "$_gs_p/online" 2>/dev/null)" = 1 ] && { GS_POWER_WHY="charger ${_gs_p##*/}"; return 0; } ;;
        Battery) _gs_bat=$(cat "$_gs_p/capacity" 2>/dev/null) ;;
        esac
    done
    [ -n "$_gs_bat" ] || { GS_POWER_WHY="no battery"; return 0; }
    case $_gs_bat in *[!0-9]*) GS_POWER_WHY="battery capacity unreadable"; return 1 ;; esac
    GS_POWER_WHY="battery $_gs_bat %"
    [ "$_gs_bat" -ge "$2" ]
}

# gs_restart_word RUNDIR SYSMNT UDDIR CMDLINEFILE KREL TARGETS KEPTDIR: the rules of a
# soft restart (013 FR-001) that the state, the runtime directory and the system
# partition decide, for the start of the first of TARGETS (ids in the pick's order:
# the pick's, then current, previous) that can assemble; prints the first reason it
# finds as a word, nothing when the restart may be soft. RUNDIR = this session's
# /run/glassine (booted, kernel-boot, healthy, kept.none), SYSMNT = the system
# partition's top level, UDDIR = <userdata>/<prefix>, KEPTDIR = the kept assembly.
# The loader record (gp_restart_word), SOFT_RESTART and PID 1 are the caller's: the
# restart step reads them, the soft start's second decision has the record only.
# Words: plain (no deployments start), bare, first-start, test-role and
# no-assembly (no kept assembly, or the word the initramfs left why), kernel-trial,
# kernel, kernel-candidate, no-target, not-covered, modules, not-healthy.
gs_restart_word() {
    _gs_b=$(cat "$1/booted" 2>/dev/null)
    case $_gs_b in '') echo plain; return 0 ;; bare:*) echo bare; return 0 ;; esac
    [ ! -e "$2/state/install" ] || { echo first-start; return 0; }
    if [ ! -e "$7/.complete" ]; then
        _gs_v=$(cat "$1/kept.none" 2>/dev/null)
        case $_gs_v in ''|*[!a-z-]*) _gs_v=no-assembly ;; esac
        echo "$_gs_v"; return 0
    fi
    case $(cat "$1/kernel-boot" 2>/dev/null) in '') ;; *) echo kernel-trial; return 0 ;; esac
    _gs_v=$(gs_kernel_word "$2/state/kernel" "$4" "$5")
    [ -z "$_gs_v" ] || { echo "$_gs_v"; return 0; }
    # the first of TARGET's ids that can assemble (its meta, its base): the pick
    # marks one that can't failed and starts the next (FR-014)
    _gs_b=''
    for _gs_t in $6; do
        _gs_v=$(gs_kv "$3/deployments/$_gs_t/meta" base)
        [ -n "$_gs_v" ] && [ -d "$2/bases/$_gs_v" ] && { _gs_b=$_gs_v; break; }
    done
    [ -n "$_gs_b" ] || { echo no-target; return 0; }
    _gs_v=$(gs_covers "$2" "$2/bases/$_gs_b" "$5")
    [ -z "$_gs_v" ] || { echo "$_gs_v"; return 0; }
    [ -e "$1/healthy" ] || echo not-healthy
}
