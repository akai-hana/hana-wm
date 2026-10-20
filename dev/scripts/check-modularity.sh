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
#
# Second gate (P1-35): every Tier-1 (subsystem) and Tier-5 (bar-internal)
# scenario runs `zig build check -Doptimize=Debug` after its build, proving
# the layer rules and the plugin-template gate still hold on the reduced tree
# -- a plain compile would miss a layer violation that only appears once a
# whole subsystem is gone. Cost: +12 scenarios x ~2-4s Sema (no codegen),
# ~30-50s added to a cold matrix, near-zero on the warm per-scenario caches.

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

# Second gate (P1-35): type-check + layer rules + plugin-template against the
# reduced tree, no codegen. Always Debug (the cheap, assert-heavy profile),
# independent of -O, because the point is Sema + the layer allowlist, not a
# release link. Throttled the same way the build is.
try_check() {
    local root="$1"
    local log="$root/_check.log"
    local -a cmd=("${ZIG[@]}" check -Doptimize=Debug -j"$JOBS")
    (
        cd "$root"
        if [[ "$VERBOSE" -eq 1 ]]; then
            "${cmd[@]}" 2>&1
        else
            "${cmd[@]}" >"$log" 2>&1
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
declare -a REC_FAIL=()   # "1" = the build must FAIL (negative scenario)
declare -a REC_CHECK=()  # "1" = also run `zig build check` after the build
                         #   (P1-35, Tier 1/5: proves layer rules + the
                         #   plugin-template gate hold on the reduced tree)

# The scenario table (Tier 3/4 + the negative case) comes from build.zig's own
# discovery walk, so the matrix cannot drift from what the registries see: a
# new layout or segment file adds a row without touching this script. Fetched
# once, into an array of TSV lines.
MANIFEST=()
fetch_manifest() {
    mapfile -t MANIFEST < <(zig build modularity-manifest 2>/dev/null)
    if [[ ${#MANIFEST[@]} -eq 0 ]]; then
        echo "error: 'zig build modularity-manifest' produced no rows" >&2
        exit 1
    fi
}

tier_header() {
    REC_TYPE+=("header")
    REC_TEXT+=("$1")
    REC_NAME+=("")
    REC_PATHS+=("")
    REC_FAIL+=("")
    REC_CHECK+=("")
}

run_scenario() {
    record_scenario 0 0 "$@"
}

# Like run_scenario, but the scenario ALSO runs `zig build check` after the
# build succeeds (P1-35). Use for subsystem-level removals (Tier 1) and bar
# internals (Tier 5), where a layer violation or fmt breakage that only
# manifests once a whole subsystem is gone is exactly what a plain compile
# would miss.
run_scenario_check() {
    record_scenario 0 1 "$@"
}

# Like run_scenario, but the build is EXPECTED to fail. Used by the negative
# tier: a tree that still compiles after the deletion is the bug.
run_scenario_fail() {
    record_scenario 1 0 "$@"
}

# Record one manifest row as a scenario. Layout rows remove just the named
# file; the single-file bar segments do the same; `all_segments`/`all_tiling`
# and the group rows already carry their full path list.
emit_manifest_rows() {
    local kind="$1" row name paths
    for row in "${MANIFEST[@]}"; do
        [[ "$row" == "$kind"$'\t'* ]] || continue
        IFS=$'\t' read -r _ name paths <<< "$row"
        # shellcheck disable=SC2086  # paths is a space-joined list by design
        record_scenario 0 0 "tier34-$name" $paths
    done
}

# Record a manifest row as a build-must-FAIL scenario (negative tier).
emit_manifest_rows_fail() {
    local kind="$1" row name paths
    for row in "${MANIFEST[@]}"; do
        [[ "$row" == "$kind"$'\t'* ]] || continue
        IFS=$'\t' read -r _ name paths <<< "$row"
        # shellcheck disable=SC2086  # paths is a space-joined list by design
        record_scenario 1 0 "tier6-$name" $paths
    done
}

# Record a single named manifest row (the all-removed composites).
emit_manifest_row() {
    local kind="$1" label="$2" row name paths
    for row in "${MANIFEST[@]}"; do
        [[ "$row" == "$kind"$'\t'* ]] || continue
        IFS=$'\t' read -r _ name paths <<< "$row"
        # shellcheck disable=SC2086
        record_scenario 0 0 "$label" $paths
    done
}

record_scenario() {
    local expect_fail="$1"
    local do_check="$2"
    local name="$3"
    shift 3

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
    REC_FAIL+=("$expect_fail")
    REC_CHECK+=("$do_check")
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

    if [[ "${REC_FAIL[$i]:-0}" == "1" ]]; then
        # Negative scenario (orphan config fragment): the build is REQUIRED to
        # reject the tree, so a successful build is the failure.
        if [[ "$build_ok" -eq 0 ]]; then
            printf 'PASS\t%s\n' "$name" > "$out"
            printf "  %-55s ${GREEN}PASS${RESET} (build rejected the orphan as expected)\n" "$name"
        else
            printf 'FAIL\t%s\tbuild succeeded but should have failed\n' "$name" > "$out"
            printf "  %-55s ${RED}FAIL${RESET} (build accepted a tree it must reject)\n" "$name"
            if [[ "$VERBOSE" -ne 1 ]]; then
                printf "       ${YELLOW}last 30 lines:${RESET}\n"
                tail -30 "$dest/_build.log" 2>/dev/null | sed 's/^/       /' || true
            fi
            if [[ "$KEEP_ON_FAILURE" -ne 1 ]]; then
                rm -rf "$dest"
            fi
        fi
        return 0
    fi

    if [[ "$build_ok" -eq 1 ]]; then
        # Second gate (P1-35): the compile is proven, now prove the layer
        # rules + plugin-template still hold on the reduced tree. Only for
        # scenarios flagged with run_scenario_check, and only when the build
        # itself got that far -- a tree that fails to compile has already
        # failed, and a `check` on it would just re-report the same error.
        if [[ "${REC_CHECK[$i]:-0}" == "1" ]] && ! try_check "$dest"; then
            printf 'FAIL\t%s\tbuild ok, check failed\n' "$name" > "$out"
            printf "  %-55s ${RED}FAIL${RESET} (check: layer/plugin gate)\n" "$name"
            if [[ "$VERBOSE" -ne 1 ]]; then
                printf "       ${YELLOW}last 30 lines:${RESET}\n"
                tail -30 "$dest/_check.log" 2>/dev/null | sed 's/^/       /' || true
            fi
            if [[ "$KEEP_ON_FAILURE" -ne 1 ]]; then
                rm -rf "$dest"
            fi
            return 0
        fi
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

    run_scenario_check \
        "bar (entire subsystem)" \
        "src/bar"

    run_scenario_check \
        "tiling (entire subsystem)" \
        "src/tiling"

    # Each behavior's `*_config.zig` fragment is part of the subsystem: the
    # build fails loudly (OrphanConfigFragment) if a fragment outlives its
    # owner, so every removal path takes the pair.
    #
    # Behavior note (P1-10): with floating.zig gone there is no
    # honorConfigureRequest provider, so every managed window is tiled and
    # every ConfigureRequest is DENIED -- client_events' no-provider limb
    # must still send the ICCCM 4.1.5 synthetic ConfigureNotify echo. The
    # X-gated "denied ConfigureRequest gets a synthetic ConfigureNotify"
    # test in actions_test.zig asserts that echo against a tiled window and
    # is the same observable in this build (it is the no-provider limb that
    # produces it there).
    run_scenario_check \
        "floating (behavior module)" \
        "src/window/modules/floating.zig" \
        "src/window/modules/floating_config.zig"

    run_scenario_check \
        "vim (removable)" \
        "src/bar/modules/prompt/vim.zig"

    run_scenario_check \
        "bar + tiling (both)" \
        "src/bar" \
        "src/tiling"

    run_scenario_check \
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
        "borders (behavior module)" \
        "src/window/modules/borders.zig"

    run_scenario \
        "all behaviors" \
        "src/window/modules/floating.zig" \
        "src/window/modules/floating_config.zig" \
        "src/window/modules/fullscreen.zig" \
        "src/window/modules/minimize.zig" \
        "src/window/modules/workspaces.zig" \
        "src/window/modules/workspaces_config.zig" \
        "src/window/modules/borders.zig"

    # Tier 3: Individual tiling layouts. Derived from the same discovery walk
    # build.zig runs, so a new layout file adds a scenario on its own.
    tier_header ""
    tier_header "${CYAN}Tier 3: tiling layouts (individual removal)${RESET}"
    emit_manifest_rows layout

    run_scenario \
        "tiling layouts: -master -monocle" \
        "src/tiling/modules/master.zig" \
        "src/tiling/modules/monocle.zig"

    run_scenario \
        "tiling layouts: all removed" \
        "src/tiling/modules"

    # Tier 4: Bar segments (individual removal). The bar_segment rows list
    # exactly the BOUND sub-addons (the ones a `segmentFor(i)` entry exposes)
    # plus the whole-surface modules; multi-file surfaces are bundled so a
    # helper that only the core imports is never torn out alone.
    tier_header ""
    tier_header "${CYAN}Tier 4: bar segments (individual removal)${RESET}"
    emit_manifest_rows bar_segment

    run_scenario \
        "bar segment: -systatus package" \
        "src/bar/modules/systatus"

    run_scenario \
        "bar segment: -slider package" \
        "src/bar/modules/slider"

    emit_manifest_row all_segments "bar segment: all segments removed"

    # Tier 5: Bar internals
    tier_header ""
    tier_header "${CYAN}Tier 5: bar internals${RESET}"

    run_scenario_check \
        "bar internal: -drawing" \
        "src/bar/render/drawing.zig"

    run_scenario_check \
        "bar internal: -win" \
        "src/bar/wire/win.zig"

    run_scenario_check \
        "bar internal: -segment dispatch" \
        "src/bar/segment.zig"

    # Tier 6: negative case. Leaving a `*_config` fragment behind its owner is
    # NOT modular -- the build must refuse it, so this scenario inverts the
    # outcome: a build that SUCCEEDS here is a failure.
    tier_header ""
    tier_header "${CYAN}Tier 6: orphan fragments (must FAIL the build)${RESET}"
    emit_manifest_rows_fail orphan
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
fetch_manifest
run_scenarios

echo ""
echo "${BOLD}Building ${SCENARIO_COUNT} scenarios${RESET} (-P ${PAR}, zig -j${JOBS}, -Doptimize=${OPTIMIZE:-ReleaseFast})"

dispatch_scenarios
collect_results
print_report

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
