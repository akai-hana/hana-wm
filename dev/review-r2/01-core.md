# core review (round 2)

Re-verify of `src/core/**` against the CURRENT tree (fresh, not inherited from
`dev/review/01-core.md`). Round-1's one △ (events.zig) landed its dispatch
table; `persist/spawn/signals/restart/lifecycle` now sit under `core/proc/`.
Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

**Now** = high-level pseudo-code of current behavior · **Verdict** · **Ideal**
= from-scratch pseudo-code · **Path** = ordered, behavior-preserving refactor steps.

Layer policy (enforced by `dev/scripts/check-layers.sh`): wire-mutating XCB
requests and server grabs live behind the `core/x11/reconcile.zig` +
`sink.zig` boundary (+ a documented allowlist); `model.zig`, `tiling/`,
`config/` stay xcb-free; single-threaded event loop; allocation-free hot
paths. Verified honored throughout this tree.

---

## `core/core.zig` (334) — process-global state + facade

**Now:**
```
State = { conn, screen, root, alloc, config: *Config, dpi_info, facts: Facts }
Facts = { focus_rev, window_rev, fullscreen_rev, layout_rev, config_rev }   // u32 counters
factAccessors(field) -> { rev(), bump() }   // per-fact accessors: focus/window/.../config_rev
Phase = { uninit, core_ready, model_ready }; currentPhase/markCoreReady/markModelReady
isReady() (= state != null); isModelReady() (= phase == .model_ready)
getState() -> *State (panic before init)
init(conn, screen, root, alloc, config, dpi)   // writes State once, markCoreReady
tilingEnabled(); borderWidth()                  // config facts core answers without importing tiling
toggleBarScreenPosition()                       // single writer of config.bar.bar_position
refreshScreenGeometry(conn) -> bool             // re-read root geometry, update cached screen
replaceOwnedConfig(new)                          // deinit displaced box, swap ptr, bump config_rev
deinitOwnedConfig(); dpi()/setDpi(v)
pub const xcb/Connection/Screen/eventCast/WindowId/WorkspaceId  // FACADE re-exports
pub const XK (keysym enum)
```
**Verdict:** ◐ — the singleton is the pragmatic C-boundary choice and the
`Facts` revision counters (consumers diff a u32 instead of dereferencing a
possibly-freed pointer after a config swap) are the right mechanism. Two nits:
(1) `core.zig` is simultaneously a *facade* (re-exporting `xcb`, `Connection`,
`Screen`, `eventCast`, `WindowId`, `WorkspaceId`, `XK` from the x11 leaf and
`ids`) *and* the state singleton — two roles in one file; (2) the `Phase`
machine has a deliberate hole: `markModelReady()` does NOT require
`.core_ready` first (for headless test fixtures that have no X connection), so
`uninit → model_ready` is a legal jump a production boot can never produce.
Documented, but it means the "one readiness answer" is not a strict linear
progression.
**Ideal:**
```
// State owns only process-global state; the facade re-exports move to the x11
// leaf (or a tiny core/facade.zig) so a module that wants the protocol types
// imports the leaf, and core.zig's only public surface is State + Facts + Phase.
// Equivalent behavior; no runtime gain today — a cleanliness split only.
```
**Path:** (1) keep as-is — single-threaded main loop makes the singleton
race-free and the facade is a convenience, not a coupling; (2) long-term only:
move the `xcb`/`Connection`/`Screen`/`eventCast`/`XK` re-exports into the x11
leaf so `core.zig` is purely the state module. Do not spend effort now.

---

## `core/architecture/` — composition contracts (pure vocabulary)

### `core/architecture/contract.zig` (830)
**Now:**
```
tiling_mods = has_tiling ? generated_registry : &[_]Layout{}   // ONE intentional edge
default_kind = 0                                             // named sentinel
moduleOf(kind) -> ?*const Layout            // bounds-checked registry lookup (owns the guard)
activeLayoutKind(kind, tiling_enabled) -> ?u8   // registry + tiling gates
activeLayoutMeta(kind, tiling_enabled, pick, fallback) -> T
WindowModule = { name, init, deinit, ...36 fields }   // hook shape
  .single_binder_hooks / .multi_binder_hooks / .non_hook_fields  // PARTITION, comptime-asserted
Segment = { name, self_ticking, center_slot, dirty_sources, ... }  // bar-segment shape
  .single_binder_hooks = { measureString, overlay }
Layout = { name, compute, variant_count, fifo_variant, variant_parse, slotWidth, maxOffset, preReconcile, icon, indicators }
View / Placement / List / HintsView / Env / parked_rect   // tiling interchange vocabulary
providerOf/callFirst/callFirstBool/callAll/callAllTry/callFirstTrue   // one dispatch family
DirtySources / BarOverlay / KeyPressEvent (opaque) / Painted / Frame / ClickCtx
comptime { every WindowModule field classified exactly once; list names are real fields }
```
**Verdict:** ★ — the seam vocabulary of the whole plugin system. The comptime
partition assert (every `WindowModule` field classified into exactly one of
single/multi/non-hook, with `assertListedFields` proving each list names a real
field) makes an unclassified or renamed hook a *compile error* rather than a
silent escape. The one edge into a generated module (`tiling_mods`) is named
and intentional. Size is the honest union of three plugin interfaces + the
interchange vocabulary, and it is self-checking.
**Ideal:** unchanged.
**Path:** none.

### `core/architecture/contract_x11.zig` (67)
**Now:**
```
KeyPressEvent = xcb_key_press_event_t   // the concrete half of contract.KeyPressEvent
Surfaces = { init, deinit, handleExpose, updateIfDirty, pollTimeoutMs, onPollWakeup,
             updateClock, onReload, chromeHandleKeypress, isBarWindow, handleButtonPress,
             handleButtonMotion, handleButtonRelease, setBarState, updateBarVisibilityForWorkspace,
             hideBarForFullscreen, toggleBarSegmentAnchor, barForcedHiddenByFullscreen,
             chromeToggleOverlay }   // one type in EVERY build (generated no-op when no chrome)
```
**Verdict:** ★ — the no-op `Surfaces` is generated when no chrome is compiled in,
so call sites never test a build flag. The X-typed half of the contract lives
here so `contract.zig` stays importable by headless/config-only consumers.
**Ideal:** unchanged. **Path:** none.

