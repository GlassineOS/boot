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
# recovery partition, FR-008); empty: kernel updates are paused; blocklist:
# not built yet (hub#56).
#
# Not built yet (phase 2 of specs/004): the trial in the initramfs and
# promote's verdict. Until then `promote` does nothing in this layout, a
# deferred release waits, and nothing finishes a cut default-slot write
# (status says state=writing).
#
# Exit codes: 0 done, 1 error, 2 usage, 3 the state format (or a record) is
# newer than this tool, 6 busy (state/.lock held).
#
# busybox ash only, except the packer (python3). Test hooks: GLASSINE_BI_SYSTEM
# (the system partition's top level), GLASSINE_BI_SYSBLOCK (/sys/class/block),
# GLASSINE_BI_AFTER_BODY (eval'd in gk_put after an image's body is written and
# before its header: the tests cut or corrupt writes with it; only with
# GLASSINE_BI_TEST=1, never on an ordinary write).

GK_CONF=${GLASSINE_DEPLOY_CONF:-/etc/glassine/deploy.conf}
SYSTEM_MNT=/run/glassine/system
# shellcheck source=/dev/null
[ -r "$GK_CONF" ] && . "$GK_CONF"
SYS=${GLASSINE_BI_SYSTEM:-$SYSTEM_MNT}
S=$SYS/state K=$SYS/state/kernel BI=$SYS/state/bootimg
GK_FORMAT=1
GK_KEYS='current previous current_img previous_img candidate candidate_img tries failed failed_img deferred requested writing writing_op'
# also in state/kernel, not printed by status: deferred_dtb, deferred_initramfs
HANDOFF=${HANDOFF:-} DEVICE=${DEVICE:-}
GK_RAM=''
GK_STARTED=$TMP/glassine-bootimg.started

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
    : >>"$S/.lock" 2>/dev/null || die "$S is not writable"
    gs_lock "$S" || fail 6 "busy: another glassine-bootimg or glassine-deploy holds $S/.lock"
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
    blocklist) die "the blocklist hand-off is not built yet (hub#56); kernel updates are paused" ;;
    *) die "unknown HANDOFF '$HANDOFF' in $BOARD" ;;
    esac
    [ -n "$TESTDEV" ] && [ -n "$DEFDEV" ] || die "no TEST_DEV/DEFAULT_DEV in $BOARD"
    [ "$(gk_partname "$TESTDEV")" != recovery ] ||
        die "TEST_DEV is the recovery partition: bootpart-test needs a spare slot (the recovery stays the recovery)"
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
    _keep=" $(k current_img) $(k previous_img) $(k candidate_img) $(k failed_img) $(k writing) "
    for _f in "$BI"/*.img; do
        [ -e "$_f" ] || continue
        _i=${_f##*/}; _i=${_i%.img}
        case "$_keep" in *" $_i "*) ;; *) rm -f "$_f" && log "removed the unused image $_i" ;; esac
    done
}

