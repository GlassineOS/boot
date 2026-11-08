# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-device.sh: device data (docs/kernel-artifacts.md, "Device data"): the
# list a device ships, the seed on its DEVICE_PART, and the initramfs's step.
# Sourced by glassine-device-seed and by the boot initramfs. busybox ash only.
#
# The list (/usr/share/glassine/device-data.list in the root, format=1): the
# first line "format=1", then one entry per line, "NAME SOURCE [CHECK]"; "#"
# starts a comment. NAME: the path in the seed (relative, no "."/".." parts or
# hidden parts, not "manifest"); NAME.* with a SOURCE ending in .*: a split
# image (a .mdt and its numbered parts .b00, .b01, ...). SOURCE: PART:/PATH.
# CHECK: wbf (a waveform header), none when left out.
#
# The seed: glassine/ on DEVICE_PART (ext4): "manifest" (format=1, then one line
# per file: NAME SOURCE SHA256) and the files. A line whose file is missing
# isn't held, but its sha256 stays recorded (a changed source is taken only on
# an explicit refresh). The seed may be bound when every file it holds
# verifies and it holds no file the manifest doesn't name (gd_verify).

GD_LIST_FORMAT=1
GD_MANIFEST_FORMAT=1
gd_log() { echo "glassine-device: $*" >&2; }

# gd_sha FILE: its sha256
gd_sha() { sha256sum < "$1" | cut -d' ' -f1; }

