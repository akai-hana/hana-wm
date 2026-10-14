# window review (round 2)

Re-verify of `src/window/**` against the CURRENT tree (fresh, not
inherited from `dev/review/02-window.md`). Round 1 extracted
`hints.zig`/`identity.zig` out of `window.zig` and split the old
`actions.zig` god-file into `geometry/layout_params/ws/wm/modulate`
+ a 233-line hub; both landings are re-verified below, not assumed.
Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** ·
**▽ redesign**.

**Now** = high-level pseudo-code of current behavior · **Verdict** ·
**Ideal** = from-scratch pseudo-code · **Path** = ordered,
behavior-preserving refactor steps.

Layer policy (enforced by `dev/scripts/check-layers.sh`):
wire-mutating XCB requests and server grabs live behind the
`core/x11/reconcile.zig` + `sink.zig` boundary (+ a documented
allowlist — `window.zig`/`focus.zig`/`icccm.zig`/`borders.zig` hold
Rule-1 entries, each for protocol duty, not layout mutation);
`model/`, `tiling/`, `config/` stay xcb-free; single-threaded event
loop; allocation-free hot paths. Core/window reach optional subsystems
only through the `core/architecture/contract.zig` `WindowModule`
contract and the build-generated `window_modules` registry — verified
throughout this tree (no file under `src/window/` names a sibling
module; peers are reached via `window.providerOf`/`callHook*`).

---

### `window/window.zig` (1474) — X11 event boundary + admission + adoption  **◐**
**Now:**
```
FACADE: providerOf/callHook/callHookBool/dispatchAll/dispatchAllTry/
  dispatchFirstTrue/isCoveringMode  (thin typed forwards onto
  contract.* over window_mods[0..]); re-exports the icccm protocol
  surface (peekInputModelResolved/…/discardProtocolCookie)
State = { alloc, spawn_queue[64], rules_map, float_rules,
  child_cache(IdMap,64), snapshot[store_capacity], spawn_cursor,
  borders_flushed_this_batch, warned_active_ignore,
  warned_unmanaged_state }
child resolution: findManagedWindow (direct -> cache -> query_tree
  walk, depth-capped), cacheChildWindow, evictChildCache (value sweep)
buildRulesMap (config rules -> two first-wins hash maps)
ADMISSION: AdmissionRule, findAdmissionRuleByClass (drains WM_CLASS
  cookie -> identity.parseWmClass -> matchRule), matchRule (2 O(1)
  lookups, class then instance), findSpawnQueueWorkspace (exact PID,
  else sole-entry heuristic), resolveAdmissionDecision,
  AdmissionCookies + fireAdmissionCookies (5 pipelined cookies),
  drainAdmissionCookies / discardAdmissionCookies, claimManagedEventMask,
  snapshotSpawnCursor, registerSpawn
handleMapRequest (fire all -> drain -> resolve -> admitWindow)
admitWindow (shared with adoption: getGeometry-if-float -> actions.mapRequest)
ADOPTION: adoptRootWindows (pipelined boot adoption: fire all
  children's cookies up-front, drain in order), applyRestoredRecord
  (ext-blob claimant resolution: named fast-path -> legacy ordinal ->
  magic-byte scan), findWindowRecord, resolveClassFloat, restoredOrCurrent
EVENTS: handleUnmapNotify/handleDestroyNotify -> unmanageWindow
  (evict caches, capture covering/focus into Ctx, dispatchAll
  onWindowGone, actions.unmanage)
  handleConfigureRequest (drag-resize deny -> managed honor/deny ->
  synthetic ConfigureNotify echo), sendRequestedConfigure
  handleEnterNotify/handleLeaveNotify (crossingShouldDrop ->
  suppressSpawnCrossing -> maybeFocusWindow)
  handlePropertyNotify (title / WM_NORMAL_HINTS / protocols+hints refresh)
  handleClientMessage (_NET_WM_FULLSCREEN_REQUEST -> fullscreenSetWindow;
  _NET_ACTIVE_WINDOW -> warn-once reject; _NET_WM_STATE -> toggle)
BORDER SWEEP: sweepWorkspaceBorders(skip_tiled) (one coveringOccupants
  pass + one allWindowsInto pass, ledger dedup),
  updateWorkspaceBorders / updateFloatingWindowBorders /
  updateWorkspaceBordersIfNeeded / reloadBorders
```
**Verdict:** ◐ — cohesive around "the X11 window boundary" and the
pure kernels (hints/identity) are extracted, but the file still carries
five responsibilities (facade, admission, adoption, event handlers,
border-sweep driver) in one 1474-line file. The admission slice
(~400 lines: rules map, spawn queue, the 5-cookie pipeline, the
admission decision, spawn-cursor snapshot) is a clean seam with exactly
two in-file consumers (`handleMapRequest`, `adoptRootWindows`) and its
own state, so it belongs in its own file — round 1's record/store
question obscured it (the file's bulk is admission, not a record
store). Second, the `_NET_WM_STATE` arm of `handleClientMessage`
re-implements the want-vs-current guard that `fullscreenSetWindow`
already performs internally, so it computes `is_fs` (a covering scan)
and then `fullscreenToggleWindow` re-computes it again — two covering
scans per EWMH state message.
**Ideal:**
```
window/admission.zig  — State{spawn_queue, rules_map, float_rules,
  spawn_cursor}; buildRulesMap, registerSpawn, matchRule,
  findSpawnQueueWorkspace, resolveAdmissionDecision, AdmissionCookies +
  fire/drain/discard, claimManagedEventMask, snapshotSpawnCursor,
  suppressSpawnCrossing (owns the spawn-cursor compare)
window/window.zig     — facade + event handlers + adoption + border
  sweep driver; handleClientMessage's _NET_WM_STATE arm calls
  actions.fullscreenSetWindow(win, should_enter) — fullscreenSetWindow
  re-derives is_fs and re-guards internally, so the local guard and the
  local is_fs scan both disappear (wire-identical, one fewer covering scan)
adoption could follow admission out (adopt.zig) as a later step; it
  depends on admission's cookie machinery, so it naturally trails it
each still mutates only via pipeline.mut; admission owns no X beyond
  the cookie fires it already issues
```
**Path:** (1) split `State` into `admission.zig`'s `AdmissionState`
(spawn_queue/rules_map/float_rules/spawn_cursor) and window.zig's
`WindowState` (child_cache/snapshot/borders_flushed/warned latches);
`window.init` calls `admission.init(alloc)` + `admission.buildRulesMap()`,
`window.deinit` calls `admission.deinit()`; (2) move
`buildRulesMap`, `registerSpawn`, `findAdmissionRuleByClass`,
`matchRule`, `findSpawnQueueWorkspace`, `resolveAdmissionDecision`,
`AdmissionCookies` + fire/drain/discard, `claimManagedEventMask`,
`snapshotSpawnCursor`, `suppressSpawnCrossing` verbatim; (3)
`handleMapRequest`/`adoptRootWindows` call
`admission.fireAdmissionCookies(...)`/`admission.drainAdmissionCookies(...)`
(cookie fire/drain order preserved — behavior identical); (4) rewrite the
`_NET_WM_STATE` arm to `actions.fullscreenSetWindow(win, should_enter)`
and delete the local `is_fs` + `should_enter == is_fs` guard; (5) re-run
`actions_test`/`ewmh_test`/`focus_test` + the X scenarios (spawn, EWMH
fullscreen) to pin admission and the EWMH paths.