### `core/architecture/model.zig` (624)
**Now:**
```
Rect{x,y,width,height,border_width} { eql, eqlGeom }   // geometry value object
Margins{gap,border}; doubledBorder; satI16; toXcbCoord; wrapIndex
Mask=u64; bit(ws); maskedOn; ALL_MASK
SizeHints{min/max/inc/aspect, isEmpty}
max_layouts=256; LayoutParams{kind,variant_idx,primary_width,primary_count,secondary_balance,viewport_offset,viewport_prev_count}
BaseMode = tiled | floating:Rect; Presence = {present, parked, covering}
Entry{mask,anchor,size_hints,home_ws,presence,covering_ws}
WsState{tiled_order, focus_mru, params}; Store=bounded.Store; capacities
lowestBit; Model{store, ws[MAX_WS], current, focused, all_view_active}
register(win,hint_ws) / unregister(win)   // defined-capacity refusal with rollback; whole-model scrub
findHome (cached home_ws, fallback scan); visibleOn/visibleEntry/isPinned/taggedOn
tiledCountOnWs; coveringWsOf/isCovering/isCoveringOn/coveringOccupantOnWs (anchor-or-visible OR)
setFocus (MRU upkeep) / clearFocus / focusedBorderColor / applyParamsDelta
collectCyclePool (tiled_order first, then untiled store order, covering collapses pool)
fallbackFocusCandidate (MRU → reversed tiled_order → floating tail)
reorderTiled/stepTiled (wrapIndex)/swapPrimary/swapFocusedWithPrevious/adjustPrimaryWidth
applyConfigReload (preserve viewport runtime state across the reload template)
```
**Verdict:** ★ — pure domain model, zero I/O, zero allocation, xcb-free (only
`std` + `constants` + `bounded` + `ids`). The `*const` read-only export via
pipeline is the mutation tripwire. `eql` vs `eqlGeom` exists because a `Rect`
carries geometry AND border width, sent by different requests tracked by
different sent-state. `unregister`'s whole-model scrub (not just the cached
home) removes the home-then-unregister ordering dance.
**Ideal:** unchanged. **Path:** none.

---

## `core/pure/` — allocation-free vocabulary (xcb-free)

### `core/pure/bounded.zig` (340)
**Now:**
```
BoundedList(T,N): stack array + len
  indexOf(ctx, comptime match); fieldEq; indexOfByIdField; indexOfScalar
  append -> bool (false when full); upsertById; swapRemove; orderedRemove
  pushFrontEvictingTail (newest-N pattern, one call)
  removeWhere/removeById/removeValue/removeAllById/removeAllWhere
  insert(i, item) -> bool; clear
Store(K,V,N): sorted-key binary search
  exactAt/lowerBound; getPtr/get/has; put -> error{CapacityFull}!*V (one lowerBound)
  remove -> bool; Iterator (sorted row); at(seq) (assert len>0, clamp); count; indexOf
```
**Verdict:** ★ — the two containers the entire WM runs on. Capacity-full is a
returned `bool`/`error{CapacityFull}`, never a panic; no allocator anywhere.
`pushFrontEvictingTail` is the newest-N pattern as one container op (the
evict-then-insert order cannot be transposed at a call site).
**Ideal:** unchanged. **Path:** none.

### `core/pure/log.zig` (181)
**Now:**
```
moduleFromSrc(@src()) -> basename sans .zig
Diagnostic{level, module, message}
Collector{allocator, items: ArrayList<Diagnostic>}: count/contains/line   // --check-config counts
pub var collector: ?*Collector   // module-level; installed by --check-config
capture/log(err/warn/info/debug)   // collector captures warn/err; test-silence unless test_emit
err/warn/info/debug(...)            // routed through std.log, tag = moduleFromSrc
warnOnErr(e, context)
WindowedProfiler(enabled, fmt, logFn)   // rolling 200-sample latency profiler
```
**Verdict:** ★ — the module-level `collector` pointer means the sixty-odd config
warn sites need zero signature changes, and CI gates on a count instead of
scraping text. The test-silence rule (`is_test and !test_emit`) keeps the 0.16
runner's "any stderr fails the step" from turning recoverable-path tests red.
`WindowedProfiler` is a mild co-tenant (profiling, not logging), but it is
diagnostic machinery that reports through this sink — acceptable.
**Ideal:** unchanged. **Path:** none.

### `core/pure/idmap.zig` (162)
**Now:**
```
IdMap(V,N): open-addressed u32 -> V, Fibonacci hashing, power-of-two slots
  home(id); find(id) -> ?usize (stops at empty, steps over tombstones)
  get/contains; put -> bool (rehash when len+tombstones == slots, false at capacity)
  remove -> bool (tombstone); count; clear; rehash (drop tombstones in place)
  Iterator (walks slot array, remaining-countdown — cannot scan keys[0..len])
```
**Verdict:** ★ — tombstones keep probe chains intact across removes; `put`
rehashes before declaring full so a tombstone-heavy table degrades gracefully.
The iterator's slot-array walk (with the documented reason it cannot scan a
dense prefix) is correct.
**Ideal:** unchanged. **Path:** none.

### `core/pure/constants.zig` (108)
**Now:** comptime limits — `max_workspaces=64` (tied to the u64 mask + fixed
`ws` array), `max_tiled_windows=64`, `offscreen_x_position=-30000` (clears
any realistic desktop under the INT16 floor), `max_minimized=32`,
`x11_min/max_keycode`, `property_max_length`, mouse-button codes,
`baseline_dpi`, master-width bounds/steps.
**Verdict:** ★ — each constant is single-sourced with its consumers named in
the comment (e.g. `max_workspaces` raises require widening the u64 geom cache
and per-ws override tables first). Pure leaves, no dependencies but std.
**Ideal:** unchanged. **Path:** none.

