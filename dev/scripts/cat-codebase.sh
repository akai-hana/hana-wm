#!/bin/sh
echo "ls src"
ls src

echo "tree src"
tree src

find ./src -type f -name "*.zig" | while read -r file; do
    echo "Printing file "$file""
    cat "$file"
    echo ""
done

zig version
