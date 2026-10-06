#!/bin/bash
# Invokes a sed command recursively across all files, relative from current path.

set -eu

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <search> <replace>"
  exit 1
fi

SEARCH="$1"
REPLACE="$2"

# Skip build artifacts so a stray run can't rewrite cached/binaries:
# .zig-cache/ and zig-out/ are derivable output.
# The substitute's delimiter must be absent from both operands, or the render
# collapses them together (a search containing `|` is the alternation it IS; a
# fork replacing `|` in REPLACE ate the point of ERE). Pick one absent from
# both, and escape the replacement's sed-meta characters.
delim="|"
for d in "|" "#" "@" "%" "!"; do
  case "$SEARCH$REPLACE" in
    *"$d"*) ;;   # collision between operand and delimiter
    *) delim="$d"; break ;;
  esac
done
case "$SEARCH$REPLACE" in
  *"$delim"*) echo "Refusing: no `s` delimiter separates the operands" >&2; exit 1 ;;
esac
REP_ESC="$(printf '%s' "$REPLACE" | sed 's/\\/\\\\/g; s/&/\\&/g')"
grep -rlE -- "$SEARCH" . | grep -vE '(^|/)(\.zig-cache|zig-out)/' | while IFS= read -r file; do
  sed -i -E "s${delim}${SEARCH}${delim}${REP_ESC}${delim}g" "$file"
  echo "Updated: $file"
done
