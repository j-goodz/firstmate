#!/usr/bin/env bash
# fm-backlog-overdue-lib.sh — library for scanning overdue backlog items
# Sourced by bin/fm-backlog-overdue.sh; not executed directly.
#
# Implements the overdue scan in a single POSIX awk pass. The awk program
# receives `now` (epoch seconds) and `queued_hours` via -v, computes
# days-from-civil internally (no external date calls), and emits TSV:
#   overdue_secs<TAB>id<TAB>dur<TAB>reason<TAB>title
# The caller sorts by overdue_secs desc, id asc.
#
# Overdue rules (applied to rows in ## In flight and ## Queued only):
# 1. hold-until: row has (hold-until: D) and now >= D 00:00:00Z.
#    overdue_secs = now - D_epoch. reason: "hold-until D".
# 2. due: row has (due: D) and now >= D 00:00:00Z.
#    overdue_secs = now - D_epoch. reason: "due D".
# 3. queued too long: row in ## Queued, has (since D), NO (hold ...) text,
#    NO "blocked-by:", and age = now - D_epoch > QUEUED_HOURS*3600.
#    overdue_secs = age - QUEUED_HOURS*3600.
#    reason: "queued Nd, never dispatched" where N = floor(age/86400).
# 4. pacing hold without reset: row has (hold: ...) containing "pacing"
#    (case-insensitive) and NO (hold-until:). overdue_secs = max(1, now - D_epoch)
#    using (since D) if present.
#    reason: "pacing hold has no hold-until reset date".
# 5. undated hold: row has (hold: ...), NO (hold-until:), has (since D), and
#    age = now - D_epoch > QUEUED_HOURS*3600 (whatever the hold wording).
#    overdue_secs = age - QUEUED_HOURS*3600. reason: "undated hold, re-check".
# If multiple rules match, the one with the largest overdue_secs wins.
# Pacing holds always surface (overdue_secs floor of 1).
# Future hold-until does not trigger rule 1.
#
# The library prints nothing if the backlog file is missing, empty, or
# contains no overdue items. Exit status is always 0.

set -u
export LC_ALL=C

