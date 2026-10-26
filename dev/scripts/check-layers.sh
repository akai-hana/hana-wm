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

# P2-70: allowlist hygiene. Every allowlist entry line (a `src/...` case
# pattern ending `;;`) must carry a justification comment block directly
# above it whose LAST line is the review stamp `# last-reviewed: YYYY-MM-DD`
# -- the per-entry review/expiry tag: re-warrant the entry, move the date.
# An entry without that stamp fails the gate (not a warning), and each list's
# size is printed so growth is visible in every check/CI log: the allowlist
# is a reviewed fact, not a monotonically-growing scar.
allowlist_entry_lines() { # $1 = function name; prints "<line>:<entry>"
    awk -v fn="$1" '
        $0 ~ "^" fn "\\(\\) \\{" { infun = 1; next }
        infun && /^}/ { infun = 0; next }
        infun && /^[ \t]+src\/.*\) ;;$/ { print NR ":" $0 }
    ' "$0"
}

allowlist_hygiene() { # $1 = function name, $2 = label; sets <label>_count
    local name=$1 label=$2 n=0 lno prev
    while IFS= read -r entry; do
        n=$((n + 1))
        lno=${entry%%:*}
        prev=$(sed -n "$((lno - 1))p" "$0")
        case "$prev" in
            *'# last-reviewed: '[0-9]*) ;;
            *)
                viol "allowlist hygiene ($label entry at $name:$lno: the line above must be '# last-reviewed: YYYY-MM-DD' -- justification stamp missing)"
                ;;
        esac
    done < <(allowlist_entry_lines "$name")
    say "allowlist: $label=$n entries"
    case "$label" in
        wire) wire_count=$n ;;
        grab) grab_count=$n ;;
        tiled_order) tiled_order_count=$n ;;
    esac
}

