# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-bootpart.sh: the boot partition of a UEFI PC (docs/boot-partition.md,
# format 1): its records, the loader record's two slots, a kernel set's files.
# Sourced by glassine-bootimg (lib/glassine-kernel.sh, HANDOFF=uefi) and
# glassine-loader-mark. busybox ash, sed, awk, od and sha256sum only: the recovery
# runs it too (004 FR-016). Every function but gp_open/gp_close (the end of this
# file: where a hand-off keeps its record, mounted for one command, 010 FR-026)
# works on a directory that is the boot partition's top level.
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
    if gp_nul "$1"; then return 2; fi
    [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' ')" = 0a ] || return 1
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

gp_clean() { rm -f "$GP_TMP"/glassine-bootpart.*."$$"; }

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

# --- where the record is: the hand-off's backend ----------------------------------
# Everything above works on a directory holding glassine/loader.a and loader.b. A
# hand-off whose loader keeps a record names where that directory comes from:
#   uefi   the boot partition (boot-partition.md), the FAT partition named BOOT_PART
#          on the disk of the system partition this boot names, mounted for the write
# No other hand-off keeps a loader record yet (Note Air's hand-back partition,
# specs/012, is a raw partition: its backend is not built).

# gp_has_record HANDOFF: 0 when that hand-off's loader keeps a loader record
gp_has_record() { case $1 in uefi) return 0 ;; esac; return 1; }

# gp_open HANDOFF CMDLINE BOOTPART MNT [ro]: the loader record's directory opened;
# GP_DIR its top level, GP_MNTD set when gp_open mounted it (at MNT). 1 = not
# opened (GP_WHY). GLASSINE_BI_BOOTPART_DIR (tests) is the directory, unmounted.
gp_open() {
    GP_DIR='' GP_MNTD=''
    gp_has_record "$1" || { GP_WHY="the hand-off '$1' keeps no loader record"; return 1; }
    if [ -n "${GLASSINE_BI_BOOTPART_DIR:-}" ]; then GP_DIR=$GLASSINE_BI_BOOTPART_DIR; return 0; fi
    _gp_od=$(gp_boot_dev "$2" "$3") || { GP_WHY="the boot partition: $_gp_od"; return 1; }
    mkdir -p "$4" || { GP_WHY="cannot create $4"; return 1; }
    ! mountpoint -q "$4" || { GP_WHY="$4 is mounted already: another writer?"; return 1; }
    mount -t vfat -o "${5:-rw},noatime" "$_gp_od" "$4" || { GP_WHY="cannot mount the boot partition $_gp_od"; return 1; }
    GP_DIR=$4 GP_MNTD=1
}

# gp_close: what gp_open mounted, synced and unmounted. 1 = not unmounted (GP_WHY)
gp_close() {
    [ -n "${GP_MNTD:-}" ] || return 0
    sync
    umount "$GP_DIR" || { GP_WHY="cannot unmount the boot partition at $GP_DIR"; return 1; }
    GP_DIR='' GP_MNTD=''
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
