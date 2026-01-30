#!/bin/sh
Xephyr :1 -screen 854x480 +extension RENDER -ac &
sleep 0.5
DISPLAY=:1 ./zig-out/bin/hana
