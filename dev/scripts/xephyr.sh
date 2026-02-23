#!/bin/sh
# Xephyr :2 -screen 960x540 +extension RENDER -ac &
Xephyr :1 -screen 1920x1000 +extension RENDER -ac &
# Xephyr :1 -screen 1920x1040 +extension RENDER -ac &
sleep 0.5
DISPLAY=:1 ./zig-out/bin/hana
