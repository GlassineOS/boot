# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-kernel.sh: glassine-bootimg in the deployments layout. Sourced by
# sbin/glassine-bootimg, after glassine-state.sh, when board.conf says
# ROOT_LAYOUT=deployments; it then runs gk_main. Design and formats:
# docs/kernel-artifacts.md ("Kernel records, trials and hand-off", "Records"),
# the requirements: specs/004-kernel-records/spec.md (FR-nnn below).
#
# On the system partition (its top level at SYSTEM_MNT, deploy.conf), every
# write of state/kernel a gs_update under state/.lock:
#   state/kernel                 current previous current_img previous_img
#                                candidate candidate_img tries failed failed_img
#                                deferred deferred_dtb deferred_initramfs
#                                requested writing writing_op
#   state/bootimg/<id>.img       a packed image, kept while a key above names it
#   state/bootimg/<id>.manifest  its record (format=1, FR-003)
# The kernel comes from modules/<release>/Image.gz, the device tree and the
# initramfs from boot/ (FR-004); board.conf's KERNEL, DTB, INITRAMFS are not used.
#
# Hand-off (board key HANDOFF, FR-007): bootpart-test writes the candidate to
# TEST_DEV, a spare slot the bootloader boots once when asked (never the
# recovery partition, FR-008); empty: kernel updates are paused; blocklist: the
# bootloader reads the candidate from an immutable file on userdata, through a
# record in the default slot (docs/blocklist.md, specs/005). With it, userdata
# holds what the bootloader reads (candidate_img, failed_img), and state/bootimg
# what can go back into the default slot (current_img, previous_img, writing).
#
# The trial (FR-011, FR-012): the initramfs takes the try on the candidate's
# boot (lib/glassine-root.sh, gr_boot) and boots the current deployment;
# `promote` (glassine-bootimg-promote, at every boot) then finishes a cut
# default-slot write, clears `requested`, gives the verdict and installs a
# deferred release.
#
# Exit codes: 0 done, 1 error, 2 usage, 3 the state format (or a record) is
# newer than this tool, 6 busy (state/.lock held).
#
# busybox ash only, except the packer and lib/glassine-blocklist (python3,
# neither in the initramfs or the recovery). Test hooks: GLASSINE_BI_SYSTEM
# (the system partition's top level), GLASSINE_BI_SYSBLOCK (/sys/class/block),
# GLASSINE_BI_RUN_DIR (RUN_DIR, deploy.conf), GLASSINE_BI_MOUNTS (/proc/mounts),
# GLASSINE_BI_AFTER_BODY (eval'd in gk_put after an image's body is written and
# before its header: the tests cut or corrupt writes with it),
# GLASSINE_BI_AFTER_RECORD (eval'd in gk_bl_put after the record is written);
# both only with GLASSINE_BI_TEST=1, never on an ordinary write.

GK_CONF=${GLASSINE_DEPLOY_CONF:-/etc/glassine/deploy.conf}
SYSTEM_MNT=/run/glassine/system RUN_DIR=/run/glassine
# shellcheck source=/dev/null
[ -r "$GK_CONF" ] && . "$GK_CONF"
SYS=${GLASSINE_BI_SYSTEM:-$SYSTEM_MNT}
S=$SYS/state K=$SYS/state/kernel BI=$SYS/state/bootimg
GK_FORMAT=1
GK_KEYS='current previous current_img previous_img candidate candidate_img tries failed failed_img deferred requested writing writing_op'
# also in state/kernel, not printed by status: deferred_dtb, deferred_initramfs
HANDOFF=${HANDOFF:-} DEVICE=${DEVICE:-}
# the block-list hand-off; test hooks: GLASSINE_BI_RECORD_DEV, _USERDATA_DEV,
# _USERDATA_MNT, _ABL_DEV, _BLOCKLIST, _REBOOT_MODES, GLASSINE_POWER_SUPPLY
BLOCKLIST_RECORD_PART=${BLOCKLIST_RECORD_PART:-} BLOCKLIST_REBOOT_REASON=${BLOCKLIST_REBOOT_REASON:-}
BLOCKLIST_ABL_PART=${BLOCKLIST_ABL_PART:-} BLOCKLIST_ABL_SHA256=${BLOCKLIST_ABL_SHA256:-}
USERDATA_PART=${USERDATA_PART:-} USERDATA_PREFIX=${USERDATA_PREFIX:-media/glassine}
SWITCH_MIN_CAPACITY=${SWITCH_MIN_CAPACITY:-30}
GK_BLDEV=${GLASSINE_BI_RECORD_DEV:-/dev/disk/by-partlabel/$BLOCKLIST_RECORD_PART}
GK_UDDEV=${GLASSINE_BI_USERDATA_DEV:-${USERDATA_DEV:-/dev/disk/by-partlabel/$USERDATA_PART}}
GK_UDMNT=${GLASSINE_BI_USERDATA_MNT:-${USERDATA_MNT:-/run/glassine/userdata}}
GK_BLK=$GK_UDMNT/$USERDATA_PREFIX/kernel
GK_ABLDEV=${GLASSINE_BI_ABL_DEV:-/dev/disk/by-partlabel/$BLOCKLIST_ABL_PART}
GK_BLTOOL=${GLASSINE_BI_BLOCKLIST:-/usr/lib/glassine-bootimg/glassine-blocklist}
GK_MODES=${GLASSINE_BI_REBOOT_MODES:-/sys/class/reboot-mode}
GK_PSDIR=${GLASSINE_POWER_SUPPLY:-/sys/class/power_supply}
GK_RAM=''
GK_STARTED=$TMP/glassine-bootimg.started
GK_REQUESTED=$TMP/glassine-bootimg.requested    # reboot-test ran on this boot (in RAM)
GK_RUN=${GLASSINE_BI_RUN_DIR:-$RUN_DIR}
GK_LOCKED=''

fail() { _c=$1; shift; log "$*"; exit "$_c"; }
k() { gs_kv "$K" "$1"; }                         # k KEY: a key of state/kernel
kset() { gs_update "$K" "$@" || die "cannot write $K"; }
man() { gs_kv "$BI/$1.manifest" "$2"; }          # man ID KEY: a key of an image's record
gk_sha() { sha256sum < "$1" | cut -d' ' -f1; }
gk_devsize() { blockdev --getsize64 "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null; }
gk_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- opening the state -------------------------------------------------------
# gk_open [rw]: the state readable (and with rw: writable and locked). A
# newer state/format is refused with exit 3, a held lock with exit 6.
gk_open() {
    _v=$(gs_format_version "$SYS")
    [ "$_v" != none ] || die "no deployment state at $SYS/state (the system partition is not mounted there, or not migrated)"
    gs_format_ok "$_v" || fail 3 "state format $_v is newer than this tool ($GS_FORMAT_SUPPORTED); update glassine-bootimg"
    [ "${1:-}" = rw ] || return 0
    [ -z "$GK_LOCKED" ] || return 0     # promote's deferred install: the lock is held already
    : >>"$S/.lock" 2>/dev/null || die "$S is not writable"
    gs_lock "$S" || fail 6 "busy: another glassine-bootimg or glassine-deploy holds $S/.lock"
    GK_LOCKED=1
    mkdir -p "$BI" || die "cannot create $BI"
}

# gk_record_ok FILE: refuse (exit 3) a record of a newer format
gk_record_ok() {
    _v=$(gs_kv "$1" format)
    case "$_v" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_v" -le "$GK_FORMAT" ] || fail 3 "$1 has format $_v, newer than this tool ($GK_FORMAT)"
}

# --- the hand-off --------------------------------------------------------------
# gk_partname DEV: the partition name of DEV (its by-partlabel name, else
# PARTNAME= in sysfs)
gk_partname() {
    case "$1" in */by-partlabel/*) echo "${1##*/}"; return 0 ;; esac
    _b=$(readlink -f "$1" 2>/dev/null) || return 0
    sed -n 's/^PARTNAME=//p' "${GLASSINE_BI_SYSBLOCK:-/sys/class/block}/${_b##*/}/uevent" 2>/dev/null | head -n 1
}

