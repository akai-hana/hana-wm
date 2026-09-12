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
#
# Notes:
#   - Never spawns an X server; tests (--test) run under dev/scripts/xtest.sh
#     so the live session on DISPLAY=:0 is never touched.
#   - Does NOT commit anything; wire it into the automated-sync flow as a
#     pre-commit gate by invoking it before `git add`/`git commit`.
set -eu

cd "$(dirname "$0")/../.."

echo "[check-before-commit] fmt check..."
zig fmt --check .

echo "[check-before-commit] zig build check (type-check + plugin-template + layers)..."
zig build check

if [ "${1:-}" = "--test" ]; then
    echo "[check-before-commit] isolated test suite..."
    dev/scripts/xtest.sh zig build test
fi

echo "[check-before-commit] OK"