#!/usr/bin/env bash
# Layer guards (REARCHITECTURE_PLAN.md §13, WP7).
# Exits non-zero when a rule is violated outside its documented allowlist.
set -u
cd "$(dirname "$0")/.."
fail=0

say() { printf 'check-layers: %s\n' "$*"; }
viol() { printf 'check-layers: VIOLATION: %s\n' "$*" >&2; fail=1; }

allowed() { # $1=file  $2=allowlist
    while IFS= read -r a; do
        [[ "$a" == \#* || -z "$a" ]] && continue
        case "$1" in $a) return 0 ;; esac
    done < "$2"
    return 1
}

code_lines() { # strip comment-only lines from grep output on stdin
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        content=${line#*:}          # file:line:content -> line:content
        content=${content#*:}       # -> content
        trimmed=$(printf '%s' "$content" | sed 's/^[[:space:]]*//')
        case "$trimmed" in //*) continue ;; esac
        printf '%s\n' "$line"
    done
}

WIRE_ALLOW=scripts/wire_allowlist.txt
GRAB_ALLOW=scripts/legacy_grab_allowlist.txt

# Rule 1: wire-mutating XCB requests only under src/sync/ (+ allowlist).
pat1='xcb_configure_window|XCB_CONFIG_WINDOW_|xcb_map_window|xcb_change_window_attributes'
while IFS= read -r line; do
    f=${line%%:*}
    allowed "$f" "$WIRE_ALLOW" && continue
    viol "rule 1 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -v '^src/sync/' | code_lines)

# Rule 2: server grab only under src/sync/ (+ allowlist). Comment mentions of
# xcb_grab_server are stripped so documentation doesn't trip the guard.
pat2='xcb\.xcb_grab_server'
while IFS= read -r line; do
    f=${line%%:*}
    allowed "$f" "$GRAB_ALLOW" && continue
    viol "rule 2 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat2" src/ --include='*.zig' | grep -v '^src/sync/' | code_lines)

# Rule 3: no xcb imports/references in model/ or layout/.
hits=$(grep -rn 'xcb' src/model/ src/layout/ --include='*.zig' | grep -v '^\s*//' | grep -v ':\s*//' || true)
if [ -n "$hits" ]; then
    while IFS= read -r line; do
        f=${line%%:*}
        viol "rule 3 (xcb reference in $f)"; printf '%s\n' "$line" >&2
    done <<< "$hits"
fi

# Rule 4: formatting.
if ! zig fmt --check src/ >/dev/null 2>&1; then
    viol "rule 4 (zig fmt --check)"
fi

if [ "$fail" = 0 ]; then say "all layer rules pass"; else say "FAILURES above"; fi
exit $fail
