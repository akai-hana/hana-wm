#!/usr/bin/env bash
# check-modularity.sh — verify feature-gated modularity
#
# Tests that hana compiles cleanly when optional subsystems are removed.
# For each scenario, a fresh copy of the project is built with specific
# source files/directories deleted. A pass means the build succeeded; a
# fail means it didn't.
#
# Exit code: 0 if all scenarios pass, 1 if any fail.
#
# Usage:
#   ./dev/scripts/check-modularity.sh              # run all scenarios
#   ./dev/scripts/check-modularity.sh -v           # verbose (show build output)
#   ./dev/scripts/check-modularity.sh -p "bar"     # only run scenarios matching pattern
#   ./dev/scripts/check-modularity.sh -k           # keep temp copies on failure
#   ./dev/scripts/check-modularity.sh --clean      # remove stale temp copies

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMP_BASE="/tmp/hana-modularity-test"
RESULT_FILE=""

# ── colours ──────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
    RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

# ── options ──────────────────────────────────────────────────────────────
VERBOSE=0
KEEP_ON_FAILURE=0
PATTERN=""
JOBS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -k|--keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
        -p|--pattern) PATTERN="$2"; shift 2 ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        --clean) echo "Removing $TEMP_BASE"; rm -rf "$TEMP_BASE"; exit 0 ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── setup ────────────────────────────────────────────────────────────────
mkdir -p "$TEMP_BASE"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
declare -a FAILED_SCENARIOS=()
declare -a PASSED_SCENARIOS=()

# ── helpers ──────────────────────────────────────────────────────────────

# Copy project to a temp directory. Excludes .git, build caches, and this
# script's own output to keep copies small and fast.
setup_copy() {
    local dest="$1"
    rm -rf "$dest"
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='.zig-cache/' \
        --exclude='zig-out/' \
        --exclude='dev/harness/out/' \
        --exclude='dev/harness/.cache/' \
        "$PROJECT_ROOT/" "$dest/"
}

# Remove paths (files or directories) relative to a project copy.
# Paths starting with ! are expects — if the file doesn't exist, skip.
remove_paths() {
    local root="$1"
    shift
    for p in "$@"; do
        if [[ "$p" == '!'* ]]; then
            p="${p#!}"
            [[ -e "$root/$p" ]] || continue
        fi
        rm -rf "$root/$p"
    done
}

# Build and return 0 on success, 1 on failure.
# stdout/stderr go to a log file; on failure the log is shown.
try_build() {
    local root="$1"
    local log="$root/_build.log"
    (
        cd "$root"
        if [[ "$VERBOSE" -eq 1 ]]; then
            zig build 2>&1
        else
            zig build >"$log" 2>&1
        fi
    )
}

# Run a single scenario.
#   $1 = scenario name
#   $2 = space-separated list of relative paths to remove
run_scenario() {
    local name="$1"
    shift
    local paths=("$@")

    # Apply pattern filter
    if [[ -n "$PATTERN" && "$name" != *"$PATTERN"* ]]; then
        return 0
    fi

    local dest="$TEMP_BASE/$name"
    setup_copy "$dest"
    remove_paths "$dest" "${paths[@]}"

    printf "  %-55s " "$name"

    local build_ok=1
    if ! try_build "$dest"; then
        build_ok=0
    fi

    if [[ "$build_ok" -eq 1 ]]; then
        printf "${GREEN}PASS${RESET}\n"
        PASSED_SCENARIOS+=("$name")
        ((PASS_COUNT++)) || true
    else
        printf "${RED}FAIL${RESET}\n"
        FAILED_SCENARIOS+=("$name")
        ((FAIL_COUNT++)) || true
        if [[ "$VERBOSE" -ne 1 ]]; then
            printf "       ${YELLOW}last 30 lines:${RESET}\n"
            tail -30 "$dest/_build.log" | sed 's/^/       /'
        fi
    fi

    if [[ "$KEEP_ON_FAILURE" -ne 1 || "$build_ok" -eq 1 ]]; then
        rm -rf "$dest"
    fi
}

# ── test scenarios ───────────────────────────────────────────────────────
#
# Each call:  run_scenario "name"  path1  path2  ...
#
# Paths are relative to the project root and may be files or directories.
# Prefix with ! to mean "expect this to exist before removing" (silently
# skip if already absent).

