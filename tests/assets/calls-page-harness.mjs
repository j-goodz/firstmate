// Execute a built calls page's shipped inline script under a minimal DOM shim
// and report what it actually did, so the saved-marker behavior is asserted
// through the real generated page rather than by reading its source.
//
// Usage: node calls-page-harness.mjs <built-page.html> <scenario.json>
//
// Scenario:
//   { "store": {"<saved-marker-key>": "1", ...},
//     "submit": {"call": "a1", "home": "local", "choice": "__talk__", "note": ""} }
//
// Prints one JSON document:
//   { build, loaded:[call], submitted:[call], queued:[{kind,call}], store:{...} }
// where loaded is the cards marked saved when the page opened, submitted is the
// cards marked saved after the one simulated submit, and store is the persisted
// marker map afterwards.
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

const buildMatch = html.match(/<body data-build="([^"]*)"/);
const build = buildMatch ? unescape(buildMatch[1]) : "";

const forms = [];
const byCall = new Map();
const formRe = /<form class="card"([^>]*)>/g;
let match;
while ((match = formRe.exec(html))) {
  const tag = match[1];
  const call = attrOf(tag, "data-call");
  const form = {
    dataset: { call, home: attrOf(tag, "data-home"), asked: attrOf(tag, "data-asked") },
    _classes: new Set(),
    _picked: null,
    _note: "",
    _listener: null,
    _hint: { hidden: true, textContent: "" },
  };
  form.classList = {
    add: (c) => form._classes.add(c),
    contains: (c) => form._classes.has(c),
  };
  form.addEventListener = (event, fn) => {
    if (event === "submit") form._listener = fn;
  };
  form.querySelector = (selector) => {
    if (selector.startsWith("input")) return form._picked;
    if (selector.startsWith("textarea")) return { value: form._note };
    if (selector === ".hint") return form._hint;
    if (selector === "h3") return { textContent: "card " + call };
    return null;
  };
  forms.push(form);
  byCall.set(call, form);
}

const store = new Map(Object.entries(scenario.store || {}));
const queued = [];
globalThis.document = {
  body: { dataset: { build } },
  querySelectorAll: (selector) => (selector === "form.card" ? forms : []),
};
globalThis.window = {
  localStorage: {
    getItem: (key) => (store.has(key) ? store.get(key) : null),
    setItem: (key, value) => store.set(key, String(value)),
  },
  lavish: {
    queuePrompt: (text, options) => queued.push({ kind: options.data && options.data.kind, call: options.data && options.data.call }),
    sendQueuedPrompts: () => {},
  },
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const saved = () => forms.filter((f) => f._classes.has("is-saved")).map((f) => f.dataset.call);
const loaded = saved();

let submitted = null;
if (scenario.submit) {
  const form = byCall.get(scenario.submit.call);
  if (!form || form.dataset.home !== scenario.submit.home) throw new Error("no card for " + JSON.stringify(scenario.submit));
  form._picked = scenario.submit.choice
    ? { value: scenario.submit.choice, dataset: { value: scenario.submit.choice } }
    : null;
  form._note = scenario.submit.note || "";
  form._listener({ preventDefault() {} });
  submitted = saved();
}

process.stdout.write(JSON.stringify({ build, loaded, submitted, queued, store: Object.fromEntries(store) }) + "\n");