### `core/pure/paths.zig` (97)
**Now:**
```
common_dirs = { /usr/bin, /usr/local/bin, /bin }
common_paths = StaticStringMap(common_dirs)      // comptime-derived dedup set
dirIterator(env_val) -> DirIterator            // common_dirs first, then $PATH minus covered
exeInDir(buf, dir, name) -> bool               // faccessat X_OK (existence AND executability)
configHome(buf, xdg, home) -> ![]const u8       // $XDG_CONFIG_HOME (non-empty) else $HOME/.config
restricted_file_mode = 0o600
```
**Verdict:** ★ — dedup between well-known dirs and `$PATH` is derived at comptime
so the two lists cannot drift. `configHome`'s empty-`XDG_CONFIG_HOME`-means-
unset rule (joining `""` would yield a relative path) is the XDG spec and a
concrete bug fix.
**Ideal:** unchanged. **Path:** none.

### `core/pure/dpi_math.zig` (74)
**Now:**
```
min/max_reasonable_dpi = 50/300; mm_per_inch = 25.4
Geometry{width_px,height_px,width_mm,height_mm}   // struct so the formula can't take args in the wrong order
lineStartOf(haystack, key) -> ?usize              // key at a line boundary (head or after \n)
parseXftDpi(resource_str) -> ?f32                  // "Xft.dpi:" at a line boundary, else null
calcDpiFromGeometry(g) -> ?f32                     // null when 0mm (virtual/headless)
isReasonableDpi(dpi) -> bool                       // finite and in band
```
**Verdict:** ★ — the line-boundary match is the fix for a plain `indexOf`
matching "NotXft.dpi:" / "MyXft.dpi:". Pure and testable without a server.
**Ideal:** unchanged. **Path:** none.

### `core/pure/ids.zig` (70)
**Now:**
```
WindowId = u32
isValidWorkspaceIndex(i) -> bool   // the ONE validity notion
WorkspaceId = struct { index: u8 }
  fromIndex(i) (lenient — config/recovery) / fromIndexChecked(i) (asserts) / isValid / eql
```
**Verdict:** ★ — one type per id across the core/model boundary (no conversion);
lenient vs checked constructors split by call-site kind. Lives in `pure` because
both the hub and the (xcb-free) model need it.
**Ideal:** unchanged. **Path:** none.

### `core/pure/time.zig` (38)
**Now:** `clockNs(clock_id)` (best-effort fallback to the other clock), then
`monotonicNs/Ms` (deadlines, deltas) and `realtimeNs/Ms (timestamps, expiry).
**Verdict:** ★ — two deliberately non-interchangeable families, kept together so
a caller picks deliberately. Pure leaves.
**Ideal:** unchanged. **Path:** none.

### `core/pure/scaling.zig` (38)
**Now:** `asRatio`, `scaleToPixels(value, ref)`, `scaleBorderWidth(value, ref)`
(percent → half the reference, a border insets two sides), `roundToU16`,
`clampToU16`. Pure functions over `ScalableValue`, no DPI lookup.
**Verdict:** ★ — canonical scaling formulas, single source. Pure leaves.
**Ideal:** unchanged. **Path:** none.

---

## `core/loop/` — event loop

### `core/loop/events.zig` (945) — the event loop  **◐** (up from round-1 △)
**Now:**
```
dispatch_table = comptime [event_code]?EventHandler   // indexed by response_type & 0x7f
  (ENTER/LEAVE, MAP/CONFIGURE_REQUEST, UNMAP/DESTROY, CLIENT_MESSAGE, KEY_PRESS/RELEASE,
   MAPPING_NOTIFY, BUTTON_PRESS/RELEASE, MOTION_NOTIFY, PROPERTY_NOTIFY, EXPOSE, CONFIGURE_NOTIFY)
asHandler(f) -> EventHandler   // comptime-checks the fn(*T)->void shape, then @ptrCast
handleExpose/handlePropertyNotify/handleConfigureNotify/handleDestroyNotify/handleMappingNotify  // 6 adapters
isRandrEvent(code) / routeFor(raw) -> {core, randr, ignore}   // SendEvent bit stripped FIRST
dispatch(type, event) / dispatchOwned(event) (frees; xtrace.inbound)
eventType(e); eventWindowFor(t, event) -> u32   // per-type offset table (4 / 8 / 12), pure+tested
fillGrabCookies/checkGrabCookies; grabMouseButtons; grabKeybindings   // pipelined grabs (fire all, then check)
handleConfigReload() !void     // load -> validate -> swap -> per-subsystem rebuild -> regrab
handleReexec() !void           // persist -> handoff -> disconnect -> execNext
drainEvents/collapseMotionRun (comptime pull/cap/with_tail) ; isMotion ; handleXcbEvents  // motion coalescing
run()  // poll(timeout) -> drain signals -> drain spawns -> consume reload/reexec -> handleXcbEvents -> redetect -> updateClock
```
**Verdict:** ◐ — the round-1 △ ("extract the dispatch switch into a table")
**landed**: the comptime `dispatch_table`, the pure `routeFor` routing decision,
and the pure `eventWindowFor` offset table are all present and testable
without an X connection. What keeps it at ◐ rather than ★ is size and bundling:
at 945 lines it is still the largest file in core, and two of its
responsibilities are coherent sub-concerns that are not per-event dispatch:
grab installation (`fillGrabCookies`/`checkGrabCookies`/`grabMouseButtons`/
`grabKeybindings`, ~130 lines) and `handleConfigReload` (~95 lines of
load→validate→swap→rebuild→regrab orchestration). Both are loop-invoked
transitions, so the file is not a mixed-responsibility god-file — but they are
extractable, and extracting them would separate the hot per-event path from the
lifecycle transitions.
**Ideal:**
```
handlers: [event_code]HandlerFn            // comptime dispatch table (present)
run():
  while running:
    timeout = timers.deadlineMs()
    evt = poll(timeout)
    dispatch(evt)                          // table lookup; extension base checked first (present)
    drainSignals(); drainSpawns()
    consumeReload() -> reload.apply()      // handleConfigReload moved to core/loop/reload.zig
    consumeReexec() -> restart handoff
    handleXcbEvents()                      // motion coalescing (present)
    runPendingRedetect(); updateClock()
