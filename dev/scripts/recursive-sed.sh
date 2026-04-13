#!/bin/bash
# Invokes a sed command recursively across all files, relative from current path.

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <search> <replace>"
  exit 1
fi

SEARCH="$1"
REPLACE="$2"

grep -rlE "$SEARCH" . | while read -r file; do
  sed -i '' -E "s|$SEARCH|$REPLACE|g" "$file"
  echo "Updated: $file"
done
