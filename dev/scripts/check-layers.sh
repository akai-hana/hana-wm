#!/usr/bin/env bash
# Wire-policy guards. The tree is NOT a strict import stack: core and window
# import each other (both are core systems) around a hub-and-spoke model of
# a single core model + sink. These rules enforce the one policy the
# split actually cares about -- wire mutations belong behind the reconcile
# boundary, and the pure layers (model/tiling/config) must stay xcb-pure --
# plus formatting. Each rule

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
# configure/map/change_attributes outside of the reconcile boundary's wire
# policy. Each case documents the surviving wire traffic and why it has not
# (yet) moved behind the reconciler.
wire_allowed() {
    case "$1" in
        # Bar's OWN window lifecycle: map on show, Y-reposition on height
        # change, raise-above-others, map/unmap in setBarState; win.zig holds
        # create/destroy of the bar window + colormap (same lifecycle, split
        # into its own file). Sync only raises bar_win via the force_restack
        # hook; bar self-management stays local to avoid a bar<->sync cycle.
        # visibility_glue.zig carries the same bar self-management, split out
        # of bar.zig with the apply* visibility family (map/unmap on
        # visibility change, raise-above-others, screen-claim publish).
        src/bar/bar.zig|src/bar/visibility_glue.zig|src/bar/drawing.zig|src/bar/win.zig) ;;

        # ConfigureRequest compliance: client-requested
        # geometry is honored for floating windows and BW recorded for tiled
        # -- protocol duty that answers the CLIENT, not layout.
        # restoreFloatGeom / moveFloatToDefaultPos / applyBorder ride along.
        src/window/window.zig|src/window/wincache.zig) ;;

        # Admission preamble: claimManagedEventMask sets the management
        # event mask (PropertyNotify / StructureNotify / FocusChange
        # delivery) on MapRequest and boot-time adoption -- protocol
        # setup for the windows this module admits, split out of
        # window.zig with the admission policy (rules map, spawn queue,
        # five-cookie pipeline).
        src/window/admission.zig) ;;

        # Click-raise and focus-flag restack requests tied to the X11 focus
        # protocol (kept in window.*). focus.zig rides the
        # allowlist for that protocol duty (set_input_focus / raise / the
        # _NET_ACTIVE_WINDOW property write).
        src/window/focus.zig) ;;

        # pipeline.raiseWindowNow and its one caller (the floating drag tick):
        # raising the dragged window is a STACKING write, and it goes out
        # through sync's sanctioned `sink.stackOnly` primitive followed by
        # `sink.flush` -- ungrabbed, which is the drag-tick policy. The guard
        # matches the literal `raiseWindow` inside the name, so the sanctioned
        # boundary needs an explicit entry rather than a name that dodges the
        # pattern. Surviving wire traffic: one stack-mode-above
        # xcb_configure_window, which is exactly what the primitive exists for.
        src/core/loop/pipeline.zig|src/window/modules/floating.zig) ;;

        # sink_test.zig asserts the VALUE SLOT ORDER of one configure_window
        # (X, Y, WIDTH, HEIGHT, BORDER_WIDTH, STACK_MODE) by naming the
        # XCB_CONFIG_WINDOW_* mask constants. It issues no wire traffic at all
        # -- it is the pure `sink.configureWire` assembly, which is why the
        # order is testable at all -- but the pattern cannot tell a constant
        # from a call, so the assertion needs the explicit entry.
        src/test/core/sink_test.zig) ;;

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
        # sync force_restack in a later cleanup. main no longer appears
        # here: its root-event-mask claim and flush moved into
        # core/x11/requests.zig (claimWindowManagerRole + flush), so the
        # composition root no longer names xcb.
        #
        # input.zig carried this entry until the action dispatcher
        # (executeAction/grafted/closeWindow/toggleBarPosition/dirSign)
        # moved to input/dispatch.zig (review 05-input round 2); the
        # wire traffic moved with it and is allowlisted there, so
        # input.zig itself no longer sends any.
        src/input/dispatch.zig) ;;

        # Wire PRIMITIVES: core/x11/requests.zig hosts configureWindow /
        # raiseWindow / setBorderPixel / grabServer, and core/x11/atoms.zig
        # hosts the intern/lookup half. sink.zig dispatches through those
        # (park rides an offscreen+below configure in sink.zig). Primitive
        # home is not a policy violation -- grep cannot distinguish
        # definition from rogue send. These definitions were moved out of
        # the old pure/utils.zig facade so the pure vocabulary only ever sees
        # xcb-free decls. (Rule 1's grep already exempts src/core/x11/; the
        # entries stay for documentation.)
        src/core/x11/requests.zig|src/core/x11/atoms.zig) ;;

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
        # WM_DELETE_WINDOW (dispatch.zig closes a client gracefully, ICCCM
        # §4.1.2.7). These are client protocol text, not sync-bound wire
        # mutations. window.zig was already allowlisted above;
        # icccm.zig joins them here for this family.
        src/window/icccm.zig) ;;

        # src/test/x11/fixture.zig is a TEST DOUBLE: it drives a real X
        # connection owned by the X-gated harness to destroy leftover windows
        # during reset, flush, and write WM_PROTOCOLS / WM_HINTS properties on
        # synthetic override-redirect windows (setWmTakeFocus/setNoInput). Test
        # setup is not WM wire traffic and never routes through sync.
        src/test/x11/fixture.zig) ;;

        # src/test/window/focus_test.zig is a TEST DOUBLE: its liveness
        # ordering test destroys the clicked window through the X-gated
        # harness's real connection (xcb_destroy_window) so it can assert that
        # a mouse_click on a window destroyed mid-click is never re-focused.
        # Same test-double carve-out as fixture.zig; never routes through sync.
        src/test/window/focus_test.zig) ;;

        # src/test/engine/pipeline_test.zig is a TEST DOUBLE: it maps two
        # synthetic override-redirect windows through the X-gated harness's
        # real connection so it can assert the pipeline's window-enter /
        # map-request path. Test setup is not WM wire traffic and never routes
        # through the reconciler. Same carve-out as fixture.zig.
        src/test/engine/pipeline_test.zig) ;;

        # Bare output-buffer flushes that match the widened symbol set but send
        # NO geometry/border/map mutation (flush pushes the shared connection
        # buffer after others' queued requests). events.zig is the core
        # event-loop flush; display/hz.zig is the RandR refresh-rate detection
        # flush (it subscribes to RandR notify on the root); prompt.zig is the
        # bar's keyboard grab-drop flush; input/mouse.zig is the Super+click
        # grab-unwind flush (finishGrab pushes the buffer after the two
        # xcb_allow_events replay/async calls -- no mutation of its own);
        # core/loop/grabs.zig is the grab-installation flush
        # (grabMouseButtons/grabKeybindings push the buffer after firing
        # all grab cookies -- the grabs themselves are not Rule-1 mutations).
        # These are documented non-mutations, not Rule-1 sends.
        src/core/loop/events.zig|src/core/display/hz.zig|src/bar/modules/prompt/prompt.zig|src/input/mouse.zig|src/core/loop/grabs.zig) ;;

        *) return 1 ;;
    esac
    return 0
}

