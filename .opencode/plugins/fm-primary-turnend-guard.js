import { spawn } from "node:child_process";
import { appendFileSync, mkdirSync, realpathSync } from "node:fs";
import { resolve } from "node:path";
import { encodeFirstmateOperationalInput } from "./lib/fm-operational-input.js";
import { resolveSessionModel } from "./lib/fm-session-model.js";

const COORDINATOR_KEY = "__firstmateOpenCodeWatchArm";

// A guard follow-up that fails or ends without any tool call must never
// re-inject forever. After this many consecutive follow-ups with no tool call
// between them the guard stops and records one failure line in the home's own
// status record; a normal turn (one that produces a tool call) or a watcher
// arming resets the count.
const MAX_CONSECUTIVE_FOLLOW_UPS = 3;

let consecutiveNoToolFollowUps = 0;
let followUpPending = false;
let toolCallObserved = false;
let failureRecorded = false;

function resetGuardBudget() {
  consecutiveNoToolFollowUps = 0;
  followUpPending = false;
  toolCallObserved = false;
  failureRecorded = false;
}

function recordGuardFailure(state, sessionID) {
  try {
    mkdirSync(state, { recursive: true });
    const epoch = Math.floor(Date.now() / 1000);
    appendFileSync(
      `${state}/.opencode-turnend-guard.status`,
      `failed [at=${epoch}]: opencode turn-end guard stopped after ${MAX_CONSECUTIVE_FOLLOW_UPS} consecutive follow-ups with no tool call and supervision still missing (session ${sessionID})\n`,
    );
  } catch {
    // A record that cannot be written must never keep the loop running.
  }
}

function runProcess(command, args, input = "") {
  return new Promise((resolve) => {
    const child = spawn(command, args, {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolve({ code: 0, stdout: "", stderr: "" }));
    child.on("close", (code) => resolve({ code: code ?? 0, stdout, stderr }));
    child.stdin.end(input);
  });
}

async function resolveRoot(anchor) {
  if (!anchor) return "";
  const result = await runProcess("git", ["-C", anchor, "rev-parse", "--show-toplevel"]);
  const root = result.stdout.trim();
  if (result.code === 0 && root) return root;
  return resolvePath(anchor);
}

function resolvePath(anchor) {
  try {
    return realpathSync(anchor);
  } catch {
    return resolve(anchor);
  }
}

function runGuard(root) {
  if (!root) return Promise.resolve({ code: 0, stderr: "" });
  return runProcess(`${root}/bin/fm-turnend-guard.sh`, [], '{"stop_hook_active":false}');
}

async function watchArmStatus(sessionID, client) {
  const coordinator = globalThis[COORDINATOR_KEY];
  if (!coordinator?.ensureArmed) return "";
  return coordinator.ensureArmed(sessionID, client);
}

export const FmPrimaryTurnendGuard = async ({ client, directory, worktree }) => {
  const root = worktree ? resolvePath(worktree) : await resolveRoot(directory);
  const state = process.env.FM_STATE_OVERRIDE || `${process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root}/state`;

  return {
    "tool.execute.before": async () => {
      toolCallObserved = true;
    },
    event: async ({ event }) => {
      if (event.type !== "session.idle") return;

      const sessionID = event.properties?.sessionID;
      if (!sessionID) return;

      const armStatus = await watchArmStatus(sessionID, client);
      if (armStatus === "armed" || armStatus === "wake") {
        resetGuardBudget();
        return;
      }
      if (armStatus === "failed") return;

      const result = await runGuard(root);
      if (result.code !== 2) return;

      if (toolCallObserved) {
        consecutiveNoToolFollowUps = 0;
        failureRecorded = false;
      } else if (followUpPending) {
        consecutiveNoToolFollowUps += 1;
      }
      toolCallObserved = false;
      followUpPending = false;

      if (consecutiveNoToolFollowUps >= MAX_CONSECUTIVE_FOLLOW_UPS) {
        if (!failureRecorded) {
          recordGuardFailure(state, sessionID);
          failureRecorded = true;
        }
        return;
      }

      try {
        const text = await encodeFirstmateOperationalInput(
          root,
          "turn-end-guard",
          "TURN WOULD END BLIND - supervision is off. " +
            "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
            result.stderr,
        );
        const model = await resolveSessionModel(client, sessionID);
        await client.session.promptAsync({
          path: { id: sessionID },
          body: {
            parts: [{ type: "text", text }],
            ...(model ? { model } : {}),
          },
        });
        followUpPending = true;
      } catch {
        followUpPending = false;
      }
    },
  };
};
