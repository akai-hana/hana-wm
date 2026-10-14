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
# Match with the SAME semantics on both sides: a literal-string grep paired
# with a regex-match sed line filter once deleted the wrong lines wherever the
# pattern contained a metacharacter. Both sides are ERE now. Also escape `/`
# along the sed address-side delimiter anti-collision.
SEARCH_SED="${SEARCH//\//\\/}"
grep -rlE -- "$SEARCH" . | grep -vE '(^|/)(\.zig-cache|zig-out)/' | while IFS= read -r file; do
  sed -i -E "/$SEARCH_SED/d" "$file"
  echo "Updated: $file"
done