# gk_fail REASON: the candidate failed (its record says why)
gk_fail() {
    _ci=$(k candidate_img) _c=$(k candidate)
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
    _img=$(mktemp "$TMP/glassine-bootimg.XXXXXX") || die "mktemp in $TMP failed"
    _out=$(python3 "$PACK" "$BOARD" "$_md/Image.gz" "$SYS/boot/dtb/$_dtb.dtb" "$_irf" "$_img" --expect-release "$_rel" 2>&1) ||
        { rm -f "$_img"; die "install $_rel: pack failed: $_out"; }
    _id=$(echo "$_out" | sed -n 's/.*ID=\([0-9a-f]*\).*/\1/p') _size=$(echo "$_out" | sed -n 's/.*SIZE=\([0-9]*\).*/\1/p')
    _sha=$(echo "$_out" | sed -n 's/.*SHA=\([0-9a-f]*\).*/\1/p')
    [ -n "$_id" ] && [ -n "$_size" ] && [ -n "$_sha" ] || { rm -f "$_img"; die "install $_rel: pack said '$_out'"; }
    for _d in "$TESTDEV" "$DEFDEV"; do
        _ds=$(gk_devsize "$_d")
        [ -n "$_ds" ] && [ "$_size" -le "$_ds" ] || { rm -f "$_img"; die "install $_rel: the image ($_size bytes) doesn't fit $_d (${_ds:-unreadable})"; }
    done
    [ "$_id" != "$(k current_img)" ] || { rm -f "$_img"; die "install $_rel: image $_id is the current one already"; }

    # the record, then the candidate
    _cmd=$(gk_hdr_cmdline "$_img")
    mv -f "$_img" "$BI/$_id.img.tmp" && sync && mv -f "$BI/$_id.img.tmp" "$BI/$_id.img" ||
        { rm -f "$_img" "$BI/$_id.img.tmp"; die "install $_rel: cannot write $BI/$_id.img"; }
    printf 'format=1\nid=%s\nrelease=%s\nsize=%s\nsha256=%s\nstaged=%s\nreason=\ndevice=%s\nkernel=%s\ndtb=%s\ninitramfs=%s\ncmdline=%s\nboard=%s\n' \
        "$_id" "$_rel" "$_size" "$_sha" "$(gk_utc)" "${_dtb%@*}" "$_rel" "$_dtb" "$_ird" "$_cmd" "$(gk_sha "$BOARD")" |
        gs_write "$BI/$_id.manifest" || die "install $_rel: cannot write $BI/$_id.manifest"
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
    gk_slot_holds "$TESTDEV" "$_ci" || die "reboot-test: the test slot doesn't hold the candidate's image any more; run glassine-bootimg retry"
    kset "requested=$_ci"
    log "reboot-test: $(k candidate) ($_ci)"
    [ -n "${GLASSINE_BI_NOREBOOT:-}" ] && return 0
    exec 9>&-       # the lock released: the shutdown's own steps (the switch) take it
    exec "$REBOOT_CLEAN" "$TEST_REBOOT_REASON"
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
    gk_img_ok "$_id" || die "retry: $BI/$_id.img is gone or damaged; install the kernel again"
    _rel=$(man "$_id" release)
    if ! gk_slot_holds "$TESTDEV" "$_id"; then
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
# (phase 2's promote runs this after the health check; by hand it is refused
# on any other boot)
gk_accept() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "accept: a write of the default slot is unfinished (image $(k writing))"
    _ci=$(k candidate_img) _c=$(k candidate)
    [ -n "$_ci" ] || die "accept: no kernel candidate"
    [ "$(run_id)" = "$_ci" ] || die "accept: this boot runs image $(run_id), not the candidate's ($_ci)"
    gk_img_ok "$_ci" || die "accept: $BI/$_ci.img is gone or damaged; nothing written"
    gk_write_default "$_ci" accept
    case $? in
    0) ;;
    1) gk_fail "default slot write"; exit 1 ;;
    *) exit 1 ;;
    esac
    kset "previous=$(k current)" "previous_img=$(k current_img)" "current=$_c" "current_img=$_ci" \
        candidate= candidate_img= tries= requested= writing= writing_op=
    rm -f "$GK_STARTED"
    gk_prune
    log "accept: the default slot = $_c ($_ci); previous: $(k previous) ($(k previous_img))"
    echo "Kernel $_c is now the default." > "$TMP/glassine-bootimg.notice" 2>/dev/null
    return 0
}

gk_rollback() {
    gk_handoff
    gk_open rw
    [ -z "$(k writing)" ] || die "rollback: a write of the default slot is unfinished (image $(k writing))"
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
    kset "current=$_p" "previous=$(k current)" "current_img=$_pi" "previous_img=$(k current_img)" writing= writing_op=
    rm -f "$GK_STARTED"
    gk_prune
    log "rollback: the default slot = ${_p:-the previous kernel} ($_pi) again"
    echo "glassine-bootimg: the default kernel is ${_p:-the previous one} ($_pi) again; reboot to use it"
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
    promote:0) gk_open; log "promote: the kernel trial is not built in the deployments layout yet (specs/004, phase 2): nothing done" ;;
    *) gk_usage ;;
    esac
}