# gk_handoff: the board's hand-off can take a candidate (FR-007, FR-008)
gk_handoff() {
    case "$HANDOFF" in
    bootpart-test) ;;
    '') die "kernel updates are paused on this board (no HANDOFF in $BOARD)" ;;
    blocklist) gk_bl_handoff; return 0 ;;
    *) die "unknown HANDOFF '$HANDOFF' in $BOARD" ;;
    esac
    [ -n "$TESTDEV" ] && [ -n "$DEFDEV" ] || die "no TEST_DEV/DEFAULT_DEV in $BOARD"
    [ "$(gk_partname "$TESTDEV")" != recovery ] ||
        die "TEST_DEV is the recovery partition: bootpart-test needs a spare slot (the recovery stays the recovery)"
}

# gk_bl_handoff: the board's keys for the block-list hand-off are coherent
gk_bl_handoff() {
    [ -n "$DEFDEV" ] || die "no DEFAULT_DEV in $BOARD"
    [ -n "$BLOCKLIST_REBOOT_REASON" ] || die "no BLOCKLIST_REBOOT_REASON in $BOARD"
    [ -n "$(readlink -f "$GK_BLDEV")" ] && [ "$(readlink -f "$GK_BLDEV")" = "$(readlink -f "$DEFDEV")" ] ||
        die "BLOCKLIST_RECORD_PART in $BOARD is not the default slot"
}

# --- reading and writing slots -----------------------------------------------
# gk_read DEV N: the first N bytes of DEV, read with O_DIRECT (the device's
# bytes, never the page cache)
gk_read() { dd if="$1" bs=4096 count=$((($2 + 4095) / 4096)) iflag=direct 2>/dev/null | head -c "$2"; }
gk_sha_dev() { gk_read "$1" "$2" | sha256sum | cut -d' ' -f1; }

# gk_u32 FILE OFFSET: a little-endian u32 (od uses the host's order: every
# board this runs on is little-endian)
gk_u32() { od -An -tu4 -j"$2" -N4 "$1" 2>/dev/null | tr -d ' '; }

# gk_hdr_size FILE: the size of the boot image whose header v0 starts FILE
# (header page + kernel + ramdisk + second, each padded to the page); empty
# when FILE starts with no header, or with a header of another version (its
# image has more sections than v0 sizes: the packer only writes v0)
gk_hdr_size() {
    [ "$(head -c 8 "$1" 2>/dev/null)" = 'ANDROID!' ] || return 0
    [ "$(gk_u32 "$1" 40)" = 0 ] || return 0
    _ks=$(gk_u32 "$1" 8) _rs=$(gk_u32 "$1" 16) _ss=$(gk_u32 "$1" 24) _ps=$(gk_u32 "$1" 36)
    case "$_ps" in 2048|4096|8192|16384) ;; *) return 0 ;; esac
    echo $((_ps + (_ks + _ps - 1) / _ps * _ps + (_rs + _ps - 1) / _ps * _ps + (_ss + _ps - 1) / _ps * _ps))
}

# gk_hdr_cmdline FILE / gk_hdr_id FILE: the header's command line, its glassine.img=
gk_hdr_cmdline() { dd if="$1" bs=64 skip=1 count=8 2>/dev/null | tr -d '\000'; }
gk_hdr_id() { gk_hdr_cmdline "$1" | sed -n 's/.*glassine[._]img=\([0-9a-f]*\).*/\1/p'; }

# gk_put IMG DEV: IMG onto DEV (blocklist.md, "Writing the default slot"):
# O_DIRECT, the first 4 KiB zeroed first and written last, so a cut write
# leaves no header a bootloader would take; then read back with O_DIRECT. One
# retry. 0 = DEV holds IMG.
gk_put() {
    _n=$(stat -c %s "$1") _sha=$(gk_sha "$1")
    touch "$TMP/glassine-bootimg.writing"       # the service's stop waits for it
    for _try in 1 2; do
        if dd if=/dev/zero of="$2" bs=4096 count=1 conv=notrunc,fsync oflag=direct 2>/dev/null &&
            dd if="$1" of="$2" bs=4096 skip=1 seek=1 conv=sync,notrunc,fsync oflag=direct 2>/dev/null &&
            { [ "${GLASSINE_BI_TEST:-}" != 1 ] || [ -z "${GLASSINE_BI_AFTER_BODY:-}" ] || eval "$GLASSINE_BI_AFTER_BODY"; } &&
            dd if="$1" of="$2" bs=4096 count=1 conv=sync,notrunc,fsync oflag=direct 2>/dev/null &&
            [ "$(gk_sha_dev "$2" "$_n")" = "$_sha" ]; then
            rm -f "$TMP/glassine-bootimg.writing"
            return 0
        fi
        log "writing $1 to $2: the write or its read-back failed (try $_try)"
    done
    rm -f "$TMP/glassine-bootimg.writing"
    return 1
}

# gk_ram DEV: the image the slot holds, its own bytes (its header's size,
# never the whole slot), in RAM (TMP) as GK_RAM; read twice, the same both
# times. 1 (GK_RAM empty) when the slot holds no image.
gk_ram() {
    GK_RAM=$TMP/glassine-bootimg.ram
    gk_read "$1" 4096 > "$GK_RAM" || { rm -f "$GK_RAM"; GK_RAM=''; return 1; }
    _sz=$(gk_hdr_size "$GK_RAM")
    if [ -n "$_sz" ] && [ "$_sz" -le "$(gk_devsize "$1")" ] && gk_read "$1" "$_sz" > "$GK_RAM" &&
        [ "$(stat -c %s "$GK_RAM")" = "$_sz" ] && [ "$(gk_sha "$GK_RAM")" = "$(gk_sha_dev "$1" "$_sz")" ]; then
        return 0
    fi
    rm -f "$GK_RAM"; GK_RAM=''
    return 1
}

# --- the block-list record ----------------------------------------------------
# docs/blocklist.md, "The record"; specs/005, FR-001 to FR-003. Ash, for the
# recovery and for promote on every boot. The full format is lib/glassine-blocklist.
GK_BL_TAIL=65536

# gk_bl_block DEV: where the record is in DEV, in 4096-byte blocks
gk_bl_block() {
    _bz=$(gk_devsize "$1")
    case "$_bz" in ''|*[!0-9]*) return 1 ;; esac
    [ $((_bz % 4096)) = 0 ] && [ "$_bz" -ge $((GK_BL_TAIL + 4096)) ] || return 1
    echo $(((_bz - GK_BL_TAIL) / 4096))
}

# gk_bl_read DEV OUT: the record's 4096 bytes, the device's own
gk_bl_read() {
    _bb=$(gk_bl_block "$1") || return 1
    dd if="$1" of="$2" bs=4096 skip="$_bb" count=1 iflag=direct 2>/dev/null && [ "$(stat -c %s "$2")" = 4096 ]
}

