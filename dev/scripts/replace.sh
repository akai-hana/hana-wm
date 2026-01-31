#!/bin/sh
# Sequentially pipe all files inside dev/files/ onto dev/codebase/.
# The purpose of this is to be able to write and replace files more easily.

set -eu

FILES_DIR="dev/files"
CODE_DIR="dev/codebase"
DL_ZIP="$HOME/Downloads/files.zip"
TARGET_ZIP="$FILES_DIR/files.zip"

# Preconditions
if [ ! -d "$FILES_DIR" ]; then
  echo "Error: $FILES_DIR does not exist" >&2
  exit 1
fi

if [ ! -d "$CODE_DIR" ]; then
  echo "Error: $CODE_DIR does not exist" >&2
  exit 1
fi

# Handle files.zip download
if [ -f "$DL_ZIP" ]; then
  mv "$DL_ZIP" "$TARGET_ZIP"
fi

if [ ! -f "$TARGET_ZIP" ]; then
  echo "Error: no files.zip found in $FILES_DIR or ~/Downloads" >&2
  exit 1
fi

# Extract into dev/files
unzip -o "$TARGET_ZIP" -d "$FILES_DIR"
rm -f "$TARGET_ZIP"

# If archive created dev/files/files/, flatten it
if [ -d "$FILES_DIR/files" ]; then
  for item in "$FILES_DIR/files/"* "$FILES_DIR/files/".*; do
    [ -e "$item" ] || continue
    case "$(basename "$item")" in
      .|..) continue ;;
    esac
    mv "$item" "$FILES_DIR/"
  done
  rmdir "$FILES_DIR/files" || true
fi

# Pipe each file into codebase, then remove it
for f in "$FILES_DIR"/*; do
  [ -f "$f" ] || continue
  cat "$f" > "$CODE_DIR/$(basename "$f")"
  doas rm -f "$f"
done

