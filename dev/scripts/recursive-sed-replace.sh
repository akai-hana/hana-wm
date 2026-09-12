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
grep -rlE "$SEARCH" . | grep -vE '(^|/)(\.zig-cache|zig-out)/' | while IFS= read -r file; do
  sed -i -E "s|$SEARCH|$REPLACE|g" "$file"
  echo "Updated: $file"
done
