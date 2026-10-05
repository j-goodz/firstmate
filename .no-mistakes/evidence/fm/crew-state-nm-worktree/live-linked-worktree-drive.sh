#!/usr/bin/env bash
# Live drive for the linked-worktree -> primary-checkout inventory fix.
# Drives the REAL bin/fm-crew-state.sh end-to-end against the REAL no-mistakes
# CLI (for the positive/regression scenarios) over a disposable NM_HOME sqlite
# database and a real git primary checkout + linked worktree. Read-only w.r.t.
# the operator's real ~/.no-mistakes: the disposable DB schema is cloned, data
# stays in the scratch tree.
set -u
REPO=${REPO:?set REPO to the validated worktree}
BASE=${BASE:?set BASE to the pre-fix commit}
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-drive.XXXXXX")
trap 'rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid
export GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid

# 1. Real primary checkout on main, real linked worktree on the lane branch.
git -C "$S" init -q primary
git -C "$S/primary" commit -q --allow-empty -m init
git -C "$S/primary" worktree add -q -b fm/live-lane "$S/linked"
head=$(git -C "$S/linked" rev-parse HEAD)
short=$(git -C "$S/linked" rev-parse --short=8 HEAD)

# 2. Disposable NM_HOME with the real schema cloned (read-only) from the
#    operator DB, then one registered repo (the PRIMARY checkout only, exactly
#    as ~/.no-mistakes/state.sqlite registers primary checkouts) and 13 runs.
mkdir -p "$S/nm"
python3 - "$S/nm/state.sqlite" <<'PY'
import sqlite3, os, sys
real = os.path.expanduser("~/.no-mistakes/state.sqlite")
src = sqlite3.connect(f"file:{real}?mode=ro", uri=True)
ddl = [s for (s,) in src.execute("select sql from sqlite_master where sql is not null")]
dst = sqlite3.connect(sys.argv[1])
for s in ddl:
    dst.execute(s)
dst.commit()
PY
python3 - "$S/nm/state.sqlite" "$S/primary" "$head" <<'PY'
import sqlite3, sys
db_path, primary, head = sys.argv[1:]
db = sqlite3.connect(db_path)
base = {'repo_id':'repo','branch':'fm/live-lane','head_sha':head,'base_sha':head,
        'status':'running','created_at':20,'updated_at':20}
db.execute("insert into repos (id,working_path,upstream_url,default_branch,created_at) "
           "values ('repo',?,?,?,0)", (primary,'https://example.invalid/r.git','main'))
def ins(v):
    db.execute('insert into runs (%s) values (%s)' % (','.join(v), ','.join('?'*len(v))), list(v.values()))
v=dict(base); v['id']='01NEW'; ins(v)
v=dict(base); v['id']='01OLD'; v['status']='cancelled'; v['created_at']=10; v['updated_at']=10; ins(v)
for i in range(11):
    v=dict(base); v['id']='01OTHER%02d'%i; v['branch']='fm/other-%d'%i; v['status']='running'
    v['created_at']=i; v['updated_at']=i; ins(v)
db.commit()
PY

# A copy of bin/ with the PRE-FIX library, for the regression reproduction.
cp -r "$REPO/bin" "$S/prefix-bin"
git -C "$REPO" show "$BASE:bin/fm-nm-run-lib.sh" > "$S/prefix-bin/fm-nm-run-lib.sh"

# 3. Disposable FM_HOME with a ship meta pointing at the LINKED worktree.
mkdir -p "$S/fmhome/state"
printf 'window=fm:fm-live-lane\nworktree=%s\nkind=ship\n' "$S/linked" > "$S/fmhome/state/lane.meta"

# A stub no-mistakes serving the documented capped-overview interface, used only
# for the unregistered-primary guard where the real CLI refuses to answer at all.
mkdir -p "$S/fakebin"
cat > "$S/fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  axi)
    shift
    if [ "\$#" = 0 ]; then
      echo "repo: $S/primary"
      echo "count: 10 of 13 total"
      echo "runs[10]{id,branch,status,head,pr}:"
      echo "  \"01NEW\",fm/live-lane,running,$short,\"\""
      echo "  \"01OTHER10\",fm/other-10,running,$short,\"\""
      echo "  \"01OLD\",fm/live-lane,cancelled,$short,\"\""
      for i in 09 08 07 06 05 04 03; do echo "  \"01OTHER\$i\",fm/other-\$i,running,$short,\"\""; done
      exit 0
    fi
    case "\${1:-}" in
      status)
        printf 'run:\n  id: "01NEW"\n  branch: fm/live-lane\n  status: running\n  head: %s\n  head_sha: %s\n  pr: ""\n  findings: none\n  steps[1]{step,status,findings,duration_ms}:\n    test,running,0,0\n' "$short" "$head"
        exit 0 ;;
    esac ;;
  runs) printf 'running fm/live-lane %s 2026-10-05 12:00\n' "$short"; exit 0 ;;
  daemon) echo 'daemon running (pid 4242)'; exit 0 ;;
esac
exit 0
SH
chmod +x "$S/fakebin/no-mistakes"

# Guard DB: same data but NO repos row (primary never registered).
mkdir -p "$S/nm-norepo"; cp "$S/nm/state.sqlite" "$S/nm-norepo/state.sqlite"
python3 - "$S/nm-norepo/state.sqlite" <<'PY'
import sqlite3, sys
db=sqlite3.connect(sys.argv[1]); db.execute("DELETE FROM repos"); db.commit()
PY

cd "$S/linked"
echo "### setup"
echo "primary checkout : $S/primary  (registered in disposable state.sqlite)"
echo "linked worktree  : $S/linked   (branch fm/live-lane, HEAD $short)"
echo "git-dir          : $(git rev-parse --path-format=absolute --git-dir)"
echo "git-common-dir   : $(git rev-parse --path-format=absolute --git-common-dir)"
echo
echo "### A. REAL no-mistakes CLI + linked worktree, POST-FIX fm-crew-state"
NM_HOME="$S/nm" FM_HOME="$S/fmhome" PATH="/home/justin/.local/bin:$PATH" "$REPO/bin/fm-crew-state.sh" lane
echo
echo "### B. REAL no-mistakes CLI + linked worktree, PRE-FIX fm-crew-state (the reported bug)"
NM_HOME="$S/nm" FM_HOME="$S/fmhome" PATH="/home/justin/.local/bin:$PATH" "$S/prefix-bin/fm-crew-state.sh" lane
echo
echo "### C. GUARD: capped overview, primary checkout NOT registered, POST-FIX"
PATH="$S/fakebin:$PATH" NM_HOME="$S/nm-norepo" FM_HOME="$S/fmhome" "$REPO/bin/fm-crew-state.sh" lane
echo
echo "### D. CONTROL: capped overview, primary checkout registered, POST-FIX"
PATH="$S/fakebin:$PATH" NM_HOME="$S/nm" FM_HOME="$S/fmhome" "$REPO/bin/fm-crew-state.sh" lane