# gk_bl_id DEV: prints the image id the record names, `none` for no record, or
# `bad` when there is no magic, format or id to read. A record torn after its
# id still prints the id: only `glassine-blocklist decode` says a record is
# whole. 1 when the record can't be read. Promote calls this without the lock,
# so each process has its own file.
gk_bl_id() {
    _rf=$TMP/glassine-bootimg.rec.$$
    gk_bl_read "$1" "$_rf" || { rm -f "$_rf"; return 1; }
    if [ "$(tr -d '\000' < "$_rf" | wc -c)" -eq 0 ]; then echo none
    elif [ "$(head -c 8 "$_rf")" != GLBLKLST ] || [ "$(gk_u32 "$_rf" 8)" != 1 ]; then echo bad
    else
        _ri=$(dd if="$_rf" bs=1 skip=16 count=16 2>/dev/null | tr -d '\000')
        case "$_ri" in
        ''|*[!0-9a-f]*) echo bad ;;
        *) if [ ${#_ri} = 16 ]; then echo "$_ri"; else echo bad; fi ;;
        esac
    fi
    rm -f "$_rf"
}

# gk_bl_put DEV FILE: FILE (4096 bytes) into DEV's record, and nothing else
# (FR-003). Refused when DEV holds no header v0 image, or one that reaches the
# record. The image's bytes are kept in RAM and compared after the write; on a
# mismatch they go back and the write counts as failed. 0 = the record is FILE.
gk_bl_put() {
    _bb=$(gk_bl_block "$1") || { log "record: cannot place the record in $1"; return 1; }
    [ "$(stat -c %s "$2" 2>/dev/null)" = 4096 ] || { log "record: $2 is not 4096 bytes"; return 1; }
    gk_ram "$1" || { log "record: $1 holds no boot image to keep: the record is not written"; return 1; }
    _rlen=$(stat -c %s "$GK_RAM")
    if [ "$_rlen" -gt $((_bb * 4096)) ]; then
        rm -f "$GK_RAM"; GK_RAM=''
        log "record: the image in $1 reaches the record: the record is not written"
        return 1
    fi
    _rsha=$(gk_sha "$GK_RAM") _rr=0 _rb=$TMP/glassine-bootimg.recback.$$
    dd if="$2" of="$1" bs=4096 seek="$_bb" count=1 conv=notrunc,fsync oflag=direct 2>/dev/null || _rr=1
    [ "${GLASSINE_BI_TEST:-}" != 1 ] || [ -z "${GLASSINE_BI_AFTER_RECORD:-}" ] || eval "$GLASSINE_BI_AFTER_RECORD"
    gk_bl_read "$1" "$_rb" && cmp -s "$_rb" "$2" || _rr=1
    rm -f "$_rb"
    if [ "$(gk_sha_dev "$1" "$_rlen")" != "$_rsha" ]; then
        _rr=1
        if gk_put "$GK_RAM" "$1"; then log "record: the write changed the image in $1: its bytes are back"
        else log "record: the write changed the image in $1, and putting it back failed: the default slot cannot boot"
        fi
    fi
    rm -f "$GK_RAM"; GK_RAM=''
    [ "$_rr" = 0 ] || log "record: writing the record in $1 failed"
    return "$_rr"
}

# gk_bl_clear DEV: no record in DEV. Writes nothing when there is none.
gk_bl_clear() {
    _rc=$(gk_bl_id "$1") || { log "record: cannot read the record in $1"; return 1; }
    [ "$_rc" != none ] || return 0
    _rz=$TMP/glassine-bootimg.reczero.$$
    head -c 4096 /dev/zero > "$_rz" || return 1
    gk_bl_put "$1" "$_rz"; _rzr=$?
    rm -f "$_rz"
    return "$_rzr"
}

# gk_bl_settle: no record of anything but the candidate (FR-010). A failed
# clear is logged and goes on: without the reboot reason, the record is never read.
gk_bl_settle() {
    _rs=$(gk_bl_id "$DEFDEV") || return 0
    [ "$_rs" != none ] && [ "$_rs" != "$(k candidate_img)" ] || return 0
    if gk_bl_clear "$DEFDEV"; then log "the record of image $_rs is cleared"
    else log "the record of image $_rs could not be cleared (harmless: nothing sets the reboot reason for it)"
    fi
}

# gk_bl_mode: the running kernel can write this hand-off's reboot reason
gk_bl_mode() {
    cat "$GK_MODES"/*/reboot_modes 2>/dev/null | tr ' ' '\n' | grep -qx "$BLOCKLIST_REBOOT_REASON"
}

# gk_power_ok: a charger online, or a battery at SWITCH_MIN_CAPACITY or more
# (the shutdown switch's rule); no battery at all = ok. Sets GK_POWER.
gk_power_ok() {
    _bat='' GK_POWER=''
    for _p in "$GK_PSDIR"/*; do
        [ -r "$_p/type" ] || continue
        case $(cat "$_p/type") in
        Mains|USB|USB_*|Wireless) [ "$(cat "$_p/online" 2>/dev/null)" = 1 ] && { GK_POWER="charger ${_p##*/}"; return 0; } ;;
        Battery) _bat=$(cat "$_p/capacity" 2>/dev/null) ;;
        esac
    done
    [ -n "$_bat" ] || { GK_POWER="no battery"; return 0; }
    case $_bat in *[!0-9]*) GK_POWER="battery capacity unreadable"; return 1 ;; esac
    GK_POWER="battery $_bat %"
    [ "$_bat" -ge "$SWITCH_MIN_CAPACITY" ]
}

# gk_bl_checks DTB: what a real install needs (FR-005), before anything changes
gk_bl_checks() {
    case $(cat "$GK_RUN/booted" 2>/dev/null) in
    bare:*) die "install: this is a bare boot: userdata isn't in use" ;;
    esac
    [ -n "$USERDATA_PART" ] || die "install: no USERDATA_PART in $BOARD"
    [ -n "$BLOCKLIST_ABL_SHA256" ] || die "install: no bootloader build is known to read the record (BLOCKLIST_ABL_SHA256 in $BOARD)"
    _as=$(sha256sum < "$GK_ABLDEV" 2>/dev/null | cut -d' ' -f1)
    case " $BLOCKLIST_ABL_SHA256 " in
    *" ${_as:-unreadable} "*) ;;
    *) die "install: this bootloader (${_as:-unreadable}) is not one known to read the record" ;;
    esac
    gk_bl_mode || die "install: the running kernel has no reboot mode '$BLOCKLIST_REBOOT_REASON'"
    grep -aqF "mode-$BLOCKLIST_REBOOT_REASON" "$1" || die "install: the candidate's device tree has no mode-$BLOCKLIST_REBOOT_REASON"
    mkdir -p "$GK_BLK" || die "install: cannot create $GK_BLK"
    _be=$(python3 "$GK_BLTOOL" check-fs "$GK_BLK" 2>&1) || die "install: $_be"
    _bs=$(gk_devsize "$DEFDEV")
    [ -n "$_bs" ] && [ "$_bs" -ge $((PART_SIZE)) ] || die "install: $DEFDEV (${_bs:-unreadable}) is smaller than PART_SIZE"
    _bb=$(gk_bl_block "$DEFDEV") || die "install: cannot place the record in $DEFDEV"
    _bh=$TMP/glassine-bootimg.hdr.$$
    gk_read "$DEFDEV" 4096 > "$_bh" || { rm -f "${_bh:?}"; die "install: cannot read $DEFDEV"; }
    _be=$(gk_hdr_size "$_bh"); rm -f "${_bh:?}"
    [ -n "$_be" ] || die "install: $DEFDEV holds no boot image"
    [ "$_be" -le $((_bb * 4096)) ] || die "install: the image in $DEFDEV reaches the record"
}

# gk_bl_file_ok ID: the candidate's file on userdata matches its manifest
gk_bl_file_ok() {
    [ -r "$GK_BLK/$1.img" ] && [ -r "$BI/$1.manifest" ] || return 1
    gk_record_ok "$BI/$1.manifest"
    [ "$(stat -c %s "$GK_BLK/$1.img")" = "$(man "$1" size)" ] && [ "$(gk_sha "$GK_BLK/$1.img")" = "$(man "$1" sha256)" ]
}

# gk_bl_store ID SIZE SHA FROM: FROM becomes userdata's immutable ID.img, in
# as few extents as allocation gives: allocated, written in full, synced,
# renamed, made immutable. An existing file with this content is kept.
gk_bl_store() {
    _bf=$GK_BLK/$1.img _bn=$GK_BLK/.$1.img.new
    if [ -e "$_bf" ]; then
        if [ "$(gk_sha "$_bf")" = "$3" ]; then
            rm -f "${4:?}"
            chattr +i "$_bf"
            return
        fi
        chattr -i "$_bf" 2>/dev/null
        rm -f "${_bf:?}" || return 1
    fi
    rm -f "${_bn:?}"
    fallocate -l "$2" "$_bn" && dd if="$4" of="$_bn" bs=4096 conv=notrunc,fsync 2>/dev/null &&
        [ "$(gk_sha "$_bn")" = "$3" ] && mv -f "$_bn" "$_bf" && sync && chattr +i "$_bf" && sync ||
        { rm -f "${_bn:?}"; return 1; }
    rm -f "${4:?}"
}

