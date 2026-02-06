#!/bin/sh
Xephyr :1 -screen 960x540 +extension RENDER -ac &
sleep 0.5
DISPLAY=:1 ./zig-out/bin/hana
