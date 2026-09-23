# Input-layer simplification audit (v8)

Scope: `src/input/input.zig` (556), `src/input/xkbcommon.zig` (279),
`src/input/keybind.zig` (81), `src/input/keysyms.zig` (37).
Research-only pass; no files modified. Interop references into core are marked.
Baseline: clean tree `c5b0873`.

Prior-plan verification (SIMPLIFICATION_PLAN_v6 §D, items ER-01..03, ER-05..10,
ER-12 claimed DONE; ER-11 recorded no-op; ER-04 is guard-policy) against CURRENT
source — all verified fixed, none re-reported:

- ER-01 flat retry loops: `retrySetup`/`retryDeviceId`/`retryKeymap` are 3 flat
  `for` loops; no generic `retryPoll`/closures survive. ✓
- ER-02 `onBarWindow` predicate exists (input.zig:208) and is used by all three
  handlers. ✓
- ER-03 dispatch map value is `*const types.Action`, no `Entry`/`first_index`
  (keybind.zig:22,30-48). ✓
- ER-05 keysyms.zig:27 uses `xkb.XKB_KEYSYM_CASE_INSENSITIVE` directly. ✓
- ER-06 `sendWmDelete`/`forceDestroy` folded; one `closeWindow` (input.zig:313). ✓
- ER-07 `const matched` has no type annotation (input.zig:176). ✓
- ER-08 `clicked_window == 0` gone; guard is root-or-unmanaged (input.zig:251). ✓
- ER-09 ICCCM cites §4.1.2.7 consistently (input.zig:310,335). ✓
- ER-10 `screen.root`, no `.*` (input.zig:544). ✓
- ER-12 `pipeline.model()` hoisted to `const m` (input.zig:461). ✓
- ER-11 no `barForward`; single `chromeHandleKeypress` gate (input.zig:180). ✓

Verified-clean (grep-confirmed, no finding): the keysym name↔keysym pair lives
ONLY in keysyms.zig (`keysymFromName` ← config, `keysymGetName` ← keybind);
xkbcommon.zig no longer re-exports either (old B4/IN-13 overlap is resolved).
No dead params/imports/pub fns in the four files. No chained keysym
if/else-if-else candidates in scope (dispatch is the O(1) map lookup).

---

## Findings

### [IN01] Medium / High: input.zig:313-327 — `closeWindow` repeats the same destroy fall-back three times
- What: three identical `{ _ = xcb.xcb_destroy_window(conn, win); return; }`
  tails guard (a) no `WM_DELETE_WINDOW` support (315-318), (b) missing
  `WM_PROTOCOLS` atom (320-323), (c) missing `WM_DELETE_WINDOW` atom (324-327);
  the graceful path is sunk two levels deep.
- Why: 6 duplicated lines triple spelling of one fallback; the reader must
  confirm all three tails are the same.
- Concrete fix: invert — run the graceful path in a labeled block and fall
  through to a single trailing destroy:
  ```zig
  fn closeWindow(win: u32) void {
      const conn = core.getState().conn;
      if (window.supportsWMDeleteCached(conn, win)) blk: {
          const protocols_atom = utils.getAtomCached("WM_PROTOCOLS") orelse break :blk;
          const delete_atom = utils.getAtomCached("WM_DELETE_WINDOW") orelse break :blk;
          var event = std.mem.zeroes(xcb.xcb_client_message_event_t);
          ... // send, unchanged
          return;
      }
      _ = xcb.xcb_destroy_window(conn, win);
  }
  ```
- LoC delta: −3..−4.

### [IN02] Low-Medium / High: input.zig:354-360 — `executeSequenceStep` is a one-use wrapper
- What: 7-line helper (with inline `return`) used only by the `.sequence` arm
  (input.zig:369); its body is `if (a.* == .exec) spawn.execSynchronous(a.exec) else executeAction(a)`.
- Why: one-use wrapper; the fold is behavior-identical and the `.exec`-vs-everything
  special case reads fine inline.
- Concrete fix:
  ```zig
  .sequence => |acts| for (acts) |*a|
      if (a.* == .exec) spawn.execSynchronous(a.exec) else executeAction(a),
  ```
  (move the existing 3-line comment above the arm).
- LoC delta: −4.

### [IN03] Medium / Medium: xkbcommon.zig:129-131 vs 150-151 — `init` and `rebuild` duplicate device+keymap acquisition
- What: `init` does `retryDeviceId` (retried) + `retryKeymap`; `rebuild` re-spells
  the same pair but grabs the device id UNRETRIED (`xkb_x11_get_core_keyboard_device_id`
  single call, `== -1` test). Same follow-on: `buildKeysymTable(km)` + `defer unref`.