### `window/focus.zig` (714) — X11 focus protocol  **★**
**Now:**
```
State = { last_applied, suppress_reason, last_event_time,
  net_active_window, tiling_op_cookie }
Query: getFocused (model.focused truth; last_applied pre-pipeline),
  getSuppressReason, protocolParityHolds (test invariant),
  shouldSuppressEnterNotify, getLastEventTime
setLastEventTime / setSuppressReason / focusNow (set_input_focus,
  always CurrentTime)
grabs: grabButtons (ungrab-all, re-grab if unfocused), initWindowGrabs
Reason enum; CommitFlags; SetFocusIntent/ClearFocusIntent;
  FocusTransition union { set, clear, no_input, none }; yieldsModelFocus
Etiquette = { raise, suppress:?Reason, force_set_input_focus } — one row
  per Reason (etiquetteFor), so per-reason policy is data
setIntent, resolveFocusTarget (invalid -> store.has -> map-state liveness
  for mouse_click)
PHASE 1 (outside grab): prepareFocus / prepareClearFocus (cache-only
  input-model resolve; provisionalResolution fallback; zero round trips
  except mouse_click liveness)
PHASE 2 (inside grab): applyPendingFocus (fire-and-forget XCB only:
  set_input_focus, grabButtons, raise, WM_TAKE_FOCUS,
  _NET_ACTIVE_WINDOW, focus.bump)
grabFocus / grabFocusWithDuty (duty runs inside the same grab)
beginTilingOpSettle / drainTilingOpSettle (async has-the-server-caught-up
  poll; lifts suppression only when still .tiling_operation)
cycle_buf (module-global, non-reentrant); collectVisibleWindows,
  cycleIndex, cycleFocus (folds the viewport-snap duty into the cycle's
  grab), cycleTarget (pure read)
```
**Verdict:** ★ — the prepare/apply split makes focus transitions
testable and lets tiling ops defer focus to a settle point; the
`Etiquette` table carries per-reason policy as data (one row, not three
switches); the `FocusTransition` union makes the `no_input` refusal a
type the compiler carries to every consumer (the old module-global flag
could be misread). The two-phase contract (caller does the model write
before the grab, apply runs fire-and-forget XCB inside it) is the right
atomicity boundary. `cycle_buf` is a safe global scratch: `cycleTarget`
returns a copied `WindowId`, so no slice escapes it — unlike
tracking's pre-11.9 snapshot, there is no aliasing hazard to fix.
**Ideal:** unchanged. **Path:** none.

