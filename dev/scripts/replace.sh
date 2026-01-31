#!/bin/sh
# Sequentially pipe all files inside dev/files/ onto dev/codebase/.
# The purpose of this is to be able to write and replace files more easily.

# Handle files.zip download
mv ~/Downloads/files.zip ./dev/files
unzip ./dev/files/files.zip ./dev/files/.
rm ./dev/files/files.zip
mv ./dev/files/files/* ./dev/files
rmdir ./dev/files/files

# Sequentially pipe each file into codebase
for f in dev/files/*; do
  [ -f "$f" ] || continue
  cat "$f" > "dev/codebase/$(basename "$f")"
  doas rm "$f" # Once done with it, remove it
done