# gd_list FILE DEVICE_PART: the entries, one per line "NAME SOURCE CHECK".
# 0 = entries printed; 1 = no file, or no entries (no device data); 2 = an
# invalid list (said with gd_log; nothing is seeded from it); 3 = a format
# newer than this code.
gd_list() {
    [ -r "$1" ] || return 1
    _gd_f=$(head -n 1 "$1")
    case $_gd_f in
    "format=$GD_LIST_FORMAT") ;;
    format=*) _gd_v=${_gd_f#format=}
        case $_gd_v in ''|*[!0-9]*) gd_log "$1: bad first line '$_gd_f'"; return 2 ;; esac
        [ "$_gd_v" -gt "$GD_LIST_FORMAT" ] && { gd_log "$1: format $_gd_v is newer than this tool ($GD_LIST_FORMAT)"; return 3; }
        gd_log "$1: unknown format $_gd_v"; return 2 ;;
    *) gd_log "$1: the first line is not format=$GD_LIST_FORMAT"; return 2 ;;
    esac
    _gd_out=$(tail -n +2 "$1" | sed 's/#.*//' | awk -v dp="$2" '
        function bad(m) { if (!err) print "BAD " NR + 1 ": " m; err = 1; exit }
        NF == 0 { next }
        NF > 3 { bad("more than NAME SOURCE CHECK") }
        NF < 2 { bad("a name and a source are needed") }
        {
            n = $1; s = $2; c = (NF == 3 ? $3 : "none")
            if (n ~ /^\// || n ~ /\/$/ || n ~ /\/\//) bad("name " n ": not a relative path")
            k = split(n, p, "/")
            for (i = 1; i <= k; i++) if (p[i] ~ /^\./) bad("name " n ": a . or .. or hidden part")
            if (n == "manifest") bad("name manifest is the seed'"'"'s own")
            if (n !~ /^[A-Za-z0-9._\/+@-]+(\.\*)?$/ || n ~ /\*./) bad("name " n ": bad characters")
            if (s !~ /^[A-Za-z0-9._+-]+:\//) bad("source " s ": not PART:/PATH")
            part = s; sub(/:.*/, "", part); path = s; sub(/^[^:]*:/, "", path)
            if (path ~ /(^|\/)\.\.?(\/|$)/ || path ~ /\/\//) bad("source " s ": . or .. in the path")
            if (path !~ /^[A-Za-z0-9._\/+@-]+(\.\*)?$/ || path ~ /\*./) bad("source " s ": bad characters")
            if ((n ~ /\.\*$/) != (path ~ /\.\*$/)) bad(n ": a split image pattern needs NAME.* and PATH.*")
            if (dp != "" && part == dp) bad(n ": its source is on DEVICE_PART (" dp "), where the seed lives")
            if (c !~ /^[a-z0-9]+$/) bad(n ": bad check " c)
            if (n in seen) bad("name " n " twice")
            seen[n] = 1
            out[++k2] = n " " s " " c
        }
        END { if (!err) for (i = 1; i <= k2; i++) print out[i] }') || return 2
    case $_gd_out in
    BAD*) gd_log "$1: line ${_gd_out#BAD }"; return 2 ;;
    '') return 1 ;;
    esac
    printf '%s\n' "$_gd_out"
}

# gd_part_dev NAME: /dev/<node> of the GPT partition NAME, from sysfs (no udev
# links this early); GD_SYS_BLOCK stands in for /sys/class/block in tests
gd_part_dev() {
    for _gd_u in "${GD_SYS_BLOCK:-/sys/class/block}"/*/uevent; do
        grep -qx "PARTNAME=$1" "$_gd_u" 2>/dev/null || continue
        echo "/dev/$(sed -n 's/^DEVNAME=//p' "$_gd_u")"
        return 0
    done
    return 1
}

# gd_mounted_rw DEV [MOUNTS]: DEV is mounted read-write somewhere (MOUNTS:
# /proc/mounts); devices compared by number, whatever node a mount names
gd_mounted_rw() {
    _gd_w=$(stat -L -c %t:%T "$1" 2>/dev/null) || return 1
    while read -r _gd_s _gd_mp _gd_t _gd_o _gd_r; do
        case $_gd_s in /dev/*) ;; *) continue ;; esac
        case ,$_gd_o, in *,rw,*) ;; *) continue ;; esac
        [ "$(stat -L -c %t:%T "$_gd_s" 2>/dev/null)" = "$_gd_w" ] && return 0
    done < "${2:-/proc/mounts}"
    return 1
}

# gd_has_entries FILE: the list exists and names at least one file (a quick
# look: whether the device has device data at all; validity is gd_list's)
gd_has_entries() {
    [ -r "$1" ] || return 1
    tail -n +2 "$1" | sed 's/#.*//' | grep -q '[^[:space:]]'
}

# gd_verify DIR: DIR (a seed's glassine/) may be bound: its manifest is
# format=1, every file a line names that is there matches its sha256, and
# there is no other file (no temp file of a cut-off write, nothing unverified)
gd_verify() {
    [ "$(head -n 1 "$1/manifest" 2>/dev/null)" = "format=$GD_MANIFEST_FORMAT" ] || return 1
    _gd_names=$(tail -n +2 "$1/manifest" | while read -r _gd_n _gd_s _gd_h; do
            [ -n "$_gd_n" ] || continue
            if [ -e "$1/$_gd_n" ] || [ -L "$1/$_gd_n" ]; then
                [ -f "$1/$_gd_n" ] && [ ! -L "$1/$_gd_n" ] && [ "$(gd_sha "$1/$_gd_n")" = "$_gd_h" ] || { echo "/BAD"; exit 1; }
            fi
            echo "$_gd_n"
        done) || return 1
    # every non-directory under DIR is the manifest or a file it names
    (cd "$1" && find . ! -type d) | while read -r _gd_p; do
        _gd_p=${_gd_p#./}
        [ "$_gd_p" = manifest ] && continue
        printf '%s\n' "$_gd_names" | grep -Fxq -- "$_gd_p" || exit 1
    done
}

# gd_held DIR NAME SOURCE: the seed holds NAME from SOURCE: its line, and the
# file there, matching
gd_held() {
    _gd_l=$(awk -v n="$2" 'NR > 1 && $1 == n { print; exit }' "$1/manifest" 2>/dev/null)
    [ -n "$_gd_l" ] || return 1
    set -- "$1" $_gd_l "$3"
    [ "$3" = "$5" ] && [ -f "$1/$2" ] && [ ! -L "$1/$2" ] && [ "$(gd_sha "$1/$2")" = "$4" ]
}

# gd_parts DIR NAMESTEM SOURCESTEM: the lines of a split image in the manifest:
# NAMESTEM.mdt and NAMESTEM.bNN, as "NAME SOURCE SHA256"
gd_parts() {
    awk -v n="$2" -v s="$3" 'NR > 1 {
        if ($1 == n ".mdt" && $2 == s ".mdt") print
        else if (index($1, n ".b") == 1 && substr($1, length(n) + 3) ~ /^[0-9]+$/ && $2 == s substr($1, length(n) + 1)) print
    }' "$1/manifest" 2>/dev/null
}

# gd_contiguous: the part numbers on stdin (one per line) run 0, 1, ... with no gap
gd_contiguous() { sort -n | awk '$1 + 0 != NR - 1 { exit 1 }'; }

# gd_held_split DIR NAME SOURCE: the seed holds the split image NAME.* from
# SOURCE.*: its .mdt and parts .b00 up to the last one with no gap, all there
# and matching (decided from the manifest alone: no source is read)
gd_held_split() {
    _gd_n=${2%.\*} _gd_s=${3%.\*}
    _gd_ls=$(gd_parts "$1" "$_gd_n" "$_gd_s")
    printf '%s\n' "$_gd_ls" | grep -q "^$_gd_n\.mdt " || return 1
    printf '%s\n' "$_gd_ls" | awk -v n="$_gd_n" '$1 != n ".mdt" { print substr($1, length(n) + 3) }' | gd_contiguous || return 1
    printf '%s\n' "$_gd_ls" | while read -r _gd_a _gd_b _gd_c; do
        [ -f "$1/$_gd_a" ] && [ ! -L "$1/$_gd_a" ] && [ "$(gd_sha "$1/$_gd_a")" = "$_gd_c" ] || exit 1
    done
}

# gd_complete DIR ENTRIES: every entry ("NAME SOURCE CHECK" lines) is held
gd_complete() {
    gd_verify "$1" || return 1
    printf '%s\n' "$2" | while read -r _gd_n _gd_s _gd_c; do
        [ -n "$_gd_n" ] || continue
        case $_gd_n in
        *.\*) gd_held_split "$1" "$_gd_n" "$_gd_s" || exit 1 ;;
        *) gd_held "$1" "$_gd_n" "$_gd_s" || exit 1 ;;
        esac
    done
}

