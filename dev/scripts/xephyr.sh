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

# Wait for the X server to actually come up (poll for its unix socket).
i=0
while [ ! -S "$SOCKET" ]; do
    i=$((i + 1))
    if [ "$i" -ge 200 ]; then # ~10s cap
        echo "Xephyr did not create $SOCKET in time" >&2
        exit 1
    fi
    sleep 0.05
done

# Keep the run line on the same display the server was started with above.
DISPLAY=":$DISPLAY_NUM" ./zig-out/bin/hana
