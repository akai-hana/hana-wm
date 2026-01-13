#!/bin/sh
Xephyr -ac -screen 1280x720 -br -reset -dpi 256 :1 &
sleep 0.5
DISPLAY=:1 ./zig-out/bin/hana
