#!/usr/bin/env bash
# shellcheck source=.fm-lint-parity.bLQnaa/owner-dep.sh
. "/home/justin/.no-mistakes/worktrees/c7804fcd202d/01M44FQ65G41NWHZ1YFQSPGV1Y/.fm-lint-parity.bLQnaa/owner-dep.sh"
owner_bad() {
  printf '%s\n' "$owner_dependency_value"
  cd "$1"
}
