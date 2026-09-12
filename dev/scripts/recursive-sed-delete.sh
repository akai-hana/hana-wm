#!/bin/bash
# Invokes a sed command recursively across all files, relative from current path.

set -eu

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <search>"
  exit 1
fi

SEARCH="$1"

# Skip build artifacts so a stray run can't rewrite (or in the delete case
# corrupt) cached/binaries: .zig-cache/ and zig-out/ are derivable output.
grep -rlF -- "$SEARCH" . | grep -vE '(^|/)(\.zig-cache|zig-out)/' | while IFS= read -r file; do
  sed -i -e "\|$SEARCH|d" "$file"
  echo "Updated: $file"
done
