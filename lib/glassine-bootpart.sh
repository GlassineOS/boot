# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-bootpart.sh: the boot partition, glassine-boot (docs/boot-partition.md,
# format 1): its records, the loader record's two slots, a kernel set's files; and
# its raw form (the gr_ functions at the end: the region table, the regions).
# Sourced by glassine-bootimg (lib/glassine-kernel.sh, HANDOFF=uefi),
# glassine-loader-mark and glassine-boot-raw. busybox ash, sed, awk, od, gzip and
# sha256sum only: the recovery runs it too (004 FR-016). Every gp_ function but
# gp_open/gp_close (where a board keeps its record, mounted or read for one command,
# 010 FR-026) works on a directory that is the boot partition's top level.
#
# The reading of a record is the installer's and the loader's (GlassineOS/installer
# core/src/pc_boot.rs parse_record/read_slot/record_in_use, GlassineOS/loader
# core/src/record.rs), byte for byte: text of key=value lines each ended by a
# newline, valid UTF-8, no carriage return, format=1 first, no key twice, no empty
# key, last check=<sha256 of every byte before that line>. A slot is valid when the
# record in it is, nothing but newlines follows it, and seq is decimal. A slot
# holding a NUL byte can't be carried by this shell code: no write is made then
# (GP_WHY says so), so a slot the loader may read as valid is never written over.
#
# Test hooks (only with GLASSINE_BI_TEST=1): GLASSINE_BI_AFTER_SLOT is eval'd after
# a slot's bytes are written and before they are read back ($1 = the slot file);
# GLASSINE_BI_AFTER_SETFILE after a set file's bytes are written ($1 = the file).

# shellcheck disable=SC2034  # GP_USE, GP_OTHER, GP_SEQ, GP_BOTH: read by the callers
GP_SLOT_BYTES=16384
GP_CMDLINE_MAX=1920
GP_TMP=${TMP:-/run}

gp_sha() { sha256sum < "$1" | cut -d' ' -f1; }
gp_hook() {     # gp_hook VAR FILE
    [ "${GLASSINE_BI_TEST:-}" = 1 ] || return 0
    eval "_gp_gh=\${$1:-}"
    [ -n "$_gp_gh" ] || return 0
    set -- "$2"
    eval "$_gp_gh"
}

# gp_read FILE N: the first N bytes of FILE, read with O_DIRECT (the disk's bytes,
# not the page cache's); a plain read where the file system can't do O_DIRECT
gp_read() {
    if dd if="$1" of=/dev/null bs=4096 count=1 iflag=direct 2>/dev/null; then
        dd if="$1" bs=4096 count=$((($2 + 4095) / 4096)) iflag=direct 2>/dev/null | head -c "$2"
    else
        head -c "$2" "$1"
    fi
}

# gp_utf8 FILE: FILE is valid UTF-8 (Rust's from_utf8: no overlong forms, no
# surrogates, nothing past U+10FFFF)
gp_utf8() {
    od -An -v -tu1 "$1" | awk '
        { for (i = 1; i <= NF; i++) { b = $i + 0
            if (need == 0) {
                if (b < 128) continue
                if (b >= 194 && b <= 223) { need = 1; lo = 128; hi = 191 }
                else if (b == 224) { need = 2; lo = 160; hi = 191 }
                else if ((b >= 225 && b <= 236) || b == 238 || b == 239) { need = 2; lo = 128; hi = 191 }
                else if (b == 237) { need = 2; lo = 128; hi = 159 }
                else if (b == 240) { need = 3; lo = 144; hi = 191 }
                else if (b >= 241 && b <= 243) { need = 3; lo = 128; hi = 191 }
                else if (b == 244) { need = 3; lo = 128; hi = 143 }
                else { bad = 1; exit }
            } else {
                if (b < lo || b > hi) { bad = 1; exit }
                need--; lo = 128; hi = 191
            } } }
        END { exit (bad || need) ? 1 : 0 }'
}

# gp_nul FILE: FILE holds a NUL byte
gp_nul() { [ "$(tr -d '\000' < "$1" | wc -c)" != "$(wc -c < "$1")" ]; }

# gp_rec_ok FILE: the whole of FILE is a valid record (no NUL byte either)
gp_rec_ok() {
    [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' ')" = 0a ] || return 1
    ! gp_nul "$1" || return 1
    ! grep -q "$(printf '\r')" "$1" || return 1
    gp_utf8 "$1" || return 1
    _gp_gl=$(tail -n 1 "$1")
    case $_gp_gl in check=*) ;; *) return 1 ;; esac
    [ "${_gp_gl#check=}" = "$(sed '$d' "$1" | sha256sum | cut -d' ' -f1)" ] || return 1
    sed '$d' "$1" | awk '
        { e = index($0, "="); if (e < 2) { bad = 1; exit }
          k = substr($0, 1, e - 1); if (k in seen) { bad = 1; exit }; seen[k] = 1
          if (NR == 1 && $0 != "format=1") { bad = 1; exit } }
        END { exit (bad || NR == 0) ? 1 : 0 }'
}

# gp_get REC KEY: KEY's value in the record file REC (a missing key: empty)
gp_get() { sed '$d' "$1" | awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }

