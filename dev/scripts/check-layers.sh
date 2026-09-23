#!/usr/bin/env bash
# Wire-policy guards. The tree is NOT a strict import stack: core and window
# import each other (both are core systems) around a hub-and-spoke model of
# a single core model + sync sink. These rules enforce the one policy the
# split actually cares about -- wire mutations belong behind the sync
# boundary, and model/tiling must stay xcb-pure -- plus formatting. Each rule

# exits non-zero when its policy is violated outside a documented allowlist.
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
        trimmed=${content#"${content%%[![:space:]]*}"}
        case "$trimmed" in //*) continue ;; esac
        printf '%s\n' "$line"
    done
}

# Rule 1 allowlist: files permitted to send
# configure/map/change_attributes outside of the sync boundary's wire policy.
# Each case documents the surviving wire traffic and why it has not (yet)
# moved behind sync.
wire_allowed() {
    case "$1" in
        # Bar's OWN window lifecycle: map on show, Y-reposition on height
        # change, raise-above-others, map/unmap in setBarState; win.zig holds
        # create/destroy of the bar window + colormap (same lifecycle, split
        # into its own file). Sync only raises bar_win via the force_restack
        # hook; bar self-management stays local to avoid a bar<->sync cycle.
        src/bar/bar.zig|src/bar/drawing.zig|src/bar/win.zig) ;;

        # ConfigureRequest compliance: client-requested
        # geometry is honored for floating windows and BW recorded for tiled
        # -- protocol duty that answers the CLIENT, not layout.
        # restoreFloatGeom / moveFloatToDefaultPos / applyBorder ride along.
        src/window/window.zig|src/window/wincache.zig) ;;

        # Click-raise and focus-flag restack requests tied to the X11 focus
        # protocol (kept in window.*). focus.zig rides the
        # allowlist for that protocol duty (set_input_focus / raise / the
        # _NET_ACTIVE_WINDOW property write).
        src/window/focus.zig) ;;

        # Detectable auto-repeat enablement (enableDetectableAutoRepeat in
        # src/input/xkbcommon.zig): a ONE-SHOT, STARTUP-ONLY XKB negotiation
        # that issues xcb_xkb_per_client_flags + its reply and
        # xcb_get_extension_data. It is best-effort setup, not per-window wire
        # mutation: it flips a per-client flag the WM must set once before
        # keybinding dispatch starts and never again (there is no layout/tiling
        # geometry being moved). Documented here with the same
        # "setup, not mutation" warrant as the detect-drag/restack family.
        # Rides pat-wide via the `xcb_xkb_` family plus
        # `xcb_get_extension_data`; see enableDetectableAutoRepeat's own
        # comment for the retry contract.
        src/input/xkbcommon.zig) ;;

        # Root-window keygrab installation at startup and click-focus
        # stack-mode: startup is pre-WM-loop; the restack routes through
        # sync force_restack in a later cleanup.
        src/main.zig|src/input/input.zig) ;;

        # Wire PRIMITIVES: sync/sink.zig dispatches through
        # core/x11/wire.zig's configureWindow / raiseWindow / setBorderPixel
        # (park rides an offscreen+below configure in sink.zig). Primitive
        # home is not a policy violation -- grep cannot distinguish
        # definition from rogue send. These definitions were moved out of
        # utils.zig into core/x11/wire.zig so the model/tiling layer only
        # ever sees xcb-free utils decls.
        src/core/x11/wire.zig) ;;

        # Re-export DECLARATIONS only: utils.zig's `pub const raiseWindow =
        # x11wire.raiseWindow;` is an xcb-free forwarding decl, not a send (the
        # actual primitive lives in wire.zig, allowlisted above). Grep matches
        # the wrapper NAME here, so this is the same definition-vs-call caveat.
        src/core/utils/utils.zig) ;;

        # Tiled border-width application: borders.zig's xcb_configure_window
        # sets XCB_CONFIG_WINDOW_BORDER_WIDTH on tiled windows (the per-frame
        # border sweep). A width-only configure is NOT a geometry/map
        # mutation and runs outside reconcile by design; the wincache
        # cacheBorderWidth dedup keeps it from spamming the server.
        src/window/borders.zig) ;;

        # ICCCM client-message sends (pat1's xcb_send_event): WM_TAKE_FOCUS
        # (icccm.zig hands focus to windows that advertise the protocol),
        # the synthetic ConfigureNotify (window.zig reports back the geometry
        # it actually applied after honoring a ConfigureRequest), and
        # WM_DELETE_WINDOW (input.zig closes a client gracefully, ICCCM
        # §4.1.2.7). These are client protocol text, not sync-bound wire
        # mutations. window.zig/input.zig were already allowlisted above;
        # icccm.zig joins them here for this family.
        src/window/icccm.zig) ;;

        # src/test/window/fixture.zig is a TEST DOUBLE: it drives a real X
        # connection owned by the X-gated harness to destroy leftover windows
        # during reset, flush, and write WM_PROTOCOLS / WM_HINTS properties on
        # synthetic override-redirect windows (setWmTakeFocus/setNoInput). Test
        # setup is not WM wire traffic and never routes through sync.
        src/test/window/fixture.zig) ;;

        # src/test/window/focus_test.zig is a TEST DOUBLE: its liveness
        # ordering test destroys the clicked window through the X-gated
        # harness's real connection (xcb_destroy_window) so it can assert that
        # a mouse_click on a window destroyed mid-click is never re-focused.
        # Same test-double carve-out as fixture.zig; never routes through sync.
        src/test/window/focus_test.zig) ;;

        # Bare output-buffer flushes that match the widened symbol set but send
        # NO geometry/border/map mutation (flush pushes the shared connection
        # buffer after others' queued requests). events.zig is the core
        # event-loop flush; refresh.zig is the RandR (bar-side) detection
        # flush; prompt.zig is the bar's keyboard grab-drop flush. These are
        # documented non-mutations, not Rule-1 sends.
        src/core/events.zig|src/bar/refresh.zig|src/bar/modules/prompt/prompt.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 2 allowlist (same wire policy): files permitted to grab the server