// core/loop/grabs.zig: grabKeybindings/grabMouseButtons/cookies  (moved out of events.zig)
```
**Path:** (1) extract grab installation into `core/loop/grabs.zig` (verbatim
move of the cookie/grab family; `handleConfigReload` and boot call into it);
(2) extract `handleConfigReload` into `core/loop/reload.zig` (it already
touches six subsystems and is a lifecycle transition, not a per-event concern);
(3) keep the dispatch table, `routeFor`, `eventWindowFor`, drain order, and
motion-coalescing logic byte-identical. Each step independently testable via
`events_test.zig`.

### `core/loop/pipeline.zig` (550) — model owner + transition layer
**Now:**
```
instance: Model (stack, no allocator)
init()            // instance = .{}; g_sink = { conn }; markModelReady(); ledger.init()
model() -> *const Model          // read-only export; panic before init
mut(g: *const Gate) -> *Model    // private transition gate
getCurrentLayout() / getCurrentVariantIdx(); defaultIndexForLayout(name)
g_sink / syncSink(); g_ctx / ctx()   // per-tick reconcile Ctx (asserts grab_depth == 0)
tilingEnv(); colorOf(win, m)
dragTick(win)   // flushless drag reconcile (raiseWindowNow's ungrabbed path)
preReconcileDuties()   // active layout's preReconcile delta via model.applyParamsDelta
prepare() = preReconcileDuties + ctx(); currentCtx()  (asserts grab_depth > 0)
raiseWindowNow(win)   // ungrabbed stackOnly + flush (drag-tick)
grab_depth; ScopedGrab{c,s} { deinit (assert+ungrabAndFlush), reconcileNow (refresh workarea/bar_win, run) }
grabScoped() / grabOnly() / withServerGrab(body)
retile_prof; reconcileUnderGrabNow(o); reconcileGrab()   // bumps window_rev
reconcileGrabFocus(o, t, order, duty); focusOnlyCommit(t)
FullscreenKind; reconcileUnderGrabNowFullscreen(...)   // EWMH + bar hide/show inside the grab
reconcileNow()   // flushless, fresh ctx, no grab (drag tick)
```
**Verdict:** ◐ — the `*const`/`Gate` split is exactly right, and `ScopedGrab`
(grab ownership as a depth-counted token whose `deinit` asserts and
ungrab+flushes) is the correct fix for the non-reentrant `XGrabServer` hazard
(a nested ungrab would release the outer grab). Size (550) comes from being the
single transition layer — the correct home for this code. The split point, if it
ever grows past ~800, is the reconcile-family entry points
(`reconcileGrab`/`reconcileGrabFocus`/`reconcileUnderGrabNowFullscreen`) into a
`pipeline_reconcile.zig`.
**Ideal:** same shape.
**Path:** none today; note the split point for the future.

### `core/loop/xtrace.zig` (123)
**Now:**
```
watch: ?[]const u32 (lazy from HANA_XTRACE; "*" = empty list = all); armed: bool
enabled() -> bool   // one-compare hot-path guard
watches(win) -> bool   // empty list = all, else scan
name(t) -> []const u8   // event-code -> name table (SendEvent bit stripped)
inbound(t, win); outbound(win, what, arg); announce()
```
**Verdict:** ★ — opt-in, zero-cost-when-disabled, lazy env resolution keeps
getenv off the hot path.
**Ideal:** unchanged. **Path:** none.

### `core/loop/diag.zig` (48)
**Now:** `dumpState()` — read-only snapshot: focused window, total windows,
suppress reason, per-ws window counts (stack scratch `[store_capacity]`),
tiling layout/kind, tiled count (gated on build_options).
**Verdict:** ★ — read-only snapshot; the stack scratch array keeps `tracking`
free of module-level mutable state.
**Ideal:** unchanged. **Path:** none.

### `core/loop/timers.zig` (39)
**Now:** `Source = *const fn () ?i32` (null = no wakeup wanted);
`Timers.deadlineMs()` — min over ALL sources (never short-circuits), null when
none.
**Verdict:** ★ — the reduce-over-all-sources rule IS the policy; absence is
`null`, not a negative number, so "no timer" and "timer in -1ms" cannot be
confused. The list is not redundant — it is the rule a one-entry version
could not express.
**Ideal:** unchanged. **Path:** none.

---

## `core/x11/` — X11 leaf layer (wire mutations behind the sink)

### `core/x11/reconcile.zig` (498) — the reconciler
**Now:**
```
Ctx{ sink, screen, workarea, env, color_of, bar_win, layout_active }
Opts{ force_restack }
reconcileDragTick(m, snk, win)   // fast path: geometry only for the dragged floating window
run(m, ctx, opts):
  wa = ctx.workarea; fs_win = coveringOccupantOnWs(m, current)
  build order_buf/hints_buf/placements + pl_of_slot[] (O(1) placement lookup)
  layout compute (skipped under fs_win; float_all when tiling off/absent)
  winner seed = fs_win | focused-if-non-parked
  FUSED store loop:
    gop = ledger.sentGetOrPut(win); last = gop or blank
    OFF-WORKSPACE FAST PATH: !is_fs and definitely_parked_desire and last.parked and !last.parked_dirty -> skip
    desire = computeDesire(...)   // rect, bw, pixel, parked; fallback-winner election
    if parked: map-if-never-sent + park (on transition or parked_dirty)
    else: derive map/pixel/bw/geom/raise from last vs desire; ONE merged configure
    ledger write (park preserves rect/has_rect; visible overwrites)
  force_restack -> stackOnly(bar_win, above)
truthRect(m, win)   // floating base rect, else last sent visible geometry
computeDesire / desireIsNonParked / markParked / placementOfSlot
```
**Verdict:** ★ — the crown jewel, re-verified. Unconditional recompute from
the model, delta-send against the sent ledger, atomic under a server grab
(bracketed by the caller's `ScopedGrab`). The off-workspace fast path is a
real optimization with a correct escape (`parked_dirty` — a client that moved
itself while parked forces a re-park). The `pl_of_slot` lookup table turns
placement resolution from O(N) per window into O(1). The four ledger reads
(off-workspace fast path, multi-tag orphan keep-last, winner-raise derivation,
truthRect) are contractual and documented in the header. `desireIsNonParked`
is shared by the winner seed and `computeDesire`, so the focused-window
priority cannot drift from its desire.
**Ideal:** unchanged. **Path:** none.

### `core/x11/sink.zig` (284) — the send seam
**Now:**
```
Stack = enum { above }
ConfigureWire{mask, values[6]}; configureWire(c) -> ConfigureWire   // PURE assembly, slot order assertable
Configure{ rect: ?Rect, bw: ?u16, stack: ?Stack }
Sink = vtable { map, configure, border_pixel, park, stack_only, set_state_atom, flush, grab_server, ungrab_and_flush }
XcbSink { conn } + shims (each wraps its exact xcb pattern)
  park = X-offscreen + BELOW merged into ONE configure_window (deliberately NOT folded into configure)
  setStateAtom = read-merge-replace _NET_WM_STATE, preserving other atoms (bails on overflow)