# gk_bl_record ID SIZE SHA: the file's blocks checked, read back through the
# raw partition, then the record (install's steps 4 to 6). A file whose blocks
# don't hold its image is removed; one that couldn't be read back is kept (the
# read-back says nothing about it). 0 = the record names ID.
gk_bl_record() {
    _bf=$GK_BLK/$1.img _br=$TMP/glassine-bootimg.newrec.$$
    _bm=$(python3 "$GK_BLTOOL" map "$_bf" 2>&1) || { log "$_bm"; return 1; }
    if ! _be=$(printf '%s\n' "$_bm" | python3 "$GK_BLTOOL" encode "$_br" "$1" "$USERDATA_PART" "$2" "$3" 2>&1); then
        log "$_be"; rm -f "${_br:?}"; return 1
    fi
    _be=$(python3 "$GK_BLTOOL" check "$_br" "$_bf" "$GK_UDDEV" 2>&1); _brc=$?
    if [ "$_brc" = 3 ]; then
        log "$_be: the file is kept"
        rm -f "${_br:?}"
        return 1
    fi
    if [ "$_brc" != 0 ]; then
        log "$_be: the file is removed"
        chattr -i "$_bf" 2>/dev/null; rm -f "${_bf:?}" "${_br:?}"
        return 1
    fi
    gk_bl_put "$DEFDEV" "$_br"; _brc=$?
    rm -f "${_br:?}"
    return "$_brc"
}

# gk_bl_verify ID: the slot's record names ID, ID's file still has the record's
# blocks, and they hold its image (FR-007). 0 = yes; 1 = no, why on stdout;
# 2 = this can't be checked here (no python3, userdata not mounted, the
# partition can't be read), why on stdout.
gk_bl_verify() {
    command -v python3 >/dev/null 2>&1 && [ -r "$GK_BLTOOL" ] || { echo "no python3"; return 2; }
    mountpoint -q "$GK_UDMNT" || { echo "userdata is not mounted at $GK_UDMNT"; return 2; }
    _rv=$TMP/glassine-bootimg.verify.$$
    _vid=$(gk_bl_id "$DEFDEV") && gk_bl_read "$DEFDEV" "$_rv" || { rm -f "${_rv:?}"; echo "the record can't be read"; return 1; }
    [ "$_vid" = "$1" ] || { rm -f "${_rv:?}"; echo "the record names ${_vid}, not $1"; return 1; }
    _ve=$(python3 "$GK_BLTOOL" check "$_rv" "$GK_BLK/$1.img" "$GK_UDDEV" 2>&1); _vk=$?
    if [ "$_vk" != 0 ]; then
        rm -f "${_rv:?}"; echo "$_ve"
        if [ "$_vk" = 3 ]; then return 2; fi
        return 1
    fi
    _vr=0
    python3 "$GK_BLTOOL" decode "$_rv" | grep -qx "sha256=$(man "$1" sha256)" || { echo "the record's sha256 is not the manifest's"; _vr=1; }
    rm -f "${_rv:?}"
    return "$_vr"
}

# gk_bl_copy ID: the candidate's image onto the system partition, before an
# accept touches the default slot (FR-009). A good ID already there (a rollback
# target or a seed, installed again) is left as it is. The copy is checked
# before it replaces anything, and a failure removes only the temporary file.
gk_bl_copy() {
    if gk_img_ok "$1"; then return 0; fi
    gk_bl_file_ok "$1" || { log "accept: $GK_BLK/$1.img is gone or damaged"; return 1; }
    if cp "$GK_BLK/$1.img" "$BI/$1.img.tmp" && sync && [ "$(gk_sha "$BI/$1.img.tmp")" = "$(man "$1" sha256)" ] &&
        mv -f "$BI/$1.img.tmp" "$BI/$1.img" && gk_img_ok "$1"; then
        return 0
    fi
    rm -f "${BI:?}/${1:?}.img.tmp"
    log "accept: cannot copy image $1 to the system partition"
    return 1
}

# gk_img_ok ID: state/bootimg/ID.img is there and matches its record
gk_img_ok() {
    [ -r "$BI/$1.img" ] && [ -r "$BI/$1.manifest" ] || return 1
    gk_record_ok "$BI/$1.manifest"
    [ "$(stat -c %s "$BI/$1.img")" = "$(man "$1" size)" ] && [ "$(gk_sha "$BI/$1.img")" = "$(man "$1" sha256)" ]
}

# gk_slot_holds DEV ID: DEV's first bytes are ID's image
gk_slot_holds() {
    _sz=$(man "$2" size); [ -n "$_sz" ] || return 1
    [ "$(gk_sha_dev "$1" "$_sz")" = "$(man "$2" sha256)" ]
}

# gk_deploy_trial: why a deployment trial is pending (a staged deployment or a
# deployment candidate), empty if none: one trial at a time
gk_deploy_trial() {
    _dc=$(gs_kv "$S/deploy" candidate) _dcur=$(gs_kv "$S/deploy" current) _dst=$(gs_kv "$S/deploy" staged)
    if [ -n "$_dst" ]; then echo "the staged deployment $_dst"
    elif [ -n "$_dc" ] && [ "$_dc" != "$_dcur" ]; then echo "the deployment candidate $_dc"
    fi
}

# --- records -------------------------------------------------------------------
# gk_prune: drop every state/bootimg/*.img no key names (FR-003); the
# manifests stay
gk_prune() {
    _keep=" $(k current_img) $(k previous_img) $(k writing) "
    [ "$HANDOFF" = blocklist ] || _keep="$_keep$(k candidate_img) $(k failed_img) "
    for _f in "$BI"/*.img; do
        [ -e "$_f" ] || continue
        _i=${_f##*/}; _i=${_i%.img}
        case "$_keep" in *" $_i "*) ;; *) rm -f "$_f" && log "removed the unused image $_i" ;; esac
    done
    [ "$HANDOFF" = blocklist ] || return 0
    # userdata: what the bootloader reads, and never what a record names (FR-008)
    _rid=$(gk_bl_id "$DEFDEV") || return 0
    _keep=" $(k candidate_img) $(k failed_img) $_rid "
    for _f in "$GK_BLK"/*.img "$GK_BLK"/.*.img.new "$GK_BLK"/.pack.*; do
        [ -e "$_f" ] || continue
        _i=${_f##*/}; _i=${_i%.img}
        case "$_keep" in
        *" $_i "*) ;;
        *) chattr -i "$_f" 2>/dev/null; rm -f "${_f:?}" && log "removed the unused image file $_i" ;;
        esac
    done
}

# gk_fail REASON: the candidate failed (its record says why)
gk_fail() {
    _ci=$(k candidate_img) _c=$(k candidate)
    if [ "$HANDOFF" = blocklist ]; then
        gk_bl_clear "$DEFDEV" || log "the record could not be cleared (harmless: nothing sets the reboot reason for it)"
    fi
    [ -z "$_ci" ] || [ ! -e "$BI/$_ci.manifest" ] || gs_update "$BI/$_ci.manifest" "reason=$1" || die "cannot write $BI/$_ci.manifest"
    kset "failed=$_c" "failed_img=$_ci" candidate= candidate_img= tries= requested=
    log "kernel $_c ($_ci) FAILED: $1; the default boot keeps $(k current)"
    echo "Kernel $_c failed its trial ($1). The old kernel stays." > "$TMP/glassine-bootimg.notice" 2>/dev/null
    gk_prune
}