### `window/wincache.zig` (333) — per-window hints + title cache  **★**
**Now:**
```
WindowData = { hints: SizeHints, title_buf[256], title_len }   // POD, inline
CacheMap = AutoHashMap(u32, WindowData)   // heap: 270B/entry x 512
max_entries = max_window_cache (512); ceiling ABOVE store_capacity
getOrPutDefault (at-capacity policy: skip the update, carry on — every
  reader has a correct fall-through; overwrites of cached windows exempt)
cacheSizeHints / peekHints / removeWindow
TitleCookies = { net_wm, wm_name }; fireTitleCookies (both always
  fired, UTF8_STRING preferred), discardTitleCookies, collectTitleCookies,
  pickTitle (_NET_WM_NAME over WM_NAME), takePropertyReply (format-8,
  type-matched validation)
storeTitle / setTitle (truncate at 256) / refreshTitle (single-window
  PropertyNotify refresh, returns changed)
peekTitle (pure cache hit; borrow contract documented)
cachedWindowCount (test-only count seam, 11.9)
```
**Verdict:** ★ — round 1's open question (invalidation coverage) now
passes: both cached fields have a write path, a PropertyNotify refresh
(WM_NORMAL_HINTS -> refreshSizeHints; WM_NAME/_NET_WM_NAME ->
refreshTitle) and an evict-on-unmanage (`removeWindow`), and the POD
inline title buffer removed the last non-POD field and its three
ownership obligations. The at-capacity drop-new policy is stated once and
the ceiling is deliberately above `store_capacity` so transient clients
cannot evict live entries. The heap map (vs icccm's allocation-free
IdMap) is justified by value size (~270B/entry). It sits beside icccm's
per-window property cache as a second keyed store on the same id domain
— justified by the size asymmetry and the different consumers (bar/
admission vs focus protocol), so not a flaw.
**Ideal:** unchanged. **Path:** none.

### `window/wm.zig` (264) — lifecycle actions (fullscreen/map/unmanage)  **★**
**Now:**
```
fullscreenToggleWindow -> fullscreenSetWindow(win, want:?bool)
  (classify enter/exit/switch from prev_fs_win + is_fs; explicit want
  is a SET not a toggle — the _NET_WM_FULLSCREEN_REQUEST path; toggle
  focus the covering winner unless exit/already-focused; EWMH + bar-arm
  land inside the same grab; exit resolves the pending bar-show now so
  the exit bump is the only one; FSPROF timing gated on -Dprofile-key)
mapRequest(win, target_ws, on_current, float_rect)
  (register; bridge cached hints; float-rule detach to anchor+rect, else
  fifo-variant spawn head-slot placement; initWindowGrabs; on-current:
  prepareAndSetFocus(.window_spawn) + reconcileGrabFocus)
focusAfterGeometry (post-adoption focus handoff, shared with restore)
unmanage(ctx, win) (model.unregister + ledger.forget + retileWithFallback;
  covering/focus truth rides ctx because the entry is already gone)
```
**Verdict:** ★ — one model transition + one sync entry per action; the
covering classification (`prev_fs_win` via the module's strict AND scan,
`is_fs` via the model OR scan) asks two different questions and both are
needed (occupant identity vs any-claim truth), with the contrast
documented. The explicit-`want` SET (vs toggle) is the correct EWMH
semantics and the exit-path `resolvePendingBarNow`-then-bump is the
right way to keep the exit bump the only one.
**Ideal:** unchanged. **Path:** none.

### `window/tracking.zig` (172) — read-only model facade  **★**
**Now:**
```
gate (private; only init/deinit model writes: clearFocusMru)
isManaged (the double-manage guard, one place)
allWindowsInto(caller-owned buf) -> []Entry (assert buf.len >= count —
  a short snapshot is a bug, not a clamp)
clearFocusMru; init/deinit (latch workspace_count from config, clamped,
  1 when workspaces off)
getCurrentWorkspace (?u8, read-through over model.current)
getWorkspaceCount; isAllViewActive; workspace_labels (comptime "1".."64")
isTiledMode (anchor == .tiled); isOnCurrentWorkspace (maskedOn)
```
**Verdict:** ★ — the caller-owned snapshot buffer (11.9) removed the
last global mutable scratch in the window layer and the assert replaces
the silent short-clamp; the workspace count is a latched config value
(collapsing the disabled case to 1), not derivable state in the
problematic sense; every read is a read-through over the model so there
is no second store to drift. The private gate keeps the facade
read-only — no writable token escapes.
**Ideal:** unchanged. **Path:** none.