xcb_vtable: const shared VTable
```
**Verdict:** ★ — the sanctioned seam where raw xcb calls are allowed; the
vtable exists so tests record requests without an X connection, and
`configureWire` is pure and unit-tested (a swapped slot 2/3 sends width as
height, which X accepts — caught without a server). `park` staying separate
from `configure` is load-bearing: park asserts X only, and folding it into
`Configure.rect` would speculatively move/resize a window whose current rect
the park call site does not trust.
**Ideal:** unchanged. **Path:** none.

### `core/x11/requests.zig` (249) — X request primitives
**Now:**
```
rectFromXcb(reply) -> model.Rect     // xcb-typed adapter, stays on the xcb side
raiseWindow; setBorderPixel; grabServer; ungrabAndFlush (ungrab+flush, not separable)
changeProperty(conn, win, atom, T, atom_type, value)   // replace-mode, format from sizeof(T)
supported_atoms = [ _NET_SUPPORTED, ... ]   // comptime-asserted subset of AtomCache fields
claimWindowManagerRole(conn, root) !void   // SubstructureRedirect claim; BadAccess = AnotherWMRunning
flush(conn)
advertiseEwmhSupport(conn, screen, root)   // identity-window dance + _NET_SUPPORTED list
collectPropertyReply(conn, cookie) -> ?*reply   // poll-first, then blocking (cookie consumed on both)
```
**Verdict:** ★ — the allowlisted home for raw xcb calls. The comptime assert
that `supported_atoms` is a strict subset of `AtomCache` fields means a
misspelt/advertised atom without a cache field is a compile error, not a
silent `XCB_ATOM_NONE` claim. The poll-first reply collector is a real
optimization (avoids a blocking wait when the reply is already buffered).
**Ideal:** unchanged. **Path:** none.

### `core/x11/ledger.zig` (175) — the sent ledger
**Now:**
```
SentEntry{ rect, has_rect, parked, bw, pixel, parked_dirty }
  blank()   // has_rect=false is the ONLY "never sent" marker; rect holds a meaningless zero
State{ sent: model.Store(WindowId, SentEntry, store_capacity) }
init(); sentGet(win) -> ?SentEntry; sentGetOrPut(win) -> ?*SentEntry (null when full)
forget(win)   // X id recycling: a stale record would feed the orphan keep-last branch
markParkedDirty(win)   // ConfigureNotify said a parked window moved itself
markSentBorderWidth(win, w)
markSentBorderPixelIfChanged(win, pixel) -> bool   // THE one border-pixel dedup (has_rect-gated)
markSentVisible(e, rect, bw, pixel)
visibleSent(win) -> ?SentEntry   // has_rect and not parked
lastRectFor(win) -> ?Rect; lastBorderWidthFor(win) -> ?u16
```
**Verdict:** ★ — write-only diff base, explicitly *not* a server-truth cache
(the model stays authoritative via `reconcile.truthRect`). `has_rect` is a
real flag (no sentinel rect that a legal 0-size window at the origin would
collide with); bw/pixel survive parks so unpark doesn't flash the border.
`markSentBorderPixelIfChanged` is the ONE border-pixel dedup — it was in
`wincache` while reconcile's dedup read the ledger's `pixel` field, two
places that could disagree; deriving both from one record removes the class.
**Ideal:** unchanged. **Path:** none.

### `core/x11/masks.zig` (166)
**Now:** modifier masks; `mod_mask_binding` (locks excluded so binds fire
regardless of lock state); `modifier_keysym_lo/hi = 0xFFE0/0xFFEF` +
`isModifierKeysym`; `lock_bits`; `lock_modifiers` (all 2³ subsets of the
three locks, grab order); `core_event_code_mask = 0x7f`; `EventMasks{
root_window, managed_window }` (DWM-verbatim with the four deviations
documented); `BindingMods = packed struct(u4){shift,control,alt,super}` +
`normalizeModifiers`/`toMask`/`isEmpty`.
**Verdict:** ★ — the lock-subset table is the correct grab-expansion
combinatorics; the widened modifier band lets bare-modifier presses be dropped
silently. `BindingMods` as a u4 means a lock/button bit cannot be represented,
so an un-normalized modifier state is a compile error at the call site rather
than a dead binding weeks later.
**Ideal:** unchanged. **Path:** none.

### `core/x11/atoms.zig` (92)
**Now:**
```
AtomCache = { WM_PROTOCOLS, WM_DELETE_WINDOW, ..., RESOURCE_MANAGER }   // field name == atom string
atom_cache: ?AtomCache
initAtomCache(conn) !void   // one intern per field, all cookies fired, then all replies collected (pipelined)
getAtomCached(name) -> ?u32   // comptime @hasField check; @field lookup
getAtomOrZero(name) -> u32    // 0 (no atom) sentinel when the cache isn't ready
```
**Verdict:** ★ — field-name-as-atom-string means adding an atom is one field,
no parallel arrays, no index-order mismatch. Pipelined interning is one round
trip. Public so `requests.zig` can comptime-prove its advertised EWMH set is
a subset.
**Ideal:** unchanged. **Path:** none.

### `core/x11/cursor.zig` (53)
**Now:** `setupRoot(conn, screen)` — libxcb-cursor context, load `left_ptr`,
`XCB_CW_CURSOR` on the root, silent fallback; hand-written `extern` because
`xcb_cursor_load_cursor` is a C static inline cImport cannot bind.
**Verdict:** ★ — correctly placed here (root decoration, not input policy);
the server reference-counts cursors so freeing the handle after the root holds
a reference is safe.
**Ideal:** unchanged. **Path:** none.

### `core/x11/xcb.zig` (26)
**Now:** single `@cImport` of xcb/xcbext/randr/xkb; `Connection`/`Screen`
aliases; `eventCast` narrowing.
**Verdict:** ★ — the only cImport in the tree; every other x11 module imports
the hub, not `core`, so the layer stays a DAG root.
**Ideal:** unchanged. **Path:** none.

---

## `core/display/` — display facts

### `core/display/hz.zig` (366) — refresh-rate detection (value + probe)
**Now:**
```
detectedHz() -> f64   // 60.0 default until a probe publishes
publishDetectedRate(rate)   // sanity band [10, 1000] Hz enforced once, at the value
ensureRefreshRateDetected(conn)   // one-shot boot arming; subscribes RandR notify on the root
randrFirstEvent() -> u8   // extension event base for the dispatcher
handleRandrNotifyEvent(event)   // CRTC-change fast path: mode id -> cached mode table, zero X requests
                                // (else rate-limited -> redetect_pending)