# fm_overdue_scan <backlog-path> <now-epoch> <queued-hours>
# Runs the awk scan, sorts results, prints TSV lines (no cap).
fm_overdue_scan() {
    local backlog_path="$1"
    local now_epoch="$2"
    local queued_hours="$3"

    [[ -f "$backlog_path" && -s "$backlog_path" ]] || return 0

    # shellcheck disable=SC2016
    awk -v now="$now_epoch" -v queued_hours="$queued_hours" '
    BEGIN {
        section = ""
        row = 0
        queued_limit = queued_hours * 3600
    }

    /^## In flight$/ { section = "inflight"; next }
    /^## Queued$/    { section = "queued"; next }
    /^## Done$/      { section = "done"; next }

    /^- \[[ x]\] / && section != "done" {
        row++
        line = $0
        # Extract id and the rest after " - " using POSIX awk (no 3-arg match)
        sub(/^- \[[x ]\] /, "", line)
        if (match(line, / - /)) {
            id[row] = substr(line, 1, RSTART - 1)
            rest = substr(line, RSTART + 3)
        } else {
            next
        }

        # Defaults
        title[row] = rest
        since[row] = ""
        hold_until[row] = ""
        due[row] = ""
        hold[row] = ""
        blocked[row] = 0
        row_section[row] = section

        # Strip parenthesised metadata groups from rest, capture values
        while (match(rest, /\([^)]+\)/)) {
            meta = substr(rest, RSTART + 1, RLENGTH - 2)
            rest = substr(rest, 1, RSTART - 1) substr(rest, RSTART + RLENGTH)
            if (meta ~ /^since /) {
                since[row] = substr(meta, 7)
            } else if (meta ~ /^hold-until: /) {
                hold_until[row] = substr(meta, 13)
            } else if (meta ~ /^due: /) {
                due[row] = substr(meta, 6)
            } else if (meta ~ /^hold: /) {
                hold[row] = substr(meta, 7)
            } else if (meta ~ /^blocked-by:/) {
                blocked[row] = 1
            }
        }
        # Clean title: trim trailing spaces, replace tabs, truncate to 80
        gsub(/ *$/, "", rest)
        gsub(/\t/, " ", rest)
        if (length(rest) > 80) rest = substr(rest, 1, 80)
        title[row] = rest
    }

    END {
        for (i = 1; i <= row; i++) {
            max_overdue = 0
            best_reason = ""

            # Rule 1: hold-until
            if (hold_until[i] != "") {
                d = parse_date(hold_until[i])
                if (d >= 0) {
                    h_epoch = d * 86400
                    if (now >= h_epoch) {
                        overdue = now - h_epoch
                        if (overdue > max_overdue) {
                            max_overdue = overdue
                            best_reason = "hold-until " hold_until[i]
                        }
                    }
                }
            }

            # Rule 2: due
            if (due[i] != "") {
                d = parse_date(due[i])
                if (d >= 0) {
                    d_epoch = d * 86400
                    if (now >= d_epoch) {
                        overdue = now - d_epoch
                        if (overdue > max_overdue) {
                            max_overdue = overdue
                            best_reason = "due " due[i]
                        }
                    }
                }
            }

            # Rule 3: queued too long
            if (row_section[i] == "queued" && since[i] != "" && hold[i] == "" && !blocked[i]) {
                d = parse_date(since[i])
                if (d >= 0) {
                    s_epoch = d * 86400
                    age = now - s_epoch
                    if (age > queued_limit) {
                        overdue = age - queued_limit
                        if (overdue > max_overdue) {
                            max_overdue = overdue
                            days = int(age / 86400)
                            best_reason = "queued " days "d, never dispatched"
                        }
                    }
                }
            }

            # Rule 4: pacing hold without hold-until (case-insensitive without tolower)
            if (hold[i] != "" && hold_until[i] == "" && hold[i] ~ /[Pp][Aa][Cc][Ii][Nn][Gg]/) {
                overdue = 1
                if (since[i] != "") {
                    d = parse_date(since[i])
                    if (d >= 0) {
                        s_epoch = d * 86400
                        overdue = now - s_epoch
                        if (overdue < 1) overdue = 1
                    }
                }
                if (overdue > max_overdue) {
                    max_overdue = overdue
                    best_reason = "pacing hold has no hold-until reset date"
                }
            }

            # Rule 5: undated hold older than the queue limit
            if (hold[i] != "" && hold_until[i] == "" && since[i] != "") {
                d = parse_date(since[i])
                if (d >= 0) {
                    age = now - d * 86400
                    if (age > queued_limit) {
                        overdue = age - queued_limit
                        if (overdue > max_overdue) {
                            max_overdue = overdue
                            best_reason = "undated hold, re-check"
                        }
                    }
                }
            }

            if (max_overdue > 0) {
                if (max_overdue >= 86400) {
                    dur = int(max_overdue / 86400) "d"
                } else {
                    dur = "<1d"
                }
                print max_overdue "\t" id[i] "\t" dur "\t" best_reason "\t" title[i]
            }
        }
    }

    function parse_date(s,    y, m, d) {
        if (s !~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/) return -1
        y = substr(s, 1, 4) + 0
        m = substr(s, 6, 2) + 0
        d = substr(s, 9, 2) + 0
        return days_from_civil(y, m, d)
    }

    function days_from_civil(y, m, d,    era, yoe, mp, doy, doe) {
        if (m <= 2) y -= 1
        era = int(y / 400)
        yoe = y - era * 400
        if (m > 2) mp = m - 3; else mp = m + 9
        doy = int((153 * mp + 2) / 5) + d - 1
        doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
        return era * 146097 + doe - 719468
    }
    ' "$backlog_path" | sort -t "$(printf '\t')" -k1,1nr -k2,2
}

# fm_overdue_item_line <id> <title> <dur> <reason>
# Prints a single formatted item line: "<id> - <title>: <dur> overdue (<reason>)"
fm_overdue_item_line() {
    local id="$1"
    local title="$2"
    local dur="$3"
    local reason="$4"
    printf '%s - %s: %s overdue (%s)\n' "$id" "$title" "$dur" "$reason"
}