# Rule 1 allowlist: files permitted to send
# configure/map/change_attributes outside of the reconcile boundary's wire
# policy. Each case documents the surviving wire traffic and why it has not
# (yet) moved behind the reconciler.
wire_allowed() {
    # (No entry for src/core/input/dispatch.zig: its closeWindow now
    # delegates to the shared ICCCM path in icccm.zig, allowlisted below,
    # and the file matches no wire pattern at all.)
    case "$1" in
        # Bar's OWN window lifecycle: map on show, Y-reposition on height
        # change, raise-above-others, map/unmap in setBarState; win.zig holds
        # create/destroy of the bar window + colormap (same lifecycle, split
        # into its own file). Sync only raises bar_win via the force_restack
        # hook; bar self-management stays local to avoid a bar<->sync cycle.
        # The apply* visibility family (map/unmap on visibility change,
        # raise-above-others, screen-claim publish) lives here too: it was
        # split out as wire/visibility.zig, then folded back in (Phase 3 of
        # the bar refactor) with the pure policy left in src/bar/visibility.zig.
        # surface.zig holds the bar frame's wire traffic (the xcb_flush that
        # orders fills under glyphs, moved here from drawing.zig with the
        # Surface in Phase 4 step 24); drawing.zig no longer sends wire.
        # last-reviewed: 2026-10-20
        src/bar/bar.zig|src/bar/render/surface.zig|src/bar/wire/win.zig) ;;

        # Window event handlers (merged client_events.zig): ConfigureRequest
        # compliance (client-requested geometry honored for floating windows
        # and BW recorded for tiled -- protocol duty that answers the CLIENT,
        # not layout; restoreFloatGeom / moveFloatToDefaultPos /
        # applyBorder ride along), EWMH ClientMessage, and Enter/Leave
        # crossing. Split out of window.zig (which no longer sends wire
        # itself); window.zig re-exports the handlers as the dispatch
        # surface. Merged back from configure/client_message/crossing.zig
        # 2026-10-09.
        # last-reviewed: 2026-10-20
        src/window/protocol/client_events.zig) ;;

        # Admission preamble: claimManagedEventMask sets the management
        # event mask (PropertyNotify / StructureNotify / FocusChange
        # delivery) on MapRequest and boot-time adoption -- protocol
        # setup for the windows this module admits, split out of
        # window.zig with the admission policy (rules map, spawn queue,
        # five-cookie pipeline).
        # last-reviewed: 2026-10-20
        src/window/admission.zig) ;;

        # Click-raise and focus-flag restack requests tied to the X11 focus
        # protocol (kept in window.*). focus.zig rides the
        # allowlist for that protocol duty (set_input_focus / raise / the
        # _NET_ACTIVE_WINDOW property write).
        # last-reviewed: 2026-10-20
        src/window/protocol/focus.zig) ;;

        # (No entry for src/core/loop/pipeline.zig or
        # src/window/modules/floating.zig: their former raiseWindowNow /
        # floating-drag-tick raise now routes through sync's sanctioned
        # `sink.stackOnly` primitive, and neither file matches any pat1 code
        # line any more, so the entry that existed for them was stale (P1-36a)
        # and is gone. focus.zig's literal `requests.raiseWindow` call still
        # matches pat1 and is allowed by its own entry above.)

        # sink_test.zig asserts the VALUE SLOT ORDER of one configure_window
        # (X, Y, WIDTH, HEIGHT, BORDER_WIDTH, STACK_MODE) by naming the
        # XCB_CONFIG_WINDOW_* mask constants. It issues no wire traffic at all
        # -- it is the pure `sink.configureWire` assembly, which is why the
        # order is testable at all -- but the pattern cannot tell a constant
        # from a call, so the assertion needs the explicit entry.
        #
        # actions_test.zig's "denied ConfigureRequest" test (P1-10) is the
        # same warrant for the same reason: it names XCB_CONFIG_WINDOW_* to
        # SHAPE a synthetic xcb_configure_request_event_t fed straight to
        # window.handleConfigureRequest. The configure it elicits goes out
        # through the handler's own send path, never through this file.
        # last-reviewed: 2026-10-20
        src/test/core/sink_test.zig|src/test/window/actions_test.zig) ;;

        # Detectable auto-repeat enablement (enableDetectableAutoRepeat in
        # src/core/input/xkb.zig): a ONE-SHOT, STARTUP-ONLY XKB negotiation
        # that issues xcb_xkb_per_client_flags + its reply and
        # xcb_get_extension_data. It is best-effort setup, not per-window wire
        # mutation: it flips a per-client flag the WM must set once before
        # keybinding dispatch starts and never again (there is no layout/tiling
        # geometry being moved). Documented here with the same
        # "setup, not mutation" warrant as the detect-drag/restack family.
        # Rides pat-wide via the `xcb_xkb_` family plus
        # `xcb_get_extension_data`; see enableDetectableAutoRepeat's own
        # comment for the retry contract.
        # last-reviewed: 2026-10-20
        src/core/input/xkb.zig) ;;

        # Root-window keygrab installation at startup and click-focus
        # stack-mode: startup is pre-WM-loop; the restack routes through
        # sync force_restack in a later cleanup. main no longer appears
        # here: its root-event-mask claim and flush moved into
        # core/x11/requests.zig (claimWindowManagerRole + flush), so the
        # composition root no longer names xcb.
        #
        # Root-window cursor theming (setupRoot in src/core/input/cursor.zig):
        # one xcb_change_window_attributes on the root taken at startup,
        # decoration rather than per-window mutation — same "startup, not
        # mutation" warrant as enableDetectableAutoRepeat.
        # last-reviewed: 2026-10-20
        src/core/input/cursor.zig) ;;

        # Wire PRIMITIVES: core/x11/requests.zig hosts configureWindow /
        # raiseWindow / setBorderPixel / grabServer, and core/x11/atoms.zig
        # hosts the intern/lookup half. sink.zig dispatches through those
        # (park rides an offscreen+below configure in sink.zig). Primitive
        # home is not a policy violation -- grep cannot distinguish
        # definition from rogue send. These definitions were moved out of
        # the old pure/utils.zig facade so the pure vocabulary only ever sees
        # xcb-free decls. (Rule 1's grep exempts requests/sink/reconcile by
        # path as of P1-36a -- the narrow boundary window; the entries here
        # stay as their documentation, and atoms.zig's is load-bearing: it is
        # the only reason that file passes if it ever grows a pat1 line.)
        # last-reviewed: 2026-10-20
        src/core/x11/requests.zig|src/core/x11/atoms.zig) ;;

        # Tiled border-width application: the borders module's xcb_configure_window
        # sets XCB_CONFIG_WINDOW_BORDER_WIDTH on tiled windows (the per-frame
        # border sweep). A width-only configure is NOT a geometry/map
        # mutation and runs outside reconcile by design; the sync ledger's
        # last-sent-width dedup keeps it from spamming the server.
        # last-reviewed: 2026-10-20
        src/window/modules/borders.zig) ;;

        # ICCCM client-message sends (pat1's xcb_send_event): WM_TAKE_FOCUS
        # (icccm.zig hands focus to windows that advertise the protocol),
        # the synthetic ConfigureNotify (client_events.zig reports back the
        # geometry it actually applied after honoring a ConfigureRequest), and
        # the shared close path (icccm.closeViaProtocol: the WM_DELETE_WINDOW
        # client message plus its xcb_destroy_window fallback, once dispatched
        # from core/input/dispatch.zig's closeWindow; both the close_window
        # keybind and EWMH's _NET_CLOSE_WINDOW land here). These are
        # client protocol text, not sync-bound wire mutations.
        # client_events.zig is allowlisted above for the ConfigureRequest
        # family; icccm.zig joins them here for this family.
        # last-reviewed: 2026-10-20
        src/window/protocol/icccm.zig) ;;

        # src/test/harness/fixture.zig is a TEST DOUBLE: it drives a real X
        # connection owned by the X-gated harness to destroy leftover windows
        # during reset, flush, and write WM_PROTOCOLS / WM_HINTS properties on
        # synthetic override-redirect windows (setWmTakeFocus/setNoInput). Test
        # setup is not WM wire traffic and never routes through sync. (It
        # moved here from src/test/x11/ in the Phase-7 harness consolidation;
        # the carve-out follows the file.)
        # last-reviewed: 2026-10-20
        src/test/harness/fixture.zig) ;;

        # src/test/core/pipeline_test.zig is a TEST DOUBLE: it maps two
        # synthetic override-redirect windows through the X-gated harness's
        # real connection so it can assert the pipeline's window-enter /
        # map-request path. Test setup is not WM wire traffic and never routes
        # through the reconciler. Same carve-out as fixture.zig.
        # last-reviewed: 2026-10-20
        src/test/core/pipeline_test.zig) ;;

        # src/test/window/struts_test.zig is a TEST DOUBLE: it writes
        # _NET_WM_WINDOW_TYPE / _NET_WM_STRUT_PARTIAL onto its synthetic
        # windows and unmaps them so the admission, PropertyNotify, and
        # unmanage strut lifecycle can be driven through the REAL handlers
        # (handleMapRequest/handlePropertyNotify/handleUnmapNotify) and
        # asserted against usable_area. Test setup is not WM wire traffic and
        # never routes through sync. Same carve-out as fixture.zig /
        # pipeline_test.zig.
        # last-reviewed: 2026-10-20
        src/test/window/struts_test.zig) ;;

        # Bare output-buffer flushes that match the widened symbol set but send
        # NO geometry/border/map mutation (flush pushes the shared connection
        # buffer after others' queued requests). events.zig is the core
        # event-loop flush; display/hz.zig is the RandR refresh-rate detection
        # flush (it subscribes to RandR notify on the root); prompt.zig is the
        # bar's keyboard grab-drop flush; core/input/mouse.zig is the
        # Super+click grab-unwind flush (finishGrab pushes the buffer after
        # the two xcb_allow_events replay/async calls -- no mutation of its
        # own); core/input/keybinds.zig is the grab-installation flush
        # (grabMouseButtons/grabKeybindings push the buffer after firing
        # all grab cookies -- the grabs themselves are not Rule-1 mutations).
        # These are documented non-mutations, not Rule-1 sends.
        # last-reviewed: 2026-10-20
        src/core/loop/events.zig|src/core/display/hz.zig|src/bar/modules/prompt/prompt.zig|src/core/input/mouse.zig|src/core/input/keybinds.zig) ;;

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
        # core/x11/requests.zig hosts the shared grab/ungrabAndFlush
        # PRIMITIVES; reconcile.reconcileUnderGrab calls these; the primitive
        # home is not itself a policy violation, but grep cannot tell call
        # from definition.
        # last-reviewed: 2026-10-20
        src/core/x11/requests.zig) ;;

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
    viol "rule 1 ($f outside the reconcile boundary and allowlist)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat1" src/ --include='*.zig' | grep -vE '^src/core/x11/(requests|sink|reconcile)\.zig:' | code_lines)

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

