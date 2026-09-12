#!/usr/bin/env bash
# xtest.sh — Run any test command against an isolated Xvfb display.
#
# WHY THIS EXISTS
#   hana runs on the developer's real display (currently :0). A bare `zig build
#   test` makes the X-gated engine tests connect to that display, briefly grab
#   substructure-redirect/focus, and steal focus from the running hana session.
#   This wrapper starts its OWN Xvfb, exports DISPLAY onto it, runs the command
#   there, then tears the server down — so tests never touch the live session.
#
#   ALWAYS run the test suite through this wrapper
#       dev/scripts/xtest.sh zig build test
#   Never run `zig build test` (or `zig build run`) bare on a machine that has
#   a live hana session.
#
# USAGE
#   dev/scripts/xtest.sh <command...>
#
# ENV
#   XTEST_DISPLAY_RANGE  space-separated display numbers to probe (default "99 100 ... 199")
#   HANA_REQUIRE_X        passed straight through to the child (fixture fail-mode)
#
# Exit code is the child's exit code.
set -u

DISPLAYS="${XTEST_DISPLAY_RANGE:-$(seq 99 199)}"

free_display() {
    local display
    for display in $DISPLAYS; do
        if [ ! -e "/tmp/.X11-unix/X${display}" ] && ! pgrep -f "Xvfb :${display} " >/dev/null 2>&1; then
            echo "$display"
            return 0
        fi
    done
    return 1
}

display="$(free_display)" || { echo "xtest: no free display in range '$DISPLAYS'" >&2; exit 1; }

Xvfb ":$display" -screen 0 1280x800x24 -nolisten tcp -ac >"/tmp/opencode/xvfb_${display}.log" 2>&1 &
xvfb_pid=$!

cleanup() {
    kill "$xvfb_pid" 2>/dev/null
    wait "$xvfb_pid" 2>/dev/null
}
trap cleanup EXIT INT TERM

# Wait until the socket is ready (bounded wait).
for _ in $(seq 1 50); do
    [ -e "/tmp/.X11-unix/X${display}" ] && break
    sleep 0.1
done

export DISPLAY=":$display"
"$@"
exit $?