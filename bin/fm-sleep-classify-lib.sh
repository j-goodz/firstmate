#!/usr/bin/env bash
# fm_sleep_classify_lib.sh - Single owner of the sleep-poll classification used by bin/fm-sleep-pretool-check.sh
#
# This library defines the function fm_sleep_classify which classifies a command string
# according to the sleep-poll and sleep-too-long rules. It sets the global variables
# CODE and SLEEP_SECONDS and always returns 0.

# shellcheck disable=SC2034 # CODE and SLEEP_SECONDS are the function's outputs, read by the sourcing script
function fm_sleep_classify {
    local cmd="$1"
    CODE=""
    SLEEP_SECONDS="null"

    # Only a segment whose first word is exactly "sleep" can be flagged, so a
    # command with no "sleep" text anywhere needs no segmenting (no process).
    [[ "$cmd" == *sleep* ]] || return 0

    local seen_until_or_while=false
    local IFS=$' \t\n'   # ensure word splitting uses default IFS for reads

    # Split the command into simple segments at ; & | ( { and newline.
    # Existing newlines are kept because they are not in the set.
    while IFS= read -r seg || [[ -n $seg ]]; do
        # Strip leading whitespace and then repeatedly strip a leading word (do, then, else, !) followed by whitespace
        local start=0
        local len=${#seg}
        # Strip leading whitespace
        while (( start < len )) && [[ ${seg:start:1} == [[:space:]] ]]; do
            start=$((start+1))
        done
        # Now strip zero or more occurrences of (keyword followed by one or more whitespace)
        while (( start < len )); do
            if [[ ${seg:start} =~ ^(do|then|else|!)[[:space:]]+ ]]; then
                local match=${BASH_REMATCH[0]}
                start=$((start + ${#match}))
            else
                break
            fi
        done
        seg="${seg:start}"

        # Track until/while as first word after the strip above
        local first_word="${seg%% *}"
        if [[ "$first_word" == "until" || "$first_word" == "while" ]]; then
            seen_until_or_while=true
        fi

        # Truncate segment at first ), } or #
        local truncated=""
        local cut=0
        for (( i=0; i<${#seg}; i++ )); do
            local c="${seg:i:1}"
            case "$c" in
                ')'|'}'|'#')
                    truncated="${seg:0:i}"
                    cut=1
                    break
                    ;;
            esac
        done
        # If a terminator was found, use the truncated segment; otherwise keep the whole segment
        if (( cut )); then seg="$truncated"; fi

        # Skip empty segments
        [[ -z "$seg" ]] && continue

        # Determine if this segment is a sleep command
        first_word="${seg%% *}"
        local rest=""
        [[ "$seg" == *" "* ]] && rest="${seg#* }"
        if [[ "$first_word" != "sleep" ]]; then
            continue
        fi

        # Prepare arguments array
        local -a args=()
        if [[ -n "$rest" ]]; then
            # Split on whitespace (default IFS)
            read -r -a args <<< "$rest"
        fi

        # Compute duration or judgeability using awk
        local total
        if (( ${#args[@]} == 0 )); then
            total="0"
        else
            total=$(printf '%s\n' "${args[@]}" | awk '
                function conv(s) {
                    if (s ~ /^[0-9]+(\.[0-9]+)?[smhd]?$/) {
                        if (s ~ /[smhd]$/) {
                            val = substr(s,1,length(s)-1)
                            suf = substr(s,length(s),1)
                        } else {
                            val = s
                            suf = ""
                        }
                        if (suf == "" || suf == "s") return val*1
                        if (suf == "m") return val*60
                        if (suf == "h") return val*3600
                        if (suf == "d") return val*86400
                        return val   # default seconds
                    } else {
                        badarg = 1
                        return 0
                    }
                }
                BEGIN { sum=0; inf=0; bad=0 }
                {
                    if ($0 == "infinity") { inf=1 }
                    else {
                        badarg = 0
                        v = conv($0)
                        if (badarg) { bad=1 }
                        else { sum += v }
                    }
                }
                END {
                    if (inf) { print "null" }
                    else if (bad) { print "unjudgeable" }
                    else { print sum }
                }')
        fi

        # Loop rule takes precedence over too-long rule
        if $seen_until_or_while; then
            CODE="sleep-poll-loop"
            if [[ "$total" == "null" || "$total" == "unjudgeable" ]]; then
                SLEEP_SECONDS="null"
            else
                SLEEP_SECONDS="$total"
            fi
            return 0
        fi

        # Too-long rule: first judged sleep with total > 30 (or infinity)
        if [[ "$total" != "unjudgeable" ]]; then
            if [[ "$total" == "null" ]]; then
                CODE="sleep-too-long"
                SLEEP_SECONDS="null"
                return 0
            else
                # Compare numeric total > 30 using awk
                if awk -v t="$total" 'BEGIN { exit !(t > 30) }'; then
                    CODE="sleep-too-long"
                    SLEEP_SECONDS="$total"
                    return 0
                fi
            fi
        fi
    done < <(printf '%s' "$cmd" | tr ';&|({' '\n')

    # If we reach here, no denying condition was found; CODE remains empty and SLEEP_SECONDS null.
    return 0
}