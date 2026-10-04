#!/usr/bin/env python3
# fm-calls-page.py - the selection, rendering, and result parsing behind
# bin/fm-calls-page.sh. That script's header owns the contract; this helper
# owns only the mechanics it delegates:
#
#   render <manifest> <today> <now> <out> [<curated-json>]
#       Select open and parked captain calls from the collected homes and
#       write the page atomically to <out>. Prints "open=N parked=M".
#   index <manifest> <today>
#       Print one JSON object per open call: {home, id, kind, title}.
#   parse-result
#       Read `fm-procevent-lavish.sh read` output on stdin and print one JSON
#       object per open-call-answer.v1 item, last save per call winning (an
#       item carrying the reserved value reconcile is kept apart so it never
#       displaces a real save; nor does a request to talk).
#
# The manifest is JSON lines, one per home:
#   {"home": "<id>", "label": "<text>", "snapshot": "<path or null>",
#    "resolved": ["<task-id>", ...], "error": "<text or null>"}
# where snapshot is fm-fleet-snapshot.sh --contribution-input output.
import datetime
import html
import json
import os
import re
import sys
import tempfile

SCHEMA = "open-call-answer.v1"
LOCAL = "local"


def load_manifest(path):
    homes = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                homes.append(json.loads(line))
    return homes


def call_options(body_lines):
    """Options from a `call-options:` block: following `- ` lines, one each."""
    options = []
    inside = False
    for line in body_lines or []:
        text = line.strip()
        if not inside:
            inside = text == "call-options:"
            continue
        if not text.startswith("- "):
            break
        option = text[2:].strip()
        if option:
            options.append({"value": option, "label": option, "detail": ""})
    return options


def select(homes, today):
    """Return (open_calls, parked_calls, errors) from the collected homes."""
    open_calls, parked, errors = [], [], []
    for home in homes:
        if home.get("error"):
            errors.append({"home": home["home"], "label": home.get("label") or home["home"],
                           "error": home["error"]})
        path = home.get("snapshot")
        if not path or not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as handle:
            snapshot = json.load(handle)
        resolved = set(home.get("resolved") or [])
        for record in (snapshot.get("backlog") or {}).get("records") or []:
            if not record.get("structured") or record.get("hold_kind") != "captain":
                continue
            if record.get("state") == "done":
                continue
            call = {
                "home": home["home"],
                "home_label": home.get("label") or home["home"],
                "id": record["id"],
                "title": record.get("title") or record["id"],
                "repo": record.get("repo") or "",
                "kind": record.get("kind") or "",
                "reason": record.get("hold_reason") or "",
                "since": record.get("since") or "",
                "asked": record.get("hold_set") or record.get("since") or "",
                "until": record.get("hold_until") or "",
                "options": call_options(record.get("body_lines")),
            }
            if call["until"] and call["until"] > today:
                parked.append(call)
            elif record["id"] in resolved:
                continue
            else:
                open_calls.append(call)
    return open_calls, parked, errors


