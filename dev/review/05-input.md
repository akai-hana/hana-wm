# Input subsystem review (`src/input/**`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `input/input.zig` (620 lines) — event intake + dispatch  **◐**
**Now:**
```
initXkb(conn) / deinitXkb() / getXkbState()
setup(conn, screen)          // mouse grabs (root + per-lock-modifier sets)
buildKeybinds(keybindings)   // resolve config binds -> dispatch map
resolvedKeybinds() / deinitKeybinds()
handleMappingNotify(keyboard)   // XKB keymap rebuild on MappingNotify
reportUndeliverableMouseBinds() // warns binds the grab set cannot deliver
handleKeyPress(event)        // keysym -> Action -> execute
handleKeyRelease(event)
handleButtonPress(event)     // mouse bind match + bar routing
classifyMousePress(p) -> MouseIntent   // click / drag-start / scrub
handleButtonRelease(event)
handleMotionNotify(event)    // drag/resize routing (floating module)
findMouseBind(...)
```
**Verdict:** ◐ — correct single-threaded intake; the press-classification and motion-routing halves (mouse gesture state machine) are a distinct concern from key dispatch and could be `input/mouse.zig`. Also the largest reason this file is long: motion routing re-enters the floating module's drag state.
**Ideal:**
```
input/input.zig   — XKB + key dispatch + grabs
input/mouse.zig   — button/motion intake, press classification,
                      drag routing to the floating module
```
**Path:** (1) extract the four mouse handlers + `classifyMousePress` + `findMouseBind` + `undeliverableMouseBindReason` consumer into `input/mouse.zig` verbatim; (2) keep `input.zig` re-exporting them. Tests: `input_test.zig` covers press classification.

### `input/keybind.zig` (270 lines) — bind resolution  **★**
**Now:**
```
KeybindResolver { dispatch map: (keycode, modmask) -> Action }
rebuildDispatchMap(keybindings, keymap state)
resolveKeycodes(...)          // keysym -> keycode expansion (all layouts)
undeliverableMouseBindReason(bind, grab_spec) -> ?[]const u8
reportUnresolved(resolved)    // warn on binds that matched no keycode
logShadowConflict(...)        // warn when a later bind shadows an earlier
deinit(alloc)
```
**Verdict:** ★ — keysym-to-keycode expansion across all keyboard layouts is the hard part of X11 keybinding and it is isolated here; shadow-conflict and undeliverable-bind warnings are exactly the diagnostics a config author needs.
**Ideal:** unchanged. **Path:** none.

### `input/keymap.zig` (120 lines) — keycode↔keysym tables  **★**
**Now:**
```
buildKeysymTable(keymap) -> [x11_max_keycode]u32   // keycode -> keysym
ReverseIndex { find(keysym) -> ?keycode }           // keysym -> keycode
buildReverseIndex(table) -> ReverseIndex
```
**Verdict:** ★ — fixed-size arrays, no allocation; the reverse index is the structure the dispatch map is built on.
**Ideal:** unchanged. **Path:** none.

### `input/keysyms.zig` (~40 lines)
**Now:** `keysymFromName(name) -> u32`; `keysymGetName(keysym, buf) -> []u8` — name↔keysym via the xkbcommon keysym tables.
**Verdict:** ★ — thin, pure, testable (`keysyms_test.zig`).
**Ideal:** unchanged. **Path:** none.

### `input/xkbcommon.zig` (140 lines) — XKB state  **★**
**Now:**
```
XkbState { context, keymap, state }
init(xcb_conn):            // xkb_context_new, keymap from XCB,
                           // state, detectable auto-repeat enabled
deinit()
rebuild(xcb_conn)          // on MappingNotify / config reload
```
**Verdict:** ★ — enabling detectable auto-repeat (via `xcb_xkb_per_client_flags`) is the subtle fix that stops a held key from emitting interleaved KeyRelease events; documented and isolated.
**Ideal:** unchanged. **Path:** none.

---

## Input subsystem summary

- 5 files: 4 ★, 1 ◐ (input.zig — mouse-intake extraction).
- The keysym/keycode layering (keysyms → keymap → keybind → input) is already ideal: each layer is pure or single-purpose, and the hard X11 problem (layout-independent bind resolution) has a dedicated home.
