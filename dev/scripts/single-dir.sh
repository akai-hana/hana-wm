#!/bin/sh

# The purpose of this script is to hard link all files onto a single dir,
# for easier access to the entire codebase, without having to deal with directory
# structuring (as it isn't really necessary and only serves aesthetic purposes)

doas rm -r dev/codebase
mkdir dev/codebase
find src/ -type f -name '*.zig' -exec ln {} dev/codebase/ \;
