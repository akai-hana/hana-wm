#!/bin/sh
# Xephyr :3 -screen 2560x1600 +extension RENDER -ac &
Xephyr :4 -screen 1920x1000 +extension RENDER -ac &
sleep 0.1
DISPLAY=:4 ./zig-out/bin/hana
