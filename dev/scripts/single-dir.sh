#!/bin/sh
# Hard links all codebase files recursively onto a single dir (dev/codebase/).

rm -r dev/codebase > /dev/null 2>&1 # Silence output error in case dev/codebase doesn't exist
mkdir dev/codebase
find src/ -type f -name '*.zig' -exec ln {} dev/codebase/ \;