# gp_slot SLOTFILE OUT: SLOTFILE is a valid slot; its record goes to OUT and its
# seq (leading zeros dropped) is printed. 1 = not valid (OUT removed); 2 = it holds
# a NUL byte (what the loader makes of it is not known here).
gp_slot() {
    rm -f "$2"
    [ -r "$1" ] || return 1
    # what no valid slot can be, NUL bytes or not: the last byte not a newline (a
    # region never written, a slot cut over zeros), the first line not format=1
    [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' ')" = 0a ] || return 1
    [ "$(head -c 9 "$1" | od -An -tx1 | tr -d ' \n')" = 666f726d61743d310a ] || return 1
    if gp_nul "$1"; then return 2; fi
    # the record: every line up to the last that isn't empty (only newlines follow it)
    awk '{ l[NR] = $0 } $0 != "" { last = NR } END { for (i = 1; i <= last; i++) print l[i] }' "$1" > "$2" || { rm -f "$2"; return 1; }
    gp_rec_ok "$2" || { rm -f "$2"; return 1; }
    _gp_gs=$(gp_get "$2" seq)
    case $_gp_gs in ''|*[!0-9]*) rm -f "$2"; return 1 ;; esac
    _gp_gs=$(echo "$_gp_gs" | sed 's/^0*//'); _gp_gs=${_gp_gs:-0}
    # u64, as the loader parses it
    if [ ${#_gp_gs} -gt 20 ] || { [ ${#_gp_gs} = 20 ] && [ "$(printf '%s\n18446744073709551615\n' "$_gp_gs" | LC_ALL=C sort | tail -n 1)" != 18446744073709551615 ]; }; then
        rm -f "$2"; return 1
    fi
    echo "$_gp_gs"
}

# gp_gt A B: decimal A > decimal B (no leading zeros)
gp_gt() {
    [ ${#1} -gt ${#2} ] && return 0
    [ ${#1} -lt ${#2} ] && return 1
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | tail -n 1)" = "$1" ]
}

# gp_in_use DIR: the loader record in use on the boot partition at DIR. Sets
# GP_USE (a or b), GP_OTHER, GP_SEQ, GP_BOTH (1: both slots valid), GP_REC (the
# record, a file) and GP_OREC (the other slot's record, a file, when it is valid).
# 1 = no valid slot (GP_WHY says why); 2 = a slot holds a NUL byte: nothing is
# written.
gp_in_use() {
    GP_REC=$GP_TMP/glassine-bootpart.rec.$$ GP_OREC=$GP_TMP/glassine-bootpart.orec.$$ GP_WHY=''
    [ -z "${GP_RAW:-}" ] || gp_raw_pull "$1"
    _gp_ga=$GP_TMP/glassine-bootpart.a.$$ _gp_gb=$GP_TMP/glassine-bootpart.b.$$
    _gp_sa=$(gp_slot "$1/glassine/loader.a" "$_gp_ga"); _gp_ra=$?
    _gp_sb=$(gp_slot "$1/glassine/loader.b" "$_gp_gb"); _gp_rb=$?
    if [ $_gp_ra = 2 ] || [ $_gp_rb = 2 ]; then
        rm -f "$_gp_ga" "$_gp_gb"; GP_WHY="a slot of the loader record holds a NUL byte: this tool can't carry it"; return 2
    fi
    if [ $_gp_ra = 0 ] && [ $_gp_rb = 0 ]; then
        GP_BOTH=1
        if gp_gt "$_gp_sb" "$_gp_sa"; then GP_USE=b GP_OTHER=a GP_SEQ=$_gp_sb; mv -f "$_gp_gb" "$GP_REC"; mv -f "$_gp_ga" "$GP_OREC"
        else GP_USE=a GP_OTHER=b GP_SEQ=$_gp_sa; mv -f "$_gp_ga" "$GP_REC"; mv -f "$_gp_gb" "$GP_OREC"; fi
        return 0
    fi
    GP_BOTH=0; rm -f "$GP_OREC"
    if [ $_gp_ra = 0 ]; then GP_USE=a GP_OTHER=b GP_SEQ=$_gp_sa; mv -f "$_gp_ga" "$GP_REC"; return 0; fi
    if [ $_gp_rb = 0 ]; then GP_USE=b GP_OTHER=a GP_SEQ=$_gp_sb; mv -f "$_gp_gb" "$GP_REC"; return 0; fi
    GP_WHY="no slot of the loader record is valid"
    return 1
}

gp_clean() { rm -rf "$GP_TMP"/glassine-bootpart.*."$$"; }

# gp_record_text OUT REC KEY=VALUE...: REC with each KEY set to VALUE where it is
# (or added after the last line, in the order given), every other line kept as
# it is, the check line made again
gp_record_text() {
    _gp_go=$1 _gp_gi=$2; shift 2
    _gp_gc=$GP_TMP/glassine-bootpart.chg.$$
    printf '%s\n' "$@" > "$_gp_gc"
    sed '$d' "$_gp_gi" | awk -v chg="$_gp_gc" '
        BEGIN { while ((getline l < chg) > 0) { e = index(l, "="); k = substr(l, 1, e - 1); v[k] = substr(l, e + 1); ord[++n] = k } }
        { e = index($0, "="); k = substr($0, 1, e - 1)
          if (k in v) { print k "=" v[k]; done[k] = 1 } else print }
        END { for (i = 1; i <= n; i++) if (!(ord[i] in done)) { print ord[i] "=" v[ord[i]]; done[ord[i]] = 1 } }' > "$_gp_go.body" || return 1
    { cat "$_gp_go.body"; echo "check=$(gp_sha "$_gp_go.body")"; } > "$_gp_go"
    rm -f "$_gp_go.body" "$_gp_gc"
}

# gp_write DIR KEY=VALUE...: one write of the loader record (boot-partition.md,
# "Writing"): the record in use with the keys changed and seq one higher, padded
# with newlines to 16384 bytes, over the other slot only, synced and read back
# (O_DIRECT). One retry. The slot in use is never written. 0 = the new record is
# the one in use (read back whole, or, after a failed read-back, read as the loader
# reads it); 1 = it isn't (GP_WHY): the record in use is as it was. A value
# holding a newline, a bad key, a record that wouldn't fit, a seq that can't be
# raised: refused.
gp_write() {
    _gp_gd=$1; shift
    for _gp_ga in "$@"; do
        case $_gp_ga in *=*) ;; *) GP_WHY="bad change '$_gp_ga'"; return 1 ;; esac
        case ${_gp_ga%%=*} in ''|*[!a-z0-9_]*) GP_WHY="bad key in '$_gp_ga'"; return 1 ;; esac
        case $_gp_ga in *"
"*) GP_WHY="a value holds a newline"; return 1 ;; esac
    done
    gp_in_use "$_gp_gd" || return 1
    [ ${#GP_SEQ} -le 18 ] || { GP_WHY="seq $GP_SEQ can't be raised"; return 1; }
    _gp_gn=$GP_TMP/glassine-bootpart.new.$$
    gp_record_text "$_gp_gn" "$GP_REC" "seq=$((GP_SEQ + 1))" "$@" || { GP_WHY="cannot make the record"; return 1; }
    _gp_gz=$(wc -c < "$_gp_gn")
    [ "$_gp_gz" -le $GP_SLOT_BYTES ] || { rm -f "$_gp_gn"; GP_WHY="the record would be $_gp_gz bytes, a slot holds $GP_SLOT_BYTES: not written"; return 1; }
    { cat "$_gp_gn"; head -c $((GP_SLOT_BYTES - _gp_gz)) /dev/zero | tr '\000' '\n'; } > "$_gp_gn.slot"
    _gp_gt=$_gp_gd/glassine/loader.$GP_OTHER
    for _gp_gtry in 1 2; do
        if [ -n "${GP_RAW:-}" ]; then
            # the raw form: the slot's 16384 bytes in the region record, flushed, read back
            if gr_put_check $((GP_RAW_REC + $([ "$GP_OTHER" = a ] && echo 0 || echo $GP_SLOT_BYTES))) "$_gp_gn.slot"; then
                rm -f "$_gp_gn" "$_gp_gn.slot"
                return 0
            fi
            GP_WHY="slot $GP_OTHER: the write or its read-back failed (try $_gp_gtry)"
            continue
        fi
        if [ -f "$_gp_gt" ]; then
            dd if="$_gp_gn.slot" of="$_gp_gt" bs=$GP_SLOT_BYTES count=1 conv=notrunc,fsync 2>/dev/null
        else
            dd if="$_gp_gn.slot" of="$_gp_gt" bs=$GP_SLOT_BYTES count=1 conv=fsync 2>/dev/null
        fi
        gp_hook GLASSINE_BI_AFTER_SLOT "$_gp_gt"
        sync
        if [ "$(gp_read "$_gp_gt" $GP_SLOT_BYTES | sha256sum | cut -d' ' -f1)" = "$(gp_sha "$_gp_gn.slot")" ] &&
            [ "$(wc -c < "$_gp_gt")" = $GP_SLOT_BYTES ]; then
            rm -f "$_gp_gn" "$_gp_gn.slot"
            return 0
        fi
        GP_WHY="slot $GP_OTHER: the write or its read-back failed (try $_gp_gtry)"
    done
    rm -f "$_gp_gn.slot"
    # what the loader will read: a slot whose bytes aren't the ones written may
    # still hold the whole new record (cut in its newlines): then it is in use
    _gp_gw=$GP_WHY
    if gp_in_use "$_gp_gd" && cmp -s "$GP_REC" "$_gp_gn"; then
        rm -f "$_gp_gn"
        GP_WHY="$_gp_gw; the slot holds the new record all the same, and it is in use"
        return 0
    fi
    rm -f "$_gp_gn"
    GP_WHY=$_gp_gw
    return 1
}

# gp_names DIR: the kernel sets the two slots name (default, previous, trial),
# one per line, sorted; empty lines dropped. Needs gp_in_use first.
gp_names() {
    for _gp_gf in "$GP_REC" "$GP_OREC"; do
        [ -r "$_gp_gf" ] || continue
        for _gp_gk in default previous trial; do gp_get "$_gp_gf" "$_gp_gk"; done
    done | grep . | sort -u
}

# --- kernel sets ---------------------------------------------------------------------
# gp_board_cmdline BOARD: CMDLINE of board.conf, as the installer reads it
# (pc_boot.rs board_cmdline): one line CMDLINE="<text>" or CMDLINE=<word>, no
# backslash, $, backtick or further quote; a second line, another form or none:
# refused (1, the reason on stderr)
gp_board_cmdline() {
    _gp_bn=$(grep -c "^[[:space:]]*\\(export[[:space:]]\\+\\)\\?CMDLINE[= ]" "$1")
    [ "$_gp_bn" = 1 ] || { if [ "$_gp_bn" = 0 ]; then echo "board.conf sets no CMDLINE" >&2; else echo "board.conf sets CMDLINE twice" >&2; fi; return 1; }
    _gp_bl=$(grep "^[[:space:]]*\\(export[[:space:]]\\+\\)\\?CMDLINE[= ]" "$1")
    case $_gp_bl in CMDLINE=*) ;; *) echo "board.conf's '$_gp_bl' isn't CMDLINE=\"<text>\" or CMDLINE=<word>" >&2; return 1 ;; esac
    _gp_bv=${_gp_bl#CMDLINE=}
    case $_gp_bv in
    \"*\")
        _gp_bv=${_gp_bv#\"}; _gp_bv=${_gp_bv%\"}
        case $_gp_bv in *[\\\$\`\"\']*) echo "board.conf's CMDLINE holds a backslash, \$, backtick or quote" >&2; return 1 ;; esac
        ;;
    *)
        case $_gp_bv in ''|*[\\\$\`\"\'[:space:]]*) echo "board.conf's CMDLINE=$_gp_bv isn't CMDLINE=\"<text>\" or CMDLINE=<word>" >&2; return 1 ;; esac
        ;;
    esac
    printf '%s\n' "$_gp_bv"
}

# gp_base_ok BASE: a base command line a kernel set may be made with
# (boot-partition.md, "The command line"); 1 with the reason on stderr
gp_base_ok() {
    case $1 in *[[:cntrl:]]*) echo "the base command line holds a control character" >&2; return 1 ;; esac
    case $1 in " "*|*" "|*"  "*) echo "the base command line '$1' isn't words separated by single spaces" >&2; return 1 ;; esac
    for _gp_bw in $1; do
        case $_gp_bw in glassine.system=*|glassine.userdata=*|glassine.img=*|glassine.deploy.once=*)
            echo "the base command line holds ${_gp_bw%%=*}=, which is added to a kernel set, never given" >&2; return 1 ;;
        esac
    done
}

# gp_set_id KERNEL_SHA INITRD_SHA BASE: a set's id
gp_set_id() { printf '%s\n%s\n%s\n' "$1" "$2" "$3" | sha256sum | cut -c1-16; }

# gp_set_rec OUT ID RELEASE KSHA KSIZE ISHA ISIZE CMDLINE INITRAMFS: set.rec
gp_set_rec() {
    printf 'format=1\nid=%s\nrelease=%s\nkernel_sha256=%s\nkernel_size=%s\ninitrd_sha256=%s\ninitrd_size=%s\ncmdline=%s\ninitramfs=%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" > "$1.body" || return 1
    { cat "$1.body"; echo "check=$(gp_sha "$1.body")"; } > "$1"
    rm -f "$1.body"
}

# gp_cpio_entry INO MODE NAME DATAFILE: one newc entry (boot-partition.md, "The
# board archive"); DATAFILE empty: no data
gp_cpio_entry() {
    _gp_cs=0; [ -z "$4" ] || _gp_cs=$(wc -c < "$4")
    _gp_cn=$((${#3} + 1))
    printf '070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%s' "$1" "$2" 0 0 1 0 "$_gp_cs" 0 0 0 0 "$_gp_cn" 0 "$3"
    # the name's zero byte, then zeros to a multiple of 4 (the 110-byte header + name)
    head -c $((1 + (4 - (110 + _gp_cn) % 4) % 4)) /dev/zero
    [ -z "$4" ] || { cat "$4"; head -c $(((4 - _gp_cs % 4) % 4)) /dev/zero; }
}

# gp_board_archive BOARD OUT: the board archive of board.conf BOARD
gp_board_archive() {
    {
        gp_cpio_entry 1 $((0x41ED)) etc ''
        gp_cpio_entry 2 $((0x41ED)) etc/glassine-boot ''
        gp_cpio_entry 3 $((0x81A4)) etc/glassine-boot/board.conf "$1"
        gp_cpio_entry 4 0 'TRAILER!!!' ''
    } > "$2"
}

# gp_pad4 FILE: zeros onto FILE up to a multiple of 4
gp_pad4() { head -c $(((4 - $(wc -c < "$1") % 4) % 4)) /dev/zero >> "$1"; }

# gp_assemble OUT BOARD INITRAMFS MICRODIR BOOTMODS: a kernel set's initrd: the
# microcode archives of MICRODIR (*-ucode.img, in byte order of their names), the
# initramfs file, the board archive, the boot-modules archive (BOOTMODS, empty:
# none), each at a multiple of 4, nothing after the last
gp_assemble() {
    : > "$1" || return 1
    if [ -d "$4" ]; then
        for _gp_am in $(cd "$4" && ls -1 | LC_ALL=C sort); do
            case $_gp_am in *-ucode.img) ;; *) continue ;; esac
            [ -f "$4/$_gp_am" ] || continue
            cat "$4/$_gp_am" >> "$1" && gp_pad4 "$1" || return 1
        done
    fi
    cat "$3" >> "$1" && gp_pad4 "$1" || return 1
    gp_board_archive "$2" "$1.board" && cat "$1.board" >> "$1" || { rm -f "$1.board"; return 1; }
    rm -f "$1.board"
    [ -z "$5" ] || { gp_pad4 "$1" && cat "$5" >> "$1"; } || return 1
}

# gp_set_check DIR ID REC_SHA: the set in DIR/glassine/sets/ID is complete and
# matches, as the loader checks it (boot-partition.md, "How the loader checks and
# starts a set"; 010 FR-007): set.rec's sha256 is REC_SHA, the record is valid, its
# id the directory's, its fields well formed, its command line within the rules,
# vmlinuz and initrd of the record's sizes and sums (read with O_DIRECT). 1 = no,
# GP_WHY says why.
gp_set_check() {
    _gp_cd=$1/glassine/sets/$2 _gp_cr=$GP_TMP/glassine-bootpart.set.$$
    [ -r "$_gp_cd/set.rec" ] || { GP_WHY="set $2 has no set.rec"; return 1; }
    _gp_csz=$(wc -c < "$_gp_cd/set.rec")
    [ "$_gp_csz" -le 65536 ] || { GP_WHY="set $2: set.rec is too large"; return 1; }
    gp_read "$_gp_cd/set.rec" "$_gp_csz" > "$_gp_cr"
    [ "$(gp_sha "$_gp_cr")" = "$3" ] || { rm -f "$_gp_cr"; GP_WHY="set $2: set.rec is not the one the loader record names"; return 1; }
    gp_rec_ok "$_gp_cr" || { rm -f "$_gp_cr"; GP_WHY="set $2: set.rec is not a valid record"; return 1; }
    _gp_ci=$(gp_get "$_gp_cr" id) _gp_cks=$(gp_get "$_gp_cr" kernel_sha256) _gp_ckz=$(gp_get "$_gp_cr" kernel_size)
    _gp_cis=$(gp_get "$_gp_cr" initrd_sha256) _gp_ciz=$(gp_get "$_gp_cr" initrd_size) _gp_cc=$(gp_get "$_gp_cr" cmdline)
    rm -f "$_gp_cr"
    [ "$_gp_ci" = "$2" ] && echo "$_gp_ci" | grep -qx '[0-9a-f]\{16\}' || { GP_WHY="set $2: its id is not its directory's"; return 1; }
    echo "$_gp_cks" | grep -qx '[0-9a-f]\{64\}' && echo "$_gp_cis" | grep -qx '[0-9a-f]\{64\}' &&
        echo "$_gp_ckz" | grep -qx '[0-9]\+' && echo "$_gp_ciz" | grep -qx '[0-9]\+' || { GP_WHY="set $2: its record's sums or sizes are not well formed"; return 1; }
    gp_cmdline_ok "$_gp_cc" "$2" || return 1
    for _gp_cf in "vmlinuz $_gp_ckz $_gp_cks" "initrd $_gp_ciz $_gp_cis"; do
        set -- $_gp_cf
        [ -r "$_gp_cd/$1" ] && [ "$(wc -c < "$_gp_cd/$1")" = "$2" ] || { GP_WHY="set $_gp_ci: $1 is missing or not $2 bytes"; return 1; }
        [ "$(gp_read "$_gp_cd/$1" "$2" | sha256sum | cut -d' ' -f1)" = "$3" ] || { GP_WHY="set $_gp_ci: $1 doesn't match its sum"; return 1; }
    done
}

# gp_cmdline_ok CMDLINE ID: the rules the loader checks a set's command line by
gp_cmdline_ok() {
    [ ${#1} -le $GP_CMDLINE_MAX ] || { GP_WHY="set $2: its command line is longer than $GP_CMDLINE_MAX bytes"; return 1; }
    case $1 in *[[:cntrl:]]*) GP_WHY="set $2: its command line holds a control character"; return 1 ;; esac
    _gp_cy='' _gp_cu='' _gp_cm=''
    for _gp_cw in $1; do
        case $_gp_cw in
        glassine.system=*) _gp_cy=1 ;;
        glassine.userdata=*) _gp_cu=1 ;;
        "glassine.img=$2") _gp_cm=1 ;;
        glassine.deploy.once=*) GP_WHY="set $2: its command line holds glassine.deploy.once="; return 1 ;;
        esac
    done
    [ -n "$_gp_cy$_gp_cu$_gp_cm" ] && [ "$_gp_cy$_gp_cu$_gp_cm" = 111 ] || { GP_WHY="set $2: its command line lacks glassine.system=, glassine.userdata= or glassine.img=$2"; return 1; }
}

# gp_put FROM TO: a set file written as TO.new, synced, read back (O_DIRECT) against
# FROM's sum, renamed to TO, synced. One retry. 1 = not written (TO.new removed).
gp_put() {
    _gp_ps=$(gp_sha "$1") _gp_pz=$(wc -c < "$1")
    for _gp_ptry in 1 2; do
        rm -f "$2.new"
        if dd if="$1" of="$2.new" bs=1M conv=fsync 2>/dev/null && { gp_hook GLASSINE_BI_AFTER_SETFILE "$2.new"; sync; } &&
            [ "$(wc -c < "$2.new")" = "$_gp_pz" ] && [ "$(gp_read "$2.new" "$_gp_pz" | sha256sum | cut -d' ' -f1)" = "$_gp_ps" ] &&
            mv -f "$2.new" "$2" && sync; then
            return 0
        fi
        GP_WHY="${2##*/}: the write or its read-back failed (try $_gp_ptry)"
    done
    rm -f "$2.new"
    return 1
}

# gp_sweep DIR [KEEP]: removes what no valid slot names: every directory under
# glassine/sets/ neither slot names (both slots read as gp_in_use left them) but
# KEEP (the set about to be written, kept when its files already match), and every
# file ending in .new under glassine/ (boot-partition.md, "Layout"). The recovery's
# directories are the recovery update's to tidy. Prints what it removed, one per
# line.
gp_sweep() {
    _gp_wn=" $(gp_names | tr '\n' ' ') ${2:-} "
    for _gp_wd in "$1"/glassine/sets/*; do
        [ -e "$_gp_wd" ] || continue
        case $_gp_wn in *" ${_gp_wd##*/} "*) continue ;; esac
        rm -rf "${_gp_wd:?}" && echo "set ${_gp_wd##*/}"
    done
    find "$1/glassine" -name '*.new' 2>/dev/null | while read -r _wf; do rm -rf "${_wf:?}" && echo "${_wf#"$1"/}"; done
    sync
}

# --- where the record is: the boot partition's form -------------------------------
# Everything above works on a directory holding glassine/loader.a and loader.b. Where
# that directory comes from is the board's (gp_kind: board.conf HANDOFF and
# BOOT_FORM):
#   uefi   the FAT form (a PC, HANDOFF=uefi): the FAT partition named BOOT_PART on
#          the disk of the system partition this boot names, mounted for the write
#   raw    the raw form (BOOT_FORM=raw: a machine whose parent bootloader starts the
#          loader, specs/012): the partition named BOOT_PART, its region table read,
#          the two slots of the region record copied into a directory of GP_TMP for
#          reading; a write goes to the slot's place on the device (gp_write), and
#          every gp_in_use reads both slots from the device again

# gp_kind HANDOFF BOOT_FORM: where this board's loader record is: uefi, raw, or
# nothing (1: the board keeps no loader record). 2 = a combination that is wrong
# (said on stderr): a PC's boot partition is always FAT
gp_kind() {
    case $2 in
    '') [ "$1" = uefi ] && { echo uefi; return 0; }; return 1 ;;
    raw) [ "$1" != uefi ] || { echo "BOOT_FORM=raw with HANDOFF=uefi: a PC's boot partition is FAT" >&2; return 2; }; echo raw ;;
    *) echo "unknown BOOT_FORM '$2'" >&2; return 2 ;;
    esac
}

# gp_has_record KIND: 0 when a board of that kind (gp_kind) keeps a loader record
gp_has_record() { case $1 in uefi|raw) return 0 ;; esac; return 1; }

# gp_open KIND CMDLINE BOOTPART MNT [ro]: the loader record's directory opened;
# GP_DIR its top level, GP_MNTD set when gp_open mounted it (at MNT), GP_RAW the
# device in the raw form (GP_RAW_REC: the offset of its region record). 1 = not
# opened (GP_WHY). GLASSINE_BI_BOOTPART_DIR (tests) is the directory of the FAT
# form, unmounted; GLASSINE_BI_BOOTPART_DEV the device of either form.
gp_open() {
    GP_DIR='' GP_MNTD='' GP_RAW=''
    gp_has_record "$1" || { GP_WHY="the hand-off '$1' keeps no loader record"; return 1; }
    if [ "$1" = raw ]; then
        _gp_od=$(gp_raw_dev "$2" "$3") || { GP_WHY="the boot partition: $_gp_od"; return 1; }
        # the device's lock, the one glassine-boot-raw holds for its writes (fd 8)
        exec 8<"$_gp_od" || { GP_WHY="cannot open the boot partition $_gp_od"; return 1; }
        _gp_on=0
        until flock -n 8; do
            [ $_gp_on -lt 10 ] || { GP_WHY="the boot partition $_gp_od is locked by another writer"; return 1; }
            sleep 1; _gp_on=$((_gp_on + 1))
        done
        gr_open "$_gp_od" || { GP_WHY="the boot partition $_gp_od: $GR_WHY"; return 1; }
        gr_region record && [ "$GR_RSIZE" -ge $((2 * GP_SLOT_BYTES)) ] || { GP_WHY="the boot partition $_gp_od has no region record of 32 KiB"; return 1; }
        GP_DIR=$GP_TMP/glassine-bootpart.raw.$$
        mkdir -p "$GP_DIR/glassine" || { GP_WHY="cannot create $GP_DIR"; GP_DIR=''; return 1; }
        GP_RAW=$_gp_od GP_RAW_REC=$GR_ROFF
        return 0
    fi
    if [ -n "${GLASSINE_BI_BOOTPART_DIR:-}" ]; then GP_DIR=$GLASSINE_BI_BOOTPART_DIR; return 0; fi
    _gp_od=$(gp_boot_dev "$2" "$3") || { GP_WHY="the boot partition: $_gp_od"; return 1; }
    mkdir -p "$4" || { GP_WHY="cannot create $4"; return 1; }
    ! mountpoint -q "$4" || { GP_WHY="$4 is mounted already: another writer?"; return 1; }
    mount -t vfat -o "${5:-rw},noatime" "$_gp_od" "$4" || { GP_WHY="cannot mount the boot partition $_gp_od"; return 1; }
    GP_DIR=$4 GP_MNTD=1
}

# gp_close: what gp_open mounted, synced and unmounted. 1 = not unmounted (GP_WHY)
gp_close() {
    if [ -n "${GP_RAW:-}" ]; then
        rm -rf "${GP_DIR:?}"; GP_DIR='' GP_RAW=''
        exec 8<&-
        return 0
    fi
    [ -n "${GP_MNTD:-}" ] || return 0
    sync
    umount "$GP_DIR" || { GP_WHY="cannot unmount the boot partition at $GP_DIR"; return 1; }
    GP_DIR='' GP_MNTD=''
}

# gp_restart_word KIND CMDLINE BOOT_PART MNT: what the loader record says about the
# next cold start, for a soft restart (specs/013 FR-001), read only (a FAT boot
# partition mounted read-only for it): loader-request (it holds a request: the start
# menu, the recovery, a kernel trial), loader-default (its default names another
# kernel set than this boot's glassine.img=; under a parent, BOOT_FORM=raw, an empty
# default is the parent's baseline, which this boot runs when it names no set either
# slot names), loader-unreadable (no record in use can be read); nothing when the
# next cold start would start this boot's set, and on a board that keeps no record.
gp_restart_word() {
    gp_has_record "$1" || return 0
    _gp_rw=''
    if ! gp_open "$1" "$2" "$3" "$4" ro || ! gp_in_use "$GP_DIR"; then
        _gp_rw=loader-unreadable
    else
        _gp_run=$(tr ' ' '\n' < "$2" 2>/dev/null | sed -n 's/^glassine\.img=//p' | head -n 1)
        _gp_def=$(gp_get "$GP_REC" default)
        if [ -n "$(gp_get "$GP_REC" request)" ]; then _gp_rw=loader-request
        elif [ -z "$_gp_def" ] && [ "$1" = raw ]; then
            case " $(gp_names | tr '\n' ' ')" in *" $_gp_run "*) [ -z "$_gp_run" ] || _gp_rw=loader-default ;; esac
        elif [ "$_gp_def" != "$_gp_run" ]; then _gp_rw=loader-default
        fi
    fi
    gp_close >/dev/null 2>&1
    gp_clean
    [ -z "$_gp_rw" ] || echo "$_gp_rw"
}

# gp_raw_pull DIR: both slots of the device's region record into DIR/glassine
# (loader.a, loader.b); a slot that can't be read is left out (not valid)
gp_raw_pull() {
    rm -f "$1/glassine/loader.a" "$1/glassine/loader.b"
    gr_get "$GP_RAW_REC" $GP_SLOT_BYTES > "$1/glassine/loader.a.r" && [ "$(wc -c < "$1/glassine/loader.a.r")" = $GP_SLOT_BYTES ] && mv -f "$1/glassine/loader.a.r" "$1/glassine/loader.a"
    gr_get $((GP_RAW_REC + GP_SLOT_BYTES)) $GP_SLOT_BYTES > "$1/glassine/loader.b.r" && [ "$(wc -c < "$1/glassine/loader.b.r")" = $GP_SLOT_BYTES ] && mv -f "$1/glassine/loader.b.r" "$1/glassine/loader.b"
    rm -f "$1/glassine/loader.a.r" "$1/glassine/loader.b.r"
}

# gp_raw_dev CMDLINE NAME: the raw boot partition's device: with a system partition
# on the command line (glassine.system=PARTUUID=), the one gp_boot_dev finds; else
# the one partition named NAME on any disk (a device with one disk passes no
# identities, docs/boot.md). 1 = not found, or more than one (the reason printed).
# Test hooks: as gp_boot_dev's.
gp_raw_dev() {
    [ -z "${GLASSINE_BI_BOOTPART_DEV:-}" ] || { echo "$GLASSINE_BI_BOOTPART_DEV"; return 0; }
    if gp_cmdpart glassine.system "$1" >/dev/null; then gp_boot_dev "$1" "$2"; return; fi
    _gp_rn=0 _gp_rd=''
    for _gp_u in "${GLASSINE_BI_SYSBLOCK:-/sys/class/block}"/*/uevent; do
        grep -qx "PARTNAME=$2" "$_gp_u" 2>/dev/null || continue
        _gp_rn=$((_gp_rn + 1)) _gp_rd=${GLASSINE_BI_DEVDIR:-/dev}/$(sed -n 's/^DEVNAME=//p' "$_gp_u")
    done
    [ $_gp_rn = 1 ] || { echo "$_gp_rn partitions named $2"; return 1; }
    echo "$_gp_rd"
}

# gp_cmdpart KEY CMDLINE: the identity the command line (a file) gives KEY
# (KEY=PARTUUID=<uuid>, once), in lower case; 1 = none
gp_cmdpart() {
    _gp_cq=$(tr ' ' '\n' < "$2" | awk -v k="$1=" 'index($0, k) == 1 { n++; v = substr($0, length(k) + 1) } END { if (n == 1) print v }')
    case $_gp_cq in PARTUUID=*) _gp_cq=$(echo "${_gp_cq#PARTUUID=}" | tr A-F a-f) ;; *) return 1 ;; esac
    echo "$_gp_cq" | grep -qx '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' || return 1
    echo "$_gp_cq"
}

# gp_boot_dev CMDLINE NAME: the boot partition's device: the partition named NAME
# on the disk that holds the system partition the command line names
# (glassine.system=PARTUUID=; its identity from the kernel's uevent, else the
# disk's GPT, as the initramfs reads it), and only one. 1 = not found (the reason
# printed). Test hooks: GLASSINE_BI_BOOTPART_DEV, GLASSINE_BI_SYSBLOCK
# (/sys/class/block), GLASSINE_BI_DEVDIR (/dev).
gp_boot_dev() {
    [ -z "${GLASSINE_BI_BOOTPART_DEV:-}" ] || { echo "$GLASSINE_BI_BOOTPART_DEV"; return 0; }
    _gp_sb=${GLASSINE_BI_SYSBLOCK:-/sys/class/block}
    _gp_su=$(gp_cmdpart glassine.system "$1") || { echo "this boot's command line names no system partition (glassine.system=PARTUUID=)"; return 1; }
    _gp_sd=''
    for _gp_u in "$_gp_sb"/*/uevent; do
        grep -q '^PARTN=' "$_gp_u" 2>/dev/null || continue
        [ "$(gp_part_uuid "${_gp_u%/uevent}")" = "$_gp_su" ] || continue
        _gp_sd=$(cd -P "${_gp_u%/uevent}/.." && pwd -P) || continue
    done
    [ -n "$_gp_sd" ] || { echo "no partition is the system partition $_gp_su"; return 1; }
    _gp_bn=0 _gp_bd=''
    for _gp_u in "$_gp_sd"/*/uevent; do
        grep -qx "PARTNAME=$2" "$_gp_u" 2>/dev/null || continue
        _gp_bn=$((_gp_bn + 1)) _gp_bd=${GLASSINE_BI_DEVDIR:-/dev}/$(sed -n 's/^DEVNAME=//p' "$_gp_u")
    done
    [ $_gp_bn = 1 ] || { echo "$_gp_bn partitions named $2 on the system partition's disk"; return 1; }
    echo "$_gp_bd"
}

# gp_le DEV OFFSET N, gp_part_uuid DIR: as the initramfs's le and part_uuid
gp_le() { od -An -v -tu1 -j "$2" -N "$3" "$1" 2>/dev/null | awk 'BEGIN { m = 1 } { for (i = 1; i <= NF; i++) { v += $i * m; m *= 256 } } END { if (m > 1) printf "%.0f\n", v }'; }
gp_part_uuid() {
    _gp_qu=$(sed -n 's/^PARTUUID=//p' "$1/uevent" 2>/dev/null | head -n 1)
    [ -z "$_gp_qu" ] || { echo "$_gp_qu" | tr A-F a-f; return 0; }
    _gp_pn=$(sed -n 's/^PARTN=//p' "$1/uevent" 2>/dev/null)
    case $_gp_pn in ''|*[!0-9]*) return 1 ;; esac
    _gp_pd=$(cd -P "$1/.." 2>/dev/null && pwd -P) || return 1
    _gp_dn=$(sed -n 's/^DEVNAME=//p' "$_gp_pd/uevent" 2>/dev/null)
    _gp_dv=${GLASSINE_BI_DEVDIR:-/dev}/$_gp_dn
    [ -n "$_gp_dn" ] && [ -r "$_gp_dv" ] || return 1
    _gp_lb=$(cat "$_gp_pd/queue/logical_block_size" 2>/dev/null); _gp_lb=${_gp_lb:-512}
    [ "$(dd if="$_gp_dv" bs=1 skip="$_gp_lb" count=8 2>/dev/null)" = "EFI PART" ] || return 1
    _gp_el=$(gp_le "$_gp_dv" $((_gp_lb + 72)) 8) _gp_en=$(gp_le "$_gp_dv" $((_gp_lb + 80)) 4) _gp_es=$(gp_le "$_gp_dv" $((_gp_lb + 84)) 4)
    [ -n "$_gp_el" ] && [ -n "$_gp_en" ] && [ -n "$_gp_es" ] && [ "$_gp_pn" -ge 1 ] && [ "$_gp_pn" -le "$_gp_en" ] && [ "$_gp_es" -ge 128 ] || return 1
    _gp_eo=$((_gp_el * _gp_lb + (_gp_pn - 1) * _gp_es))
    [ "$(gp_le "$_gp_dv" $((_gp_eo + 32)) 8)" = "$(( $(cat "$1/start" 2>/dev/null || echo -1) * 512 / _gp_lb ))" ] || return 1
    od -An -v -tx1 -j $((_gp_eo + 16)) -N 16 "$_gp_dv" 2>/dev/null | tr -s ' \n' ' ' | awk '{ if (NF != 16) exit 1
        printf "%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s\n", $4, $3, $2, $1, $6, $5, $8, $7, $9, $10, $11, $12, $13, $14, $15, $16 }'
}

# --- the raw form (docs/boot-partition.md, "The raw form") ----------------------------
# A boot partition with no file system: a region table (GLREGION, the primary at 0, the
# backup in the last 4096 bytes) and named regions. gr_open reads the table of a device
# (a block device or, for tests, a file); the other gr_ functions work on that device
# (GR_DEV). Every write is whole 4096-byte blocks at 4096-byte offsets, flushed, and
# read back where the format asks for it. CRC-32 is zlib's, taken from gzip's trailer
# (busybox has no CRC-32 tool). Read and written byte for byte as the loader's
# core/src/raw.rs (GlassineOS/loader) reads and writes them.
# Test hooks (only with GLASSINE_BI_TEST=1): GLASSINE_BI_RAW_TRACE, a directory: each
# block write is also kept there as <n>.off (its offset) and <n>.bin (its bytes), in
# the order made; GLASSINE_BI_RAW_CUT, a file holding a number of bytes: the writes
# stop after that many (the last one cut inside, at that byte) and the process is
# killed, as by a power cut; GLASSINE_BI_AFTER_PUT is eval'd after a block write
# ($1 = the device, $2 = the offset, $3 = the length).

GR_TABLE=4096 GR_HEAD=4096 GR_ENTRIES=62 GR_LOADER_MAX=3141632 GR_LAYOUT_MIN=16777216
# the table of "Sizes" (16 MiB), used for every partition of 16 MiB or more:
# name, offset, size
GR_LAYOUT='record 65536 32768
probe 131072 65536
loader 1048576 3145728
splash-default 4194304 3145728
splash 7340032 3145728
override 10485760 3145728'

# gr_crc: the CRC-32 of stdin, 8 hex digits
gr_crc() { gzip -1 -c | tail -c 8 | od -An -N4 -tu1 | awk '{ printf "%02x%02x%02x%02x\n", $4, $3, $2, $1 }'; }

# gr_le N VALUE: VALUE (decimal, 0 to 2^63-1) as N bytes, little endian
gr_le() {
    _gr_lv=$2 _gr_ls='' _gr_li=0
    while [ $_gr_li -lt "$1" ]; do
        _gr_ls="$_gr_ls\\$(printf %03o $((_gr_lv & 255)))"; _gr_lv=$((_gr_lv >> 8)); _gr_li=$((_gr_li + 1))
    done
    # shellcheck disable=SC2059  # octal escapes only
    printf "$_gr_ls"
}

# gr_u FILE OFFSET N: the little-endian number at OFFSET (N bytes), decimal; a value
# of 2^63 or more prints negative, which every caller refuses
gr_u() {
    _gr_ur=0 _gr_um=0
    for _gr_ub in $(od -An -v -tu1 -j "$2" -N "$3" "$1"); do
        _gr_ur=$((_gr_ur | (_gr_ub << _gr_um))); _gr_um=$((_gr_um + 8))
    done
    echo $_gr_ur
}

# gr_hex32 FILE OFFSET: the 32-bit number there as 8 hex digits (a stored CRC)
gr_hex32() { printf '%08x\n' "$(gr_u "$1" "$2" 4)"; }

# gr_part FILE OFFSET N: bytes OFFSET to OFFSET+N of FILE
gr_part() { tail -c +$(($2 + 1)) "$1" | head -c "$3"; }

# gr_zero FILE OFFSET N: those bytes of FILE are all zero
gr_zero() { [ "$(gr_part "$1" "$2" "$3" | tr -d '\000' | wc -c)" = 0 ]; }

# gr_get OFFSET LEN: LEN bytes of GR_DEV from OFFSET (a multiple of 512), read with
# O_DIRECT where the device can, to stdout
gr_get() {
    _gr_gb=4096; [ $(($1 % 4096)) = 0 ] || _gr_gb=512
    if dd if="$GR_DEV" of=/dev/null bs=$_gr_gb skip=$(($1 / _gr_gb)) count=1 iflag=direct 2>/dev/null; then
        dd if="$GR_DEV" bs=$_gr_gb skip=$(($1 / _gr_gb)) count=$((($2 + _gr_gb - 1) / _gr_gb)) iflag=direct 2>/dev/null | head -c "$2"
    else
        dd if="$GR_DEV" bs=$_gr_gb skip=$(($1 / _gr_gb)) count=$((($2 + _gr_gb - 1) / _gr_gb)) 2>/dev/null | head -c "$2"
    fi
}

# gr_flush: the device's writes on the medium and its cached blocks dropped
gr_flush() { sync; [ ! -b "$GR_DEV" ] || blockdev --flushbufs "$GR_DEV" 2>/dev/null; return 0; }

# gr_pad FILE: zeros onto FILE up to a multiple of 4096
gr_pad() { head -c $(((4096 - $(wc -c < "$1") % 4096) % 4096)) /dev/zero >> "$1"; }

# gr_put OFFSET FILE: FILE (whole blocks) written at OFFSET of GR_DEV and flushed.
# 1 = the write failed
gr_put() {
    _gr_pn=$(wc -c < "$2")
    if [ "${GLASSINE_BI_TEST:-}" = 1 ]; then
        if [ -n "${GLASSINE_BI_RAW_TRACE:-}" ]; then
            _gr_pt=$(($(find "$GLASSINE_BI_RAW_TRACE" -name '*.off' | wc -l) + 1))
            echo "$1" > "$GLASSINE_BI_RAW_TRACE/$_gr_pt.off"; cp "$2" "$GLASSINE_BI_RAW_TRACE/$_gr_pt.bin"
        fi
        if [ -n "${GLASSINE_BI_RAW_CUT:-}" ]; then
            _gr_pc=$(cat "$GLASSINE_BI_RAW_CUT")
            if [ "$_gr_pc" -lt "$_gr_pn" ]; then
                head -c "$_gr_pc" "$2" | dd of="$GR_DEV" bs=4096 seek=$(($1 / 4096)) conv=notrunc iflag=fullblock 2>/dev/null
                sync
                kill -KILL $$
            fi
            echo $((_gr_pc - _gr_pn)) > "$GLASSINE_BI_RAW_CUT"
        fi
    fi
    dd if="$2" of="$GR_DEV" bs=4096 seek=$(($1 / 4096)) conv=notrunc,fsync 2>/dev/null || return 1
    gr_flush
    if [ "${GLASSINE_BI_TEST:-}" = 1 ] && [ -n "${GLASSINE_BI_AFTER_PUT:-}" ]; then
        set -- "$GR_DEV" "$1" "$_gr_pn"
        eval "$GLASSINE_BI_AFTER_PUT"
    fi
    return 0
}

# gr_put_check OFFSET FILE: gr_put, then FILE's bytes read back. 1 = not written or
# not read back as written
gr_put_check() {
    gr_put "$1" "$2" || return 1
    [ "$(gr_get "$1" "$(wc -c < "$2")" | sha256sum | cut -d' ' -f1)" = "$(gp_sha "$2")" ]
}

# gr_dev_size DEV: the device's size in bytes; 1 when its block size doesn't divide 4096
gr_dev_size() {
    if [ -b "$1" ]; then
        _gr_ds=$(blockdev --getss "$1" 2>/dev/null) || return 1
        [ "$_gr_ds" -gt 0 ] && [ $((4096 % _gr_ds)) = 0 ] || return 1
        blockdev --getsize64 "$1"
    else
        [ -f "$1" ] || return 1
        stat -c %s "$1"
    fi
}

# gr_table_check FILE PART: FILE's first 4096 bytes are a valid table for a partition
# of PART bytes ("The region table"); its entries go to stdout as "name offset size
# flags" lines. 1 = not valid (GR_WHY)
gr_table_check() {
    _gr_tf=$1 _gr_tp=$2
    [ "$(wc -c < "$_gr_tf")" -ge $GR_TABLE ] || { GR_WHY="short"; return 1; }
    [ "$(head -c 8 "$_gr_tf")" = GLREGION ] || { GR_WHY="no GLREGION"; return 1; }
    [ "$(head -c 4092 "$_gr_tf" | gr_crc)" = "$(gr_hex32 "$_gr_tf" 4092)" ] || { GR_WHY="its CRC doesn't match"; return 1; }
    [ "$(gr_u "$_gr_tf" 8 4)" = 1 ] || { GR_WHY="format $(gr_u "$_gr_tf" 8 4)"; return 1; }
    [ "$(gr_u "$_gr_tf" 16 8)" = "$_gr_tp" ] && [ "$_gr_tp" -ge $((2 * GR_TABLE)) ] || { GR_WHY="made for a partition of $(gr_u "$_gr_tf" 16 8) bytes, this one has $_gr_tp"; return 1; }
    _gr_tn=$(gr_u "$_gr_tf" 12 4)
    [ "$_gr_tn" -ge 1 ] && [ "$_gr_tn" -le $GR_ENTRIES ] || { GR_WHY="$_gr_tn entries"; return 1; }
    gr_zero "$_gr_tf" 24 40 && gr_zero "$_gr_tf" $((64 + 64 * _gr_tn)) $((4092 - 64 - 64 * _gr_tn)) || { GR_WHY="bytes that must be zero aren't"; return 1; }
    _gr_te=$GP_TMP/glassine-bootpart.entry.$$ _gr_tl=$GP_TMP/glassine-bootpart.entries.$$
    : > "$_gr_tl"
    _gr_ti=0
    while [ $_gr_ti -lt "$_gr_tn" ]; do
        gr_part "$_gr_tf" $((64 + 64 * _gr_ti)) 64 > "$_gr_te"
        GR_WHY="entry $_gr_ti is not valid"
        [ "$(head -c 52 "$_gr_te" | gr_crc)" = "$(gr_hex32 "$_gr_te" 52)" ] && gr_zero "$_gr_te" 56 8 || { rm -f "$_gr_te" "$_gr_tl"; return 1; }
        # the name: 1 to 31 of a-z 0-9 -, then zeros only
        od -An -v -tu1 -N 32 "$_gr_te" | awk '
            { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
            END { for (l = 0; l < n && b[l] != 0; l++) if (!((b[l] >= 97 && b[l] <= 122) || (b[l] >= 48 && b[l] <= 57) || b[l] == 45)) exit 1
                  if (l < 1 || l > 31) exit 1
                  for (i = l; i < n; i++) if (b[i] != 0) exit 1 }' || { rm -f "$_gr_te" "$_gr_tl"; return 1; }
        _gr_tnm=$(head -c 32 "$_gr_te" | tr -d '\000')
        _gr_to=$(gr_u "$_gr_te" 32 8) _gr_tz=$(gr_u "$_gr_te" 40 8) _gr_tg=$(gr_u "$_gr_te" 48 4)
        [ "$_gr_to" -ge $GR_TABLE ] && [ "$_gr_tz" -gt 0 ] && [ $((_gr_to % 4096)) = 0 ] && [ $((_gr_tz % 4096)) = 0 ] &&
            [ "$_gr_tz" -le $((_gr_tp - GR_TABLE - _gr_to)) ] || { rm -f "$_gr_te" "$_gr_tl"; return 1; }
        # once, and no overlap
        if awk -v n="$_gr_tnm" -v o="$_gr_to" -v z="$_gr_tz" '$1 == n || (o < $2 + $3 && $2 < o + z) { bad = 1 } END { exit bad ? 0 : 1 }' "$_gr_tl"; then
            rm -f "$_gr_te" "$_gr_tl"; return 1
        fi
        echo "$_gr_tnm $_gr_to $_gr_tz $_gr_tg" >> "$_gr_tl"
        _gr_ti=$((_gr_ti + 1))
    done
    cat "$_gr_tl"; rm -f "$_gr_te" "$_gr_tl"
    GR_WHY=''
}

# gr_open DEV: the raw form of DEV read: GR_DEV, GR_PART (its size), GR_COPY
# (primary or backup: the copy in use) and GR_REGS (a file: "name offset size flags"
# per region). 1 = not opened (GR_WHY): a device that can't be used, or no valid
# table (the partition holds nothing)
gr_open() {
    GR_DEV=$1 GR_COPY='' GR_REGS=$GP_TMP/glassine-bootpart.regions.$$ GR_WHY=''
    GR_PART=$(gr_dev_size "$1") || { GR_WHY="$1: no device, or a block size that doesn't divide 4096"; return 1; }
    [ "$GR_PART" -ge $((2 * GR_TABLE)) ] || { GR_WHY="$1 is too small for the two copies of a region table"; return 1; }
    _gr_ot=$GP_TMP/glassine-bootpart.table.$$
    for _gr_oc in primary backup; do
        _gr_oo=0; [ $_gr_oc = primary ] || _gr_oo=$((GR_PART - GR_TABLE))
        gr_get $_gr_oo $GR_TABLE > "$_gr_ot" 2>/dev/null || continue
        if gr_table_check "$_gr_ot" "$GR_PART" > "$GR_REGS"; then GR_COPY=$_gr_oc; rm -f "$_gr_ot"; return 0; fi
        eval "_gr_why_$_gr_oc=\$GR_WHY"
    done
    rm -f "$_gr_ot" "$GR_REGS"
    # shellcheck disable=SC2154  # set by the eval above
    GR_WHY="no valid region table (primary: $_gr_why_primary; backup: $_gr_why_backup): the partition holds nothing"
    return 1
}

# gr_region NAME: GR_ROFF, GR_RSIZE of the region NAME with no flag set. 1 = none
gr_region() {
    _gr_rl=$(awk -v n="$1" '$1 == n && $4 == 0 { print $2, $3; exit }' "$GR_REGS" 2>/dev/null)
    [ -n "$_gr_rl" ] || return 1
    GR_ROFF=${_gr_rl% *} GR_RSIZE=${_gr_rl#* }
}

# gr_clear NAME: the region's first 4096 bytes zero, flushed and read back as zero:
# it holds no item. 1 = not done (GR_WHY)
gr_clear() {
    gr_region "$1" || { GR_WHY="the table has no region $1"; return 1; }
    head -c $GR_HEAD /dev/zero > "$GP_TMP/glassine-bootpart.zero.$$"
    gr_put_check "$GR_ROFF" "$GP_TMP/glassine-bootpart.zero.$$" || { rm -f "$GP_TMP/glassine-bootpart.zero.$$"; GR_WHY="$1: zeroing its head failed or didn't read back"; return 1; }
    rm -f "$GP_TMP/glassine-bootpart.zero.$$"
}

# gr_write_region NAME FILE: FILE as the region's content ("Writing a region"): the
# head zeroed (read back), the bytes from 4096 on, then the first 4096 bytes, then all
# of it read back. A content that is empty or larger than the region is refused
# before anything is written (2). 1 = a step failed (GR_WHY); the region then holds
# no item, or the new one.
gr_write_region() {
    gr_region "$1" || { GR_WHY="the table has no region $1"; return 2; }
    _gr_wn=$(wc -c < "$2")
    [ "$_gr_wn" -gt 0 ] || { GR_WHY="$2 is empty"; return 2; }
    [ "$_gr_wn" -le "$GR_RSIZE" ] || { GR_WHY="$2 is $_gr_wn bytes, the region $1 holds $GR_RSIZE: not written"; return 2; }
    _gr_wo=$GR_ROFF _gr_wt=$GP_TMP/glassine-bootpart.part.$$
    gr_clear "$1" || return 1
    if [ "$_gr_wn" -gt $GR_HEAD ]; then
        tail -c +$((GR_HEAD + 1)) "$2" > "$_gr_wt"; gr_pad "$_gr_wt"
        gr_put $((_gr_wo + GR_HEAD)) "$_gr_wt" || { rm -f "$_gr_wt"; GR_WHY="$1: writing its content failed"; return 1; }
    fi
    head -c $GR_HEAD "$2" > "$_gr_wt"; gr_pad "$_gr_wt"
    gr_put "$_gr_wo" "$_gr_wt" || { rm -f "$_gr_wt"; GR_WHY="$1: writing its head failed"; return 1; }
    rm -f "$_gr_wt"
    [ "$(gr_get "$_gr_wo" "$_gr_wn" | sha256sum | cut -d' ' -f1)" = "$(gp_sha "$2")" ] || { GR_WHY="$1: the content doesn't read back as written"; return 1; }
}

# gr_table_bytes PART OUT: the table of GR_LAYOUT for a partition of PART bytes
gr_table_bytes() {
    _gr_bn=$(echo "$GR_LAYOUT" | wc -l) _gr_be=$GP_TMP/glassine-bootpart.mkentry.$$
    {
        printf GLREGION; gr_le 4 1; gr_le 4 "$_gr_bn"; gr_le 8 "$1"; head -c 40 /dev/zero
        echo "$GR_LAYOUT" | while read -r _gr_bm _gr_bo _gr_bz; do     # no write in it
            { printf %s "$_gr_bm"; head -c $((32 - ${#_gr_bm})) /dev/zero; gr_le 8 "$_gr_bo"; gr_le 8 "$_gr_bz"; gr_le 4 0; } > "$_gr_be"
            cat "$_gr_be"; gr_le 4 $((0x$(gr_crc < "$_gr_be"))); head -c 8 /dev/zero
        done
        head -c $((4092 - 64 - 64 * _gr_bn)) /dev/zero
    } > "$2.body"
    { cat "$2.body"; gr_le 4 $((0x$(gr_crc < "$2.body"))); } > "$2"
    rm -f "$2.body" "$_gr_be"
}

# gr_loader_content IMAGE OUT: the region loader's content for IMAGE: the 4096-byte
# header (docs/handback.md, "The loader region"), then the image
gr_loader_content() {
    {
        printf GLLOADER; gr_le 4 1; gr_le 4 0; gr_le 8 "$(wc -c < "$1")"; gr_le 4 $((0x$(gr_crc < "$1")))
    } > "$2.h"
    { cat "$2.h"; gr_le 4 $((0x$(gr_crc < "$2.h"))); head -c 4064 /dev/zero; cat "$1"; } > "$2"
    rm -f "$2.h"
}

# gr_splash_ok FILE REGION: FILE is a format-2 image a reader takes (the header's
# checks in the reader's order, the payload's CRC, an uncompressed payload's length;
# the decoding itself is the reader's); leave the screen (kind 1) only as the
# override. 1 = not (GR_WHY)
gr_splash_ok() {
    _gr_sn=$(wc -c < "$1")
    [ "$_gr_sn" -ge 64 ] || { GR_WHY="shorter than its 64-byte header"; return 1; }
    [ "$(head -c 8 "$1")" = GLSPLASH ] || { GR_WHY="not a splash image (no GLSPLASH)"; return 1; }
    [ "$(head -c 52 "$1" | gr_crc)" = "$(gr_hex32 "$1" 52)" ] || { GR_WHY="its header's CRC doesn't match"; return 1; }
    [ "$(gr_u "$1" 8 2)" = 2 ] || { GR_WHY="format $(gr_u "$1" 8 2), not 2"; return 1; }
    case $(gr_u "$1" 10 2) in
    0) ;;
    1)  [ "$2" = override ] || { GR_WHY="'leave the screen' is valid only as the override"; return 1; }
        gr_zero "$1" 12 40 && [ "$_gr_sn" = 64 ] || { GR_WHY="'leave the screen' with picture fields or a payload"; return 1; }
        return 0 ;;
    *) GR_WHY="kind $(gr_u "$1" 10 2)"; return 1 ;;
    esac
    [ "$(gr_u "$1" 40 8)" = $((_gr_sn - 64)) ] || { GR_WHY="its payload length isn't the file's length less 64"; return 1; }
    _gr_sw=$(gr_u "$1" 12 4) _gr_sh=$(gr_u "$1" 16 4)
    [ "$_gr_sw" -ge 1 ] && [ "$_gr_sw" -le 16384 ] && [ "$_gr_sh" -ge 1 ] && [ "$_gr_sh" -le 16384 ] &&
        [ $((_gr_sw * _gr_sh)) -le 8388608 ] && [ "$_gr_sn" -le $((33554432 + 64)) ] || { GR_WHY="outside the limits"; return 1; }
    case $(gr_u "$1" 28 4) in 1) _gr_sp=4 ;; 2) _gr_sp=3 ;; 3) _gr_sp=1 ;; *) GR_WHY="pixel layout $(gr_u "$1" 28 4)"; return 1 ;; esac
    _gr_sc=$(gr_u "$1" 36 2)
    [ "$_gr_sc" -le 2 ] && [ "$(gr_u "$1" 38 2)" -le 1 ] || { GR_WHY="an unknown compression or filter"; return 1; }
    [ "$(tail -c +65 "$1" | gr_crc)" = "$(gr_hex32 "$1" 48)" ] || { GR_WHY="its payload's CRC doesn't match"; return 1; }
    [ "$_gr_sc" != 0 ] || [ $((_gr_sn - 64)) = $((_gr_sw * _gr_sh * _gr_sp)) ] || { GR_WHY="an uncompressed payload of the wrong length"; return 1; }
}

# gr_splash_leave OUT: the override "leave the screen" (kind 1) in OUT: the 64-byte
# header of format 2 with every picture field zero, its CRC, no payload
gr_splash_leave() {
    { printf GLSPLASH; gr_le 2 2; gr_le 2 1; head -c 40 /dev/zero; } > "$1.h"
    { cat "$1.h"; gr_le 4 $((0x$(gr_crc < "$1.h"))); head -c 8 /dev/zero; } > "$1"
    rm -f "$1.h"
}

# gp_splash_put FROM TO: an image of the splash store on FAT (docs/boot-partition.md,
# "The splash store", Writing): a TO.new left by a cut removed, FROM written as TO.new,
# synced and read back (O_DIRECT); then the old TO removed and TO.new renamed, each
# synced. A cut leaves the old image, none or the new one (and a TO.new no reader
# uses). 1 = not written (GP_WHY): TO as it was, no TO.new. Test hooks (only with
# GLASSINE_BI_TEST=1, eval'd with $1 = the file): GLASSINE_BI_AFTER_SPLASH_NEW after
# TO.new is written and before it is read back, GLASSINE_BI_AFTER_SPLASH_RM after the
# old TO is removed and before the rename.
gp_splash_put() {
    _gp_xs=$(gp_sha "$1") _gp_xz=$(wc -c < "$1")
    rm -f "$2.new"; sync
    if ! { dd if="$1" of="$2.new" bs=1M conv=fsync 2>/dev/null && gp_hook GLASSINE_BI_AFTER_SPLASH_NEW "$2.new" && sync &&
        [ "$(wc -c < "$2.new")" = "$_gp_xz" ] && [ "$(gp_read "$2.new" "$_gp_xz" | sha256sum | cut -d' ' -f1)" = "$_gp_xs" ]; }; then
        rm -f "$2.new"; sync
        GP_WHY="${2##*/}: the write or its read-back failed: the old image kept"
        return 1
    fi
    rm -f "$2" && sync && gp_hook GLASSINE_BI_AFTER_SPLASH_RM "$2" && mv -f "$2.new" "$2" && sync ||
        { GP_WHY="${2##*/}: the old image could not be replaced"; return 1; }
}

# gr_item NAME OUT: the item of a region, as its reader takes it: loader: the image
# (its header and CRC checked as a parent checks them); splash-default, splash,
# override: the image file (its length from its header, within the region; the
# file's own checks are gr_splash_ok's); probe: the report up to its check line.
# 1 = the region holds no item (GR_WHY)
gr_item() {
    gr_region "$1" || { GR_WHY="the table has no region $1"; return 1; }
    _gr_ih=$GP_TMP/glassine-bootpart.head.$$
    gr_get "$GR_ROFF" $GR_HEAD > "$_gr_ih"
    case $1 in
    loader)
        _gr_iz=$(gr_u "$_gr_ih" 16 8)
        [ "$(head -c 8 "$_gr_ih")" = GLLOADER ] && [ "$(head -c 28 "$_gr_ih" | gr_crc)" = "$(gr_hex32 "$_gr_ih" 28)" ] &&
            [ "$(gr_u "$_gr_ih" 8 4)" = 1 ] && [ "$(gr_u "$_gr_ih" 12 4)" = 0 ] &&
            [ "$_gr_iz" -ge 1 ] && [ "$_gr_iz" -le $GR_LOADER_MAX ] && [ "$_gr_iz" -le $((GR_RSIZE - GR_HEAD)) ] || { rm -f "$_gr_ih"; GR_WHY="no valid loader header"; return 1; }
        gr_get "$GR_ROFF" $((GR_HEAD + _gr_iz)) | tail -c +$((GR_HEAD + 1)) > "$2"
        [ "$(gr_crc < "$2")" = "$(gr_hex32 "$_gr_ih" 24)" ] || { rm -f "$_gr_ih" "$2"; GR_WHY="the loader image doesn't match its CRC"; return 1; }
        ;;
    splash-default|splash|override)
        _gr_iz=$(($(gr_u "$_gr_ih" 40 8) + 64))
        [ "$(head -c 8 "$_gr_ih")" = GLSPLASH ] || { rm -f "$_gr_ih"; GR_WHY="no image"; return 1; }
        [ "$_gr_iz" -ge 64 ] && [ "$_gr_iz" -le "$GR_RSIZE" ] || { rm -f "$_gr_ih"; GR_WHY="an image longer than its region"; return 1; }
        gr_get "$GR_ROFF" "$_gr_iz" > "$2"
        ;;
    probe)
        gr_get "$GR_ROFF" "$((GR_RSIZE < 65536 ? GR_RSIZE : 65536))" | tr -d '\000' | sed -n '1,/^check=/p' > "$2"
        gp_rec_ok "$2" || { rm -f "$_gr_ih" "$2"; GR_WHY="no report, or one whose check fails"; return 1; }
        ;;
    *) rm -f "$_gr_ih"; GR_WHY="no item reader for the region $1"; return 1 ;;
    esac
    rm -f "$_gr_ih"
}
