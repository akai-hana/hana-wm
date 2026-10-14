#!/usr/bin/env bash
# check-modularity.sh - verify feature-gated modularity
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
#   ./dev/scripts/check-modularity.sh -P 8         # scenarios building at once (default 4)
#   ./dev/scripts/check-modularity.sh -j 16        # zig build jobs per scenario (default: cores / -P)
#   ./dev/scripts/check-modularity.sh -O ReleaseFast  # prove the release profile (default Debug)
#   ./dev/scripts/check-modularity.sh --clean      # remove stale temp copies
#
# Scenario copies live under /tmp/hana-modularity-test/<scenario> and keep
# their .zig-cache between runs, so a repeat matrix only rebuilds what the
# deletion invalidated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMP_BASE="/tmp/hana-modularity-test"
RESULT_FILE=""

# colours
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'  GREEN=$'\033[0;32m'  YELLOW=$'\033[0;33m'
    CYAN=$'\033[0;36m' BOLD=$'\033[1m'      RESET=$'\033[0m'
else
    RED=""  GREEN=""  YELLOW=""  CYAN=""  BOLD=""  RESET=""
fi

# options
VERBOSE=0
KEEP_ON_FAILURE=0
PATTERN=""
JOBS=""                 # zig build jobs per scenario; "" = auto (derived below)
JOBS_SET=0
PAR=4                   # scenarios building at once (-P); 1 = serial
PAR_SET=0
# Optimize mode for the scenario builds. A bare `zig build` defaults to
# ReleaseFast (see resolveOptimize in build.zig), so every scenario was paying
# for full codegen -- ~50s each, ~25 minutes for the matrix. These builds only
# assert that a feature-deleted tree still COMPILES, which Debug proves just as
# well and far more cheaply (~6s per scenario, and the Debug run additionally
# executes the std.debug.assert coverage ReleaseFast compiles out); the release
# modes are still covered by the gate's own `zig build`. Override with
# -O ReleaseFast when the release profile itself is what needs proving.
OPTIMIZE="Debug"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=1; shift ;;
        -k|--keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
        -p|--pattern) PATTERN="$2"; shift 2 ;;
        -j|--jobs) JOBS="$2"; JOBS_SET=1; shift 2 ;;
        -P|--parallel) PAR="$2"; PAR_SET=1; shift 2 ;;
        -O|--optimize) OPTIMIZE="$2"; shift 2 ;;
        --clean) echo "Removing $TEMP_BASE"; rm -rf "$TEMP_BASE"; exit 0 ;;
        -h|--help)
            sed -n '2,/^$/{ s/^# \?//; p }' "$0"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if ! [[ "$PAR" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: -P/--parallel must be a positive integer (got '$PAR')" >&2
    exit 1
fi

# Under ZBUILD_THROTTLE=1 the whole point is to stay out of the machine's way,
# so scenario-level parallelism defaults back to serial (and the per-scenario
# -j back to the throttle's own -j2) unless the caller asked for them by hand.
if [[ "${ZBUILD_THROTTLE:-0}" == "1" ]]; then
    if [[ "$PAR_SET" -eq 0 ]]; then PAR=1; fi
    if [[ "$JOBS_SET" -eq 0 ]]; then JOBS=2; fi
fi

# Split the machine across the scenarios that are in flight instead of letting
# every one of them grab all the cores: 4 scenarios x 4 jobs on a 16-core box.
if [[ -z "$JOBS" ]]; then
    JOBS=$(( $(nproc 2>/dev/null || echo 4) / PAR ))
    if [[ "$JOBS" -lt 1 ]]; then JOBS=1; fi
fi

# setup
mkdir -p "$TEMP_BASE"
# Per-scenario result/teardown files, one per index so parallel workers never
# append to a shared file: a worker writes its single result line atomically
# and the collector reads them back in record order for the report.
RESULTS_DIR="$TEMP_BASE/.results-$$"
rm -rf "$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
SCENARIO_COUNT=0
declare -a FAILED_SCENARIOS=()
declare -a PASSED_SCENARIOS=()

# helpers

# Copy project to a temp directory. Excludes .git, build caches, and this
# script's own output to keep copies small and fast.
#
# The scenario dir is NOT wiped first: rsync --delete below already brings the
# tree in line, and because .zig-cache/ is excluded on BOTH sides, each
# scenario keeps its own cache between runs. A repeat run of the same matrix
# then only rebuilds what the deletion actually invalidated instead of paying
# a cold build again (the first run still pays full price).
setup_copy() {
    local dest="$1"
    mkdir -p "$dest"
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='.zig-cache/' \
        --exclude='zig-out/' \
        --exclude='.opencode/' \
        --exclude='*.swp*' \
        --exclude='dev/harness/out/' \
        --exclude='dev/harness/.cache/' \
        --exclude='dev/demonstration.gif' \
        "$PROJECT_ROOT/" "$dest/"
}

# Remove paths (files or directories) relative to a project copy.
# Paths starting with ! are expects; if the file doesn't exist, skip. Any
# other missing path is an error -- a scenario that names a path the tree
# no longer has is silently testing nothing, so fail loudly instead.
remove_paths() {
    local root="$1"
    shift
    for p in "$@"; do
        if [[ "$p" == '!'* ]]; then
            p="${p#!}"
            [[ -e "$root/$p" ]] || continue
        elif [[ ! -e "$root/$p" ]]; then
            echo "${RED}error: scenario path '$p' does not exist (stale scenario?)${RESET}" >&2
            return 1
        fi
        rm -rf "$root/$p"
    done
}

# Build and return 0 on success, 1 on failure.
# stdout/stderr go to a log file; on failure the log is shown.
# Speed policy: full speed by default; with ZBUILD_THROTTLE=1 each scenario
# build routes through dev/scripts/throttle.sh (nice + pinned cores), which
# also propagates the flag to nested gates. Scenario copies live outside
# the repo, so the wrapper path must be absolute and it runs in the
# scenario's cwd (-- mode does not cd).
ZIG=(zig build)
if [[ "${ZBUILD_THROTTLE:-0}" == "1" ]]; then
    ZIG=("$SCRIPT_DIR/throttle.sh" -- zig build)
fi
try_build() {
    local root="$1"
    local log="$root/_build.log"
    (
        cd "$root"
        local -a opts=(-j"$JOBS")
        if [[ -n "$OPTIMIZE" ]]; then
            opts+=("-Doptimize=$OPTIMIZE")
        fi
        if [[ "$VERBOSE" -eq 1 ]]; then
            "${ZIG[@]}" "${opts[@]}" 2>&1
        else
            "${ZIG[@]}" "${opts[@]}" >"$log" 2>&1
        fi
    )
}

# Scenario recording + execution.
#
# run_scenarios() is pure BOOKKEEPING: it records every tier header and every
# scenario in order (applying the -p filter as it goes). dispatch_scenarios()
# then EXECUTES them, PAR at a time. Splitting the two is what makes
# parallelism possible -- the scenarios are independent copies + cold builds,
# so they share no state and their order cannot matter -- while the output and
# the final report still follow the recorded (tier) order.
#
# Each recorded scenario is: name + space-joined paths relative to the project
# root. A path prefixed with ! means "expect this to exist before removing"
# (silently skip if already absent).
declare -a REC_TYPE=()   # header | scenario
declare -a REC_TEXT=()   # header text (headers only)
declare -a REC_NAME=()   # scenario name (scenarios only)
declare -a REC_PATHS=()  # removal paths, space-joined (scenarios only)

tier_header() {
    REC_TYPE+=("header")
    REC_TEXT+=("$1")
    REC_NAME+=("")
    REC_PATHS+=("")
}

run_scenario() {
    local name="$1"
    shift

    # Apply pattern filter
    if [[ -n "$PATTERN" && "$name" != *"$PATTERN"* ]]; then
        ((SKIP_COUNT++)) || true
        return 0
    fi

    # Paths are re-split on spaces when the scenario runs, so a path with
    # whitespace in it would silently be torn into two -- refuse it here
    # instead of deleting the wrong thing.
    local p
    for p in "$@"; do
        if [[ "$p" =~ [[:space:]] ]]; then
            echo "error: scenario path '$p' contains whitespace" >&2
            exit 1
        fi
    done

    REC_TYPE+=("scenario")
    REC_TEXT+=("")
    REC_NAME+=("$name")
    REC_PATHS+=("$*")
    ((SCENARIO_COUNT++)) || true
}

# Execute one recorded scenario. Writes its result to $RESULTS_DIR/<idx>.result
# FIRST (one small file per scenario, so parallel workers never append through
# each other), then prints its own result line.
#
# The copy is kept on success: its path is stable per scenario, so the next
# matrix reuses its .zig-cache instead of paying a cold build again (reclaim
# the space with --clean). On failure it is kept only under -k, as before.
execute_scenario() {
    local i="$1"
    local name="${REC_NAME[$i]}"
    local dest="$TEMP_BASE/$name"
    local lock_fd=""

    # Two matrices running at once would rsync and rm -rf the same per-scenario
    # copy under each other, so take the dest for the duration of the build.
    # flock drops the lock in the kernel if this run dies mid-build, and the
    # lock file itself is never deleted (only --clean removes it): a lock on a
    # fresh inode would not exclude anybody.
    if command -v flock &>/dev/null && exec {lock_fd}> "$dest.lock"; then
        if ! flock -w 300 "$lock_fd"; then
            printf "${YELLOW}warn:${RESET} %s: lock held >5 min, running unlocked (another matrix?)\n" "$name" >&2
            exec {lock_fd}>&- 2>/dev/null || true
            lock_fd=""
        fi
    else
        lock_fd=""
    fi

    run_one_scenario "$i" "$dest"

    if [[ -n "$lock_fd" ]]; then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&- 2>/dev/null || true
    fi
}

# The build itself: rsync the tree, apply the deletion, build, record.
run_one_scenario() {
    local i="$1"
    local dest="$2"
    local name="${REC_NAME[$i]}"
    local out="$RESULTS_DIR/$i.result"
    local -a paths=()
    read -r -a paths <<< "${REC_PATHS[$i]}"

    setup_copy "$dest"

    # A stale scenario path makes remove_paths fail: the scenario would
    # silently test nothing, so it is reported as a hard FAIL (which fails the
    # matrix) rather than aborting the run the way a bare `set -e` exit did.
    if ! remove_paths "$dest" "${paths[@]}"; then
        printf 'FAIL\t%s\tstale scenario path\n' "$name" > "$out"
        printf "  %-55s ${RED}FAIL${RESET} (remove_paths: stale path in scenario)\n" "$name"
        rm -rf "$dest"
        return 0
    fi

    local build_ok=1
    if ! try_build "$dest"; then
        build_ok=0
    fi

    if [[ "$build_ok" -eq 1 ]]; then
        printf 'PASS\t%s\n' "$name" > "$out"
        printf "  %-55s ${GREEN}PASS${RESET}\n" "$name"
    else
        printf 'FAIL\t%s\tbuild failed\n' "$name" > "$out"
        printf "  %-55s ${RED}FAIL${RESET}\n" "$name"
        # Under -v the build streamed to stdout already; otherwise keep the
        # last 30 lines of the log (tail from the worker so the context sits
        # next to its own FAIL line, not in a later report section).
        if [[ "$VERBOSE" -ne 1 ]]; then
            printf "       ${YELLOW}last 30 lines:${RESET}\n"
            tail -30 "$dest/_build.log" 2>/dev/null | sed 's/^/       /' || true
        fi
        if [[ "$KEEP_ON_FAILURE" -ne 1 ]]; then
            rm -rf "$dest"
        fi
    fi
}

# Walk the recorded matrix in order. Headers wait for the in-flight batch
# first, so every scenario of a tier is launched under that tier's header and
# its result lines appear between this header and the next -- the grouping a
# serial run had, with PAR builds running at once inside the tier.
dispatch_scenarios() {
    local i n="${#REC_TYPE[@]}"
    for ((i = 0; i < n; i++)); do
        if [[ "${REC_TYPE[$i]}" == "header" ]]; then
            wait || true
            printf '%s\n' "${REC_TEXT[$i]}"
            continue
        fi
        if [[ "$PAR" -gt 1 ]]; then
            while (( $(jobs -rp | wc -l) >= PAR )); do
                sleep 0.05
            done
            execute_scenario "$i" &
        else
            execute_scenario "$i"
        fi
    done
    wait || true
}

# Fold the per-scenario result files back into the report state, in recorded
# order, so the summary and the failed/passed lists come out in tier order no
# matter what finished first.
collect_results() {
    local i n="${#REC_TYPE[@]}" line status name note
    for ((i = 0; i < n; i++)); do
        [[ "${REC_TYPE[$i]}" == "scenario" ]] || continue
        [[ -f "$RESULTS_DIR/$i.result" ]] || continue
        IFS=$'\t' read -r status name note < "$RESULTS_DIR/$i.result"
        case "$status" in
            PASS) ((PASS_COUNT++)) || true; PASSED_SCENARIOS+=("$name") ;;
            FAIL) ((FAIL_COUNT++)) || true; FAILED_SCENARIOS+=("$name") ;;
        esac
    done
}

