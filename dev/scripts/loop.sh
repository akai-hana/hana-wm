#!/bin/bash
# Destructive rewrite loop: each pass rewrites commit history with an LLM and
# force-pushes it. Deliberately demands an explicit opt-in flag so a stray run
# cannot clobber shared history.

set -euo pipefail

# Branch guards: fail fast on a missing prerequisite rather than corrupting
# history mid-loop.
command -v git >/dev/null || { echo "Refusing: git is not installed." >&2; exit 1; }
command -v git-rewrite-commits >/dev/null || { echo "Refusing: git-rewrite-commits is not on PATH." >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Refusing: not inside a git repository." >&2; exit 1; }

[ "$1" = "--yes-i-know" ] || { echo "Refusing: pass --yes-i-know to run this destructive force-push loop." >&2; exit 1; }

# Run one rewrite pass and report ONLY the tool's exit status. `yes` is left
# feeding the pipe so the tool can prompt as long as it likes; when the tool
# exits it stops reading and `yes` dies with SIGPIPE (141) -- unter pipefail
# that would mask a genuine failure, so the pipeline's status is discarded
# and ${PIPESTATUS[1]} (the tool's own exit code) is returned instead.
run_rewrite() {
    yes y | git-rewrite-commits --provider ollama --model hf.co/noctrex/Qwopus3.5-9B-Coder-MTP \
        --template "feat\(scope\): message" \
        --max-commits "$1" || true
    return "${PIPESTATUS[1]}"
}

max=250

while true; do
    run_rewrite "$max" || { echo "Aborting: git-rewrite-commits failed." >&2; exit 1; }
    git push --force-with-lease
    max=$((max + 1))
done
