# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-state.sh: shared helpers for the deployment state on the system
# partition and for the hibernate guard on userdata. Sourced (not run) by
# glassine-deploy, the boot initramfs and the hibernate wrapper, so all of
# them read and write the same files the same way. busybox ash only: no
# bash-isms, no util-linux (it runs in the initramfs and in recovery).
#
# Files (paths relative to their file system, see glassine-deploy):
#   system:   state/format (version=N), state/deploy, state/kernel   key=value
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