runPendingRedetect(conn)   // debounced full re-detect, deferred out of event dispatch
setupRandr(conn, root) -> bool
cacheModes(modes) / rateForModeId(id) -> ?f64   // mode table, capped at 256
rateFromNotifyEvent(event) -> ?f64   // RRNotify (base+1) + CRTC_CHANGE + cached mode
detectRefreshRate(conn, root)   // pipelined: fire resources+primary, then all output-info cookies,
                                // then all crtc-info cookies (~3 blocking waits vs 1+2N)
pipelinedRefreshRateFromOutputs(conn, res, primary) -> ?f64
subscribeRandrNotify(conn, root)
```
**Verdict:** ★ — one file, one purpose: the display's refresh rate, both the
value and the probe that discovers it. A display feature, not a bar one (the
rate serves bar title pacing AND the floating drag throttle), so detection is
compiled into every tree, armed once at boot, and the event loop forwards
RandR events to it directly. The CRTC-change fast path resolves the rate from
the cached mode table with zero X requests; the stale-cache-drop on a failed
re-detect ("cheaper to be wrong slowly than confidently") is careful. The
sanity band is enforced once, at the value, instead of re-derived per consumer.
**Ideal:** unchanged. **Path:** none.

### `core/display/dpi.zig` (184)
**Now:**
```
BarHeightPolicy{ min_px=20, max_px=200, default_px=24 }; bar_height_policy
clampBarHeight(px) -> u16   // both ends of the policy
resource_manager_max_len=1024 / retry_len=4096
XftProbe{ got_string, dpi, possibly_truncated }
probeXftDpi(conn, root, atom, max_len) -> XftProbe
readXftDpi(conn, screen) -> ?f32   // small fetch first; retry larger ONLY if truncated (bytes_after>0)
detectDpi(conn, screen) -> f32      // Xft.dpi -> geometry formula -> baseline_dpi (96)
scaleFontSizeForHeight(value, screen_height_px) -> u16   // percent relative to 1080p baseline
scaleBarHeight(value, screen_height) -> u16   // scaleToPixels then clampBarHeight
```
**Verdict:** ★ — `BarHeightPolicy` groups the three loose constants into one
passable value; the two-stage probe (1024 words, retry 4096 only when the
reply was truncated) avoids a large fetch in the common case; `XftProbe`
distinguishes "absent" from "unreadable" from "truncated". DPI resolution
order (config override > Xft.dpi > physical guess) is a `main.zig` decision,
correctly placed here as the detection entry.
**Ideal:** unchanged. **Path:** none.

### `core/display/usable_area.zig` (179)
**Now:**
```
Edge = { top, bottom, left, right }
Claim{ monitor, edge, px, active }
max_claims = has_bar ? 1 : 0   // comptime; one slot per surface
bar_id = has_bar ? 0 : unreachable
claims: [max_claims]Claim
surface_win: ?WindowId; setSurfaceWindow/clearSurfaceWindow/surfaceWindow/isSurfaceWindow
mappedSurfaceWindow() -> ?WindowId   // keyed off the BAR's own claim, not "any active claim"
setClaim(comptime id, edge, px) / releaseClaim(id)   // comptime id -> compile-time bounds check
claimInsets() -> [4]u32   // sum of active claims per edge
workAreaFrom(screen_w, screen_h) -> Rect   // screen minus max strut per edge, SATURATING subtraction
workArea(screen) -> Rect
```
**Verdict:** ★ — comptime claim ids make the struts table allocation-free and
self-documenting; the surface-window exclusion keeps the bar's own strut from
shrinking the work area it computes. `mappedSurfaceWindow` keyed off the bar's
own claim (not "any active claim") is a real fix written down for the day a
second surface (a dock) adds a slot. The "fullscreen means no work area is
NOT this module's rule" contract (occupancy is expressed only as claims) is
the right single encoding. Saturating subtraction makes an over-claiming
surface yield a zero rect, never a wrapped one.
**Ideal:** unchanged. **Path:** none.

---

## `core/proc/` — process concerns

### `core/proc/persist.zig` (531) — session persistence
**Now:**
```
persist_version = 5; ext_format_version = 2 (name-stamped blob header); ext_format_version_ordinal = 1 (legacy, still READ)
extHeaderLen(name_len); extPayload(header) -> ?[]const u8; ExtHeader{payload, claimed_name, legacy_ordinal}
decodeExt(blob); extClaimantName(header); extLegacyOrdinal(header); max_stamped_name_len = 255
max_restore_bytes = 1 MiB
WindowRecord{ win, mask, anchor, presence, covering_ws, ext }
WsRecord{ params, tiled, mru }
StateFile{ version, current, focused, all_view_active, workspaces[MAX_WS], windows }
loaded_parsed: ?Parsed(StateFile)
defaultStatePath(alloc)   // $XDG_RUNTIME_DIR/hana-restore.json else /tmp/hana-restore-<uid>.json
Snapshot{allocator, windows, workspaces, ws_filled} + deinit
saveSnapshot(alloc, m) -> Snapshot   // store iter (sorted-key), per-blob adopt by module NAME
stringifySnapshot(alloc, m, snap) -> ArrayList(u8)   // JSON, indent_2
atomicWrite(alloc, path, bytes)   // pid-qualified O_EXCL no-follow temp + writeStreamingAll + sync + rename
createExclusive(io, path)   // .exclusive + 0o600
save(alloc, m, path) !void
loadToGlobal(alloc, path) -> bool   // readFileAlloc (1 MiB limit) -> parse -> version check -> install
loaded() -> ?*const StateFile
resumableDefaultKind()   // config default layout name -> registry index
restoreMembers(list, src, m, cap)
applyModelLevel(m)   // covering restore, current/focused/all_view, per-ws params (variant_idx clamp,
                     // unresolvable kind -> config default), tiled_order/mru restore, membership repair
