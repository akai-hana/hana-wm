#!/usr/bin/env bash
# Dev-only throttle wrapper for the hana dev gates.
#
# FULL SPEED IS THE DEFAULT everywhere: plain `zig build`, and every gate
# script (check-before-commit, check-layers, check-modularity), run
# unthrottled unless explicitly asked otherwise. "Otherwise" goes through
# this script, two ways:
#
#   dev/scripts/zbuild.sh [args...]     `zig build`, throttled
#   dev/scripts/zbuild.sh -- <cmd...>   ANY command, throttled (runs in the
#                                       caller's cwd; e.g. gate scripts that
#                                       need their own working directory)
#   ZBUILD_THROTTLE=1 <gate script>     the gate routes every zig build / fmt
#                                       step through this wrapper itself
#
# Throttled runs export ZBUILD_THROTTLE=1 so nested gate steps (e.g.
# check-layers inside `zig build check`) inherit the throttle. Kill switch:
# ZBUILD_THROTTLE=0 forces plain full speed even through this wrapper.
#
# USER/PRODUCTION BUILDS never touch this wrapper: plain `zig build` is
# unchanged, full speed.
#
# Overrides:
#   ZBUILD_CPUS="6,7"    CPUs to pin to (default: last two logical CPUs)
#   ZBUILD_JOBS=4        parallel jobs  (default: 2)
#   ZBUILD_NICE=10       nice value     (default: 19, idle priority)
set -eu

nice_val="${ZBUILD_NICE:-19}"
jobs="${ZBUILD_JOBS:-2}"

cpus="${ZBUILD_CPUS:-}"
if [ -z "$cpus" ]; then
    n="$(nproc)"
    if [ "$n" -ge 4 ]; then
        cpus="$((n - 2)),$((n - 1))"
    elif [ "$n" -ge 2 ]; then
        cpus="0"
    fi
fi

throttle() {
    if [ -n "$cpus" ]; then
        exec nice -n "$nice_val" taskset -c "$cpus" "$@"
    else
        exec nice -n "$nice_val" "$@"
    fi
}

# Generic mode: run any command throttled, in the caller's cwd (no cd —
# gate scripts build staged copies outside the repo).
if [ "${1:-}" = "--" ]; then
    shift
    if [ "${ZBUILD_THROTTLE:-1}" = "0" ]; then
        export ZBUILD_THROTTLE=0
        exec "$@"
    fi
    export ZBUILD_THROTTLE=1
    printf 'zbuild: throttled %s (nice %s, cpus %s)\n' \
        "${1:-?}" "$nice_val" "${cpus:-any}" >&2
    throttle "$@"
fi

# zig-build mode: resolve everything relative to the repo root.
cd "$(dirname "$0")/../.."

if [ "${ZBUILD_THROTTLE:-1}" = "0" ]; then
    export ZBUILD_THROTTLE=0
    exec zig build "$@"
fi

export ZBUILD_THROTTLE=1
printf 'zbuild: throttled build (nice %s, jobs %s, cpus %s)\n' \
    "$nice_val" "$jobs" "${cpus:-any}" >&2
throttle zig build -j"$jobs" "$@"
