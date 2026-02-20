#!/bin/sh
# Sequentially pipe all files inside dev/files/ onto dev/codebase/.
# The purpose of this is to be able to write and replace files more easily.

mkdir -p dev/files
mkdir -p dev/codebase

dev/scripts/single-dir.sh

set -eu

FILES_DIR="dev/files"
CODE_DIR="dev/codebase"
DL_ZIP1="$HOME/Downloads/files.zip"
DL_ZIP2="$HOME/parallel/Downloads/files.zip"
TARGET_ZIP="$FILES_DIR/files.zip"

# Preconditions (don't create anything)
if [ ! -d "$FILES_DIR" ]; then
  echo "Error: $FILES_DIR does not exist" >&2
  exit 1
fi

if [ ! -d "$CODE_DIR" ]; then
  echo "Error: $CODE_DIR does not exist" >&2
  exit 1
fi

# Choose download source: first try ~/Downloads, then ~/parallel/Downloads
SOURCE=""
if [ -f "$DL_ZIP1" ]; then
  SOURCE="$DL_ZIP1"
elif [ -f "$DL_ZIP2" ]; then
  SOURCE="$DL_ZIP2"
fi

# Move if a download was found
if [ -n "$SOURCE" ]; then
  mv "$SOURCE" "$TARGET_ZIP"
fi

if [ ! -f "$TARGET_ZIP" ]; then
  echo "Error: no files.zip found in $FILES_DIR or in ~/Downloads or ~/parallel/Downloads" >&2
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

# Helper to write a source file to a destination basename in CODE_DIR
write_to_codebase() {
  src="$1"
  dest_basename="$2"
  cat "$src" > "$CODE_DIR/$dest_basename"
  rm -f "$src"
}

# Helper to drop text/markdown files
maybe_drop_text() {
  case "$1" in
    *.txt|*.md)
      rm -f "$1"
      return 0
      ;;
  esac
  return 1
}

# Process all files (including those with .fixed suffix)
for f in "$FILES_DIR"/* "$FILES_DIR"/.*; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in
    .|..) continue ;;
  esac
  [ -f "$f" ] || continue

  maybe_drop_text "$f" && continue

  bn="$(basename "$f")"

  # Remove .fixed suffix if present (but keep the original extension)
  bn_no_fixed="${bn%.fixed}"

  # Remove any occurrence of "_improved" and "_optimized" inside the basename (POSIX-safe)
  dest="$(printf '%s' "$bn_no_fixed" | sed 's/_improved//g; s/_optimized//g')"

  # If dest ends up empty for some weird reason, fall back to the original basename
  if [ -z "$dest" ]; then
    dest="$bn_no_fixed"
  fi

  write_to_codebase "$f" "$dest"
done

zig build -freference-trace=20 --color on 2>&1 | sed -E '/failed command:/,/Build Summary:/d'