# Rule 3: no xcb imports/references in the pure state vocabulary
# (model.zig), the split contract vocabulary
# (tiling_contract.zig, contract_dispatch.zig, window_contract.zig,
# bar_contract.zig), tiling/, or config/. Comments are stripped first so `/* ... */` (incl. multi-line) and
# `//` commentary that merely names an xcb symbol does not trip the guard. The
# strip runs through the shared build-time scanner
# (dev/build-support/source_scan.zig, via dev/build-support/rule3.zig) --
# string-aware, newline-preserving -- so real code references still match
# and report at their true file:line, and a `"//...xcb"`-shaped string
# literal can no longer hide following code from the sweep. The tool prints
# `path:line:content`, the same shape the loop below consumes.
#
# This rule is the SOLE body/reference guard on pure-layer xcb contamination:
# it sweeps for any `xcb` token in the state files, the contract vocabulary,
# tiling/, and config/ after
# comment removal -- imports AND re-exported bare references alike. (The
# complementary IMPORT-EDGE scan lives in build.zig's assertPureLayerImports:
# a pure module can import an xcb-using sibling and pass there, so Rule 3, not
# that scan, is the last line of defense on bodies. Only the state files are
# swept: model.zig is the pure root (state plus the Rect/Margins value
# objects and their coordinate helpers), and the pure/ shelf carries no xcb
# tokens by construction. The split contracts (from the 2026-10 monolithic
# contract.zig) ARE on this side of the sweep: they name the key-press event
# as an opaque `KeyPressEvent` and carry the connection as `*const anyopaque`,
# so they are xcb-free vocabulary and are swept like any other pure file.
# (The X-typed vocabulary they deliberately do not hold -- the concrete
# key-press struct and the `Surfaces` hook set -- lives with its binding
# site in hub-wired bar.zig, outside the sweep.) The merge of
# contract_window.zig / contract_segment.zig into the monolith (2026-10-08)
# and the monolith's later split into per-engine contracts are both history;
# the sweep follows the files, not the lineage.)
mapfile -t rule3_files < <(find src/core/model.zig src/core/architecture/contract_dispatch.zig src/core/architecture/tiling_contract.zig src/window/window_contract.zig src/bar/bar_contract.zig src/tiling src/config -name '*.zig' 2>/dev/null)
if [ "${#rule3_files[@]}" -eq 0 ]; then
    viol "rule 3 (sweep input set is empty)"
    hits=""
