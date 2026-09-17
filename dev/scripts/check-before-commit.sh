#!/usr/bin/env bash
# Pre-commit sanity gate for the `automated sync` flow.
#
# Validates the working tree before a commit lands: format drift, full
# type-check + plugin-template compile gate + layer guards (`zig build
# check`), and optionally the isolated X-backed test suite.
#
# Usage:
#   dev/scripts/check-before-commit.sh            # fmt + build + layer checks
#   dev/scripts/check-before-commit.sh --test     # ... + full isolated test suite
#   dev/scripts/check-before-commit.sh --modularity  # ... + feature-deletion build matrix
#   dev/scripts/check-before-commit.sh --all      # ... + tests + modularity
#
# Notes:
#   - Tests (--test) run through dev/scripts/xtest.sh, which starts and tears
#     down its OWN Xvfb and points DISPLAY at it, so the live session on
#     DISPLAY=:0 is never touched.
#   - --modularity is heavy (builds each deletion scenario cold); it is NOT part
#     of the default gate.
#   - Does NOT commit anything; wire it into the automated-sync flow as a
#     pre-commit gate by invoking it before `git add`/`git commit`.
set -eu

cd "$(dirname "$0")/../.."

RUN_TEST=0
RUN_MODULARITY=0
for arg in "$@"; do
    case "$arg" in
        --test) RUN_TEST=1 ;;
        --modularity) RUN_MODULARITY=1 ;;
        --all) RUN_TEST=1; RUN_MODULARITY=1 ;;
        *) echo "check-before-commit: unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "[check-before-commit] fmt check..."
zig fmt --check .

echo "[check-before-commit] zig build check (type-check + plugin-template + layers)..."
zig build check

if [ "$RUN_MODULARITY" -eq 1 ]; then
    echo "[check-before-commit] feature-deletion modularity matrix..."
    zig build check-modularity
fi

if [ "$RUN_TEST" -eq 1 ]; then
    echo "[check-before-commit] isolated test suite..."
    dev/scripts/xtest.sh zig build test
fi

echo "[check-before-commit] OK"