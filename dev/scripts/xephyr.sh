#!/bin/sh
# Xephyr :3 -screen 2560x1600 +extension RENDER -ac &
Xephyr :2 -screen 800x600 +extension RENDER -ac &
sleep 0.1
DISPLAY=:2 ./zig-out/bin/hana