# outside the sync boundary. This list starts non-empty and shrinks.
# Note: grab_allowed covers BOTH the raw xcb.xcb_grab_server call and the
# utils.grabServer wrapper (Rule 2 matches both; see pat2 below).
grab_allowed() {
    case "$1" in
        # core/x11/wire.zig hosts the shared grab/ungrabAndFlush PRIMITIVES;
        # sync.zig's reconcileUnderGrab calls
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

# Rule 1: wire-mutating XCB requests belong behind the sync boundary
# (+ allowlist). The original pattern missed unmap/destroy/circulate and
# set_input_focus, all wire-mutating requests that belong behind the sync
# boundary exactly like configure/map. Widening only makes violations FAIL
# where they previously passed.
pat1='xcb_configure_window|XCB_CONFIG_WINDOW_|xcb_map_window|xcb_unmap_window|xcb_destroy_window|xcb_circulate_window|XCB_CIRCULATE_|xcb_set_input_focus|xcb_change_window_attributes|xcb_change_property|xcb_send_event|xcb_flush|xcb_xkb_per_client_flags|xcb_get_extension_data|raiseWindow'
while IFS= read -r line; do
    f=${line%%:*}
    wire_allowed "$f" && continue
    viol "rule 1 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -v '^src/core/sync/' | code_lines)

# Rule 2: server grabs belong behind the sync boundary (+ allowlist). Comment
# mentions of xcb_grab_server are stripped so documentation doesn't trip the
# guard. Match BOTH the raw XCB primitive and the utils.grabServer/ungrabServer
# wrappers.
# Siblings like sync.zig route grabs through the Sink vtable (sink.grabServer,
# never literally `utils.grabServer`), so a wrapper match isolates files that
# grab the server directly, which is exactly the policy being enforced.
pat2='xcb\.xcb_grab_server|utils\.grabServer|utils\.ungrabServer'
while IFS= read -r line; do
    f=${line%%:*}
    grab_allowed "$f" && continue
    viol "rule 2 ($f outside src/sync/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat2" src/ --include='*.zig' | grep -v '^src/core/sync/' | code_lines)

# Rule 3: no xcb imports/references in model/, tiling/, or config/.
# Comments are stripped first so `/* ... */` (incl. multi-line) and `//`
# commentary that merely names an xcb symbol does not trip the guard. The awk
# strips comments while preserving each physical line (and its number), so
# real code references still match and report at their true location.
#
# This rule is the SOLE body/reference guard on pure-layer xcb contamination:
# it sweeps for any `xcb` token in model/, tiling/, and config/ after comment
# removal -- imports AND re-exported bare references alike. (The complementary
# IMPORT-EDGE scan lives in build.zig's assertPureLayerImports: a pure module
# can import an xcb-using sibling and pass there, so Rule 3, not that scan,
# is the last line of defense on bodies.)
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
    done < <(find src/model src/tiling src/config -name '*.zig') || true
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