# gd_fw_path SEEDDIR CMDLINE PARAM: the kernel searches SEEDDIR/firmware first:
# its path written to the firmware loader's parameter, with no newline (the
# kernel keeps the value verbatim), unless the command line sets
# firmware_class.path itself or the seed has no firmware/. SEEDDIR as the
# booted system sees it (/run/glassine/device). 0 = set or not needed.
gd_fw_path() {
    [ -d "$1/firmware" ] || return 0
    grep -q 'firmware_class\.path=' "$2" 2>/dev/null && return 0
    printf '%s' "${4:-$1}/firmware" > "$3"
}

# gd_boot ROOT DEV CMDLINE PARAM: the initramfs's step, after gr_carry (ROOT/run
# is the new root's tmpfs). Only called with a list that names files (FR-002).
# DEV: DEVICE_PART's node. Its journal needing recovery, no seed, or a seed
# that doesn't verify: nothing is bound (the seed service fills and binds it).
# Otherwise DEV ro,noload on ROOT/run/glassine/device-part, its glassine/ bound
# read-only on ROOT/run/glassine/device, and the firmware path set.
gd_boot() {
    _gd_m=$1/run/glassine/device-part _gd_d=$1/run/glassine/device
    if ! dumpe2fs -h "$2" > /tmp/gd.dumpe2fs 2>/dev/null; then
        gd_log "$2 is not an ext4 file system: nothing bound"; return 0
    fi
    if grep -q '^Filesystem features:.*needs_recovery' /tmp/gd.dumpe2fs; then
        gd_log "the journal of $2 needs recovery: nothing bound (the seed service replays it)"; return 0
    fi
    debugfs -R 'stat /glassine/manifest' "$2" 2>/dev/null | grep -q '^Inode:' ||
        { gd_log "no seed on $2 yet (the seed service makes it)"; return 0; }
    mkdir -p "$_gd_m" "$_gd_d" && mount -t ext4 -o ro,noload "$2" "$_gd_m" ||
        { gd_log "cannot mount $2 read-only: nothing bound"; return 0; }
    if ! gd_verify "$_gd_m/glassine"; then
        umount "$_gd_m"
        gd_log "the seed on $2 doesn't verify: nothing bound (the seed service repairs it)"; return 0
    fi
    if ! { mount --bind "$_gd_m/glassine" "$_gd_d" && mount -o remount,bind,ro "$_gd_d"; }; then
        umount "$_gd_d" 2>/dev/null; umount "$_gd_m"
        gd_log "cannot bind the seed: nothing bound"; return 0
    fi
    if gd_fw_path "$_gd_d" "$3" "$4" /run/glassine/device; then
        gd_log "seed bound on /run/glassine/device$([ -d "$_gd_d/firmware" ] && echo ', firmware path set')"
    else gd_log "seed bound on /run/glassine/device; the firmware path could not be set"; fi
}