run_scenarios() {
    echo ""
    echo "${BOLD}Feature-gated modularity tests${RESET}"
    echo "──────────────────────────────"

    # ── Tier 1: Major subsystem removal ─────────────────────────────────
    echo ""
    echo "${CYAN}Tier 1 — major subsystems${RESET}"

    run_scenario \
        "bar (entire subsystem)" \
        "src/bar"

    run_scenario \
        "tiling (entire subsystem)" \
        "src/tiling"

    run_scenario \
        "floating (behavior module)" \
        "src/window/behaviors/floating.zig"

    run_scenario \
        "vim (removable)" \
        "src/bar/segments/prompt/vim.zig"

    run_scenario \
        "bar + tiling (both)" \
        "src/bar" \
        "src/tiling"

    run_scenario \
        "bar + floating" \
        "src/bar" \
        "src/window/behaviors/floating.zig"

    run_scenario \
        "tiling + floating" \
        "src/tiling" \
        "src/window/behaviors/floating.zig"

    run_scenario \
        "everything optional (bar+tiling+floating)" \
        "src/bar" \
        "src/tiling" \
        "src/window/behaviors/floating.zig"

    # ── Tier 2: Window behaviors ────────────────────────────────────────
    echo ""
    echo "${CYAN}Tier 2 — window behaviors${RESET}"

    run_scenario \
        "fullscreen (behavior module)" \
        "src/window/behaviors/fullscreen.zig"

    run_scenario \
        "minimize (behavior module)" \
        "src/window/behaviors/minimize.zig"

    run_scenario \
        "workspaces (behavior module)" \
        "src/window/behaviors/workspaces.zig"

    run_scenario \
        "all behaviors" \
        "src/window/behaviors/floating.zig" \
        "src/window/behaviors/fullscreen.zig" \
        "src/window/behaviors/minimize.zig" \
        "src/window/behaviors/workspaces.zig"

    # ── Tier 3: Individual tiling layouts ───────────────────────────────
    echo ""
    echo "${CYAN}Tier 3 — tiling layouts (individual removal)${RESET}"

    local layouts=(master monocle fibonacci grid leaf scroll)
    for layout in "${layouts[@]}"; do
        run_scenario \
            "tiling layout: -$layout" \
            "src/tiling/layouts/${layout}.zig"
    done

    run_scenario \
        "tiling layouts: -master -monocle" \
        "src/tiling/layouts/master.zig" \
        "src/tiling/layouts/monocle.zig"

    # ── Tier 4: Bar segments (individual removal) ───────────────────────
    echo ""
    echo "${CYAN}Tier 4 — bar segments (individual removal)${RESET}"

    run_scenario \
        "bar segment: -clock" \
        "src/bar/segments/clock.zig"

    run_scenario \
        "bar segment: -tags" \
        "src/bar/segments/tags.zig"

    run_scenario \
        "bar segment: -layout+variants" \
        "src/bar/segments/layout/layout.zig" \
        "src/bar/segments/layout/variants.zig"

    run_scenario \
        "bar segment: -title+carousel" \
        "src/bar/segments/title/title.zig" \
        "src/bar/segments/title/carousel.zig"

    run_scenario \
        "bar segment: -prompt (no vim)" \
        "src/bar/segments/prompt/prompt.zig" \
        "src/bar/segments/prompt/vim.zig"

    run_scenario \
        "bar segment: all segments removed" \
        "src/bar/segments/clock.zig" \
        "src/bar/segments/tags.zig" \
        "src/bar/segments/layout/layout.zig" \
        "src/bar/segments/layout/variants.zig" \
        "src/bar/segments/title/title.zig" \
        "src/bar/segments/title/carousel.zig" \
        "src/bar/segments/prompt/prompt.zig" \
        "src/bar/segments/prompt/vim.zig"

    # ── Tier 5: Bar internals ───────────────────────────────────────────
    echo ""
    echo "${CYAN}Tier 5 — bar internals${RESET}"

    run_scenario \
        "bar internal: -drawing" \
        "src/bar/drawing.zig"

    run_scenario \
        "bar internal: -render" \
        "src/bar/render.zig"

    run_scenario \
        "bar internal: -win" \
        "src/bar/win.zig"

    run_scenario \
        "bar internal: -segment dispatch" \
        "src/bar/segments/segment.zig"
}

# ── report ───────────────────────────────────────────────────────────────

print_report() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

    echo ""
    echo "──────────────────────────────"
    echo "${BOLD}Results${RESET}: ${GREEN}${PASS_COUNT} passed${RESET}, ${RED}${FAIL_COUNT} failed${RESET}, ${SKIP_COUNT} skipped (${total} total)"
    echo ""

    if [[ ${#FAILED_SCENARIOS[@]} -gt 0 ]]; then
        echo "${RED}Failed scenarios:${RESET}"
        for s in "${FAILED_SCENARIOS[@]}"; do
            printf "  - %s\n" "$s"
        done
        echo ""
    fi

    if [[ ${#PASSED_SCENARIOS[@]} -gt 0 && "$VERBOSE" -eq 1 ]]; then
        echo "${GREEN}Passed scenarios:${RESET}"
        for s in "${PASSED_SCENARIOS[@]}"; do
            printf "  - %s\n" "$s"
        done
        echo ""
    fi
}

# ── main ─────────────────────────────────────────────────────────────────

cd "$PROJECT_ROOT"

if ! command -v zig &>/dev/null; then
    echo "Error: zig not found in PATH" >&2
    exit 1
fi

run_scenarios
print_report

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