# gk_seed: FR-015. With no current_img, the image in RAM (the default slot's)
# becomes the current one's record if it is a boot image with a glassine.img=
# whose kernel is release `current` (the packer's --expect-release check).
# Prints its id; nothing when it doesn't qualify.
gk_seed() {
    [ -n "$GK_RAM" ] || return 0
    _id=$(gk_hdr_id "$GK_RAM") _cur=$(k current)
    [ -n "$_id" ] && [ -n "$_cur" ] || { log "seed: the default slot's image has no glassine.img=, or no current release: no rollback until the next accept"; return 0; }
    _ps=$(gk_u32 "$GK_RAM" 36) _ks=$(gk_u32 "$GK_RAM" 8)
    if ! dd if="$GK_RAM" bs="$_ps" skip=1 2>/dev/null | head -c "$_ks" | gunzip -c 2>/dev/null | grep -aqF "Linux version $_cur "; then
        log "seed: the default slot's kernel is not release $_cur: not recorded, no rollback until the next accept"
        return 0
    fi
    cp "$GK_RAM" "$BI/$_id.img.tmp" && mv -f "$BI/$_id.img.tmp" "$BI/$_id.img" || { rm -f "$BI/$_id.img.tmp"; log "seed: cannot write $BI/$_id.img"; return 0; }
    printf 'format=1\nid=%s\nrelease=%s\nsize=%s\nsha256=%s\nstaged=%s\nreason=\nseeded=1\ndevice=\nkernel=\ndtb=\ninitramfs=\ncmdline=\nboard=\n' \
        "$_id" "$_cur" "$(stat -c %s "$GK_RAM")" "$(gk_sha "$GK_RAM")" "$(gk_utc)" | gs_write "$BI/$_id.manifest" ||
        { rm -f "$BI/$_id.img"; log "seed: cannot write $BI/$_id.manifest"; return 0; }
    log "seed: the default slot's image $_id (release $_cur) recorded as the current one (seeded=1)"
    echo "$_id"
}

# gk_write_default ID OP [KEY=VALUE...]: FR-009, the default slot gets ID's
# image for OP (accept, rollback). The image the slot holds is in RAM first
# (gk_ram), and with no current_img it is seeded (FR-015: current_img set in
# the same write as `writing`, so whatever completes OP later finds it). The
# KEY=VALUEs go in that write too, and get their old values back with the
# restore. 0 = written; 1 = failed, the old image back on the slot, writing
# cleared; 2 = failed and so did the restore: writing stays set, the default
# slot can't boot.
gk_write_default() {
    _wid=$1 _wop=$2; shift 2
    _undo=''
    for _a in "$@"; do _undo="$_undo ${_a%%=*}=$(k "${_a%%=*}")"; done
    gk_ram "$DEFDEV" || log "$_wop: the default slot holds no image to keep: nothing to put back if this write fails"
    _seed=''
    [ -n "$(k current_img)" ] || _seed=$(gk_seed)
    # this boot started the write (in RAM: a later boot of that image is a
    # finishing boot, this one isn't)
    echo "$_wid" > "$GK_STARTED" || die "cannot write $GK_STARTED"
    kset "writing=$_wid" "writing_op=$_wop" ${_seed:+"current_img=$_seed"} "$@"
    log "$_wop: writing image $_wid to the default slot ($DEFDEV)"
    if gk_put "$BI/$_wid.img" "$DEFDEV"; then rm -f "$GK_RAM"; return 0; fi
    if [ -n "$GK_RAM" ] && gk_put "$GK_RAM" "$DEFDEV"; then
        rm -f "$GK_RAM"
        # shellcheck disable=SC2086  # KEY=VALUE words without spaces
        kset writing= writing_op= $_undo
        rm -f "$GK_STARTED"
        log "$_wop: writing the default slot failed; its old image is back"
        return 1
    fi
    rm -f "$GK_RAM"
    log "$_wop: writing the default slot failed, and putting its old image back failed too: the default slot cannot boot (writing=$_wid stays)"
    return 2
}

# --- commands ------------------------------------------------------------------
gk_install() {
    _rel='' _dtb='' _ird=''
    while [ $# -gt 0 ]; do
        case "$1" in
        --dtb) [ $# -ge 2 ] || gk_usage; _dtb=$2; shift ;;
        --initramfs) [ $# -ge 2 ] || gk_usage; _ird=$2; shift ;;
        -*) gk_usage ;;
        *) [ -z "$_rel" ] || gk_usage; _rel=$1 ;;
        esac
        shift
    done
    case "$_rel" in ''|.*|*[!A-Za-z0-9._+-]*) gk_usage ;; esac
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "install $_rel: a write of the default slot is unfinished (image $(k writing)); nothing installed"
    _md=$SYS/modules/$_rel
    [ -d "$_md" ] || die "install $_rel: no $_md (receive the kernel's modules first)"
    [ -r "$_md/kernel.manifest" ] && [ -r "$_md/Image.gz" ] || die "install $_rel: $_md has no kernel.manifest or Image.gz"
    gk_record_ok "$_md/kernel.manifest"

    # the device tree and the initramfs (FR-005)
    # no --dtb: the tree of the running image (the device's update names a new one)
    _cimg=$(k current_img)
    if [ -z "$_dtb" ]; then
        [ -z "$_cimg" ] || _dtb=$(man "$_cimg" dtb)
        [ -n "$_dtb" ] || die "install $_rel: the current image names no device tree; name one with --dtb DEVICE@ID"
    fi
    case "$_dtb" in *@*) ;; *) die "install $_rel: --dtb takes DEVICE@ID" ;; esac
    # DEVICE@ID: a device name (not starting with a dot), then a hex id
    case "${_dtb%@*}" in ''|.*|*[!A-Za-z0-9._+-]*) die "install $_rel: bad device tree name '$_dtb' (DEVICE@ID)" ;; esac
    case "${_dtb##*@}" in ''|*[!0-9a-f]*) die "install $_rel: bad device tree name '$_dtb' (DEVICE@ID)" ;; esac
    [ -n "$DEVICE" ] || die "install $_rel: no DEVICE in $BOARD (it names the device trees this board boots)"
    [ "${_dtb%@*}" = "$DEVICE" ] || die "install $_rel: device tree $_dtb is for another device than $DEVICE"
    [ -r "$SYS/boot/dtb/$_dtb.dtb" ] || die "install $_rel: no $SYS/boot/dtb/$_dtb.dtb"
    if [ -z "$_ird" ]; then
        [ -z "$_cimg" ] || _ird=$(man "$_cimg" initramfs)
        [ -n "$_ird" ] || die "install $_rel: the current image names no initramfs; name one with --initramfs COMMIT12@ID"
    fi
    # COMMIT12@ID: hex, then a hex id (a bare hex commit: a record from before the id)
    case "$_ird" in *@*@*|@*|*@|*[!0-9a-f@]*|'') die "install $_rel: bad initramfs name '$_ird' (COMMIT12@ID)" ;; esac
    _irf=$SYS/boot/initramfs/$_ird.cpio.gz _irm=$SYS/boot/initramfs/$_ird.manifest
    [ -r "$_irf" ] || die "install $_rel: no $_irf"
    # rule 1 of "Which combinations boot" (FR-006)
    [ -r "$_irm" ] || die "install $_rel: no $_irm (rule 1 can't be checked)"
    gk_record_ok "$_irm"
    _prov=" $(gs_kv "$_md/kernel.manifest" provides) " _miss=''
    for _n in $(gs_kv "$_irm" needs); do
        case "$_prov" in *" $_n "*) ;; *) _miss="$_miss $_n" ;; esac
    done
    [ -z "$_miss" ] || die "install $_rel: the kernel doesn't provide what initramfs $_ird needs:$_miss"

    # one trial at a time: during a deployment candidate, a staged deployment
    # or a kernel trial, the release waits in deferred, with the device tree
    # and initramfs checked above (Story 1.5)
    _ci=$(k candidate_img) _run=$(run_id)
    _why=$(gk_deploy_trial)
    if [ -n "$_why" ]; then _why="$_why is accepted or failed"
    elif [ -n "$_ci" ] && [ "$_run" = "$_ci" ]; then _why="this kernel trial's verdict"
    fi
    if [ -n "$_why" ]; then
        kset "deferred=$_rel" "deferred_dtb=$_dtb" "deferred_initramfs=$_ird"
        log "install $_rel: deferred until $_why (device tree $_dtb, initramfs $_ird)"
        echo "glassine-bootimg: kernel $_rel will be installed after $_why"
        return 0
    fi
    # a candidate whose trial ended without a verdict: the verdict promote
    # would give (Story 1.7)
    [ -n "$_ci" ] && [ "$(k tries)" = 0 ] && gk_fail no-verdict

    # pack (rule 2: the packer checks PART_SIZE; the slots are checked here)
    if [ "$HANDOFF" = blocklist ]; then
        gk_bl_checks "$SYS/boot/dtb/$_dtb.dtb"
        _img=$(mktemp "$GK_BLK/.pack.XXXXXX") || die "mktemp in $GK_BLK failed"
    else
        _img=$(mktemp "$TMP/glassine-bootimg.XXXXXX") || die "mktemp in $TMP failed"
    fi
    _out=$(python3 "$PACK" "$BOARD" "$_md/Image.gz" "$SYS/boot/dtb/$_dtb.dtb" "$_irf" "$_img" --expect-release "$_rel" 2>&1) ||
        { rm -f "$_img"; die "install $_rel: pack failed: $_out"; }
    _id=$(echo "$_out" | sed -n 's/.*ID=\([0-9a-f]*\).*/\1/p') _size=$(echo "$_out" | sed -n 's/.*SIZE=\([0-9]*\).*/\1/p')
    _sha=$(echo "$_out" | sed -n 's/.*SHA=\([0-9a-f]*\).*/\1/p')
    [ -n "$_id" ] && [ -n "$_size" ] && [ -n "$_sha" ] || { rm -f "$_img"; die "install $_rel: pack said '$_out'"; }
    _tsl=$TESTDEV; [ "$HANDOFF" != blocklist ] || _tsl=''     # this hand-off has no test slot
    for _d in "$_tsl" "$DEFDEV"; do
        [ -n "$_d" ] || continue
        _ds=$(gk_devsize "$_d")
        [ -n "$_ds" ] && [ "$_size" -le "$_ds" ] || { rm -f "$_img"; die "install $_rel: the image ($_size bytes) doesn't fit $_d (${_ds:-unreadable})"; }
    done
    [ "$_id" != "$(k current_img)" ] || { rm -f "$_img"; die "install $_rel: image $_id is the current one already"; }

    # the record, then the candidate
    _cmd=$(gk_hdr_cmdline "$_img")
    if [ "$HANDOFF" = blocklist ]; then gk_bl_install; return; fi
    mv -f "$_img" "$BI/$_id.img.tmp" && sync && mv -f "$BI/$_id.img.tmp" "$BI/$_id.img" ||
        { rm -f "$_img" "$BI/$_id.img.tmp"; die "install $_rel: cannot write $BI/$_id.img"; }
    gk_manifest
    _old=$(k candidate_img)
    if [ -n "$_old" ]; then
        log "install $_rel: replaces the candidate $(k candidate) ($_old), whose trial never started"
        echo "glassine-bootimg: kernel $_rel replaces the candidate $(k candidate)"
    fi
    # the old candidate goes first: a failed write leaves no candidate whose
    # image is gone from the test slot (FR-008)
    kset candidate= candidate_img= tries= requested=
    if ! gk_put "$BI/$_id.img" "$TESTDEV"; then
        gk_prune
        die "install $_rel: writing the test slot failed: there is no kernel candidate now (the default slot is untouched)"
    fi
    if [ "$(k deferred)" = "$_rel" ]; then kset "candidate=$_rel" "candidate_img=$_id" tries=1 deferred= deferred_dtb= deferred_initramfs=
    else kset "candidate=$_rel" "candidate_img=$_id" tries=1; fi
    gk_prune
    log "install $_rel: the candidate, on the test slot (image $_id, $_size bytes)"
    echo "glassine-bootimg: kernel $_rel is ready. Reboot to test it (glassine-bootimg reboot-test)."
}