### `window/borders.zig` (136) — shared border resolution + apply  **★**
**Now:**
```
isBehindCoveringWindow(m, win, current, has_fullscreen)  // pure rule
coveringOccupants(m, buf) -> fills one slot per ws in ONE store pass
  (ties resolve to first-in-store-order, matching coveringOccupantOnWs)
isBehindCoveringWindowWith (against the precomputed table)
resolveBorderColor(win) -> coveringOccupants + resolveBorderColorWith
resolveBorderColorWith(win, occupants)  (covering -> 0; behind-covering
  -> 0; else model.focusedBorderColor)
applyWidth (ledger-dedup'd border-width configure; Rule-1 allowlisted)
apply (applyWidth + ledger-dedup'd border pixel)
```
**Verdict:** ★ — the covering-occupant scan is taken as a parameter, so
a sweep asks it once (one store pass) instead of O(N²) per-window; the
"has this pixel already gone out" dedup lives in the sent ledger, one
record answering for both the sweep and the reconcile (the
wincache-derived dedup it replaced was the stale-skip bug class). The
Rule-1 entry is a width-only configure — protocol duty, not a geometry/
map mutation — and is the right place for it.
**Ideal:** unchanged. **Path:** none.

### `window/ws.zig` (226) — workspace actions (move/tag/pin/all-view/switch)  **★**
**Now:**
```
canTagChange (present + not hidden)
moveWindowTo (sendToWs hook; focus fallback on leaving current; fullscreen
  fact bump when the mover was the current ws's occupant)
tagToggle (add/removeFromWs; last-tag protected; reconcile only when the
  visible set on the current ws changed; window-fact bump on off-ws change)
pinToggle (togglePin hook + retile)
allViewToggle (toggleAllView hook; focus fallback when the focused window
  leaves the view on exit; retile focus_restack)
switchTo(ws_idx) (no-op only when already exactly this ws and not
  all-view; suppression reset; all_view_active=false; model.current=ws;
  window-fact bump; surfaces.updateBarVisibilityForWorkspace NOW (X-free)
  so the first reconcile reads the new claim; fullscreen fact bump only
  when the target ws carries an occupant; focusFallback(.workspace_switch)
  decided model-side with zero X round trips; reconcileGrabFocus
  force_restack, FocusOrder.after so the arriving window maps before
  focus targets it)
```
**Verdict:** ★ — one model transition + one sync entry each; the
keyboard switch's no-pointer-query rule (a sync `xcb_query_pointer`
round trip would stall the single-threaded loop behind a fast-following
keypress) is the right call, and the `updateBarVisibilityForWorkspace`
call goes through the `Surfaces` contract (core service), not the bar by
name, so modularity holds. The geometry-before-focus ordering (`.after`)
is documented with the BadMatch it prevents.
**Ideal:** unchanged. **Path:** none.

### `window/icccm.zig` (357) — ICCCM focus protocol + property-query plumbing  **★**
**Now:**
```
cache_slots: IdMap(CachedProps{accepts_input, wm_delete, take_focus})
  (allocation-free, max_window_cache); setCacheArmed/evictCache
InputModel = { no_input, passive, locally_active, globally_active }  (4.1.7)
populateFocusCacheFromCookies (drains the admission WM_PROTOCOLS +
  WM_HINTS pair through the same path as the live query — pipelined
  verdict byte-identical)
firePropQuery / fireWMProtocolsQuery / u32Values / discardProtocolCookie
  (shared property-query plumbing; window.zig's admission + wincache's
  title path ride these)
peekInputModelResolved (cache-only, zero round trips) /
  provisionalResolution (dwm-style fallback, never a blocking live query)
supportsWMDeleteCached (get-or-query on a genuine miss)
sendWMTakeFocusKnown (no protocol-list scan; caller holds the verdict)
refreshCachedPropHalf (refresh the half the notify invalidated, keep the
  other from cache)
```
**Verdict:** ★ — protocol vocabulary isolated; the cache is the
allocation-free IdMap (small POD values) and the hot path is
cache-only with a dwm-style provisional fallback rather than a blocking
live query; the pipelined admission drain shares the live-query drain so
the two verdicts cannot diverge. Round 1's note ("the hint-parsing half
moves with the window.zig extraction") is moot: WM_NORMAL_HINTS parsing
lives in `hints.zig` and never did live here — icccm holds only the
WM_HINTS input flag.
**Ideal:** unchanged. **Path:** none.