# test scenarios
#
# Each call:  run_scenario "name"  path1  path2  ...
#
# Paths are relative to the project root and may be files or directories.
# Prefix with ! to mean "expect this to exist before removing" (silently
# skip if already absent).

run_scenarios() {
    tier_header ""
    tier_header "${BOLD}Feature-gated modularity tests${RESET}"
    tier_header "--------------------------------"

    # Tier 1: Major subsystem removal
    tier_header ""
    tier_header "${CYAN}Tier 1: major subsystems${RESET}"

    run_scenario \
        "bar (entire subsystem)" \
        "src/bar"

    run_scenario \
        "tiling (entire subsystem)" \
        "src/tiling"

    # Each behavior's `*_config.zig` fragment is part of the subsystem: the
    # build fails loudly (OrphanConfigFragment) if a fragment outlives its
    # owner, so every removal path takes the pair.
    run_scenario \
        "floating (behavior module)" \
        "src/window/modules/floating.zig" \
        "src/window/modules/floating_config.zig"

    run_scenario \
        "vim (removable)" \
        "src/bar/modules/prompt/vim.zig"

    run_scenario \
        "bar + tiling (both)" \
        "src/bar" \
        "src/tiling"

    run_scenario \
        "bar + floating" \
        "src/bar" \
        "src/window/modules/floating.zig" \
        "src/window/modules/floating_config.zig"

    # NOTE: no "both paradigms removed" scenario: build.zig rejects a tree
    # without at least one of src/tiling/ or floating.zig (a WM must manage
    # windows), so such a configuration is invalid by contract, not modular.

    # Tier 2: Window behaviors
    tier_header ""
    tier_header "${CYAN}Tier 2: window behaviors${RESET}"

    run_scenario \
        "fullscreen (behavior module)" \
        "src/window/modules/fullscreen.zig"

    run_scenario \
        "minimize (behavior module)" \
        "src/window/modules/minimize.zig"

    run_scenario \
        "workspaces (behavior module)" \
        "src/window/modules/workspaces.zig" \
        "src/window/modules/workspaces_config.zig"

    run_scenario \
        "all behaviors" \
        "src/window/modules/floating.zig" \
        "src/window/modules/floating_config.zig" \
        "src/window/modules/fullscreen.zig" \
        "src/window/modules/minimize.zig" \
        "src/window/modules/workspaces.zig" \
        "src/window/modules/workspaces_config.zig"

    # Tier 3: Individual tiling layouts
    tier_header ""
    tier_header "${CYAN}Tier 3: tiling layouts (individual removal)${RESET}"

    local layouts=(master monocle fibonacci grid leaf scroll)
    for layout in "${layouts[@]}"; do
        run_scenario \
            "tiling layout: -$layout" \
            "src/tiling/modules/${layout}.zig"
    done

    run_scenario \
        "tiling layouts: -master -monocle" \
        "src/tiling/modules/master.zig" \
        "src/tiling/modules/monocle.zig"

    # Tier 4: Bar segments (individual removal)
    tier_header ""
    tier_header "${CYAN}Tier 4: bar segments (individual removal)${RESET}"

    run_scenario \
        "bar segment: -clock" \
        "src/bar/modules/clock.zig"

    run_scenario \
        "bar segment: -tags" \
        "src/bar/modules/tags.zig"

    run_scenario \
        "bar segment: -layout+variants" \
        "src/bar/modules/layout/layout.zig" \
        "src/bar/modules/layout/variants.zig"

    run_scenario \
        "bar segment: -title+carousel" \
        "src/bar/modules/title/title.zig" \
        "src/bar/modules/title/carousel.zig"

    run_scenario \
        "bar segment: -prompt (no vim)" \
        "src/bar/modules/prompt/prompt.zig" \
        "src/bar/modules/prompt/vim.zig"

    # Systatus readouts and slider controls are their OWN bar segments
    # (`segmentFor(i)` generated entries), so each is individually removable
    # while its package core keeps compiling the survivors.
    run_scenario \
        "bar segment: -batt (systatus sub)" \
        "src/bar/modules/systatus/batt.zig"

    run_scenario \
        "bar segment: -cpu -ram (systatus subs)" \
        "src/bar/modules/systatus/cpu.zig" \
        "src/bar/modules/systatus/ram.zig"

    run_scenario \
        "bar segment: -volume -brightness (slider subs)" \
        "src/bar/modules/slider/volume.zig" \
        "src/bar/modules/slider/brightness.zig"

    run_scenario \
        "bar segment: -systatus package" \
        "src/bar/modules/systatus"

    run_scenario \
        "bar segment: -slider package" \
        "src/bar/modules/slider"

    run_scenario \
        "bar segment: all segments removed" \
        "src/bar/modules/clock.zig" \
        "src/bar/modules/tags.zig" \
        "src/bar/modules/layout/layout.zig" \
        "src/bar/modules/layout/variants.zig" \
        "src/bar/modules/title/title.zig" \
        "src/bar/modules/title/carousel.zig" \
        "src/bar/modules/prompt/prompt.zig" \
        "src/bar/modules/prompt/vim.zig" \
        "src/bar/modules/systatus" \
        "src/bar/modules/slider"

    # Tier 5: Bar internals
    tier_header ""
    tier_header "${CYAN}Tier 5: bar internals${RESET}"

    run_scenario \
        "bar internal: -drawing" \
        "src/bar/render/drawing.zig"

    run_scenario \
        "bar internal: -win" \
        "src/bar/wire/win.zig"

    run_scenario \
        "bar internal: -segment dispatch" \
        "src/bar/segment.zig"
}

# report

print_report() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))

    echo ""
    echo "--------------------------------"
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

# main

cd "$PROJECT_ROOT"

if ! command -v zig &>/dev/null; then
    echo "Error: zig not found in PATH" >&2
    exit 1
fi

# Record the matrix, then build it (PAR at a time), then fold the per-scenario
# results back into the report state.
run_scenarios

echo ""
echo "${BOLD}Building ${SCENARIO_COUNT} scenarios${RESET} (-P ${PAR}, zig -j${JOBS}, -Doptimize=${OPTIMIZE:-ReleaseFast})"

dispatch_scenarios
collect_results
print_report

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
