#!/bin/bash
# Invokes a sed command recursively across all files, relative from current path.

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <search>"
  exit 1
fi

SEARCH="$1"

grep -rlF -- "$SEARCH" . | while read -r file; do
  sed -i '' -e "\|$SEARCH|d" "$file"
  echo "Updated: $file"
done
