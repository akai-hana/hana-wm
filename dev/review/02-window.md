# Window subsystem review (`src/window/**`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `window/window.zig` (1474 lines) — window records + admission  **★ (hints + identity extracted)**
**Now:**
```
Window record store: per-window state (geometry, size hints,
  floating flag, override rect, transient-for, class/instance,
  title, pid, workspace membership mirror)
register/unregister, lookup helpers, geometry accessors,
  override setters, hint caching (WM_NORMAL_HINTS parsing)
```
**Verdict:** ★ — the record type plus its accessors, the admission policy (spawn rules, map-request handling, session adoption), the configure/property event handlers, and the border sweeps are one cohesive lifecycle; the two extractable pure kernels are extracted.
**Ideal:**
```
window/hints.zig    — WM_NORMAL_HINTS / WM_SIZE_HINTS parsing (pure), DONE
window/identity.zig — WM_CLASS instance/class split (pure), DONE
window/window.zig   — record + admission + store + event handlers
```
**Path:** (1) ~~extract `hints.zig`~~ **DONE** (93 lines): the ICCCM flag bits, the field-offset walk (`extractFieldPair`), and the flags→`model.SizeHints` derivation moved verbatim as `parse(fields, field_count) ?model.SizeHints` — pure over the u32 array, no X, no cache writes; `window.zig` keeps the reply drain and the model/wincache write policy, calling `hints.parse`; `hints.wm_normal_hints_long_length` is the query-length seam; `hints_test.zig` (7 cases) pins the field offsets, the min/base max-floor, the dwm aspect convention, the truncation and zero-denominator clamps; (2) ~~extract `identity.zig`~~ **DONE** (33 lines): the `parseWmClass(data) ?WmClass` split moved verbatim (per-component trailing-null trimming, the "instance\0\0 empty-class" rule); `findAdmissionRuleByClass` keeps the reply read and delegates; `identity_test.zig` (7 cases) pins the split; (3) leave the record + admission + store together as `window.zig` (the review's original "record.zig/store.zig" decomposition does not map onto the actual file: the file's bulk is admission policy — spawn queue, rules map, session adoption — not a separate record/store). Each extraction is behavior-preserving; `wincache_test.zig`/`ewmh_test.zig` cover the seams.

### `window/actions.zig` (233 lines) — action hub  **★ (five groups extracted)**
**Now:**
```
Action entry points (one per keybind Action):
  minimize/restore/restoreOrdered/restoreAll
  fullscreenToggleWindow/fullscreenSetWindow
  moveWindowTo/tagToggle/pinToggle/allViewToggle
  toggleFloating, dragRect, detachToFloating
  startDrag/stopDrag/updateDrag/isDragging/...
  cycleLayoutKind, stepVariantDir, adjustPrimaryWidth/Count,
    adjustSecondaryBalance, swapPrimaryAction, moveFocused
  viewportStep, snapViewportFocusedDuty, applyRestoredLevel
  seedParamsFromConfig, applyConfigReload
  switchTo, mapRequest, focusAfterGeometry, unmanage
Each: mutate model (via pipeline.mut gate) -> reconcile tick
```
**Verdict:** ★ — the hub owns the shared transition tails (retile/retileWithFallback/focusFallback/prepareAndSetFocus), the registry seams, and the re-export surface; the five action groups are uniform one-transition-plus-one-sync entries in their own files.
**Ideal:**
```
actions/geometry.zig    — drag/rect/moveFocused/viewport (geometry ops), DONE (260 lines; the `geom` stem is taken by bar/modules/title/geom.zig)
actions/layout_params.zig — cycle/variant/primary/swap + config seed (layout params), DONE (202 lines; the `layout` stem is taken by bar/modules/layout/layout.zig)
actions/ws.zig          — switchTo/moveWindowTo/tag/pin/allView, DONE (226 lines)
actions/wm.zig          — mapRequest/unmanage/fullscreen/floating, DONE (264 lines)
actions/modulate.zig    — minimize/restore, DONE (116 lines)
actions.zig             — shared tails + registry seams + re-exports (hub), DONE (233 lines)
each calls pipeline.mut() then a reconcile variant
```
**Path:** (1) ~~group the fns into the five sections~~ **DONE** (the file already carried section banners); (2) ~~physically split~~ **DONE** — five files, fns verbatim with `retile(`→`actions.retile(`-style substitutions for the shared tails; single-group helpers moved with their group (restoreTarget/restoreAndFocus/armFullscreenBarHideIfNeeded → modulate; detachTiledToFloating/repairStrandedHome/the viewport family → geometry; cycleActiveLayout/resolveVariant → layout_params; canTagChange → ws), multi-group helpers stayed pub in the hub (currentCoveringOccupant, isCoveringOnWs, isMinimizedOnAnyWs, focusFallback, prepareAndSetFocus, retile, retileWithFallback, gate, the registry seams); (3) ~~keep `actions.zig` re-exporting all pub fns~~ **DONE** — 35 `pub const` re-exports, so `keybind`/`events`/`input`/`bar`/`main` importers are untouched. Each group file + the hub form the window layer's intentional runtime-only import cycles (runtime accesses only, never comptime). Verified: `actions_test.zig` + `workspaces_test.zig` + `focus_test.zig` + `ewmh_test.zig` green after every split, plus the full suite, check-layers, and all 31 modularity scenarios.