- Why: two spellings of "fetch the core-keyboard keymap"; the retried vs
  single-shot divergence is also an inconsistency — mapping-notify can race the
  same early-startup window the retries exist for, yet only `init` gets them.
- Concrete fix: one helper
  ```zig
  /// Fetches the core-keyboard keymap, retrying the device+capture race.
  fn loadKeymap(ctx: *xkb_context, xcb_conn: *anyopaque) !*xkb_keymap {
      return retryKeymap(ctx, xcb_conn, try retryDeviceId(xcb_conn));
  }
  ```
  `init`: `const km = try loadKeymap(ctx, xcb_conn);`
  `rebuild`: `const km = loadKeymap(self.context, xcb_conn) catch { warn; return; };`
  Note: rebuild now also retries the device id; failure still keeps the old
  mapping (same contract).
- LoC delta: −1..−3 (larger win is consistency, not lines).

### [IN04] Low / Medium: input.zig:38-41 — unanchored comment paragraph about floating
- What: the import block's last comment ("Floating drag commands are reached
  through actions… not by naming the floating module here…") sits between the
  `events` import and the math/spawn region with no anchoring import; floating
  was never imported here and nothing in the adjacent lines relates to it.
- Why: reads as a leftover from a version that did import floating; duplicates
  the layer rationale documented at input.zig:49-53 and in the module docs.
- Concrete fix: delete the 4 lines (the floating-via-actions fact is already
  documented at the `actions`/drag call sites, e.g. the tryConfigMouseBind note).
- LoC delta: −4.

### [IN05] Low / High: input.zig:96-99 vs 106-110 — `handleMappingNotify` restates its own doc inline
- What: the `///` doc's second half (97-99: "the per-binding keycodes the key
  grabs were made with… go stale; re-resolve… and re-grab") is restated almost
  verbatim by the 5-line inline comment (106-110) inside the body.
- Why: 5 lines that add no information beyond the doc.
- Concrete fix: collapse to one line, e.g.
  `// Re-resolve per-binding keycodes from the new table, then atomically re-grab.`
- LoC delta: −3..−4.

### [IN06] Low / Medium: keysyms.zig:27,34 — redundant `@ptrCast` on C-pointer coercion
- What: `xkb_keysym_from_name(@ptrCast(z.ptr), …)` casts a `[*]const u8` to the
  C pointer param; `xkb_keysym_get_name(…, @ptrCast(buf.ptr), …)` casts `[*]u8`.
  `[*]T` → `[*c]T` is an implicit coercion in Zig 0.16.
- Why: 2 dead casts in the pure layer the config keeps minimal.
- Concrete fix: pass `z.ptr` / `buf.ptr` bare.
- LoC delta: −2. (Verify with a build before landing.)

### [IN07] Low / Medium: keybind.zig:38-47 — `contains` then `put` double-hashes the same key
- What: `rebuildDispatchMap` calls `self.map.contains(key)` purely for the
  conflict warn, then `put` performs a second lookup.
- Why: redundant double operation; `getOrPut` reports existence in one pass.
- Concrete fix:
  ```zig
  const gop = self.map.getOrPut(allocator, key) catch |e| {
      debug.warnOnErr(e, "keybind map build");
      continue;
  };
  if (gop.found_existing) debug.warn("Keybinding conflict: binding #{} …", .{ … });
  gop.value_ptr.* = &kb.action;
  ```
- LoC delta: −1..−2. (Config-reload path, not hot; worth it for single-source.)

### [IN08] Medium / Medium: xkbcommon.zig:96,183,212,233,254,264 — inconsistent code-space/retry loop spellings and identity casts
- What: three keycode-band loops spell the range two ways —
  `for (@as(usize, constants.x11_min_keycode)..constants.x11_max_keycode)` (96,
  183, forcing the loop var to usize) vs `for (constants.x11_min_keycode..keymap_health_hi)`
  (254, u8-typed var). Consequence: the `@intCast(kc)` at 97/184 are real (u8→u8
  for `baseSymbol`… no — usize→u8), while the one at 255 is an identity u8→u8.
  Likewise the three retry loops `for (0..max_xkb_retries) |i|` (u8 range since
  `max_xkb_retries: u8`) cast `retryDelay(@intCast(i))` (u8→u8, identity).
- Why: 6 casts, of which 4 are identity; two loop-range spellings for the same
  band make the casts look load-bearing when they are not.
- Concrete fix: drop the `@as(usize, …)` on 96/183 (range infers u8 from
  `x11_min_keycode: u8`), iterate `|kc|`/`|i|` as u8, pass/return bare.
- LoC delta: −4..−5 at 6 sites.