```
**Verdict:** ★ — self-identifying blob headers (module *name*, not registry
index) survive module reordering/removal; the legacy ordinal header is still
read. Versioned outer format is rejected rather than migrated. `atomicWrite` is
security-conscious: pid-qualified temp (two instances don't race), `O_EXCL`
no-follow (a planted symlink/hardlink cannot redirect the write), `sync` before
`rename` (a crash can't leave the new name pointing at non-durable blocks).
The membership-repair loop and the `variant_idx` clamp degrade loudly, not
silently. One concern (session persistence) with a clear save half and load half.
**Ideal:** unchanged. **Path:** none.

### `core/proc/spawn.zig` (425) — detached command spawning
**Now:**
```
ensureSubreaper()   // PR_SET_CHILD_SUBREAPER once (orphan re-parents to hana, reaped by the waitpid(-1) sweep)
failWithTag(pipe_write) noreturn; execShell(cmd_z); execDetached(pipe_write, cmd_z) noreturn  // setsid + exec
max_pending_spawns = 16; stack_cmd_capacity = 256; spawn_msg_max = 1; cmd_report_max = 96; spawn_timeout_ms = 5000
ResolvedCmd{z, heap?}; resolveCmdZ(alloc, cmd, buf)   // stack for short, heap dupe for long
PendingSpawn{ pid, spawn_fd, buf, len, spawn_ws, cmd, cmd_len, started_ms }
g_pending: BoundedList(PendingSpawn, 16)
executeShellCommand(cmd) !void   // snapshot ws, resolve, pre-check capacity, pipe2, fork, child execDetached, parent appends
max_read_fds = 16; readFds(buf) -> []fd_t   // read ends of pending pipes (event loop polls these)
drainPendingSpawns()   // non-blocking read to EOF/full; stuck-entry expiry (5s); eager WNOHANG reap; finishSpawn
conversationFailed(data) -> bool   // bytes mean failure, no bytes mean success (the ONLY protocol rule)
finishSpawn(entry)   // on success: registerSpawn for workspace routing; on failure: warn which command
reapPendingChildren()   // waitpid(-1, WNOHANG) sweep + per-pid reap
execSynchronous(cmd)   // single-fork, blocks on waitpid (for ','-sequenced exec steps)
```
**Verdict:** ★ — correct CLOEXEC hygiene (the child's write end closes on a
successful exec; a failed exec writes `tag_failed` before exit) and a
non-blocking reap path. The `conversationFailed` rule (bytes = failure, absence
= success) is the whole protocol and is correct after the round-1-era inverted-
predicate fix. The stuck-entry expiry (5s) means 16 stuck entries can't wedge
`exec` forever. The pending queue is now a `BoundedList` (the round-1 optional
tidy landed). Subreaper + `waitpid(-1)` sweep means an orphaned grandchild is
collected without a second reaping path.
**Ideal:** unchanged. **Path:** none.

### `core/proc/signals.zig` (333) — signal self-pipe and dispatch
**Now:**
```
signalHandler(signo) callconv(.c)   // async-signal-safe: pending_signals.fetchOr(bit) + writeWakeToken
wake_token = 1; writeWakeToken()   // non-blocking write; EAGAIN = already awake, lossy by design
alt_stack_mem[64 KiB] align(16); backtrace_in_progress: atomic bool
handleBacktraceRequest(sig, info, ctx) callconv(.c)   // SIGUSR2: frame-pointer walk over the INTERRUPTED
                                                     // thread's stack, bounded to rsp..rsp+8 MiB, raw write only
                                                     // (no locks/allocator/symbolization — async-signal-safe)