### `window/focus.zig` (700 lines)
**Now:**
```
focus stack per workspace; suppress-reason enum
protocolParityHolds()      // focus-follows-mouse vs click-to-focus consistency
initWindowGrabs(win)       // per-window button grabs
prepareFocus(win, reason) -> FocusTransition   // pure-ish plan
prepareClearFocus() -> FocusTransition
applyPendingFocus(t)        // execute: set input focus, raise, EWMH _NET_ACTIVE_WINDOW
grabFocus / grabFocusWithDuty
beginTilingOpSettle / drainTilingOpSettle   // deferred focus after tiling ops
cycleFocus(dir, duty), cycleTarget(dir) -> ?WindowId
```
**Verdict:** ★ — the prepare/apply split makes focus transitions testable and lets tiling ops defer focus to a settle point.
**Ideal:** unchanged. **Path:** none.

### `window/icccm.zig` (~300 lines)
**Now:** WM_PROTOCOLS/WM_DELETE_WINDOW/WM_TAKE_FOCUS handling; WM_NORMAL_HINTS size-hint extraction; WM_CLASS parse; _NET_WM_NAME/UTF8_STRING title read; close-vs-focus protocol selection.
**Verdict:** ★ — protocol vocabulary isolated; pure parsers where possible.
**Ideal:** unchanged. **Path:** none. (If `window.zig` extraction above lands, the hint-parsing half of icccm moves with it.)

### `window/tracking.zig` (~400 lines)
**Now:**
```
Entry = { win, mask }       // workspace membership bitmask
allWindowsInto(scratch) -> []Entry
getWorkspaceCount(), workspace_labels[]
add/remove/relabel workspaces
```
**Verdict:** ★ — mask-based membership is the single source of truth both the model and the bar tags segment read.
**Ideal:** unchanged. **Path:** none.

### `window/wincache.zig` (~200 lines)
**Now:** transient per-window cache (last-seen attributes/geometry) so event handlers avoid redundant X round trips; invalidation hooks on relevant events.
**Verdict:** ◐ — caching is the right call for a poll-free event flow; worth auditing that every cache line has an invalidation trigger (the `wincache_test.zig` suite exists for exactly this).
**Ideal:** same shape; a comptime field-keyed invalidation table if the cache grows.
**Path:** none required; add an invalidation-coverage test per field if not present.

### `window/borders.zig` (140 lines)
**Now:**
```
coveringOccupants(model, buf) -> []?WindowId   // fullscreen/covering scan
isBehindCoveringWindow(...) / isBehindCoveringWindowWith(...)
resolveBorderColor(win) -> u32        // focused/unfocused/covering-aware
resolveBorderColorWith(win, occupants)
applyWidth(conn, win); apply(conn, win)
```
**Verdict:** ★ — color resolution takes the covering-occupant scan as a parameter, so the scan is shared, not duplicated per call site.
**Ideal:** unchanged. **Path:** none.

### `window/restore.zig` (~30 lines)
**Now:** `adoptSession(restore_path)` — load persisted session (persist.zig) and re-adopt windows.
**Verdict:** ★ — thin, single-purpose.
**Ideal:** unchanged. **Path:** none.

---

## `window/modules/` — feature modules (registry-bound)

### `window/modules/floating.zig` (410 lines)
**Now:**
```
floating set (BoundedList); resetState()
startDrag(win, button, x, y)   // button 1 = move, button 3 = resize
updateDrag(x, y)               // pointer-math -> rect; reconcileDragTick
stopDrag(); cancelDragForWindow(win)
isDragging(); isResizingWindow()
seedLeakedDragForTest(win)
```
**Verdict:** ★ — drag state is module-private, motion math is pure, and the incremental reconcile path (`reconcileDragTick`) avoids full sweeps per motion event.
**Ideal:** unchanged. **Path:** none.

### `window/modules/fullscreen.zig` (340 lines)
**Now:**
```
PendingBarTable { arm/take/peek/clear }   // deferred bar hide/show
toggleFullscreen(model, win) -> bool
releaseCovering(model, win)
visibleCoveringOnWs(model, ws) -> ?WindowId
moveFullscreenTo(model, win, ws)
setEwmhFullscreenState(win, on)
notifyConfigureIfPending(win, w, h)
armPendingBarHide/armPendingBarShow/resolvePendingBarNow(win)
onWindowGone(win)
```
**Verdict:** ★ — deferred bar hide/show (pending table) is the correct shape: the bar's visibility transition is resolved at a controlled point, not mid-reconcile.
**Ideal:** unchanged. **Path:** none.

### `window/modules/minimize.zig` (310 lines)
**Now:**
```
minimize(model, win) / restore(model, win)
restoreCandidate(...), latestMinimizedBase(model, ws)
restoreAllOnWs(model, ws), isMinimized(model, win), count()
collectHiddenSet(...)   // windows hidden by minimize/covering
serializeWindow / deserializeWindow   // persist blobs
onWindowGone(win)
```
**Verdict:** ★ — LIFO restore order via `latestMinimizedBase`; hidden-set collection is shared with the border/visibility logic.
**Ideal:** unchanged. **Path:** none.

### `window/modules/workspaces.zig` (110 lines)
**Now:**
```
switchTo(model, ws); moveWindowToWs(model, win, ws)
tagRemove / tagAdd(win, ws, protect_current)
pinToggle(model, win); allViewToggle(model) -> bool
```
**Verdict:** ★ — thin model ops; the module owns no X11, so it stays trivially testable (`workspaces_test.zig`).
**Ideal:** unchanged. **Path:** none.

---

## Window subsystem summary

- 14 files: 13 ★, 1 ◐ (wincache). Both former △ god-files are split: `window.zig` (hints + identity extracted, 1558 → 1474) and `actions.zig` (five groups extracted, 1117 → 233-line hub).
- Feature modules are already at their ideal shape: registry-bound, model-only mutations, X11 deferred to the reconciler.