### [IN09] Low / Low-Medium: src/core/x11/masks.zig:76-77 — "ledger-less repeat path in input.zig" references removed machinery (interop)
- What: the `KEY_RELEASE` rationale says "the ledger-less repeat path in
  input.zig". The held-key ledger (`held_keys`, `keyHeld`…) was removed by the
  v3 INPUT-2; "ledger-less" is a stale place-holder term for a path that cannot
  be named by a ledger concept anymore.
- Why: readers will search for a ledger to understand "ledger-less"; the
  sentence's actual claim (detectable-auto-repeat re-fires presses; releases are
  otherwise lost) survives without the term.
- Concrete fix: reword to "the detectable-auto-repeat press/release stream in
  input.zig" or drop "ledger-less".
- LoC delta: −1..−2.

### [IN10] Medium / Medium: xkbcommon.zig:252-259 + 94-100 + 263-279 — two full `baseSymbol` walks per keymap load
- What: `retryKeymap` runs `keymapHasEnoughSymbols` (scan 8..128) and, once
  accepted, the caller runs `buildKeysymTable` (scan 8..255). Each is a full
  `baseSymbol` loop over the same keymap.
- Why: double work on the init and mapping-notify paths; two separate scans for
  one acceptance decision.
- Concrete fix: fold the health count into `buildKeysymTable`'s single pass —
  return the table plus the reachable-symbol count in the 8..128 window, have
  `retryKeymap` return the table (accepting only when the count ≥
  `min_keymap_symbols`), delete `keymapHasEnoughSymbols`.
- LoC delta: −5..−8.

### [IN11] Low / Medium: input.zig:45 — `mouse_buttons` module const is single-use
- What: the 5-element array is declared at module scope (input.zig:45) but only
  iterated in `setupGrabs` (input.zig:126); nothing else references it.
- Why: module scope for a local; the const sits far from its only reader.
- Concrete fix: move the declaration into `setupGrabs`.
- LoC delta: 0 (locality only).

Total estimated: −28..−37 LoC across 11 findings (IN01-IN11).

---

## Examined and rejected (no finding)

- **`finishGrab`/`releaseGrab`/`keepDragGrab` trio** (input.zig:494-515):
  `releaseGrab`/`keepDragGrab` differ only in the pointer mode constant and
  `keepDragGrab` has one call site, but the names encode the replay-vs-keep
  semantics and the doc enforces the "always `event.time`" invariant; folding
  would trade a guard point for −3 lines. Keep.
- **`dirSign` float spellings** (input.zig:391,393): the two `@as(f32,
  @floatFromInt(dirSign(dir)))` sites are a fixed pair; re-adding a `dirSignF`
  twin would regress the v5 IN-20 consolidation. Keep.
- **Scroll/edge two-way button checks** (input.zig:245,261): 2×2 `or`-tests, each
  used once; a shared predicate adds a helper for no saving. Keep.
- **`mouse_bindings` `toggle_floating_window` special case** (input.zig:481-484):
  mirrors the `executeAction` branch but targets the CLICKED window — behavioral,
  documented, not a simplification.
- **retry-loop skeleton duplication** (retrySetup/retryDeviceId/retryKeymap):
  this IS the accepted post-ER-01 flat shape; re-generalizing would regress
  ER-01's ruling. Keep.
- **Bar-first routing in the three pointer handlers** (input.zig:229,279,295): a
  shared shape calling three different surfaces methods on three event types;
  the v4 IN-17 informational deferral stands. Keep.

## DEFERRED / QUESTIONS

1. **Bare-bool conversion `mode == .focus_swap`** (input.zig:394 →
   `actions.swapPrimaryAction`): previously DEFERRED (v4 IN-16, "matches WIN-9
   deferral") and still open. Enabling a `FocusedSwapKind` enum param touches the
   actions API; decision belongs to the window-layer owner. Re-listed for
   awareness only — not a new finding.
2. **keysyms `@ptrCast` removal (IN06)** and **u8 loop-var inference (IN08)** are
   type-inference claims I could not build-verify (research-only pass). Both
   should be re-checked with one `zig build check` before landing; if the C-import
   param does not coerce implicitly, IN06 collapses.
3. **IN03 networking**: sharing `loadKeymap` changes `rebuild` from single-shot
   device-id to retried. That is a strengthening consistent with the file's
   stated intent, but it IS a (cold-path) behavior change — confirm the owner
   accepts it under the "keep old mapping on failure" contract (it does).
4. **`xkb_state` access duality** (input.zig:166 direct field vs `getXkbState()`
   at 83/103): two access paths to the same module state; harmless, but the
   accessor exists only for the events reload-null-check. Leave as-is unless the
   reload path is revisited.
5. **Health-check constants** (`min_keymap_symbols` 245, `keymap_health_hi` 248):
   if IN10 lands, reword the constants' comment blocks to sit beside
   `buildKeysymTable` rather than `keymapHasEnoughSymbols`.