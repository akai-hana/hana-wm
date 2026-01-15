#!/bin/sh
find ./src -type f -name "*.zig" | while read -r file; do
    echo "=== Printing file "$file" ==="
    cat "$file"
    echo ""
done
