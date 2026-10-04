// Resolve the model an injected OpenCode turn must run on.
//
// OpenCode's promptAsync runs on the agent's configured default when no model
// is passed, which silently overrides the model the session was launched with
// (the 2026-10-04 swift second-mate incident). An injected firstmate turn must
// instead run on the model the session is currently using: the model of the
// session's most recent user message when one exists, otherwise the session's
// stored launch model. It must never fall back to a configured default.

function normalizeModel(model) {
  if (!model || typeof model !== "object") return null;
  const providerID = model.providerID;
  const modelID = model.modelID ?? model.id;
  if (typeof providerID !== "string" || typeof modelID !== "string" || !providerID || !modelID) {
    return null;
  }
  return { providerID, modelID };
}

function unwrap(result) {
  return result && typeof result === "object" && "data" in result ? result.data : result;
}

export async function resolveSessionModel(client, sessionID) {
  if (!client?.session || !sessionID) return null;
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
    // Fall through to the session's launch model.
  }
  try {
    const session = unwrap(await client.session.get({ path: { id: sessionID } }));
    const model = normalizeModel(session?.model);
    if (model) return model;
  } catch {
    // No model could be proven; omit it rather than guessing a default.
  }
  return null;
}
