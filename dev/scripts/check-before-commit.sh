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

# Speed policy: FULL SPEED BY DEFAULT. With ZBUILD_THROTTLE=1 every step
# below (fmt, build check, modularity, tests) routes through the throttle
# wrapper dev/scripts/throttle.sh (nice + pinned cores + -j2), and the flag
# propagates to nested gates such as check-layers. Plain runs are untouched.
zb=(zig build)
fmt_cmd=(zig fmt --check .)
if [ "${ZBUILD_THROTTLE:-0}" = "1" ]; then
    zb=(dev/scripts/throttle.sh)
    fmt_cmd=(dev/scripts/throttle.sh -- zig fmt --check .)
fi

echo "[check-before-commit] fmt check..."
"${fmt_cmd[@]}"

echo "[check-before-commit] zig build check (type-check + plugin-template + layers)..."
"${zb[@]}" check

if [ "$RUN_MODULARITY" -eq 1 ]; then
    echo "[check-before-commit] feature-deletion modularity matrix..."
    "${zb[@]}" check-modularity
fi

if [ "$RUN_TEST" -eq 1 ]; then
    echo "[check-before-commit] isolated test suite..."
    dev/scripts/xtest.sh "${zb[@]}" test
fi

echo "[check-before-commit] OK"