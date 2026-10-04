// Resolve the model an injected OpenCode turn must run on.
//
// OpenCode's promptAsync runs on the agent's configured default when no model
// is passed, which silently overrides the model the session was launched with
// (the 2026-10-04 swift second-mate incident). An injected firstmate turn must
// instead run on the model the session is currently using, in this order: the
// model of the session's most recent user message when one exists, otherwise
// the model the opencode process was launched with, otherwise the session's
// stored model. It must never fall back to a configured default.

function normalizeModel(model) {
  if (!model || typeof model !== "object") return null;
  const providerID = model.providerID;
  const modelID = model.modelID ?? model.id;
  if (typeof providerID !== "string" || typeof modelID !== "string" || !providerID || !modelID) {
    return null;
  }
  return { providerID, modelID };
}

// Parse one `provider/model` value, splitting on the first slash so a model id
// that itself contains slashes (an OpenRouter-style path) is preserved whole.
function parseModelValue(value) {
  if (typeof value !== "string") return null;
  const slash = value.indexOf("/");
  if (slash <= 0 || slash === value.length - 1) return null;
  return { providerID: value.slice(0, slash), modelID: value.slice(slash + 1) };
}

// The opencode process's own launch model, parsed from the CLI arguments an
// operator passed: `--model <p/m>`, `--model=<p/m>`, or `-m <p/m>`. This is the
// fallback for a session injected before any user message carries a model. It
// is never the agent's configured default: only an explicit launch argument
// counts.
function launchModelFromArgv(argv) {
  if (!Array.isArray(argv)) return null;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    let value = null;
    if (arg === "--model" || arg === "-m") {
      value = argv[i + 1];
    } else if (typeof arg === "string" && arg.startsWith("--model=")) {
      value = arg.slice("--model=".length);
    }
    const model = parseModelValue(value);
    if (model) return model;
  }
  return null;
}

function unwrap(result) {
  return result && typeof result === "object" && "data" in result ? result.data : result;
}

export async function resolveSessionModel(client, sessionID) {
  if (client?.session && sessionID) {
    try {
      const messages = unwrap(await client.session.messages({ path: { id: sessionID } }));
      if (Array.isArray(messages)) {
        for (let i = messages.length - 1; i >= 0; i -= 1) {
          const info = messages[i]?.info;
          if (info?.role !== "user") continue;
          const model = normalizeModel(info.model);
          if (model) return model;
        }
      }
    } catch {
      // Fall through to the process launch model.
    }
  }
  const launched = launchModelFromArgv(process.argv);
  if (launched) return launched;
  if (client?.session && sessionID) {
    try {
      const session = unwrap(await client.session.get({ path: { id: sessionID } }));
      const model = normalizeModel(session?.model);
      if (model) return model;
    } catch {
      // No model could be proven; omit it rather than guessing a default.
    }
  }
  return null;
}