# gk_manifest: state/bootimg/ID.manifest for the image gk_install just packed
gk_manifest() {
    printf 'format=1\nid=%s\nrelease=%s\nsize=%s\nsha256=%s\nstaged=%s\nreason=\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\ncmdline=%s\nboard=%s\n' \
        "$_id" "$_rel" "$_size" "$_sha" "$(gk_utc)" "${_dtb%@*}" "$_rel" "$_dtb" "$_ird" "$_cmd" "$(gk_sha "$BOARD")" |
        gs_write "$BI/$_id.manifest" || die "install $_rel: cannot write $BI/$_id.manifest"
}

# gk_bl_install: the rest of gk_install for the block-list hand-off
# (docs/blocklist.md, "install"), with what it packed in _img. The record is
# cleared before anything it could name changes, and written before the
# candidate keys, so a cut install leaves at worst a record and no candidate.
gk_bl_install() {
    _fr=$(df -Pk "$SYS" | awk 'NR == 2 {print $4}')
    [ -n "$_fr" ] && [ $((_fr * 1024)) -ge "$_size" ] ||
        { rm -f "${_img:?}"; die "install $_rel: no room on the system partition for the image ($_size bytes), which an accept copies there"; }
    gk_bl_clear "$DEFDEV" || { rm -f "${_img:?}"; die "install $_rel: cannot clear the record; nothing installed"; }
    _old=$(k candidate_img)
    if [ -n "$_old" ]; then
        log "install $_rel: replaces the candidate $(k candidate) ($_old), whose trial never started"
        echo "glassine-bootimg: kernel $_rel replaces the candidate $(k candidate)"
    fi
    kset candidate= candidate_img= tries= requested=
    gk_bl_store "$_id" "$_size" "$_sha" "$_img" ||
        { rm -f "${_img:?}"; gk_prune; die "install $_rel: cannot write $GK_BLK/$_id.img: there is no kernel candidate now"; }
    gk_manifest
    if ! gk_bl_record "$_id" "$_size" "$_sha"; then
        gk_prune
        die "install $_rel: the record could not be made: there is no kernel candidate now (the default image is untouched)"
    fi
    if [ "$(k deferred)" = "$_rel" ]; then kset "candidate=$_rel" "candidate_img=$_id" tries=1 deferred= deferred_dtb= deferred_initramfs=
    else kset "candidate=$_rel" "candidate_img=$_id" tries=1; fi
    gk_prune
    log "install $_rel: the candidate, on userdata (image $_id, $_size bytes)"
    echo "glassine-bootimg: kernel $_rel is ready. Reboot to test it (glassine-bootimg reboot-test)."
}

gk_status() {
    gk_open
    _run=$(run_id) _w=$(k writing) _ci=$(k candidate_img) _fi=$(k failed_img)
    if [ -n "$_w" ]; then
        _st=writing
        [ "$_run" != "$_w" ] || [ "$(cat "$GK_STARTED" 2>/dev/null)" = "$_w" ] || _st=finishing
    elif [ -n "$_ci" ]; then
        if [ "$_run" = "$_ci" ]; then _st=trial; else _st=candidate; fi
    elif [ -n "$_fi" ]; then _st=failed
    else _st=none
    fi
    echo "format=$GK_FORMAT"
    echo "state=$_st"
    for _key in $GK_KEYS; do
        _v=$(k "$_key")
        [ -z "$_v" ] || echo "$_key=$_v"
    done
    [ -z "$_fi" ] || { _v=$(man "$_fi" reason); [ -z "$_v" ] || echo "reason=$_v"; }
    if [ -n "$_w" ] && [ -n "$DEFDEV" ] && ! gk_slot_holds "$DEFDEV" "$_w"; then
        echo "default_slot=bad"
    fi
    return 0
}

gk_cancel() {
    gk_open rw
    [ -z "$(k writing)" ] || die "cancel: a write of the default slot is unfinished (image $(k writing))"
    _c=$(gs_kernel_candidate "$K")
    [ -n "$_c" ] || { echo "glassine-bootimg: no kernel candidate"; return 0; }
    _trial=''; [ "$(run_id)" = "$(k candidate_img)" ] && _trial=1
    if [ "$HANDOFF" = blocklist ]; then
        gk_bl_clear "$DEFDEV" || log "cancel: the record could not be cleared (harmless: nothing sets the reboot reason for it)"
    fi
    gs_kernel_cancel "$K" || die "cannot write $K"
    log "cancel: the kernel candidate $_c is dropped; its files stay"
    if [ -n "$_trial" ]; then
        echo "glassine-bootimg: kernel candidate $_c cancelled; this is its trial boot: the next boot runs $(k current) again"
    else
        echo "glassine-bootimg: kernel candidate $_c cancelled; the default boot is untouched"
    fi
}

