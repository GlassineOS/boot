# SPDX-License-Identifier: GPL-2.0-or-later
# glassine-accounts.sh: the account merge of a switch (busybox sh + awk).
#
#   ga_merge OLD NEW OUT MAP   merge the accounts of OLD (the deployment carried
#                              from) and NEW (the new deployment's lower /etc)
#                              into OUT/{passwd,group,shadow,subuid,subgid};
#                              MAP gets "u OLD NEW" / "g OLD NEW" lines for every
#                              ID that moved (by name). Report lines on stdout.
#   ga_remap MAP DIR           chown every file under DIR owned by a moved ID
#
# Kept from OLD: users and groups with an ID in [1000, 65534) that NEW lacks (their
# ID when free, else the next free one from 1000), every password (shadow, by
# name), the group memberships of users that exist afterwards, subuid/subgid
# ranges. Everything else comes from NEW. OUT may hold a carried copy of the
# files; it is replaced. Missing files count as empty; NEW needs passwd.

GA_FIRST=1000 GA_NOBODY=65534

# _ga_f FILE: FILE, or /dev/null when it is missing
_ga_f() { if [ -r "$1" ]; then echo "$1"; else echo /dev/null; fi; }

# _ga_put TMP DEST MODE OWNER: move a finished file into place
_ga_put() { chmod "$3" "$1" && chown "$4" "$1" && mv -f "$1" "$2"; }

