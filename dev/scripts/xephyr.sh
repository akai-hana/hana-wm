#!/bin/sh
# Xephyr :3 -screen 2560x1600 +extension RENDER -ac &
Xephyr :3 -screen 800x600 +extension RENDER -ac &
sleep 0.1
DISPLAY=:3 ./zig-out/bin/hana
