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
#   HANA_REQUIRE_X        forced to 1 by default here (fixture fail-mode): the
#                         whole point of this wrapper is that X IS available, so
#                         X-gated tests must not silently skip and pass. Set it
#                         to 0 to override.
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

XTEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hana-xtest.XXXXXX")" || { echo "xtest: mktemp failed" >&2; exit 1; }

Xvfb ":$display" -screen 0 1280x800x24 -nolisten tcp -ac >"$XTEST_TMP/xvfb_${display}.log" 2>&1 &
xvfb_pid=$!

cleanup() {
    kill "$xvfb_pid" 2>/dev/null
    wait "$xvfb_pid" 2>/dev/null
    rm -rf "$XTEST_TMP"
}
trap cleanup EXIT INT TERM

# Wait until the server is actually ANSWERING, not merely socket-present: the
# socket file can appear before the server accepts connections, and a child
# that connects too early fails -- or silently skips its X-gated tests. Poll
# `xset q`, fail hard on timeout, and bail early (with the log) if Xvfb died.
ready=0
for _ in $(seq 1 100); do
    if DISPLAY=":$display" xset q >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$xvfb_pid" 2>/dev/null; then
        echo "xtest: Xvfb :$display exited during startup" >&2
        cat "$XTEST_TMP/xvfb_${display}.log" >&2
        exit 1
    fi
    sleep 0.1
done
if [ "$ready" != "1" ]; then
    echo "xtest: Xvfb :$display did not become ready in time" >&2
    cat "$XTEST_TMP/xvfb_${display}.log" >&2
    exit 1
fi

export DISPLAY=":$display"
# X is guaranteed up: make X-gated tests assert rather than skip.
export HANA_REQUIRE_X="${HANA_REQUIRE_X:-1}"
"$@"
exit $?