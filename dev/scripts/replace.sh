#!/usr/bin/env bash
# Script to replace .zig files from ./dev/files to ./dev/codebase
# Tries same-relative-path first, then falls back to recursive basename matches.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

SOURCE_DIR="./dev/files"
TARGET_DIR="./dev/codebase"

REPLACED=0
SKIPPED=0
ERRORS=0

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  .zig File Replacement Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Source: ${GREEN}${SOURCE_DIR}${NC}"
echo -e "Target: ${GREEN}${TARGET_DIR}${NC}"
echo ""

if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}Error: Source directory '$SOURCE_DIR' does not exist!${NC}"
    exit 1
fi
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}Error: Target directory '$TARGET_DIR' does not exist!${NC}"
    exit 1
fi

# Simple CLI: -n/--dry-run
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        *) echo "Unknown option: $1"; exit 2 ;;
    esac
done

SOURCE_DIR_ABS=$(cd "$SOURCE_DIR" && pwd -P)
TARGET_DIR_ABS=$(cd "$TARGET_DIR" && pwd -P)

ZIG_COUNT=$(find "$SOURCE_DIR_ABS" -type f -name "*.zig" -print | wc -l)
ZIG_COUNT=${ZIG_COUNT:-0}

if [ "$ZIG_COUNT" -eq 0 ]; then
    echo -e "${YELLOW}Warning: No .zig files found in $SOURCE_DIR${NC}"
    exit 0
fi

echo -e "${BLUE}Found ${ZIG_COUNT} .zig file(s) in source directory${NC}"
echo ""

if [ $DRY_RUN -eq 1 ]; then
    echo -e "${YELLOW}DRY RUN MODE - No files will be modified${NC}"
    echo ""
else
    echo -e "${YELLOW}This will replace files in $TARGET_DIR${NC}"
    echo -e "${BLUE}Using redirects to preserve hard links${NC}"
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Aborted.${NC}"
        exit 0
    fi
    echo ""
fi

# Helper: perform replacement of one target file from one source file
replace_one() {
    local src="$1"
    local tgt="$2"
    local rel="$3"   # printable relative path for messages

    if [ $DRY_RUN -eq 1 ]; then
        echo -e "${BLUE}→${NC} ${rel} - ${BLUE}would replace${NC} $tgt"
        return 0
    fi

    # unique backup name (epoch + nanoseconds)
    local ts; ts=$(date +%Y%m%d_%H%M%S_%N)
    local backup="${tgt}.backup.${ts}"

    if ! cat "$tgt" > "$backup" 2>/dev/null; then
        echo -e "${RED}✗${NC} ${rel} - ${RED}failed to create backup for${NC} $tgt"
        ((ERRORS++))
        return 1
    fi

    if ! cat "$src" > "$tgt" 2>/dev/null; then
        echo -e "${RED}✗${NC} ${rel} - ${RED}failed to write to${NC} $tgt"
        rm -f "$backup" 2>/dev/null || true
        ((ERRORS++))
        return 1
    fi

    echo -e "${GREEN}✓${NC} ${rel} - ${GREEN}replaced${NC} $tgt"
    echo -e "  ${BLUE}Backup:${NC} $backup"
    ((REPLACED++))
    return 0
}

# Iterate all source files safely (-print0)
while IFS= read -r -d '' srcfile; do
    rel_path="${srcfile#$SOURCE_DIR_ABS/}"
    filename=$(basename "$srcfile")

    # 1) Try same relative path in target
    tgt_same="$TARGET_DIR_ABS/$rel_path"
    if [ -f "$tgt_same" ]; then
        replace_one "$srcfile" "$tgt_same" "$rel_path" || true
        continue
    fi

    # 2) Fallback: recursive basename search and replace ALL matches
    mapfile -d '' -t matches < <(find "$TARGET_DIR_ABS" -type f -name "$filename" -print0 2>/dev/null || true)

    if [ "${#matches[@]}" -eq 0 ]; then
        echo -e "${YELLOW}⊘${NC} ${rel_path} - ${YELLOW}not found in target (skipping)${NC}"
        ((SKIPPED++))
        continue
    fi

    # Replace every matching target found
    for m in "${matches[@]}"; do
        # For user output print the target relative to target dir if possible
        pretty_rel="${m#$TARGET_DIR_ABS/}"
        replace_one "$srcfile" "$m" "$pretty_rel" || true
    done

done < <(find "$SOURCE_DIR_ABS" -type f -name "*.zig" -print0)

# Summary
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"
if [ $DRY_RUN -eq 1 ]; then
    echo -e "${BLUE}Dry run completed${NC}"
else
    echo -e "${GREEN}Replaced:${NC} $REPLACED"
    echo -e "${YELLOW}Skipped:${NC}  $SKIPPED"
    echo -e "${RED}Errors:${NC}   $ERRORS"
    if [ $REPLACED -gt 0 ]; then
        echo ""
        echo -e "${GREEN}✓ Files successfully replaced!${NC}"
        echo -e "${BLUE}Hard links preserved using redirects${NC}"
        echo -e "${BLUE}Backups created with .backup.* extension${NC}"
    fi
fi
echo ""

[ $ERRORS -eq 0 ] && exit 0 || exit 1