gk_reboot_test() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "reboot-test: a write of the default slot is unfinished (image $(k writing))"
    _ci=$(k candidate_img)
    [ -n "$_ci" ] || die "reboot-test: no kernel candidate"
    [ "$(run_id)" != "$_ci" ] || die "reboot-test: this is the candidate's trial boot already"
    _why=$(gk_deploy_trial)
    [ -z "$_why" ] || die "reboot-test: $_why is waiting for its trial: one trial at a time"
    _reason=$TEST_REBOOT_REASON
    if [ "$HANDOFF" = blocklist ]; then
        _reason=$BLOCKLIST_REBOOT_REASON
        gk_bl_mode || die "reboot-test: the running kernel has no reboot mode '$_reason'"
        gk_power_ok || die "reboot-test: $GK_POWER, below $SWITCH_MIN_CAPACITY % without a charger"
        _v=$(gk_bl_verify "$_ci"); _vc=$?
        [ "$_vc" != 2 ] || die "reboot-test: the record can't be checked: $_v"
        [ "$_vc" = 0 ] || die "reboot-test: $_v; run glassine-bootimg install again"
    else
        gk_slot_holds "$TESTDEV" "$_ci" || die "reboot-test: the test slot doesn't hold the candidate's image any more; run glassine-bootimg retry"
    fi
    echo "$_ci" > "$GK_REQUESTED" || die "cannot write $GK_REQUESTED"
    kset "requested=$_ci"
    log "reboot-test: $(k candidate) ($_ci)"
    [ -n "${GLASSINE_BI_NOREBOOT:-}" ] && return 0
    exec 9>&-       # the lock released: the shutdown's own steps (the switch) take it
    exec "$REBOOT_CLEAN" "$_reason"
}

gk_retry() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "retry: a write of the default slot is unfinished (image $(k writing))"
    _id=$(k candidate_img) _from=candidate
    if [ -z "$_id" ]; then _id=$(k failed_img) _from=failed; fi
    [ -n "$_id" ] || die "retry: no kernel candidate and no failed one"
    _why=$(gk_deploy_trial)
    [ -z "$_why" ] || die "retry: $_why is waiting for its trial: one trial at a time"
    _rel=$(man "$_id" release)
    if [ "$HANDOFF" = blocklist ]; then
        gk_bl_file_ok "$_id" || die "retry: $GK_BLK/$_id.img is gone or damaged; install the kernel again"
        if ! gk_bl_record "$_id" "$(man "$_id" size)" "$(man "$_id" sha256)"; then
            [ "$_from" = failed ] && die "retry: the record could not be made; $_rel stays failed"
            kset candidate= candidate_img= tries= requested=
            die "retry: the record could not be made: there is no kernel candidate now"
        fi
    elif ! gk_img_ok "$_id"; then
        die "retry: $BI/$_id.img is gone or damaged; install the kernel again"
    elif ! gk_slot_holds "$TESTDEV" "$_id"; then
        log "retry: the test slot doesn't hold image $_id; writing it again"
        if ! gk_put "$BI/$_id.img" "$TESTDEV"; then
            [ "$_from" = failed ] && die "retry: writing the test slot failed; $_rel stays failed"
            kset candidate= candidate_img= tries= requested=
            die "retry: writing the test slot failed: there is no kernel candidate now"
        fi
    fi
    gs_update "$BI/$_id.manifest" reason= || die "cannot write $BI/$_id.manifest"
    if [ "$_from" = failed ]; then kset "candidate=$_rel" "candidate_img=$_id" tries=1 failed= failed_img=
    else kset tries=1; fi
    log "retry: $_rel ($_id) is the candidate again"
    echo "glassine-bootimg: kernel $_rel is ready again. Reboot to test it (glassine-bootimg reboot-test)."
}

# accept: the candidate's trial boot passed; its image becomes the default
# (promote runs it after the health check; by hand it is refused on any
# other boot)
gk_accept() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "accept: a write of the default slot is unfinished (image $(k writing))"
    _ci=$(k candidate_img)
    [ -n "$_ci" ] || die "accept: no kernel candidate"
    [ "$(run_id)" = "$_ci" ] || die "accept: this boot runs image $(run_id), not the candidate's ($_ci)"
    gk_accept_now || exit 1
}

# gk_accept_now: the candidate's image onto the default slot (FR-009), then
# the accept completed. The state open and locked. 1 = not accepted (a
# write put back: the candidate failed; or a slot that can't boot: writing
# stays).
gk_accept_now() {
    _ci=$(k candidate_img)
    if [ "$HANDOFF" = blocklist ] && ! gk_bl_copy "$_ci"; then
        gk_fail "copy to the system partition"
        return 1
    fi
    gk_img_ok "$_ci" || { log "accept: $BI/$_ci.img is gone or damaged; nothing written"; return 1; }
    gk_write_default "$_ci" accept
    case $? in
    0) ;;
    1) gk_fail "default slot write"; return 1 ;;
    *) return 1 ;;
    esac
    gk_complete
    log "accept: the default slot = $(k current) ($_ci); previous: $(k previous) ($(k previous_img))"
}

# gk_complete: what writing_op names, once the default slot holds the image
# `writing` names (FR-010; kernel-artifacts.md, "A kernel trial"), in the
# state write that clears writing and writing_op. 1 = not done (writing stays).
gk_complete() {
    _w=$(k writing) _op=$(k writing_op)
    case "$_op" in
    accept)
        _rel=$(man "$_w" release); [ -n "$_rel" ] || _rel=$(k candidate)
        kset "previous=$(k current)" "previous_img=$(k current_img)" "current=$_rel" "current_img=$_w" \
            candidate= candidate_img= tries= requested= writing= writing_op=
        echo "Kernel $_rel is now the default." > "$TMP/glassine-bootimg.notice" 2>/dev/null
        ;;
    rollback)
        [ "$(k previous_img)" = "$_w" ] ||
            { log "rollback of image $_w: the previous image is $(k previous_img) now; writing=$_w stays"; return 1; }
        kset "current=$(k previous)" "previous=$(k current)" "current_img=$_w" "previous_img=$(k current_img)" writing= writing_op=
        ;;
    repair)
        kset candidate= candidate_img= tries= requested= writing= writing_op=
        ;;
    *)
        log "writing_op '$_op' is unknown to this tool; writing=$_w stays"
        return 1
        ;;
    esac
    rm -f "$GK_STARTED"
    [ "$HANDOFF" != blocklist ] || gk_bl_settle
    gk_prune
    log "$_op of image $_w completed"
}

gk_rollback() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "rollback: a write of the default slot is unfinished (image $(k writing))"
    if [ "$HANDOFF" = blocklist ]; then
        gk_power_ok || die "rollback: $GK_POWER, below $SWITCH_MIN_CAPACITY % without a charger"
    fi
    _pi=$(k previous_img) _p=$(k previous)
    [ -n "$_pi" ] && gk_img_ok "$_pi" || die "rollback: no previous image"
    [ -z "$_p" ] || [ -d "$SYS/modules/$_p" ] || log "rollback: warning: $SYS/modules/$_p is gone (that kernel boots without modules)"
    # a candidate is cancelled in the same state write as `writing`, so a
    # write that fails and is put back leaves it as it was (FR-009)
    _c=$(gs_kernel_candidate "$K")
    if [ -n "$_c" ]; then
        gk_write_default "$_pi" rollback candidate= candidate_img= tries= requested= || exit 1
        log "rollback: the kernel candidate $_c is cancelled"
        echo "glassine-bootimg: kernel candidate $_c cancelled"
    else
        gk_write_default "$_pi" rollback || exit 1
    fi
    gk_complete || exit 1
    log "rollback: the default slot = ${_p:-the previous kernel} ($_pi) again"
    echo "glassine-bootimg: the default kernel is ${_p:-the previous one} ($_pi) again; reboot to use it"
}

