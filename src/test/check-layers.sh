#!/usr/bin/env bash
# Layer guards (REARCHITECTURE_PLAN.md §13, WP7).
# Exits non-zero when a rule is violated outside its documented allowlist.
set -u
cd "$(dirname "$0")/../.."
fail=0

say() { printf 'check-layers: %s\n' "$*"; }
viol() { printf 'check-layers: VIOLATION: %s\n' "$*" >&2; fail=1; }

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

# Rule 1 allowlist (REARCHITECTURE_PLAN.md §13): files permitted to send
# configure/map/change_attributes outside src/sync/. Each case documents the
# surviving wire traffic and why it has not (yet) moved behind sync.
wire_allowed() {
    case "$1" in
        # Bar's OWN window lifecycle: map on show, Y-reposition on height
        # change, raise-above-others, map/unmap in setBarState. Sync only
        # raises bar_win via the force_restack hook; bar self-management
        # stays local to avoid a bar<->sync import cycle.
        src/bar/bar.zig|src/bar/drawing.zig) ;;

        # ConfigureRequest compliance (BC03/BC04/BC05): client-requested
        # geometry is honored for floating windows and BW recorded for tiled
        # -- protocol duty that answers the CLIENT, not layout.
        # restoreFloatGeom / moveFloatToDefaultPos / applyBorder ride along.
        src/window/window.zig|src/window/borders.zig) ;;

        # Click-raise of floating windows and focus-flag raises: single
        # restack request tied to the X11 focus protocol (R2 keeps protocol
        # in window.*).
        src/window/focus.zig|src/window/behaviors/floating.zig) ;;

        # (allowlist shrunk: minimize.zig/fullscreen.zig now hold zero XCB
        # traffic — fullscreen truth is model-side, its protocol residue is
        # pending-bar/EWMH only, and actions.restore is the sole restore path.)
        # Config reload BW sweep inside reloadConfig's server grab.
        src/tiling/tiling.zig|src/window/behaviors/workspaces.zig) ;;

        # Root-window keygrab installation at startup and click-focus
        # stack-mode: startup is pre-WM-loop; the restack routes through
        # sync force_restack in a later cleanup.
        src/main.zig|src/core/input/input.zig) ;;

        # Wire PRIMITIVES: sync/wire.zig dispatches through
        # x11wire.configureWindow / raiseWindow / setBorderPixel /
        # pushWindowOffscreen*. Primitive home is not a policy violation --
        # grep cannot distinguish definition from rogue send. D6 moved these
        # definitions out of utils.zig into x11wire.zig so the model/tiling
        # layer only ever sees xcb-free utils decls.
        src/core/utils/x11wire.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 2 allowlist (same §13): files permitted to call xcb_grab_server
# outside src/sync/. Per plan this list starts non-empty and shrinks.
grab_allowed() {
    case "$1" in
        # x11wire.zig hosts the shared grab/ungrabAndFlush PRIMITIVES
        # (D6 move from utils.zig). sync.zig's reconcileUnderGrab calls
        # these; the primitive home is not itself a policy violation, but
        # grep cannot tell call from definition.
        src/core/utils/x11wire.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 1: wire-mutating XCB requests only under src/sync/ (+ allowlist).
pat1='xcb_configure_window|XCB_CONFIG_WINDOW_|xcb_map_window|xcb_change_window_attributes'
while IFS= read -r line; do
    f=${line%%:*}
    wire_allowed "$f" && continue
    viol "rule 1 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -v '^src/sync/' | code_lines)

# Rule 2: server grab only under src/sync/ (+ allowlist). Comment mentions of
# xcb_grab_server are stripped so documentation doesn't trip the guard.
pat2='xcb\.xcb_grab_server'
while IFS= read -r line; do
    f=${line%%:*}
    grab_allowed "$f" && continue
    viol "rule 2 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat2" src/ --include='*.zig' | grep -v '^src/sync/' | code_lines)

# Rule 3: no xcb imports/references in model/ or tiling/.
hits=$(grep -rn 'xcb' src/model/ src/tiling/ --include='*.zig' | grep -v '^\s*//' | grep -v ':\s*//' || true)
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