def load_curated(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if isinstance(data, dict):
        data = data.get("groups")
    return data if isinstance(data, list) else []


def group(open_calls, curated):
    """Group by project, then curated feature, keeping a stable order."""
    by_key = {(c["home"], c["id"]): c for c in open_calls}
    by_id = {}
    for c in open_calls:
        by_id.setdefault(c["id"], []).append(c)
    projects = {}

    def project_entry(name):
        key = (name or "other").strip().lower()
        entry = projects.setdefault(key, {"name": name or "Other", "features": [], "loose": []})
        return entry

    placed = set()
    for feature in curated:
        if not isinstance(feature, dict):
            continue
        cards = []
        for item in feature.get("calls") or []:
            if not isinstance(item, dict):
                continue
            home = str(item.get("home") or LOCAL)
            key = (LOCAL if home in ("main", "here") else home, item.get("id"))
            call = by_key.get(key)
            if call is None and len(by_id.get(item.get("id"), [])) == 1:
                # A home named by machine rather than by home id: the task id
                # is open in exactly one home, so that home owns it.
                call = by_id[item.get("id")][0]
                key = (call["home"], call["id"])
            if call is None or key in placed:
                continue
            placed.add(key)
            merged = dict(call)
            if item.get("question"):
                merged["title"] = item["question"]
            options = [o for o in item.get("options") or [] if isinstance(o, dict) and o.get("label")]
            if options:
                merged["options"] = [{"value": str(o.get("value") or o["label"]),
                                      "label": str(o["label"]),
                                      "detail": str(o.get("detail") or "")} for o in options]
            merged["recommendation"] = str(item.get("recommendation") or "")
            merged["prior"] = str(item.get("his_prior_words") or "")
            # The feature context replaces the hold reason, which often only
            # records how the call was last parked.
            merged["reason"] = ""
            cards.append(merged)
        if cards:
            entry = project_entry(feature.get("project") or cards[0]["repo"])
            entry["features"].append({"name": str(feature.get("feature") or ""),
                                      "context": str(feature.get("context") or ""),
                                      "calls": cards})
    for call in open_calls:
        if (call["home"], call["id"]) in placed:
            continue
        project_entry(call["repo"])["loose"].append(call)
    for entry in projects.values():
        entry["loose"].sort(key=lambda c: (c["since"], c["id"], c["home"]))
    return [projects[k] for k in sorted(projects)]


def esc(text):
    return html.escape(str(text), quote=True)


def nice_date(iso):
    try:
        day = datetime.date.fromisoformat(iso[:10])
    except ValueError:
        return iso
    return day.strftime("%b ") + str(day.day)


def render_card(call):
    home = call["home"]
    qid = f"{home}/{call['id']}"
    rows = []
    rec = call.get("recommendation") or ""
    for opt in call.get("options") or []:
        mark = ""
        if rec and rec in (opt["value"], opt["label"]):
            mark = ' <span class="suggest">Suggested</span>'
        detail = f'<span class="detail">{esc(opt["detail"])}</span>' if opt.get("detail") else ""
        rows.append(
            f'<label class="opt"><input type="radio" name="a" value="{esc(opt["label"])}"'
            f' data-value="{esc(opt["value"])}"><span><span class="olabel">{esc(opt["label"])}</span>'
            f'{mark}{detail}</span></label>')
    rows.append('<label class="opt"><input type="radio" name="a" value="__later__">'
                '<span><span class="olabel">Later, park one week</span></span></label>')
    rows.append('<label class="opt"><input type="radio" name="a" value="__not_needed__">'
                '<span><span class="olabel">Not needed, close it</span></span></label>')
    rows.append('<label class="opt"><input type="radio" name="a" value="__talk__">'
                '<span><span class="olabel">Let\'s talk about it first</span>'
                '<span class="detail">Nothing is recorded; it comes up in chat.</span></span></label>')
    placeholder = "Your words (optional)" if call.get("options") else "Your answer"
    origin = []
    if call.get("since"):
        origin.append("Asked " + nice_date(call["since"]))
    if home != LOCAL:
        origin.append("held by " + call["home_label"])
    origin.append("task " + call["id"])
    reason = f'<p class="ctx">{esc(call["reason"])}</p>' if call.get("reason") else ""
    if call.get("prior"):
        reason += f'<p class="prior">You said: {esc(call["prior"])}</p>'

    return (
        f'<form class="card" data-call="{esc(call["id"])}" data-home="{esc(home)}"'
        f' data-asked="{esc(call["asked"])}" data-lavish-question="{esc(qid)}">\n'
        f'  <h3>{esc(call["title"])}</h3>\n'
        f'  {reason}\n'
        f'  <p class="origin">{esc(" · ".join(origin))}</p>\n'
        f'  <fieldset>{"".join(rows)}</fieldset>\n'
        f'  <textarea name="note" placeholder="{placeholder}"></textarea>\n'
        f'  <p class="hint" hidden>Pick an option or write an answer first.</p>\n'
        f'  <button class="save" type="submit">Save this answer</button>\n'
        f'  <p class="saved">Saved. This call leaves the page once it is recorded.</p>\n'
        f'</form>')


CSS = """
:root { --bg:#0f1115; --card:#181b22; --line:#2a2f3a; --text:#e8eaf0; --muted:#a3acbb; --accent:#5b8cff; --ok:#3fb27f; --warn:#e0a84f; }
* { box-sizing:border-box; }
body { margin:0; background:var(--bg); color:var(--text); font:16px/1.5 system-ui,-apple-system,Segoe UI,Roboto,sans-serif; }
main { max-width:720px; margin:0 auto; padding:16px 14px 80px; }
h1 { font-size:24px; margin:0 0 4px; color:var(--text); }
.sub { color:var(--muted); font-size:14px; margin:0 0 14px; }
.stats { display:flex; flex-wrap:wrap; gap:8px; margin-bottom:18px; }
.stat { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:8px 12px; font-size:16px; font-weight:600; color:var(--text); }
.notice { background:#2a2214; border:1px solid var(--warn); color:#f3dfb8; border-radius:10px; padding:10px 12px; font-size:14px; margin-bottom:14px; }
section.project > details { margin-bottom:18px; }
section.project > details > summary { cursor:pointer; font-size:18px; font-weight:700; color:var(--text); padding:6px 0; }
.count { color:var(--muted); font-weight:400; font-size:14px; }
.feature { border-left:3px solid var(--line); padding-left:10px; margin:12px 0; }
.feature h4 { margin:0 0 4px; font-size:16px; color:var(--text); }
.feature .shared { color:var(--muted); font-size:14px; margin:0 0 10px; }
.card { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px; margin-bottom:12px; color:var(--text); }
.card h3 { margin:0 0 6px; font-size:17px; color:var(--text); }
.card .ctx { margin:0 0 6px; color:var(--text); font-size:15px; }
.card .prior { margin:0 0 6px; color:#cdd5e3; font-size:14px; font-style:italic; }
.card .origin { margin:0 0 10px; color:var(--muted); font-size:13px; }
fieldset { border:0; padding:0; margin:0 0 10px; min-width:0; }
label.opt { display:flex; gap:10px; align-items:flex-start; padding:10px 12px; border:1px solid var(--line); border-radius:10px; margin-bottom:8px; cursor:pointer; color:var(--text); background:#1d2129; }
label.opt input { margin-top:4px; flex:none; }
label.opt > span { min-width:0; overflow-wrap:anywhere; }
.olabel { color:var(--text); }
.detail { display:block; color:var(--muted); font-size:13px; }
.suggest { display:inline-block; margin-left:6px; padding:0 6px; border-radius:6px; background:#22314f; color:#b9cdfb; font-size:12px; font-weight:600; }
textarea { width:100%; min-height:64px; background:#11141a; color:var(--text); border:1px solid var(--line); border-radius:10px; padding:10px; font:inherit; }
.hint { color:var(--warn); font-size:14px; margin:6px 0 0; }
button.save { margin-top:10px; width:100%; padding:12px; border:0; border-radius:10px; background:var(--accent); color:#fff; font-size:16px; font-weight:600; }
.saved { display:none; color:var(--ok); font-weight:600; margin:8px 0 0; }
.card.is-saved .saved { display:block; }
.card.is-saved fieldset, .card.is-saved textarea, .card.is-saved button.save, .card.is-saved .ctx, .card.is-saved .hint { display:none; }
details.parked { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 14px; margin-top:20px; color:var(--text); }
details.parked summary { cursor:pointer; font-weight:600; color:var(--text); }
details.parked ul { margin:10px 0 0; padding-left:18px; color:var(--text); font-size:15px; }
details.parked li { margin-bottom:6px; }
.empty { color:var(--muted); }
"""

SCRIPT = """
(function () {
  var store = null;
  try { store = window.localStorage; } catch (e) { store = null; }
  function savedKey(form) { return 'fm-calls-saved:' + form.dataset.home + '/' + form.dataset.call + '/' + form.dataset.asked; }
  document.querySelectorAll('form.card').forEach(function (form) {
    if (store && store.getItem(savedKey(form))) { form.classList.add('is-saved'); }
    form.addEventListener('submit', function (event) {
      event.preventDefault();
      var picked = form.querySelector('input[name=a]:checked');
      var note = (form.querySelector('textarea[name=note]').value || '').trim();
      var hint = form.querySelector('.hint');
      if (!picked && !note) { hint.hidden = false; return; }
      hint.hidden = true;
      var kind = 'text', answer = '', value = '';
      if (picked && picked.value === '__later__') { kind = 'later'; answer = 'Later, park one week'; }
      else if (picked && picked.value === '__not_needed__') { kind = 'not-needed'; answer = 'Not needed, close it'; }
      else if (picked && picked.value === '__talk__') { kind = 'talk'; answer = "Let's talk about it first"; }
      else if (picked) { kind = 'option'; answer = picked.value; value = picked.dataset.value || picked.value; }
      var title = form.querySelector('h3').textContent;
      var text = 'Call ' + form.dataset.call + ' (' + title + '): ' + (answer || note) + (answer && note ? ' | His words: ' + note : '');
      var data = { schema: 'open-call-answer.v1', call: form.dataset.call, home: form.dataset.home,
                   kind: kind, value: value, answer: answer, note: note, asked: form.dataset.asked };
      if (window.lavish && window.lavish.queuePrompt) {
        window.lavish.queuePrompt(text, { tag: 'call-answer', queueKey: 'call.' + form.dataset.home + '.' + form.dataset.call,
                                          element: form, text: title, data: data });
        if (window.lavish.sendQueuedPrompts) { window.lavish.sendQueuedPrompts(); }
      }
      if (store) { try { store.setItem(savedKey(form), '1'); } catch (e) {} }
      form.classList.add('is-saved');
    });
  });
})();
"""


def render_page(groups, parked, errors, now, open_count):
    built = now[:10] + " " + now[11:16] + " UTC" if len(now) >= 16 else now
    out = ['<!doctype html>', '<html lang="en">', '<head>', '<meta charset="utf-8">',
           '<meta name="viewport" content="width=device-width, initial-scale=1">',
           '<title>Your open calls</title>', '<style>' + CSS + '</style>', '</head>', '<body>', '<main>',
           '<h1>Your open calls</h1>',
           f'<p class="sub">Built {esc(built)} from the live records. A call you answer here or in chat '
           'leaves this page by itself. Each card saves on its own.</p>',
           '<div class="stats">',
           f'<div class="stat">{open_count} open</div>',
           f'<div class="stat">{len(parked)} parked</div>',
           '</div>']
    for err in errors:
        out.append(f'<p class="notice">Could not read the calls held by {esc(err["label"])}, so they are '
                   f'missing from this page. Reason: {esc(err["error"])}</p>')
    if not groups:
        out.append('<p class="empty">Nothing is waiting on you right now.</p>')
    for project in groups:
        cards = sum(len(f["calls"]) for f in project["features"]) + len(project["loose"])
        key = esc(project["name"].strip().lower())
        out.append(f'<section class="project" data-project="{key}">')
        out.append(f'<details open><summary>{esc(project["name"])} '
                   f'<span class="count">{cards} open</span></summary>')
        for feature in project["features"]:
            out.append('<div class="feature">')
            if feature["name"]:
                out.append(f'<h4>{esc(feature["name"])}</h4>')
            if feature["context"]:
                out.append(f'<p class="shared">{esc(feature["context"])}</p>')
            out.extend(render_card(c) for c in feature["calls"])
            out.append('</div>')
        out.extend(render_card(c) for c in project["loose"])
        out.append('</details>')
        out.append('</section>')
    if parked:
        out.append('<details class="parked">')
        out.append(f'<summary>{len(parked)} parked by you. None are asked before their date.</summary>')
        out.append('<ul>')
        for call in sorted(parked, key=lambda c: (c["until"], c["repo"], c["id"])):
            label = f'{call["repo"]}: ' if call["repo"] else ""
            out.append(f'<li class="parked-call" data-call="{esc(call["id"])}">{esc(label + call["title"])}'
                       f' <span class="count">until {esc(nice_date(call["until"]))}</span></li>')
        out.append('</ul>')
        out.append('</details>')
    out += ['</main>', '<script>' + SCRIPT + '</script>', '</body>', '</html>', '']
    return "\n".join(out)


def write_atomic(path, text):
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(prefix=".calls.html.tmp.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def cmd_render(args):
    manifest, today, now, out = args[:4]
    curated = args[4] if len(args) > 4 else ""
    open_calls, parked, errors = select(load_manifest(manifest), today)
    groups = group(open_calls, load_curated(curated))
    write_atomic(out, render_page(groups, parked, errors, now, len(open_calls)))
    print(f"open={len(open_calls)} parked={len(parked)}")


def cmd_index(args):
    open_calls, _, _ = select(load_manifest(args[0]), args[1])
    for call in open_calls:
        print(json.dumps({"home": call["home"], "id": call["id"], "kind": call["kind"],
                          "title": call["title"]}))


def cmd_parse_result():
    """Parse the annotations of `fm-procevent-lavish.sh read` output."""
    prompts, current, in_prompt = [], None, False
    for raw in sys.stdin.read().splitlines():
        if raw.startswith("ANNOTATION ") or raw == "END ANNOTATIONS":
            if current is not None:
                prompts.append("\n".join(current))
            current, in_prompt = None, False
            continue
        if raw == "prompt:":
            current, in_prompt = [], True
            continue
        if in_prompt:
            if raw.startswith("| "):
                current.append(raw[2:])
            elif raw == "|":
                current.append("")
            else:
                prompts.append("\n".join(current))
                current, in_prompt = None, False
    if current is not None:
        prompts.append("\n".join(current))
    latest = {}
    for prompt in prompts:
        marker = prompt.rfind("Context data:\n")
        if marker < 0:
            continue
        try:
            data = json.loads(prompt[marker + len("Context data:\n"):])
        except ValueError:
            continue
        if not isinstance(data, dict) or data.get("schema") != SCHEMA:
            continue
        call = str(data.get("call") or "")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", call):
            continue
        home = str(data.get("home") or LOCAL)
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", home):
            continue
        answer = str(data.get("answer") or "").strip()
        note = str(data.get("note") or "").strip()
        kind = str(data.get("kind") or "")
        if kind not in ("option", "text", "later", "not-needed", "talk"):
            kind = "option" if answer else "text"
        # The reserved value and a request to talk never displace a real save
        # of the same card.
        if "reconcile" in (answer.lower(), note.lower()):
            slot = "reserved"
        elif kind == "talk":
            slot = "talk"
        else:
            slot = "answer"
        latest[(home, call, slot)] = {"home": home, "call": call, "kind": kind,
                                          "answer": answer, "note": note}
    for item in latest.values():
        print(json.dumps(item))


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: fm-calls-page.py render|index|parse-result ...")
    command, args = sys.argv[1], sys.argv[2:]
    if command == "render" and len(args) >= 4:
        cmd_render(args)
    elif command == "index" and len(args) == 2:
        cmd_index(args)
    elif command == "parse-result":
        cmd_parse_result()
    else:
        sys.exit("usage: fm-calls-page.py render|index|parse-result ...")


if __name__ == "__main__":
    main()
