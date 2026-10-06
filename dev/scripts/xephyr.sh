#!/bin/sh
# Xephyr smoke-test display: starts Xephyr on :5, waits for it to be ready,
# runs hana against it, and tears the server down when hana exits (or on
# Ctrl-C / failure).
set -e

DISPLAY_NUM=5
SOCKET="/tmp/.X11-unix/X$DISPLAY_NUM"

Xephyr ":$DISPLAY_NUM" -screen 800x600 +extension RENDER -ac &
XEPHYR_PID=$!

cleanup() {
    if kill -0 "$XEPHYR_PID" 2>/dev/null; then
        kill "$XEPHYR_PID" 2>/dev/null || true
        wait "$XEPHYR_PID" 2>/dev/null || true
    fi
}
trap cleanup INT TERM EXIT

# Wait for the X server to actually answer (socket file alone is enough on a
# fresh boot but immediately true on a stale /tmp/.X11-unix/X5 from a previous
# run, which routed us to the dead server). `xset q` is the same probe xtest
# uses and bails the whole script when the display never comes up.
ready=0
i=0
while [ "$ready" != "1" ]; do
    i=$((i + 1))
    if [ "$i" -ge 100 ]; then # ~10s cap at 0.1s
        echo "Xephyr did not accept connections on :$DISPLAY_NUM in time" >&2
        exit 1
    fi
    if DISPLAY=":$DISPLAY_NUM" xset q >/dev/null 2>&1; then
        ready=1
    fi
    sleep 0.1
done

# The binary path below is given relative to the repo root; a caller running
# this from a different cwd would launch (or miss) the wrong one.
cd "$(dirname "$0")/../.."
DISPLAY=":$DISPLAY_NUM" ./zig-out/bin/hana
