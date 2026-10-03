#!/usr/bin/env bash
# Live CLI drive of bin/fm-account-pick.sh with throwaway fixture stores (no real credentials).
set -u
L=$1; P=$2
ts() { TZ=America/Toronto date -d "$1" +%s; }
mkdir -p $L/a1 $L/a2 $L/a3
cred='{"claudeAiOauth":{"refreshToken":"fake","refreshTokenExpiresAt":null}}'
for a in a1 a2 a3; do echo "$cred" > $L/$a/.credentials.json; done
snap() { # now 1pct 1weekly 2pct 2weekly fetched
  cat > $L/snap.json <<J
{"accounts":{
 "account-1":{"five_hour_pct":$2,"weekly_pct":$3,"weekly_resets_at":$(( $1 + 86400 )),"fetched_at":$6,"outcome":"ok"},
 "account-2":{"five_hour_pct":$4,"weekly_pct":$5,"weekly_resets_at":$(( $1 + 5*86400 )),"fetched_at":$6,"outcome":"ok"},
 "account-3":{"five_hour_pct":10,"weekly_pct":20,"weekly_resets_at":$(( $1 + 6*86400 )),"fetched_at":$6,"outcome":"ok"}}}
J
}
cfg() { { echo "snapshot $L/snap.json"; echo "account account-1 $L/a1"; echo "account account-2 $L/a2"; [ "${1:-}" = 3 ] && echo "account account-3 $L/a3"; echo "reserve account-1 03:00 08:00"; echo "reserve-file $L/reserve"; } > $L/cfg; }
run() { # title now current
  echo "=== $1"; echo "    clock: $(TZ=America/Toronto date -d @$2 '+%a %F %H:%M %Z')  --current ${3:-<empty>}"
  FM_ACCOUNT_PICK_NOW=$2 $P --config $L/cfg --log $L/picks.jsonl --task "t-$(echo $1|cut -c1-3)" --current "${3:-}" 2>$L/err; rc=$?
  sed 's/^/    stderr: /' $L/err; echo "    exit=$rc"
}
rm -f $L/reserve $L/picks.jsonl; cfg
N=$(ts '2026-10-06 04:00'); snap $N 5 40 5 40 $N
run "S1 Tue 04:00 ET, account-1 has best score but window reserves it" $N $L/a1
N=$(ts '2026-10-06 08:00'); snap $N 5 40 5 40 $N
run "S2 Tue 08:00 ET, window ended: account-1 back in rotation" $N $L/a1
N=$(ts '2026-10-06 02:59'); snap $N 5 40 5 40 $N
run "S2b Tue 02:59 ET, just before window: account-1 picked" $N $L/a1
N=$(ts '2026-10-10 04:00'); snap $N 5 40 5 40 $N
run "S3 Sat 04:00 ET, weekday-only window does not apply" $N $L/a1
N=$(ts '2026-10-06 12:00'); snap $N 5 40 5 40 $N
echo "1 $(( N + 3600 ))" > $L/reserve
run "S4 Tue 12:00 ET, ~/.nexus/account-reserve style line '1 <now+1h>'" $N $L/a1
echo "1 $(( N - 60 ))" > $L/reserve
run "S4b same, reserve epoch already past: account-1 back" $N $L/a1
printf 'garbage line here\n1 notanumber\n' > $L/reserve
run "S4c malformed reserve-file lines: warned, reserve nothing" $N $L/a1
rm -f $L/reserve
N=$(ts '2026-10-06 04:00'); snap $N 5 40 5 40 $(( N - 1200 ))
run "S5 F1: Tue 04:00, snapshot 20 min stale, supervisor on reserved account-1" $N $L/a1
rm $L/a2/.credentials.json
run "S6 adversarial: same but account-2 signed out, only reserved account left" $N $L/a1
echo "$cred" > $L/a2/.credentials.json
N=$(ts '2026-10-06 04:00'); snap $N 5 40 90 40 $N
run "S6b adversarial: fresh snapshot, account-2 over 5h cap, supervisor on account-1" $N $L/a1
cfg 3; N=$(ts '2026-10-06 04:00'); snap $N 5 40 5 40 $N
run "S7 three accounts, Tue 04:00: account-1 reserved, balance across 2 and 3" $N $L/a1
echo "=== S8 --check rejects bad reserve line"; { cat $L/cfg; echo "reserve account-9 03:00 08:00"; } > $L/badcfg
$P --check --config $L/badcfg; echo "    exit=$?"
{ cat $L/cfg | grep -v '^reserve '; echo "reserve account-1 25:00 08:00"; } > $L/badcfg
$P --check --config $L/badcfg; echo "    exit=$?"
echo "=== S9 log rows (chosen, fallback, refused, account-1 reserve fields)"
jq -c '{task,chosen,fallback,refused,a1:(.accounts[]|select(.label=="account-1")|{status,reserved,reserve_until_local,reserve_source})}' $L/picks.jsonl