### `window/geometry.zig` (260) — geometry actions (float transitions, drag cmds, viewport)  **◐**
**Now:**
```
detachTiledToFloating (seed floating anchor from LastSent, drop home-list)
toggleFloating (covering-anchored windows keep their anchor; tiled->floating
  detach, floating->tiled re-enter home + repairStrandedHome)
dragRect (setFloatingRect hook + dragTick — 1 configure, no grab)
detachToFloating (first motion of a drag on a tiled window)
drag command seams (registry loops, the modularity boundary window.zig
  reaches the floating module through): startDrag/stopDrag/updateDrag/
  isDragging/isResizingWindow/getDragLastRect/cancelDragForWindow
moveFocused (stepTiled, modulo wrap; reconcileGrab)
viewport family: commitViewport, viewportStep, snapViewportParamsToFocused
  (pure param mutation), snapViewportFocusedDuty, ViewportContext,
  viewportContext (resolved through the layout's slotWidth/maxOffset
  metadata), activeViewport
```
**Verdict:** ◐ — the floating transitions and the drag-command seams are
clean (the seven dispatch loops are the *modularity seam* window.zig
reaches the floating module through, not boilerplate — core/window never
names the optional subsystem). Two issues: (1) the viewport family is a
distinct concern (scroll-layout support) sitting beside floating
transitions in the same file; (2) `activeViewport` gates the viewport on
`build_options.has_bar`, coupling a tiling-layout feature to the display
subsystem — the viewport clamps to `usable_area.workArea`, which is the
full screen without a bar, so a scroll layout should work headless; if
the gate exists because the scroll layout's preReconcile duty depends on
a bar-maintained work area, that dependency is the smell, not the gate.
**Ideal:**
```
window/geometry.zig   — float transitions + drag-command seams + moveFocused
window/viewport.zig   — commitViewport, viewportStep,
  snapViewportParamsToFocused, snapViewportFocusedDuty, ViewportContext,
  viewportContext, activeViewport (drop the has_bar gate unless the
  scroll duty genuinely needs a bar-maintained work area — then state
  the dependency explicitly)
```
**Path:** (1) move the viewport family (everything from `commitViewport`
down) into `window/viewport.zig`, re-exporting the four pub fns from
`geometry.zig` (or, since only `actions.zig` re-exports them, update
the hub's re-exports) so importers are untouched; (2) audit
`activeViewport`'s `has_bar` gate: if the scroll layout is usable
without a bar, drop it (the full-screen work area is correct); if the
scroll duty needs a bar-maintained work area, hoist that dependency into
`viewportContext` with a named check rather than a blanket build-flag
gate; (3) re-run the scroll-layout scenario (viewport step + focus-snap
duty) under both `has_bar` configurations.

### `window/layout_params.zig` (202) — layout-parameter actions + config seed  **★**
**Now:**
```
cycleLayoutKind (cycleActiveLayout: config-order cycle + variant reset)
stepVariantDir (wrapIndex over the module's variant count)
adjustPrimaryWidthAction / adjustPrimaryCount (clamped 1..store_capacity/4) /
  adjustSecondaryBalance (clamped to max_primary_swing)
swapPrimaryAction (swapFocusedWithPrevious vs the MRU's [1], not the
  head; focus_swap variant moves focus before the reconcile)
applyRestoredLevel (persist.applyModelLevel — the re-exec restore seam)
seedParamsFromConfig (global template via model.applyConfigReload, then
  per-ws layout/variant/master-count overrides; primary_width/
  secondary_balance reset to runtime defaults)
resolveVariant (override_variant, else the per-layout variants map;
  module's variant_parse interprets; unparseable -> warn + 0)
applyConfigReload (seed + reconcileGrab)
```
**Verdict:** ★ — one model param mutation + one sync entry each; the
config-seeding half (seedParamsFromConfig/resolveVariant) is the same
"layout params" concern as the runtime actions and shares the param
vocabulary, so the grouping holds. `resolveVariant`'s nested logging
distinguishes the override-vs-map spellings, which is genuine
config-resolution policy.
**Ideal:** unchanged. **Path:** none.

### `window/actions.zig` (233) — action hub  **★**
**Now:**
```
gate (private transition-layer token); re-exports the registry seams
  (providerOf/callHook/callHookBool/dispatchAll/dispatchFirstTrue/
  isCoveringMode)
Ctx = { withdrawn_fullscreen_ws, withdrawn_was_focused }  (facts the
  sole unmanage caller captures BEFORE the entry is dropped)
currentCoveringOccupant (module AND hook: visibleCoveringOnWs) /
  isCoveringOnWs (model OR: isCoveringOn)
35 pub const re-exports (modulate/geometry/layout_params/ws/wm) — the
  compatibility seam so keybind/events/input/bar/main importers are
  untouched by the split
retile(RetileOpts, ft) — the four reconcile shapes as ONE axis
  (RetileMode: plain/restack/focus/focus_restack) + two orthogonal
  opts (full_redraw, bump_fullscreen); the fact-bump asymmetry is
  documented (plain leaves the window bump to reconcileGrab)
retileWithFallback (withdraw tail: fullscreen fact + focus fallback)
focusFallback (tiered: focus_mru -> reversed tiled_order -> floating,
  skipping no_input candidates; prepareClearFocus BEFORE model.clearFocus)
prepareAndSetFocus (prepare BEFORE the model write; yieldsModelFocus
  guards the write)
isMinimizedOnAnyWs (isWindowHidden hook)
```
**Verdict:** ★ — the hub owns exactly the shared transition tails, the
registry seams and the re-export surface; the `RetileMode` enum is the
right design (the four reconcile shapes as one axis rejects the
impossible combinations at compile time instead of a four-bool bag with
a truth-table if-chain). The 35 re-exports are the deliberate single
import surface, not redundancy. The five group files import the hub for
the shared tails — the window layer's intentional runtime-only cycle
(runtime accesses only, never comptime).
**Ideal:** unchanged. **Path:** none.

### `window/modulate.zig` (116) — hide/restore (minimize) actions  **★**
**Now:**
```
minimize(focused) (hideWindow hook; capturing-workspace + was-focused
  read BEFORE the park; retileWithFallback)
armFullscreenBarHideIfNeeded (arm the deferred bar-hide when the restore
  opened a fresh claim)
restoreTarget (capture had_occupant_before; restoreWindow hook;
  restoreAndFocus; arm the bar-hide)
restore (isMinimizedOnAnyWs guard -> restoreTarget)
restoreOrdered (restoreCandidateOn hook -> restoreTarget)
restoreAll (latestHiddenOnWs hook; restoreOnWs hook; restoreAndFocus the
  target; arm the bar-hide for the new occupant)
restoreAndFocus (prepareAndSetFocus(.window_spawn) +
  reconcileGrabFocus force_restack)
```
**Verdict:** ★ — one model transition + one sync entry each; the
`armFullscreenBarHideIfNeeded` guard (only when the restore opened a
fresh claim) and the `restoreAll` occupant re-read (the target may not
be the occupant that opened the claim) are the two non-obvious facts and
both are handled. The `had_occupant_before` capture-before-hook is the
right ordering (the hook mutates the occupant set).
**Ideal:** unchanged. **Path:** none.

### `window/restore.zig` (38) — session adoption driver  **★**
**Now:**
```
adoptSession(restore_path)
  (persist.loadToGlobal; window.adoptRootWindows (catch -> log, 0);
  if 0 adopted, return; actions.applyRestoredLevel; actions.focusAfterGeometry)
```
**Verdict:** ★ — thin, single-purpose; the subsystem ordering (persist
-> adopt -> re-apply model level -> focus) is the whole file and it is
explicit. No X requests, config or dispatch of its own.
**Ideal:** unchanged. **Path:** none.

### `window/hints.zig` (93) — WM_NORMAL_HINTS / WM_SIZE_HINTS parsing (pure)  **★**
**Now:**
```
p_min_size/p_max_size/p_resize_inc/p_aspect/p_base_size (ICCCM flag bits)
wm_normal_hints_long_length = 18 (flags + 17 fields)
extractFieldPair(fields, field_count, want, comptime off) -> SizePair
  (shared 2-field pattern for max_size / resize_inc)
parse(fields, field_count) ?model.SizeHints
  (flags -> want_*; null when no constraint flag set; min/base max-floor
  via @max; aspect fields[11..14], dwm convention min=y/x max=x/y;
  zero-denominator -> 0.0)
```
**Verdict:** ★ — pure over the u32 array, no X, no cache writes; the
field-offset walk is comptime-offset and the dwm aspect convention is
documented; the min/base max-floor (a client can never be dragged
smaller than either it or its base declares) is the one policy decision
and it is stated. Tested (7 cases pin the offsets, the clamps, the
truncation, the zero denominators).
**Ideal:** unchanged. **Path:** none.

### `window/identity.zig` (33) — WM_CLASS split (pure)  **★**
**Now:**
```
WmClass = { instance, class }
parseWmClass(data) ?WmClass
  (first \0 splits instance; per-component trailing-null trim, NOT a
  whole-buffer trim — "instance\0\0" keeps the instance and an empty
  class; null when no separator at all)
```
**Verdict:** ★ — the byte-level split only (the reply read stays with
the caller); the per-component trim rule is the one subtlety and it is
documented with the failure mode a whole-buffer trim would introduce.
Tested (7 cases).
**Ideal:** unchanged. **Path:** none.

### `window/modules/floating.zig` (455) — floating drag/resize module  **★**
**Now:**
```
DragState = { active, window, mode, resize_corner, start_*, last_rect,
  snap_px, workarea, last_commit_ns, pending_rect }  // snap/workarea
  resolved ONCE at drag start (constant for the whole drag)
snapDistance / workarea / snapAxis / nearestResizeCorner (8-directional
  grip)
State = { drag, pending_float }; resetState / seedLeakedDragForTest
  (test-only, builtin.is_test-guarded)
startDrag (config/is-active/surface/covering guards; model/sync truth
  rect, live query only when never placed; button1=move else resize;
  grabFocus + pipeline.raiseWindowNow — the Rule-1-sanctioned stack
  write)
computeMoveRect / sizeHintLimits (PMin/PBase + PMax, +2*bw outer bound) /
  computeResizeRect (anchor/moving-corner math, clamp-then-re-pin,
  floor = max(min_dim, declared min))
updateDrag (pending_float detach on first motion; i32-widened deltas;
  hz-throttled commits — compute every event, push at >= 1 refresh period,
  capped 1000Hz)
stopDrag (flush pending) / cancelDragForWindow / isDragging /
  isResizingWindow / getDragLastRect
setFloatingRect (model rect update, covering-guarded)
honorConfigureRequest (floating: apply requested fields; tiled:
  border_only; hidden/covering -> ignored)
module: { name="floating", the nine floating-family hooks }
```
**Verdict:** ★ — drag state is module-private, the motion math is
factored into pure `compute*Rect` functions, and the incremental
`dragTick` path (1 configure, no grab) avoids full sweeps per motion
event. The hz-throttled commit (compute every event for responsiveness,
push at refresh rate) is the right latency/throughput trade. The module
reaches peers only through the registry (`window.callHookBool`) and its
one wire write (`raiseWindowNow`) is the Rule-1-sanctioned stacking
primitive — deleting the file leaves zero residue.
**Ideal:** unchanged. **Path:** none.

### `window/modules/fullscreen.zig` (358) — fullscreen (covering) module  **★**
**Now:**
```
PendingBar = { win, hide }
PendingBarTable (per-window deferred bar intents, max 8; arm upserts,
  at-capacity reuses the last slot; take swap-removes; PEEK-not-take
  for undecidable ConfigureNotify; clear)
g_net_wm_state / g_net_wm_state_fullscreen (atom-cache-resolved);
  resetState (shared init/deinit)
toggleCovering/toggleFullscreen (hidden-guarded; OFF = releaseCovering;
  ON = release the resident occupant (when the entrant claims this ws),
  then presence=.covering + covering_ws=current — the model stays the
  authority)
releaseCovering (ONE-WAY demote verb — a peer that means "demote"
  cannot turn a demote into an entry)
visibleCoveringOnWs (strict AND: covering + anchored + visible) /
  moveCoveringTo (retarget covering_ws) / setEwmhFullscreenState
  (routes through pipeline.currentCtx().sink.setStateAtom — the sync
  sink owns the wire write)
notifyConfigureIfPending (peek; decision is MODEL TRUTH
  (presence==.covering), not the reported dimensions; enter confirms on
  screen-sized + covering, exit on non-screen-sized + not covering)
armPendingBarHide / armPendingBarShow / resolvePendingBarNow / onWindowGone
module: { name="fullscreen", lifecycle + protocol + coverage hooks }
  (NO serializeWindow/deserializeWindow — anchor + covering_ws are
  carried verbatim by persist.WindowRecord)
```
**Verdict:** ★ — the deferred bar hide/show (PendingBarTable) is the
correct shape: the bar's visibility transition is resolved at a
controlled point (a confirmed ConfigureNotify whose decision is model
truth), not mid-reconcile; the per-window table (not one slot) is the
12.7 fix for the dropped-second-transition bug. The one-way
`releaseCovering` (12.8) makes a demote unrepresentable as an entry.
Covering state is model-carried, so the module correctly binds no
persistence blob.
**Ideal:** unchanged. **Path:** none.

### `window/modules/minimize.zig` (326) — minimize module  **★**
**Now:**
```
g_recs: BoundedList(Rec{win, slot:?usize, seq:u32}, max_minimized)  //
  static, allocation-free; the model's presence=.parked IS the minimized
  state, g_recs holds the tiled slot + ordering seq
g_seq (monotonic, saturating +| so persisted seqs keep ordering stable)
minimize (idempotent; capacity pre-check; parkEntry; append; seq++)
parkEntry (drop the tiled home-list slot; tiled-anchor windows lose
  home_ws, float-anchored keep it; presence=.parked)
restore (tiled-anchor: re-list at current-ws-if-tagged else lowest-bit;
  refu-list append then re-insert at the recorded slot; presence back to
  .covering if covering_ws survived, else .present; float-anchor:
  home_ws=null)
bestSeq (fifo/lifo over parkedOnWs; skip_covering reads model.covering_ws
  directly — 12.1, not a peer hook that answers false without the module)
restoreCandidate / latestMinimizedBase (skip_covering=true)
restoreAllOnWs (collect, sort by slot, restore)
isMinimized / count (test-only) / collectHiddenSet
serializeWindow / deserializeWindow (9-byte blob: 0x5A magic + slot-or-
  maxInt + seq; magic-byte self-identification; at-capacity still claims
  the blob so the window is not left permanently parked)
onWindowGone (removeById)
module: { name="minimize", lifecycle + persistence + hide/restore hooks }
```
**Verdict:** ★ — LIFO/FIFO restore order via the monotonic `seq` (no
side buffer); the hidden-set collection is shared with the border/
visibility logic through `collectHiddenSet`; the persistence blob is
self-identifying (magic byte) so the registry deserialize loop needs no
ordinal. The 12.1 fix (read `covering_ws` off the model, not a peer
hook) is exactly right — a minimized fullscreen window restores back into
covering because the intent survived the park.
**Ideal:** unchanged. **Path:** none.

### `window/modules/workspaces.zig` (122) — workspace-state transitions module  **★**
**Now:**
```
switchTo (test-only; the production switch is actions.switchTo)
moveWindowToWs (pinned stays; refu-list capacity pre-check;
  transferFullscreenOnMove; mask=bit(ws); home-list move when the
  target differs)
retargetOrDropFullscreen (a resident occupant at dest -> releaseCovering
  (12.8 one-way); else moveCoveringTo — both through the registry,
  fullscreen is never named)
transferFullscreenOnMove (model.coveringWsOf — 12.4 model query, not a
  peer dispatch that answered false without the module)
tagRemove (last-tag protected; covering-on-removed-ws retargets to the
  lowest remaining bit or drops)
tagAdd / pinToggle / allViewToggle
module: { name="workspaces", sendToWs/addToWs/removeFromWs/togglePin/
  toggleAllView }  // pure model edits, no state of its own
```
**Verdict:** ★ — pure model edits; the one cross-module rule (covering
intent follows a move/tag) is dispatched through the registry (never
naming `fullscreen`), and both 12.4 fixes (model query for "is
covering", one-way `releaseCovering` for demote) are in place. A
membership IS the tag mask plus the home list, so a move is one mask
write plus two list edits — no separate registry to scan.
**Ideal:** unchanged. **Path:** none.

---

## Window subsystem summary (round 2)

- 18 files: 16 ★, 2 ◐ (window.zig, geometry.zig), 0 △, 0 ▽. Round 1's
  one ◐ (wincache) is upgraded: its open invalidation-coverage question
  now passes (every cached field has a PropertyNotify refresh and an
  evict-on-unmanage). Both round-1 extractions (hints/identity out of
  window.zig; the actions five-way split) are re-verified as principled
  and behavior-preserving.
- The two remaining ◐ are refinement, not repair: `window.zig` is a
  borderline god-file whose admission slice is a clean extraction
  round 1's record/store question obscured, and `geometry.zig` mixes
  the scroll-layout viewport into the floating-transition file and gates
  it on the bar.

| file | verdict | ideal delta (one line) |
| --- | --- | --- |
| `window/window.zig` | ◐ | split the admission slice (rules/spawn/cookie pipeline) into `admission.zig`; call `fullscreenSetWindow(win, should_enter)` in the `_NET_WM_STATE` arm (drops the local guard + a redundant covering scan) |
| `window/focus.zig` | ★ | unchanged — two-phase protocol, Etiquette table, Transition union; `cycle_buf` is safe (no slice escapes) |
| `window/wincache.zig` | ★ | unchanged — invalidation audit (round 1's open question) passes |
| `window/wm.zig` | ★ | unchanged |
| `window/tracking.zig` | ★ | unchanged — caller-owned snapshot, private gate |
| `window/borders.zig` | ★ | unchanged — one-pass occupant table, ledger dedup |
| `window/ws.zig` | ★ | unchanged — model-side switch focus, Surfaces-contract bar visibility |
| `window/icccm.zig` | ★ | unchanged — allocation-free IdMap, cache-only hot path |
| `window/geometry.zig` | ◐ | extract the viewport family into `viewport.zig`; drop/justify the `has_bar` gate in `activeViewport` |
| `window/layout_params.zig` | ★ | unchanged |
| `window/actions.zig` | ★ | unchanged — hub at ideal shape (RetileMode one axis) |
| `window/modulate.zig` | ★ | unchanged |
| `window/restore.zig` | ★ | unchanged |
| `window/hints.zig` | ★ | unchanged |
| `window/identity.zig` | ★ | unchanged |
| `window/modules/floating.zig` | ★ | unchanged |
| `window/modules/fullscreen.zig` | ★ | unchanged |
| `window/modules/minimize.zig` | ★ | unchanged |
| `window/modules/workspaces.zig` | ★ | unchanged |

**Cross-cutting (no ▽, but worth a decision):** two parallel
per-window caches keyed on the same id with the same lifecycle —
`icccm`'s allocation-free `IdMap` (focus props: accepts_input/
wm_delete/take_focus) and `wincache`'s heap `HashMap` (hints +
title). The split is justified today by value-size asymmetry (~12B
POD vs ~270B) and by different consumers (focus protocol vs
bar/admission), so it is not a defect — but the eviction/refresh
triggers are duplicated across the two (`unmanageWindow` calls both
`icccm.evictCache` and `wincache.removeWindow`), so any future
per-window cache field has to be wired into both. If a third per-window
cache ever appears, converge them into one per-window record cache
with the small POD fields inline and the large title buffer heap-backed
behind a pointer, so there is one key domain, one lifecycle, one
eviction path.