# Rule 2 allowlist (same wire policy): files permitted to grab the server
# outside the sync boundary. This list starts non-empty and shrinks.
# Note: grab_allowed covers BOTH the raw xcb.xcb_grab_server call and the
# requests.grabServer wrapper (Rule 2 matches both; see pat2 below).
grab_allowed() {
    case "$1" in
        # core/x11/wire.zig hosts the shared grab/ungrabAndFlush PRIMITIVES;
        # sync.zig's reconcileUnderGrab calls
        # these; the primitive home is not itself a policy violation, but
        # grep cannot tell call from definition.
        src/core/x11/requests.zig) ;;

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

# Rule 1: wire-mutating XCB requests belong behind the reconcile boundary
# (+ allowlist). The original pattern missed unmap/destroy/circulate and
# set_input_focus, all wire-mutating requests that belong behind the sync
# boundary exactly like configure/map. Widening only makes violations FAIL
# where they previously passed.
#
# The CirculateNotify case is why widening still needs care: the catch-all was
# originally XCB_CIRCULATE_, which also matches XCB_CIRCULATE_NOTIFY -- a
# read-only event TYPE that carries no request at all. core/loop/events.zig is
# allowlisted above, but its test is not, so the event-type reference in
# src/test/core/events_test.zig tripped rule 1 for citing a constant rather than
# making a call. Spelled XCB_CIRCULATE_WINDOW, which is the request; the
# lowercase xcb_circulate_window still catches the call itself.
pat1='xcb_configure_window|XCB_CONFIG_WINDOW_|xcb_map_window|xcb_unmap_window|xcb_destroy_window|xcb_circulate_window|XCB_CIRCULATE_WINDOW|xcb_set_input_focus|xcb_change_window_attributes|xcb_change_property|xcb_send_event|xcb_flush|xcb_xkb_per_client_flags|xcb_get_extension_data|raiseWindow'
while IFS= read -r line; do
    f=${line%%:*}
    wire_allowed "$f" && continue
    viol "rule 1 ($f outside src/core/x11/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -v '^src/core/x11/' | code_lines)

# Rule 2: server grabs belong behind the reconcile boundary (+ allowlist). Comment
# mentions of xcb_grab_server are stripped so documentation doesn't trip the
# guard. Match BOTH the raw XCB primitive and the requests.grabServer wrapper.
# Siblings like reconcile.zig route grabs through the Sink vtable
# (sink.grabServer, never literally `requests.grabServer`), so a wrapper match
# isolates files that grab the server directly, which is exactly the policy
# being enforced.
pat2='xcb\.xcb_grab_server|requests\.grabServer'
while IFS= read -r line; do
    f=${line%%:*}
    grab_allowed "$f" && continue
    viol "rule 2 ($f outside src/core/x11/ and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat2" src/ --include='*.zig' | grep -v '^src/core/x11/' | code_lines)

# Rule 3: no xcb imports/references in the pure model vocabulary, the window
# contract, tiling/, or config/. Comments are stripped first so `/* ... */` (incl. multi-line) and
# `//` commentary that merely names an xcb symbol does not trip the guard. The
# awk strips comments while preserving each physical line (and its number), so
# real code references still match and report at their true location.
#
# This rule is the SOLE body/reference guard on pure-layer xcb contamination:
# it sweeps for any `xcb` token in the model file, tiling/, and config/ after
# comment removal -- imports AND re-exported bare references alike. (The
# complementary IMPORT-EDGE scan lives in build.zig's assertPureLayerImports:
# a pure module can import an xcb-using sibling and pass there, so Rule 3, not
# that scan, is the last line of defense on bodies. Only the model file is
# swept: it is the pure root (state plus the Rect/Margins value objects and
# their coordinate helpers), its pure/ siblings carry no xcb tokens by
# construction. architecture/contract.zig IS on this side of the sweep since
# the xcb event TYPES moved out to its sibling contract_x11.zig: the contract
# now names the key-press event as an opaque `KeyPressEvent` and carries the
# connection as `*const anyopaque`, so it is xcb-free vocabulary and is swept
# like any other pure file.)
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
    done < <(find src/core/architecture/model.zig src/core/architecture/contract.zig src/tiling src/config -name '*.zig') || true
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
