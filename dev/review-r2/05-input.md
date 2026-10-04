# input review (round 2)

Re-verify of `src/input/**` against the CURRENT tree (fresh, not
inherited from `dev/review/05-input.md`). Round-1's one ◐ LANDED: the
mouse gesture state machine is now `input/mouse.zig` (288 lines;
`input.zig` dropped 620 → 405) and `classifyMousePress` is a pure
function over `MousePress` facts. Verdict scale: **★ ideal** ·
**◐ near-ideal** · **△ restructure** · **▽ redesign**.

**Now** = high-level pseudo-code of current behavior · **Verdict** ·
**Ideal** = from-scratch pseudo-code · **Path** = ordered,
behavior-preserving refactor steps.

Constraints verified honored: single-threaded intake (the event loop
hands key/button/motion events to this router, one at a time); the
(modifiers, keysym) → Action resolution is layout-independent
(keysym-indexed, keycode only ever read through the flat table); XKB
state is isolated in `input.zig` and exposed read-only
(`getXkbState() -> ?*const`, the one mutable handle private); the
Super+click SYNC-grab invariant is compile-checked (every `MouseIntent`
arm settles the grab exactly once — the dispatch is exhaustive with no
`else`); `input/input.zig` and `input/xkbcommon.zig` sit on the
Rule-1 allowlist (root keygrab installation; the one-shot
detectable-auto-repeat negotiation), `input/mouse.zig` for the
grab-unwind flush only (`finishGrab` pushes the buffer after the two
`xcb_allow_events` calls — no mutation of its own).

---

### `input/input.zig` (405) — intake + XKB + keybind map + action interpreter  **◐**

**Now:**
```
owns: xkb_state (?XkbState), keybind_resolver, resolved_binds
initXkb / deinitXkb / getXkbState (?*const — read-only) / getXkbStateMut (private)
buildKeybinds(binds): realloc resolved_binds; resolveKeycodes;
                      reportUnresolved; rebuildDispatchMap(binds, alloc, config_rev)
resolvedKeybinds() / deinitKeybinds()      // frees map + list (len != 0 guard)
handleMappingNotify(keyboard):             // keyboard-only; modifier/pointer remaps ignored
  state.rebuild; buildKeybinds; grabKeybindings
toggleBarPosition(): surfaces anchor + grab-scoped reconcile + border flush
setup(conn, screen): grabMouseButtons; Cursor.setupRoot; reportUndeliverableMouseBinds
key_profile (WindowedProfiler, profile_key-gated)
handleKeyPress: t0; setLastEventTime; getXkbState; normalizeModifiers;
  keycodeToKeysym; resolver.lookup; chromeHandleKeypress gate (consumes
  the key, seeing the matched action); executeAction | debug-log
handleKeyRelease: setLastEventTime
closeWindow(win): WM_PROTOCOLS/WM_DELETE_WINDOW client message (ts =
  getLastEventTime), else xcb_destroy_window
dirSign(T, dir) = forward ? 1 : -1
executeAction(action): ~70-arm switch — sequence (ordered, exec waits) /
  parallel (fire-and-forget) recurse; tiling ops grafted via `grafted`;
  bar/minimize/workspace arms call their hooks directly
grafted(tag, op, arg): comptime gate (needsTilingFocusScaffold) +
  focus scaffold (suppress reason, beginTilingOpSettle)
re-exports mouse.zig's 7 symbols (the events.zig / main / test surface)
```
**Verdict:** ◐ — the intake half is ideal: the XKB lifecycle is clean
(init / keyboard-only-rebuild / deinit, no reload window, documented),
the state is exposed `const` with the single mutable handle private,
the resolver is generation-checked (fail-closed, once-only report),
`grafted` is a comptime gate rather than documentation, and the
bare-modifier log suppression is correct. The remaining load is the
action interpreter (`executeAction` + `grafted` + `closeWindow` +
`toggleBarPosition` + `dirSign`, ~110 lines) — the "what to run"
half, distinct from intake — and its co-location forces the
input↔mouse mutual import (mouse.zig imports `input` for
`executeAction`/`grafted`; `input` re-exports `mouse`). The cycle is
Zig-legal and runtime-only (the tree accepts the same shape for
input↔events), but it is the one structural debt left in the subsystem.
**Ideal:**
```
input/input.zig    — XKB lifecycle, keybind map, key event intake, setup
input/dispatch.zig — executeAction + grafted + closeWindow +
                      toggleBarPosition + dirSign (the action
                      interpreter; imported by input.zig AND mouse.zig)
input/mouse.zig    — unchanged shape; imports dispatch.zig, no longer
                      input.zig (cycle broken)
```
**Path:** (1) create `input/dispatch.zig` with the five interpreter
symbols and their imports (spawn, lifecycle, restart, diag, focus,
actions, pipeline, surfaces, window, atoms, types, constants) — the
cluster is self-contained: `closeWindow`/`toggleBarPosition` are each
called from exactly one `executeAction` arm, and `grafted`/
`executeAction` have no consumer outside `input.zig` and `mouse.zig`;
(2) `input.zig` calls `dispatch.executeAction` from `handleKeyPress`
and drops the moved imports (grep shows no other external consumer, so
no re-export is required — add one only if a consumer appears);
(3) `mouse.zig` imports `dispatch.zig` for `executeAction`/`grafted`
and drops its `input.zig` import entirely (it needs nothing else from
input); (4) run the suite — `input_test.zig` (resolver, classification,
scaffold-gate, mouse-shadowing) passes unchanged; no behavior change.

