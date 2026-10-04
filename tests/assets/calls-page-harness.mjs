// Execute a built calls page's shipped inline script under a minimal DOM shim
// and report what it actually did, so the page's save, confirmation/collapse,
// sort, and saved-marker behavior are asserted through the real generated page
// rather than by reading its source.
//
// Usage: node calls-page-harness.mjs <built-page.html> <scenario.json>
//
// Scenario:
//   { "store": {"<saved-marker-key>": "1", ...},
//     "sort": "project",
//     "submit": {"call": "a1", "home": "local", "choice": "__talk__", "note": ""} }
//
// Prints one JSON document:
//   { build, loaded, confirmed, collapsed, queued, sent, store, scrolled,
//     sortMode, visualOrder }
// where loaded is the cards marked saved when the page opened, confirmed are
// the cards showing a save confirmation right after the one submit, collapsed
// are the cards folded once the 1.5s collapse timer fired, queued are the
// prompts the save queued, sent counts the send-at-once calls, scrolled are the
// scroll adjustments made while collapsing, sortMode is the active sort class,
// and visualOrder is the cards' visual order given the active sort.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const scenario = JSON.parse(readFileSync(process.argv[3], "utf8"));

const unescape = (s) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");

const attrOf = (tag, name) => {
  const m = tag.match(new RegExp("\\s" + name + '="([^"]*)"'));
  return m ? unescape(m[1]) : "";
};

const classListOf = (set) => ({
  add: (c) => set.add(c),
  remove: (c) => set.delete(c),
  contains: (c) => set.has(c),
  toggle: (c, on) => {
    const want = on === undefined ? !set.has(c) : !!on;
    if (want) set.add(c);
    else set.delete(c);
    return want;
  },
});

const buildMatch = html.match(/<body[^>]*data-build="([^"]*)"/);
const build = buildMatch ? unescape(buildMatch[1]) : "";
const bodyClasses = new Set((html.match(/<body[^>]*class="([^"]*)"/) || [, ""])[1].split(/\s+/).filter(Boolean));

const forms = [];
const byCall = new Map();
const formRe = /<form class="card"([^>]*)>/g;
let match;
while ((match = formRe.exec(html))) {
  const tag = match[1];
  const call = attrOf(tag, "data-call");
  const orderMatch = tag.match(/style="order:(\d+)"/);
  const form = {
    dataset: {
      call,
      home: attrOf(tag, "data-home"),
      asked: attrOf(tag, "data-asked"),
      project: attrOf(tag, "data-project"),
    },
    style: { order: orderMatch ? orderMatch[1] : "" },
    _classes: new Set(),
    _picked: null,
    _note: "",
    _listener: null,
    _hint: { hidden: true, textContent: "" },
    _saved: { textContent: "" },
  };
  form.classList = classListOf(form._classes);
  form.addEventListener = (event, fn) => {
    if (event === "submit") form._listener = fn;
  };
  form.querySelector = (selector) => {
    if (selector.startsWith("input")) return form._picked;
    if (selector.startsWith("textarea")) return { value: form._note };
    if (selector === ".hint") return form._hint;
    if (selector === ".saved") return form._saved;
    if (selector === "h3") return { textContent: "card " + call };
    return null;
  };
  form.getBoundingClientRect = () => ({ top: rectTop(form) });
  forms.push(form);
  byCall.set(call, form);
}

const collapsedHeight = (form) => (form._classes.has("is-saved") ? 30 : 100);
const rectTop = (form) => {
  let top = 0;
  for (const f of forms) {
    if (f === form) return top;
    top += collapsedHeight(f) + 10;
  }
  return top;
};

const sortButtons = [];
const buttonRe = /<button[^>]*class="sortbtn"[^>]*data-sort="([^"]*)"[^>]*>/g;
while ((match = buttonRe.exec(html))) {
  const mode = unescape(match[1]);
  const attrs = new Map();
  const button = {
    dataset: { sort: mode },
    _click: null,
    addEventListener: (event, fn) => {
      if (event === "click") button._click = fn;
    },
    setAttribute: (name, value) => attrs.set(name, value),
    getAttribute: (name) => (attrs.has(name) ? attrs.get(name) : null),
  };
  sortButtons.push(button);
}

const store = new Map(Object.entries(scenario.store || {}));
const queued = [];
const timers = [];
const scrolled = [];
let sent = 0;
const documentShim = {
  body: {
    dataset: { build },
    classList: classListOf(bodyClasses),
  },
  querySelectorAll: (selector) => {
    if (selector === "form.card") return forms;
    if (selector === "[data-sort]") return sortButtons;
    return [];
  },
};
globalThis.document = documentShim;
globalThis.window = {
  localStorage: {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
  },
  setTimeout: (fn) => {
    timers.push(fn);
    return timers.length;
  },
  scrollBy: (x, y) => scrolled.push(y),
  lavish: {
    queuePrompt: (text, options) =>
      queued.push({ kind: options.data && options.data.kind, call: options.data && options.data.call }),
    sendQueuedPrompts: () => {
      sent += 1;
    },
  },
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const withClass = (cls) => forms.filter((f) => f._classes.has(cls)).map((f) => f.dataset.call);
const loaded = withClass("is-saved");

let confirmed = [];
let collapsed = [];
if (scenario.submit) {
  const form = byCall.get(scenario.submit.call);
  if (!form || form.dataset.home !== scenario.submit.home) throw new Error("no card for " + JSON.stringify(scenario.submit));
  form._picked = scenario.submit.choice
    ? { value: scenario.submit.choice, dataset: { value: scenario.submit.choice } }
    : null;
  form._note = scenario.submit.note || "";
  form._listener({ preventDefault() {} });
  confirmed = withClass("is-confirmed");
  timers.splice(0).forEach((fn) => fn());
  collapsed = withClass("is-saved");
}

let sortMode = bodyClasses.has("sort-newest") ? "newest" : "project";
const orderedNow = () => {
  const ordered = forms.slice();
  if (sortMode === "newest") {
    ordered.sort((a, b) => (parseInt(a.style.order, 10) || 0) - (parseInt(b.style.order, 10) || 0));
  }
  return ordered.map((f) => f.dataset.call);
};
let visualOrder = orderedNow();
if (scenario.sort) {
  const button = sortButtons.find((b) => b.dataset.sort === scenario.sort);
  if (!button || !button._click) throw new Error("no sort button for " + scenario.sort);
  button._click();
  sortMode = bodyClasses.has("sort-newest") ? "newest" : "project";
  visualOrder = orderedNow();
}

process.stdout.write(
  JSON.stringify({
    build,
    loaded,
    confirmed,
    collapsed,
    queued,
    sent,
    scrolled,
    store: Object.fromEntries(store),
    sortMode,
    visualOrder,
  }) + "\n",
);