# --- promote (FR-012) ------------------------------------------------------------
# 1. writing (FR-010): whatever this boot's glassine.img=, the default slot
# is checked against `writing`'s record; written again when it doesn't hold
# it (no RAM copy: it holds nothing good), then writing_op completed. 1 =
# the slot can't boot, writing stays (status: default_slot=bad).
gk_writing() {
    _w=$(k writing)
    [ -n "$_w" ] || return 0
    [ -n "$DEFDEV" ] || { log "promote: writing=$_w, but no DEFAULT_DEV in $BOARD: nothing checked"; return 1; }
    if gk_slot_holds "$DEFDEV" "$_w"; then
        log "promote: the default slot holds image $_w: completing $(k writing_op)"
    else
        log "promote: the default slot doesn't hold image $_w (its write was cut): writing it again"
        if ! gk_img_ok "$_w"; then
            log "promote: $BI/$_w.img is gone or damaged: the default slot cannot boot (writing=$_w stays)"
            return 1
        fi
        if ! gk_put "$BI/$_w.img" "$DEFDEV"; then
            log "promote: writing the default slot again failed: it cannot boot (writing=$_w stays)"
            echo "The default boot slot could not be written. Keep the device on and charged, and get help before rebooting." \
                > "$TMP/glassine-bootimg.notice" 2>/dev/null
            return 1
        fi
    fi
    gk_complete
}

# 2. requested (Story 2.5): the trial boot clears it with the try, so one
# left on another boot means the candidate never reached the initramfs
# (no-boot); one naming another image than the candidate's is stale
gk_requested() {
    _r=$(k requested) _ci=$(k candidate_img)
    [ -n "$_r" ] || return 0
    if [ "$_r" != "$_ci" ]; then
        kset requested=
        log "promote: requested=$_r is stale (the candidate is ${_ci:-none}): cleared"
    elif [ "$(run_id)" = "$_ci" ]; then
        kset requested=
        log "promote: the trial boot left requested set (the initramfs took no try): cleared"
    elif [ "$(k tries)" = 1 ]; then
        gk_fail "$(gk_no_boot_reason "$_ci")"
    fi
}

# gk_no_boot_reason ID: why a requested trial never reached the initramfs. On
# the block-list hand-off, `handoff` if the bootloader said it rejected the
# record, or the record or its blocks no longer pass; if they pass, or can't be
# checked, no-boot. Only a label: the boot that fell back has already happened.
gk_no_boot_reason() {
    if [ "$HANDOFF" != blocklist ]; then echo no-boot; return 0; fi
    if grep -qE 'glassine[._]handoff_err=' "$CMDLINE"; then echo handoff; return 0; fi
    _nv=$(gk_bl_verify "$1"); _nc=$?
    [ "$_nc" != 1 ] || { log "promote: the hand-off of image $1 can't have worked: $_nv"; echo handoff; return 0; }
    [ "$_nc" != 2 ] || log "promote: the hand-off of image $1 can't be checked: $_nv"
    echo no-boot
}

# gk_trial_root: why this trial didn't run the system it must prove (empty:
# it did): every later boot would run this kernel, so a fallback isn't a pass.
# The current deployment assembled (not bare, not previous), with this
# kernel's modules bound.
gk_trial_root() {
    _b=$(cat "$GK_RUN/booted" 2>/dev/null) _dc=$(gs_kv "$S/deploy" current) _kr=$(uname_r)
    case "$_b" in
    '') echo "the booted deployment is not recorded"; return 0 ;;
    bare:*) echo "bare boot ($_b): userdata or the deployment did not come up"; return 0 ;;
    esac
    [ "$_b" = "$_dc" ] || { echo "booted $_b, not the current deployment ${_dc:-(none)}"; return 0; }
    awk -v m="/lib/modules/$_kr" '$2 == m {ok = 1} END {exit !ok}' "${GLASSINE_BI_MOUNTS:-/proc/mounts}" ||
        echo "no modules bound for $_kr"
}

# 3. the verdict: on the candidate's trial, the system it ran (gk_trial_root),
# health() (glassine-bootimg), then accept or fail; a candidate at tries=0 on
# another boot ended its trial without one (no-verdict). 1 = an accept that
# didn't complete.
gk_verdict() {
    _ci=$(k candidate_img)
    [ -n "$_ci" ] || return 0
    if [ "$(run_id)" = "$_ci" ]; then
        gk_handoff
        if _why=$(gk_trial_root) && [ -z "$_why" ] && _why=$(health); then gk_accept_now || return 1
        else gk_fail "health: $_why"; fi
    elif [ "$(k tries)" = 0 ]; then
        gk_fail no-verdict
    else
        log "promote: kernel candidate $(k candidate) ($_ci) waits for its trial (glassine-bootimg reboot-test)"
    fi
}

# 4. a deferred release, once nothing it waited for is pending, on a boot of
# the default kernel (after a cancel in the trial boot, it waits for the
# next boot: Story 3.2). Its keys are cleared first, as the plain layout
# does: an install that fails isn't tried again at every boot, and says so in
# the notice. The lock stays held from here through the install (the subshell
# shares it), so no other writer sees the keys gone before the install runs.
gk_deferred() {
    _d=$(k deferred) _run=$(run_id)
    [ -n "$_d" ] && [ -z "$(k writing)" ] || return 0
    _why=$(gk_deploy_trial)
    [ -z "$_why" ] || { log "promote: the deferred $_d waits for $_why"; return 0; }
    if [ -n "$_run" ] && [ "$_run" = "$(k candidate_img)" ]; then return 0; fi
    if [ -n "$_run" ] && [ "$_run" != "$(k current_img)" ] && [ -e "$BI/$_run.manifest" ]; then
        log "promote: the deferred $_d waits for a boot of the default kernel (this boot runs image $_run)"
        return 0
    fi
    gk_handoff      # paused: the release stays deferred
    _dd=$(k deferred_dtb) _di=$(k deferred_initramfs)
    kset deferred= deferred_dtb= deferred_initramfs=
    log "promote: installing the deferred $_d${_dd:+ (device tree $_dd, initramfs $_di)}"
    ( gk_install "$_d" ${_dd:+--dtb "$_dd"} ${_di:+--initramfs "$_di"} )
    _rc=$?
    [ "$_rc" = 0 ] && return 0
    log "promote: installing the deferred $_d failed (exit $_rc)"
    echo "Kernel $_d could not be installed. Install it again." > "$TMP/glassine-bootimg.notice" 2>/dev/null
    exit "$_rc"
}

gk_promote() {
    gk_open         # nothing to do (most boots): no lock, nothing written
    _srec=''
    if [ "$HANDOFF" = blocklist ]; then     # FR-010: read only, ash only
        _srec=$(gk_bl_id "$DEFDEV" 2>/dev/null) || _srec=''
        [ "$_srec" != none ] && [ "$_srec" != "$(k candidate_img)" ] || _srec=''
    fi
    [ -n "$_srec$(k writing)$(k requested)$(k candidate_img)$(k deferred)" ] || return 0
    gk_open rw
    gk_writing || exit 1
    # reboot-test ran on this boot and the shutdown is under way: its
    # `requested` is not a boot that failed to happen (Story 2.5)
    if [ -n "$(k requested)" ] && [ "$(cat "$GK_REQUESTED" 2>/dev/null)" = "$(k requested)" ]; then
        log "promote: the reboot into the trial of $(k requested) is under way: nothing to judge"
        return 0
    fi
    gk_requested
    gk_verdict || exit 1
    [ "$HANDOFF" != blocklist ] || gk_bl_settle
    gk_deferred
}

gk_usage() {
    sed -n '/^# The deployments layout/,/^set -u/s/^#   //p' "$0" >&2
    exit 2
}

gk_main() {
    trap 'rm -f "$TMP/glassine-bootimg.ram" "$TMP/glassine-bootimg.writing"' EXIT
    _cmd=${1:-}; [ $# -gt 0 ] && shift
    case "$_cmd:$#" in
    install:*) gk_install "$@" ;;
    status:0) gk_status ;;
    cancel:0) gk_cancel ;;
    reboot-test:0) gk_reboot_test ;;
    retry:0) gk_retry ;;
    accept:0) gk_accept ;;
    rollback:0) gk_rollback ;;
    promote:0) gk_promote ;;
    *) gk_usage ;;
    esac
}