### `input/mouse.zig` (288) — button/motion intake + gesture classification  **★**

**Now:**
```
handleButtonPress: setLastEventTime; super_held; clicked_window;
  plain (non-Super) click on the bar -> surfaces.handleButtonPress, return;
  else handleWindowButtonPress
MousePress = { super_held, button, target_managed, bind_fired }
MouseIntent = scroll_bind | unmanaged | focus_click | bound_action |
              start_drag | replay        // each arm = one grab outcome
classifyMousePress(p) -> MouseIntent     // PURE: scroll-before-managed,
                                         //   focus-before-bind, drag-vs-replay
                                         //   by button number
handleWindowButtonPress: mods; findManagedWindow; target_managed;
  scroll bind looked up FIRST (window 0 — fires over desktop+bar);
  then managed+Super bind; classify; exhaustive switch, no else:
    scroll_bind/unmanaged/replay -> releaseGrab
    focus_click -> grabFocus + releaseGrab
    bound_action -> {} (dispatch already released)
    start_drag -> actions.startDrag + keepDragGrab
handleButtonRelease: setLastEventTime; bar release -> surfaces; stopDrag
handleMotionNotify: setLastEventTime; bar scrub -> surfaces;
  dragging -> updateDrag; else clear suppress
reportUndeliverableMouseBinds: warn binds the root grab cannot deliver
                               (dedup by (mods, button))
findMouseBind: LAST match wins; every shadowed entry logs
tryConfigMouseBind: find + dispatch (toggle_floating grafts on the
  CLICKED window; everything else executes against keyboard focus) +
  releaseGrab
finishGrab/releaseGrab/keepDragGrab: xcb_allow_events(pointer, ts) +
  xcb_allow_events(ASYNC_KEYBOARD, ts) + flush
```
**Verdict:** ★ — the round-1 extraction is the right shape and it is
more than a split: the routing rule is now a pure, unit-tested
function (`classifyMousePress`), and the Super+click SYNC-grab
invariant is compile-checked — the `MouseIntent` dispatch is
exhaustive with no `else`, so an arm that forgets to settle the grab
(or a new intent) is a build error, not a frozen keyboard-and-pointer.
The lookup order (scroll precedes the managed guard; focus precedes
the bind) is pinned by `input_test.zig`. One nit: `executeAction`/
`grafted` are imported from `input.zig`, keeping the input↔mouse
cycle — resolved by `input.zig`'s dispatch extraction above.
**Ideal:** unchanged + delta: `const dispatch = @import("dispatch.zig")`
replaces the `input.zig` import for the two interpreter symbols;
everything else identical.
**Path:** (1) after `input.zig`'s extraction, swap mouse.zig's
`input.grafted`/`input.executeAction` for `dispatch.*` and drop the
`input.zig` import; (2) re-run `input_test.zig` (classification,
shadowing, scaffold gate) — unchanged.

### `input/keybind.zig` (287) — bind resolution + dispatch map  **★**

**Now:**
```
DispatchEntry = { key: u64 (mods<<32 | keysym), action: *const Action }
KeybindResolver { entries (sorted slice), config_rev, stale_reported }
  dispatchKey(mods, keysym) -> u64
  find(key) -> ?usize                    // std.sort.binarySearch
  rebuildDispatchMap(binds, alloc, rev): clearRetainingCapacity;
    per bind: dedup-on-insert (later wins -> logShadowConflict),
    appendAssumeCapacity, heap sort
  lookup(mods, keysym, live_rev): generation-checked (fail closed,
    report once via @constCast latch), then bisect
  deinit
logShadowConflict(table, i, mods, trigger_label, trigger)  // shared by
                                           // keyboard AND mouse tables
ResolvedBind = { modifiers, keysym, keycode: ?u8 }
resolveKeycodes(binds, state, out): zip; keycode = state.keysymToKeycode
MouseGrabSpec = { buttons, modifiers, lock_bits }   // the root grab, as data
undeliverableMouseBindReason(mb, grab) -> ?[]const u8  // PURE rule
reportUnresolved(resolved)               // once per resolve, capped at 8
```
**Verdict:** ★ — the layout-independent resolution the constraints
demand lives here and nowhere else: keysym-indexed, keycode resolved
against live XKB state, and the dispatch map is a sorted u64-keyed
slice (no hash state, no rehashing, O(log n) on the hot path). The
`config_rev` generation check turns "rebuild before the config swap
frees the Actions" from a comment into a checked invariant that fails
closed, and `logShadowConflict` is shared by the keyboard and mouse
tables so the two paths cannot drift. One micro-nit:
`rebuildDispatchMap` heap-sorts inside the insert loop (O(n² log n));
negligible at config sizes and it preserves config-order shadow
diagnostics — a collect-then-sort-once would need a second pass to
keep the warning order.
**Ideal:** unchanged. **Path:** none.