elif hits=$(zig run dev/build-support/rule3.zig -- "${rule3_files[@]}"); then
    :
else
    viol "rule 3 (sweep tool failed)"
    hits=""
fi
if [ -n "$hits" ]; then
    while IFS= read -r line; do
        f=${line%%:*}
        viol "rule 3 (xcb reference in $f)"; printf '%s\n' "$line" >&2
    done <<< "$hits"
fi

# Rule 4: formatting. Full speed by default; with ZBUILD_THROTTLE=1 the
# pass routes through dev/scripts/throttle.sh like every other gate step.
fmt_cmd=(zig fmt --check .)
if [ "${ZBUILD_THROTTLE:-0}" = "1" ]; then
    fmt_cmd=(dev/scripts/throttle.sh -- zig fmt --check .)
fi
if ! "${fmt_cmd[@]}" >/dev/null 2>&1; then
    viol "rule 4 (zig fmt --check)"
fi

# Rule 5: the model is the single writer of window state (P1-31). Mutations of
# a workspace's tiled_order -- the membership list the single-membership
# invariant is defined over -- are confined to the write API and the handful
# of callers whose semantics genuinely re-home a window; every other file must
# go through them rather than touch the list directly. The sanctioned set
# starts closed and is EDITED HERE WITH A RATIONALE when a new write path
# lands, which makes "who may write membership" a reviewed fact instead of a
# convention. Comment-only lines are stripped first (code_lines) so
# documentation cannot trip the guard. src/test/ is excluded: fixtures build
# deliberate violations to assert the invariant itself (the logic under test
# lives in model.checkInvariants, not in this grep).
tiled_order_allowed() {
    case "$1" in
        # The single writer itself: unregister un-homes a window from its
        # workspace list.
        # last-reviewed: 2026-10-20
        src/core/model.zig) ;;
        # The window layer's register/unregister write API -- the one path
        # every other file is supposed to call instead of appending itself.
        # last-reviewed: 2026-10-20
        src/window/state/window_state_ops.zig) ;;
        # Workspace moves re-home membership (moveToWorkspace semantics:
        # remove from the old list, append to the new one).
        # last-reviewed: 2026-10-20
        src/window/modules/workspaces.zig) ;;
        # Park/unpark (minimize) moves membership while keeping the anchor.
        # last-reviewed: 2026-10-20
        src/window/modules/minimize.zig) ;;
        # Float transitions re-home membership in both directions
        # (detachTiledToFloating routes through model; attach is here).
        # last-reviewed: 2026-10-20
        src/window/modules/floating.zig) ;;
        # Boot/session restore reconstructs membership from the persisted
        # snapshot -- one-shot, before the event loop ever runs.
        # last-reviewed: 2026-10-20
        src/core/process/session.zig) ;;
        *) return 1 ;;
    esac
    return 0
}

pat5='tiled_order\.(append|insert|clear|swapRemove|orderedRemove|pushFrontEvictingTail|removeWhere|removeById|removeValue)|removeValue\(&[^)]*tiled_order|restoreMembers\(&[^)]*tiled_order'
while IFS= read -r line; do
    f=${line%%:*}
    tiled_order_allowed "$f" && continue
    viol "rule 5 ($f mutates tiled_order outside the single-writer set)"; printf '%s\n' "$line" >&2
done < <(grep -rnE "$pat5" src/ --include='*.zig' | grep -v '^src/test/' | code_lines)

# P2-70: print every allowlist's size (growth visible in CI) and enforce the
# per-entry justification stamp. Counts init'd for set -u.
wire_count=0
grab_count=0
tiled_order_count=0
allowlist_hygiene wire_allowed wire
allowlist_hygiene grab_allowed grab
allowlist_hygiene tiled_order_allowed tiled_order
say "allowlist total: $((wire_count + grab_count + tiled_order_count)) entries"

if [ "$fail" = 0 ]; then say "all layer rules pass"; else say "FAILURES above"; fi
exit $fail
