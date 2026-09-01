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
        # change, raise-above-others, map/unmap in setBarState; win.zig holds
        # create/destroy of the bar window + colormap (same lifecycle, split
        # into its own file). Sync only raises bar_win via the force_restack
        # hook; bar self-management stays local to avoid a bar<->sync cycle.
        src/bar/bar.zig|src/bar/drawing.zig|src/bar/win.zig) ;;

        # ConfigureRequest compliance (BC03/BC04/BC05): client-requested
        # geometry is honored for floating windows and BW recorded for tiled
        # -- protocol duty that answers the CLIENT, not layout.
        # restoreFloatGeom / moveFloatToDefaultPos / applyBorder ride along.
        src/window/window.zig|src/window/borders.zig) ;;

        # Click-raise and focus-flag restack requests tied to the X11 focus
        # protocol (R2 keeps protocol in window.*). focus.zig rides the
        # allowlist for that protocol duty (set_input_focus / raise / the
        # _NET_ACTIVE_WINDOW property write).
        src/window/focus.zig) ;;

        # Root-window keygrab installation at startup and click-focus
        # stack-mode: startup is pre-WM-loop; the restack routes through
        # sync force_restack in a later cleanup.
        src/main.zig|src/input/input.zig) ;;

        # Wire PRIMITIVES: sync/sink.zig dispatches through
        # core/x11/wire.zig's configureWindow / raiseWindow / setBorderPixel /
        # pushWindowOffscreen*. Primitive home is not a policy violation --
        # grep cannot distinguish definition from rogue send. D6 moved these
        # definitions out of utils.zig into core/x11/wire.zig so the
        # model/tiling layer only ever sees xcb-free utils decls.
        src/core/x11/wire.zig) ;;

        # Re-export DECLARATIONS only: utils.zig's `pub const raiseWindow =
        # x11wire.raiseWindow;` is an xcb-free forwarding decl, not a send (the
        # actual primitive lives in wire.zig, allowlisted above). Grep matches
        # the wrapper NAME here, so this is the same definition-vs-call caveat.
        src/core/utils/utils.zig) ;;

        # Bare output-buffer flushes that match the widened symbol set but send
        # NO geometry/border/map mutation (flush pushes the shared connection
        # buffer after others' queued requests). refresh.zig/events.zig are core
        # event-loop/DRR-detection flushes; prompt.zig is the bar's keyboard
        # grab-drop flush. These are documented non-mutations, not Rule-1 sends.
        src/core/refresh.zig|src/core/events.zig|src/bar/modules/prompt/prompt.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 2 allowlist (same §13): files permitted to grab the server
# outside src/sync/. Per plan this list starts non-empty and shrinks.
# Note: grab_allowed covers BOTH the raw xcb.xcb_grab_server call and the
# utils.grabServer wrapper (Rule 2 matches both; see pat2 below).
grab_allowed() {
    case "$1" in
        # core/x11/wire.zig hosts the shared grab/ungrabAndFlush PRIMITIVES
        # (D6 move from utils.zig). sync.zig's reconcileUnderGrab calls
        # these; the primitive home is not itself a policy violation, but
        # grep cannot tell call from definition.
        src/core/x11/wire.zig) ;;

        # Bar's OWN window lifecycle, the counterpart of its Rule 1 entry:
        # position toggle (Y-reposition) and show/hide (map/unmap) bracket
        # their config/visibility changes with a server grab and issue the
        # wire reconfig before reconcile. Already documented in wire_allowed;
        # the grab is the same policy boundary.
        src/bar/bar.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 1: wire-mutating XCB requests only under src/sync/ (+ allowlist).
# ND-23 widening: the original pattern missed unmap/destroy/circulate and
# set_input_focus, all wire-mutating requests that belong behind the sync
# boundary exactly like configure/map. Widening only makes violations FAIL
# where they previously passed.
pat1='xcb_configure_window|XCB_CONFIG_WINDOW_|xcb_map_window|xcb_unmap_window|xcb_destroy_window|xcb_circulate_window|XCB_CIRCULATE_|xcb_set_input_focus|xcb_change_window_attributes|xcb_change_property|xcb_flush|raiseWindow'
while IFS= read -r line; do
    f=${line%%:*}
    wire_allowed "$f" && continue
    viol "rule 1 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -v '^src/core/sync/' | code_lines)

# Rule 2: server grab only under src/sync/ (+ allowlist). Comment mentions of
# xcb_grab_server are stripped so documentation doesn't trip the guard. Match
# BOTH the raw XCB primitive and the utils.grabServer/ungrabServer wrappers.
# Siblings like sync.zig route grabs through the Sink vtable (sink.grabServer,
# never literally `utils.grabServer`), so a wrapper match isolates files that
# grab the server directly, which is exactly the policy being enforced.
pat2='xcb\.xcb_grab_server|utils\.grabServer|utils\.ungrabServer'
while IFS= read -r line; do
    f=${line%%:*}
    grab_allowed "$f" && continue
    viol "rule 2 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat2" src/ --include='*.zig' | grep -v '^src/core/sync/' | code_lines)

# Rule 3: no xcb imports/references in model/ or tiling/.
# Comments are stripped first so `/* ... */` (incl. multi-line) and `//`
# commentary that merely names an xcb symbol does not trip the guard. The awk
# strips comments while preserving each physical line (and its number), so
# real code references still match and report at their true location.
hits=$(
    while IFS= read -r f; do
        awk '
            { line=$0; code=0
              while(1){
                s=index(line,"/*"); e=index(line,"*/")
                if(s>0 && e==0){ if(s>1) code=1; line=substr(line,1,s-1); inb=1; break }
                if(s>0 && e>s){ line=substr(line,1,s-1) substr(line,e+2); continue }
                if(e>0 && inb){ line=substr(line,e+2); inb=0; continue }
                break
              }
              if(inb==1 && code==0) line=""
              sub(/\/\/.*$/,"",line)
              if (line ~ /xcb/) print FILENAME ":" NR ":" line
            }' "$f"
    done < <(find src/model src/tiling -name '*.zig') || true
)
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