ga_merge() {
    _go=$1 _gn=$2 _gt=$3 _gm=$4
    [ -r "$_gn/passwd" ] || { echo "ga_merge: $_gn has no passwd" >&2; return 1; }
    _op=$(_ga_f "$_go/passwd") _og=$(_ga_f "$_go/group") _os=$(_ga_f "$_go/shadow")
    _ns=$(_ga_f "$_gn/shadow") _ng=$(_ga_f "$_gn/group")
    mkdir -p "$_gt" || return 1
    # groups: NEW's, plus OLD's user groups NEW lacks
    awk -F: -v OFS=: -v first=$GA_FIRST -v nobody=$GA_NOBODY '
        /^#/ || /^$/ { next }
        f == 1 { n++; row[n] = $0; have[$1] = 1; used[$3 + 0] = 1; next }
        f == 2 && $3 + 0 >= first && $3 + 0 < nobody && !($1 in have) {
            id = $3 + 0
            if (id in used) { id = first; while (id in used) id++ }
            used[id] = 1; was = $3; $3 = id; have[$1] = 1; n++; row[n] = $0
            print "  group " $1 " kept (gid " id (id == was ? "" : ", was " was) ")" > "/dev/stderr"
        }
        END { for (i = 1; i <= n; i++) print row[i] }' f=1 "$_ng" f=2 "$_og" > "$_gt/group.ga" 2> "$_gt/report.ga" || return 1
    # users: NEW's, plus OLD's users NEW lacks; their primary group by name
    awk -F: -v OFS=: -v first=$GA_FIRST -v nobody=$GA_NOBODY '
        /^#/ || /^$/ { next }
        f == 1 { mg[$1] = $3; next }
        f == 2 { og[$3] = $1; next }
        f == 3 { n++; row[n] = $0; have[$1] = 1; used[$3 + 0] = 1; next }
        f == 4 && $3 + 0 >= first && $3 + 0 < nobody && !($1 in have) {
            id = $3 + 0
            if (id in used) { id = first; while (id in used) id++ }
            used[id] = 1; was = $3; $3 = id
            if (($4 in og) && (og[$4] in mg)) $4 = mg[og[$4]]
            have[$1] = 1; n++; row[n] = $0
            print "  user " $1 " kept (uid " id (id == was ? "" : ", was " was) ")" > "/dev/stderr"
        }
        END { for (i = 1; i <= n; i++) print row[i] }' f=1 "$_gt/group.ga" f=2 "$_og" f=3 "$_gn/passwd" f=4 "$_op" > "$_gt/passwd.ga" 2>> "$_gt/report.ga" || return 1
    # memberships: OLD's members of a group that exists afterwards, if a user exists
    awk -F: -v OFS=: '
        /^#/ || /^$/ { next }
        f == 1 { u[$1] = 1; next }
        f == 2 { om[$1] = $4; next }
        f == 3 {
            if (NF < 4) $4 = ""
            if ($1 in om) {
                split("", have); cur = $4; added = ""
                k = split(cur, c, ","); for (i = 1; i <= k; i++) have[c[i]] = 1
                k = split(om[$1], a, ",")
                for (i = 1; i <= k; i++) if (a[i] != "" && (a[i] in u) && !(a[i] in have)) {
                    have[a[i]] = 1; cur = (cur == "" ? a[i] : cur "," a[i]); added = added " " a[i]
                }
                $4 = cur
                if (added != "") print "  group " $1 ": members" added " carried" > "/dev/stderr"
            }
            print
        }' f=1 "$_gt/passwd.ga" f=2 "$_og" f=3 "$_gt/group.ga" > "$_gt/group.ga2" 2>> "$_gt/report.ga" || return 1
    mv -f "$_gt/group.ga2" "$_gt/group.ga"
    # lost: OLD accounts with no row afterwards (system accounts NEW has no package for)
    _lost=$(awk -F: '/^#/ || /^$/ { next } f == 1 { h[t ":" $1] = 1; next } f == 2 && !((t ":" $1) in h) { printf " %s", $1 }' \
        t=u f=1 "$_gt/passwd.ga" f=2 "$_op" t=g f=1 "$_gt/group.ga" f=2 "$_og")
    [ -n "$_lost" ] && echo "  not carried (accounts the new base has no package for):$_lost" >> "$_gt/report.ga"
    # shadow: OLD's row by name, else NEW's, else a locked one
    awk -F: -v OFS=: '
        /^#/ || /^$/ { next }
        f == 1 { o[$1] = $0; next }
        f == 2 { n[$1] = $0; next }
        f == 3 {
            if ($1 in o) { print o[$1]; old++ } else if ($1 in n) print n[$1]
            else print $1 ":!::0:::::"
        }
        END { print "  passwords: " old + 0 " from the old deployment" > "/dev/stderr" }' \
        f=1 "$_os" f=2 "$_ns" f=3 "$_gt/passwd.ga" > "$_gt/shadow.ga" 2>> "$_gt/report.ga" || return 1
    # the ID map: OLD's IDs whose name has another ID afterwards
    awk -F: '
        /^#/ || /^$/ { next }
        f == 1 { nu[$1] = $3; next }
        f == 2 { ng[$1] = $3; next }
        f == 3 && ($1 in nu) && nu[$1] != $3 { print "u " $3 " " nu[$1] }
        f == 4 && ($1 in ng) && ng[$1] != $3 { print "g " $3 " " ng[$1] }' \
        f=1 "$_gt/passwd.ga" f=2 "$_gt/group.ga" f=3 "$_op" f=4 "$_og" | sort -u > "$_gm" || return 1
    # sub-ID ranges: NEW's, plus OLD's for names NEW has none for
    for _x in subuid subgid; do
        rm -f "$_gt/$_x"
        [ -s "$_go/$_x" ] || [ -s "$_gn/$_x" ] || continue
        awk -F: '/^#/ || /^$/ { next } f == 1 { h[$1] = 1; print; next } f == 2 && !($1 in h)' \
            f=1 "$(_ga_f "$_gn/$_x")" f=2 "$(_ga_f "$_go/$_x")" > "$_gt/$_x.ga" &&
            _ga_put "$_gt/$_x.ga" "$_gt/$_x" 644 0:0 || return 1
    done
    # shadow keeps NEW's owner and mode (root:shadow 0640 on Alpine)
    _so="0:0 600"; [ -e "$_gn/shadow" ] && _so=$(stat -c '%u:%g %a' "$_gn/shadow")
    _ga_put "$_gt/passwd.ga" "$_gt/passwd" 644 0:0 &&
        _ga_put "$_gt/group.ga" "$_gt/group" 644 0:0 &&
        _ga_put "$_gt/shadow.ga" "$_gt/shadow" "${_so#* }" "${_so% *}" || return 1
    cat "$_gt/report.ga"; rm -f "$_gt/report.ga"
    while read -r _k _a _b; do
        [ "$_k" = u ] && echo "  uid $_a -> $_b" || echo "  gid $_a -> $_b"
    done < "$_gm"
}

# ga_remap MAP DIR: owners by the map (one pass: swapped IDs stay right); a
# chown clears setuid/setgid, so the mode is set again. Prints the count.
ga_remap() {
    [ -s "$1" ] || { echo "  owners remapped: 0"; return 0; }
    _gr=0
    find "$2" -exec stat -c '%u %g %a %F|%n' {} + |
    awk -v map="$1" '
        BEGIN { while ((getline l < map) > 0) { split(l, a, " "); if (a[1] == "u") um[a[2]] = a[3]; else gm[a[2]] = a[3] } }
        {
            u = $1; g = $2; m = $3; p = index($0, "|"); name = substr($0, p + 1)
            link = (substr($0, 1, p - 1) ~ /symbolic link/)
            nu = (u in um) ? um[u] : u; ng = (g in gm) ? gm[g] : g
            if (nu != u || ng != g) print nu ":" ng " " (link ? "-" : m) " " name
        }' > "$1.todo" || return 1
    while read -r _own _mode _p; do
        chown -h "$_own" "$_p" || return 1
        [ "$_mode" = - ] || chmod "$_mode" "$_p" || return 1
        _gr=$((_gr + 1))
    done < "$1.todo"
    rm -f "$1.todo"
    echo "  owners remapped: $_gr"
}