writeLiteral(fd, s); writePcLine(fd, depth, addr)
setupBacktraceHandler()
handled_signals = [ HUP, TERM, INT, CHLD, USR1 ]
Plan{ handled, ignored }; plan() -> Plan   // pure data, no side effects (testable)
setup() !void   // makePipe + setSignalWriteFd + install(plan())
install(p) !void   // sigaction(handled) + SIGPIPE=IGN + sigaltstack + setupBacktraceHandler
deinit(); readFd() -> fd
dispatchSignal(pending_sig)   // HUP->reload, USR1->requestReexec, TERM/INT->quit, CHLD->reap+drain
drainAndDispatch(fd)   // read pipe to empty (wake token), then consume pending_signals bitmap
```
**Verdict:** ★ — signalfd-style self-pipe moves signal handling onto the
pollable main loop; dispatch happens at a controlled point, never inside a
handler. `Plan`-as-data separates the disposition policy (pure, testable without
clobbering the runner's own SIGINT/SIGTERM) from `install` (the only function
that mutates process state). The wake-token-not-queue design (signal STATE in
the atomic bitmap, the pipe byte is only a wake) means a TERM delivered during
a pipe-full burst can never be lost. The SIGUSR2 backtrace handler is genuinely
careful async-signal-safe systems programming (raw `write(2)`, frame-pointer
walk bounded to the stack window, no allocator/locks/symbolization).
**Ideal:** unchanged. **Path:** none.

### `core/proc/restart.zig` (170) — in-place exec coordinator
**Now:**
```
mustDupeZ(src, what) -> [:0]const u8   // c_allocator, die on OOM
exec_path_z: ?[:0]const u8; should_reexec: atomic bool
init()   // readlink /proc/self/exe; a full buffer (truncated) = unresolvable
requestReexec(); consumeReexec() -> bool   // atomic, exactly once
selfPathZ() -> ?[:0]const u8
restore_env = "HANA_RESTORE"; config_dir_env = "HANA_CONFIG_DIR"
restorePathFromEnv() -> ?[*:0]const u8
Handoff{ self_path, restore_path, config_snapshot? }
currentHandoff(restore_path, config_snapshot) -> ?Handoff
execNext(handoff) noreturn   // setenv(HANA_RESTORE, ...) + optional setenv(HANA_CONFIG_DIR) + execv(self)
```
**Verdict:** ★ — env-based hand-off keeps the re-exec path allocation-free and
testable; the env-var *names* are single-sourced (`restore_env`/`config_dir_env`)
so a typo on the reading side is impossible. `currentHandoff` dedupes a
redundant re-exec when nothing changed. The no-fork design (preserves the
session chain under startx — a fork-then-exit parent would make xinit tear
down Xorg mid-hand-off) is the correct call and well-reasoned. The
truncated-readlink-is-unresolvable rule prevents handing execv a cut-off path.
**Ideal:** unchanged. **Path:** none.

### `core/proc/lifecycle.zig` (84) — process lifecycle flags + fd plumbing
**Now:**
```
running: atomic bool (SIGTERM/SIGINT -> false)
should_reload: atomic bool (SIGHUP / reload_config keybind)
signal_write_fd: fd_t (owned by signals.zig, registered via setSignalWriteFd)
wake_byte = 0xff   // pure token; collides with no signal byte
setSignalWriteFd(fd); writeWakeByte()   // lossy: a full/unregistered pipe drops the byte
quit(); reload()   // set flag + write wake byte (only on the 0->1 transition)
wake()   // write wake byte without touching a flag (restart.zig's re-exec nudge)
consumeReload() -> bool   // atomic swap, exactly once
makePipe() -> ![2]fd_t   // pipe2 with O_NONBLOCK | O_CLOEXEC (shared by spawn + signals)
```
**Verdict:** ★ — the wake byte is a pure token (0xff collides with no signal
byte); lossy-write is fine because the loop polls its flags every iteration.
`reload()` writes the wake byte only on the 0→1 transition (a repeated
`reload()` doesn't spam the pipe). `makePipe` is the one shared pipe factory,
avoiding byte-equivalent copies in spawn and signals.
**Ideal:** unchanged. **Path:** none.

---

## Core subsystem summary (round 2)

- **34 files; 31 ★ ideal, 3 ◐ near-ideal (core.zig, pipeline.zig, events.zig), 0 △, 0 ▽.**
- Round-1's one △ (events.zig) is resolved: the comptime dispatch table, the
  pure `routeFor` routing decision, and the pure `eventWindowFor` offset table
  all landed. It is upgraded to ◐ for the remaining size/bundling (grab
  installation + config reload are extractable sub-concerns, not per-event
  dispatch).
- The `core/proc/` extraction (persist/spawn/signals/restart/lifecycle) is
  confirmed clean: each is a single-responsibility file, none imports an
  optional subsystem by name, and all reach the model/registry through the
  open contracts.
- The layering (pure → x11 leaf → loop → subsystems) is honored throughout
  and enforced by `dev/scripts/check-layers.sh` (Rules 1–4 all pass on the
  current tree).
- The single remaining restructure available is **events.zig**: extract grab
  installation (`grabs.zig`) and `handleConfigReload` (`reload.zig`) to drop
  it from 945 to ~700 lines and separate the hot per-event path from the
  lifecycle transitions. Everything else is at or near its ideal shape — much
  of it explicitly the product of prior refactor rounds (the ScopedGrab token,
  the Facts revision counters, the Phase consolidation, the self-identifying
  persist headers, the BoundedList spawn queue).

| file | verdict | one-line ideal delta |
| --- | --- | --- |
| `core/core.zig` | ◐ | move the `xcb`/`Connection`/`Screen`/`eventCast`/`XK` facade re-exports to the x11 leaf so `State` owns only process-global state (cleanliness split, no runtime gain) |
| `core/architecture/contract.zig` | ★ | unchanged |
| `core/architecture/contract_x11.zig` | ★ | unchanged |
| `core/architecture/model.zig` | ★ | unchanged |
| `core/pure/bounded.zig` | ★ | unchanged |
| `core/pure/log.zig` | ★ | unchanged (WindowedProfiler is a mild co-tenant beside its sink) |
| `core/pure/idmap.zig` | ★ | unchanged |
| `core/pure/constants.zig` | ★ | unchanged |
| `core/pure/paths.zig` | ★ | unchanged |
| `core/pure/dpi_math.zig` | ★ | unchanged |
| `core/pure/ids.zig` | ★ | unchanged |
| `core/pure/time.zig` | ★ | unchanged |
| `core/pure/scaling.zig` | ★ | unchanged |
| `core/loop/events.zig` | ◐ | extract grab installation → `grabs.zig` and `handleConfigReload` → `reload.zig` to drop 945 → ~700 lines and separate per-event dispatch from lifecycle transitions |
| `core/loop/pipeline.zig` | ◐ | single transition layer; split the reconcile-family entry points at ~800 lines (not now) |
| `core/loop/xtrace.zig` | ★ | unchanged |
| `core/loop/diag.zig` | ★ | unchanged |
| `core/loop/timers.zig` | ★ | unchanged |
| `core/x11/reconcile.zig` | ★ | unchanged |
| `core/x11/sink.zig` | ★ | unchanged |
| `core/x11/requests.zig` | ★ | unchanged |
| `core/x11/ledger.zig` | ★ | unchanged |
| `core/x11/masks.zig` | ★ | unchanged |
| `core/x11/atoms.zig` | ★ | unchanged |
| `core/x11/cursor.zig` | ★ | unchanged |
| `core/x11/xcb.zig` | ★ | unchanged |
| `core/display/hz.zig` | ★ | unchanged |
| `core/display/dpi.zig` | ★ | unchanged |
| `core/display/usable_area.zig` | ★ | unchanged |
| `core/proc/persist.zig` | ★ | unchanged |
| `core/proc/spawn.zig` | ★ | unchanged (BoundedList pending queue landed; round-1 tidy done) |
| `core/proc/signals.zig` | ★ | unchanged |
| `core/proc/restart.zig` | ★ | unchanged |
| `core/proc/lifecycle.zig` | ★ | unchanged |
