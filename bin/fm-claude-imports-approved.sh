#!/usr/bin/env bash
# fm-claude-imports-approved.sh checks whether a parent Firstmate home holds an
# explicit approval for Claude Code external CLAUDE.md imports for a given git
# origin. It consults the local Claude config and any additional account stores
# listed in the Firstmate claude-accounts file. An explicit decline anywhere
# overrides any approval and forces a negative result.
# Usage: fm-claude-imports-approved.sh <origin-url>
# Usage: fm-claude-imports-approved.sh -h | --help
# Stores consulted: the default CLAUDE_CONFIG_DIR or HOME .claude.json, and
# each store directory from FM_CONFIG_OVERRIDE or FM_HOME config/claude-accounts
# lines of the form "account <label> <absolute-store-dir> [<signin-file>]".
# The script prints exactly "approved" on stdout and exits 0 when at least one
# matching approval exists and zero matching declines exist. It prints exactly
# "none" on stdout and exits 1 otherwise. It exits 2 on usage errors.
set -u

# Print usage from header comment (lines starting with "Usage:").
if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
  sed -n '2,/^$/p' "$0" | sed -n '/^# Usage:/s/^# //p'
  exit 0
fi

if [[ $# -ne 1 ]]; then
  printf 'Usage: %s <origin-url>\n' "$(basename "$0")" >&2
  printf 'Usage: %s -h | --help\n' "$(basename "$0")" >&2
  exit 2
fi

ORIGIN_ARG="$1"

# Verify node is available.
if ! command -v node >/dev/null 2>&1; then
  printf 'node not found on PATH; cannot evaluate approvals\n' >&2
  printf 'none\n'
  exit 1
fi

# Run the decision logic in a single Node program.
node - "$ORIGIN_ARG" <<'NODE'
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const originArg = process.argv[2];

function normalizeOrigin(origin) {
  if (typeof origin !== 'string') return '';
  let s = origin.trim();
  // file:///abs/path
  if (s.startsWith('file://')) {
    const url = new URL(s);
    s = url.pathname;
  } else {
    // scheme://[userinfo@]host[:port]/path
    const schemeMatch = s.match(/^(https?|ssh|git):\/\/([^/]+)\/(.+)$/i);
    if (schemeMatch) {
      const host = schemeMatch[2].toLowerCase();
      const rest = schemeMatch[3];
      s = host + '/' + rest;
    } else {
      // scp-like [user@]host:path (no leading /, no ://)
      const scpMatch = s.match(/^([^:@/]+@)?([^:/]+):(.+)$/);
      if (scpMatch && !s.startsWith('/') && !s.includes('://')) {
        const host = scpMatch[2].toLowerCase();
        const rest = scpMatch[3];
        s = host + '/' + rest;
      }
    }
  }
  // remove trailing slashes and one trailing .git
  s = s.replace(/\/+$/, '');
  if (s.endsWith('.git')) s = s.slice(0, -4);
  return s;
}

const targetNorm = normalizeOrigin(originArg);

function collectStores() {
  const stores = new Map(); // realpath -> path
  // Store 1: default
  const defaultDir = process.env.CLAUDE_CONFIG_DIR || process.env.HOME;
  if (defaultDir) {
    const p = path.join(defaultDir, '.claude.json');
    try {
      const real = fs.realpathSync(p);
      stores.set(real, p);
    } catch {}
  }
  // Store 2+: from claude-accounts
  const fmConfigOverride = process.env.FM_CONFIG_OVERRIDE;
  const fmHome = process.env.FM_HOME;
  let accountsFile = null;
  if (fmConfigOverride) {
    accountsFile = path.join(fmConfigOverride, 'claude-accounts');
  } else if (fmHome) {
    accountsFile = path.join(fmHome, 'config', 'claude-accounts');
  }
  if (accountsFile) {
    try {
      const content = fs.readFileSync(accountsFile, 'utf8');
      for (const line of content.split('\n')) {
        const trimmed = line.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;
        const parts = trimmed.split(/\s+/);
        if (parts[0] === 'account' && parts.length >= 3) {
          const storeDir = parts[2];
          if (path.isAbsolute(storeDir)) {
            const p = path.join(storeDir, '.claude.json');
            try {
              const real = fs.realpathSync(p);
              stores.set(real, p);
            } catch {}
          }
        }
      }
    } catch {}
  }
  return Array.from(stores.values());
}

function getGitOrigin(projectPath) {
  // Remove GIT_* env vars that could affect git behavior
  const env = { ...process.env };
  delete env.GIT_DIR;
  delete env.GIT_WORK_TREE;
  delete env.GIT_COMMON_DIR;
  delete env.GIT_INDEX_FILE;
  delete env.GIT_CONFIG;
  delete env.GIT_CONFIG_GLOBAL;
  delete env.GIT_CONFIG_SYSTEM;
  try {
    const out = execFileSync('git', ['-C', projectPath, 'remote', 'get-url', 'origin'], {
      timeout: 5000,
      stdio: ['ignore', 'pipe', 'ignore'],
      env,
      encoding: 'utf8'
    });
    return out.trim();
  } catch {
    return null;
  }
}

let approvals = 0;
let declines = 0;

for (const storePath of collectStores()) {
  let data;
  try {
    const content = fs.readFileSync(storePath, 'utf8');
    if (!content.trim()) continue;
    data = JSON.parse(content);
  } catch {
    continue;
  }
  if (!data || typeof data !== 'object' || !data.projects || typeof data.projects !== 'object') {
    continue;
  }
  for (const [projectPath, entry] of Object.entries(data.projects)) {
    if (!entry || typeof entry !== 'object') continue;
    const approved = entry.hasClaudeMdExternalIncludesApproved === true;
    const declined = entry.hasClaudeMdExternalIncludesApproved === false &&
                     entry.hasClaudeMdExternalIncludesWarningShown === true;
    if (!approved && !declined) continue;
    // Check if projectPath is an existing directory
    try {
      const stat = fs.statSync(projectPath);
      if (!stat.isDirectory()) continue;
    } catch {
      continue;
    }
    const origin = getGitOrigin(projectPath);
    if (!origin) continue;
    const norm = normalizeOrigin(origin);
    if (norm === targetNorm) {
      if (approved) approvals++;
      if (declined) declines++;
    }
  }
}

if (approvals >= 1 && declines === 0) {
  console.log('approved');
  process.exit(0);
} else {
  console.log('none');
  process.exit(1);
}
NODE

# Exit with the node script's exit code
exit $?
