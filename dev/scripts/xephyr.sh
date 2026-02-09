#!/bin/sh
# Xephyr :2 -screen 960x540 +extension RENDER -ac &
Xephyr :2 -screen 1620x880 +extension RENDER -ac &
sleep 0.5
DISPLAY=:2 ./zig-out/bin/hana
