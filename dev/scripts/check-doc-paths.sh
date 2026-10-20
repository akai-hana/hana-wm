#!/usr/bin/env bash
# check-doc-paths.sh - fail when a living doc references a path that doesn't
# exist (P2-77). Pair of P2-76's documentation reconciliation: that task
# fixed the stale references, this one keeps them from rotting again --
# renaming a file without updating README/AGENTS/config docs fails CI.
#
# Usage:
#   dev/scripts/check-doc-paths.sh          # scan (exit 1 on any miss)
#
# Scope (by design):
#   - LIVING docs only: README.md, AGENTS.md, config/README.md. A doc that
#     isn't in the checkout (AGENTS.md is local-only/gitignored) is skipped
#     with a note rather than failed, so CI and local runs both work.
#   - ARCHIVAL docs are excluded on purpose: REFACTOR-PLAN.md cites files as
#     they were at the time a task ran, REVIEW.md/library/ are dated review
#     snapshots -- historical path mentions are their content, not rot.
#   - Tokens: tight backtick spans and markdown link targets that start with
#     src/ dev/ config/ contrib/, plus bare src top-level directories
#     (core/ window/ tiling/ bar/ test/ -- resolved under src/). Generic
#     prose mentions (`config.toml`, bare `domain.zig` stems, toolchain
#     files) are not paths and are not scanned; template placeholders
#     (containing < or >) are skipped.
#
# Exit: 0 all tokens exist (prints the checked count), 1 any miss (prints
# file:line per miss), 2 usage/environment problem.
set -eu
cd "$(dirname "$0")/../.."

command -v python3 >/dev/null || {
    echo "check-doc-paths: python3 is required" >&2
    exit 2
}

python3 - <<'PY'
import glob
import os
import re
import sys

DOCS = ("README.md", "AGENTS.md", "config/README.md")
PREFIXES = ("src/", "dev/", "config/", "contrib/")
SRC_DIRS = ("core/", "window/", "tiling/", "bar/", "test/")

checked = 0
missing = []
skipped_docs = []

for doc in DOCS:
    if not os.path.exists(doc):
        skipped_docs.append(doc)
        continue
    with open(doc, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            tokens = []
            for m in re.finditer(r"`([^`\n]+)`", line):
                parts = m.group(1).split()
                if parts:
                    tokens.append(parts[0])
            for m in re.finditer(r"\]\(([^)\s]+)\)", line):
                tokens.append(m.group(1))
            for tok in tokens:
                tok = tok.split("#", 1)[0].rstrip(".,;:?")
                if not tok or "<" in tok or ">" in tok:
                    continue
                if tok.startswith(PREFIXES):
                    path = tok
                elif tok.startswith(SRC_DIRS):
                    path = "src/" + tok
                else:
                    continue
                checked += 1
                if "*" in path:
                    ok = bool(glob.glob(path))
                else:
                    ok = os.path.exists(path)
                if not ok:
                    missing.append(f"{doc}:{lineno}: {tok}")

for doc in skipped_docs:
    print(f"check-doc-paths: {doc} not present, skipped (local-only doc)")

if missing:
    for m in missing:
        print(f"check-doc-paths: MISSING {m}", file=sys.stderr)
    print(
        f"check-doc-paths: {len(missing)} stale path(s) of {checked} checked; "
        "fix the doc or the rename",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"check-doc-paths: OK ({checked} path tokens checked in {len(DOCS) - len(skipped_docs)} docs)")
PY
