#!/bin/sh
echo "ls"
ls

echo "tree src"
tree src

find ./src -type f -name "*.zig" | while read -r file; do
    echo "=== Printing file "$file" ==="
    cat "$file"
    echo ""
done

zig version