### `input/xkbcommon.zig` (293) — XKB state lifecycle  **★**

**Now:**
```
XkbState = { context, keysym_by_keycode[256]u32, reverse: ReverseIndex }
init(conn): context_new; retrySetup (withRetries); enableDetectableAutoRepeat
            (xcb_xkb_per_client_flags, best-effort); retryDeviceId;
            tableForDevice; buildReverseIndex
deinit: context_unref
rebuild(conn): device id (warn + keep old when -1); keymapForRebuild
               (ONE attempt — no retry ladder in the event loop); swap
               table + reverse atomically (failure keeps old mapping)
keycodeToKeysym(kc) -> u32               // flat table read, lock-independent
keysymToKeycode(sym) -> ?u8              // reverse bisection
withRetries(T, args, attempt, failure)   // generic retry ladder
retryDelay: nanosleep, EINTR-resume
```
**Verdict:** ★ — the lifecycle is exactly right: init retries the
early-startup XKB negotiation (setup / device-id / keymap behind one
generic ladder), rebuild deliberately does NOT retry (the server just
announced the change, so the keymap is already present and a retry
would only sleep the event loop), and the table swap is atomic so a
failed rebuild leaves dispatch fully functional on the old mapping.
The detectable-auto-repeat enablement (the held-key flapping fix) is
isolated, best-effort, and allowlisted in check-layers.sh. Level-0
reads keep a startup CapsLock from pinning shifted symbols.
**Ideal:** unchanged. **Path:** none.

### `input/keymap.zig` (155) — keycode↔keysym tables  **★**

**Now:**
```
@cImport owner for xkbcommon (+x11) headers (borrowed by xkbcommon.zig
  and keysyms.zig — one translation unit)
baseSymbol(km, kc) -> u32                // level-0 read, lock-independent
buildKeysymTable(km) -> BuiltTable{table, healthy}
                                         // flatten + health count in ONE walk
ReverseIndex{index, len}.find(sym) -> ?u8  // bisection
buildReverseIndex(table): insertion sort by keysym, LOWEST keycode on a
  tie; post-sort dedup (adjacent-after-sort) makes the tie-break real
health heuristic: >= min_keymap_symbols (40) reachable in 8..128
```
**Verdict:** ★ — connection-free and pure (importable from the pure
layers), the single-`@cImport` ownership is a real consolidation, and
the reverse-index tie-break is correct for the subtle reason (scan-side
dedup would miss duplicates that are non-adjacent in keycode order;
the post-sort compaction catches them) — documented and tested. The
readiness heuristic guards the early-startup race the retry ladder
works around.
**Ideal:** unchanged. **Path:** none.

### `input/keysyms.zig` (32) — name↔keysym  **★**

**Now:**
```
keysymFromName(name) -> u32              // case-insensitive, NUL-truncating
keysymGetName(keysym, buf) -> []u8       // diagnostic messages
```
**Verdict:** ★ — thin, pure, testable (`keysyms_test.zig`); borrows
the `@cImport` from `keymap.zig` rather than translating the header a
second time.
**Ideal:** unchanged. **Path:** none.

---

## Input subsystem summary

Six files: five ★, one ◐. Round-1's mouse extraction landed and is
the right shape — the gesture state machine is a pure, exhaustively
dispatched classification, and the Super+click SYNC-grab invariant is
now compile-checked rather than conventional. The keysym layering
(keysyms → keymap → xkbcommon → keybind → input) is ideal: each layer
is pure or single-purpose, XKB state is isolated and const-exposed, and
the hard X11 problem (layout-independent bind resolution plus the
generation-guarded dispatch map) has a dedicated home. The one
remaining restructure is `input.zig`'s action interpreter: extracting
`input/dispatch.zig` separates "what to run" from "how events arrive"
and breaks the input↔mouse import cycle.

| file | verdict | one-line ideal delta |
| --- | --- | --- |
| `input/input.zig` | ◐ | extract the action interpreter (`executeAction`/`grafted`/`closeWindow`/`toggleBarPosition`/`dirSign`) → `input/dispatch.zig`; breaks the input↔mouse import cycle |
| `input/mouse.zig` | ★ | unchanged (the `input.zig`-import nit is resolved by input.zig's dispatch extraction) |
| `input/keybind.zig` | ★ | unchanged (per-insert heap sort in `rebuildDispatchMap` is negligible at config sizes) |
| `input/xkbcommon.zig` | ★ | unchanged |
| `input/keymap.zig` | ★ | unchanged |
| `input/keysyms.zig` | ★ | unchanged |
