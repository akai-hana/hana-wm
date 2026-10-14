# Core subsystem review (`src/core/**`)

Verdict scale: **★ ideal** (ship as-is) · **◐ near-ideal** (minor nits) · **△ restructure** (split a god-file) · **▽ redesign** (shape is wrong).

Every file below: **Now** = high-level pseudo-code of current behavior · **Verdict** · **Ideal** = from-scratch pseudo-code · **Path** = ordered, behavior-preserving refactor steps.

---

## `core/architecture/` — composition contracts (pure vocabulary)

### `core/architecture/contract.zig` (830 lines)
**Now:**
```
tiling_mods = has_tiling ? generated_registry : empty
default_kind = 0   // named sentinel
moduleOf(kind) -> ?*Layout            // bounds-checked registry lookup
activeLayoutKind(kind, tiling_enabled) -> ?u8   // registry + tiling gates
activeLayoutMeta(kind, tiling_enabled, pick, fallback) -> T
Layout    = { name, icon, indicators, variantCount, compute, ... }
Segment   = { name, measure/naturalWidth, draw, onClick, ... }  // bar segment shape
WindowModule = { name, hooks... }        // window feature hook shape
providerOf(module) / callHook*(...)      // dispatch through registry
DirtySources, Painted, Frame, DrawCtx    // draw vocabulary
```
**Verdict:** ★ — the seam vocabulary of the whole plugin system; one intentional edge into the generated `tiling_modules` registry, everything else reached through caller-passed registries.
**Ideal:** unchanged.
**Path:** none. (If it ever grows, split `Segment`/bar vocabulary into `contract_bar.zig` — not needed today.)

### `core/architecture/contract_x11.zig` (74 lines)
**Now:**
```
KeyPressEvent = xcb_key_press_event_t
Surfaces = { init, deinit, handleExpose, updateIfDirty, pollTimeoutMs,
             onPollWakeup, updateClock, randrFirstEvent, handleRandrEvent,
             runPendingRedetect, onReload, chromeHandleKeypress, isBarWindow,
             handleButtonPress, handleMotion, ... }   // one type in every build
BarHandlers, TitleRender, DrawCtx                     // X-typed halves of bar vocabulary
```
**Verdict:** ★ — no-op `Surfaces` is generated when no chrome is compiled in, so call sites never test a build flag.
**Ideal:** unchanged. **Path:** none.

### `core/architecture/model.zig` (620 lines)
**Now:**
```
Model = {
  ws: [MAX_WS]Workspace { tiled: BoundedList<WindowId>, mask, params: LayoutParams, ... }
  focus_stack, covering: per-ws occupant, tag maps (BoundedList per window)
}
register(win, hint_ws) / unregister(win)
findHome, visibleOn, tiledCountOnWs, coveringWsOf/isCoveringOn/coveringOccupantOnWs
setFocus / clearFocus, collectCyclePool, fallbackFocusCandidate
reorderTiled, stepTiled, swapPrimary, swapFocusedWithPrevious, adjustPrimaryWidth
applyParamsDelta(ws, delta), applyConfigReload(tpl)
```
**Verdict:** ★ — pure domain model, zero I/O, zero allocation, `*const` read-only export via pipeline; the compiler is the mutation tripwire.
**Ideal:** unchanged. **Path:** none.

---

## `core/core.zig` (330 lines) — process-global state

**Now:**
```
State = { conn, screen, root, alloc, config: *Config, dpi, screen_w/h, ... }
init(conn, screen, root, alloc, config_ptr, dpi)
replaceOwnedConfig(new)   // frees displaced box, swaps pointer atomically
deinitOwnedConfig()
refreshScreenGeometry(conn) -> bool
toggleBarScreenPosition() -> BarScreenPosition
dpi()/setDpi(v)
```
**Verdict:** ◐ — a singleton is the pragmatic choice at the C boundary; `replaceOwnedConfig` correctly centralizes box ownership (the reload GP fault is fixed by exactly-one-free).
**Ideal:**
```
explicit Context value threaded through init; State becomes immutable after boot
except config pointer swap. (Equivalent behavior; no runtime gain today.)
```
**Path:** optional, long-term only: (1) keep as-is — single-threaded main loop makes the singleton race-free; (2) if ever ported to threads, convert to an explicit `Ctx` passed down the DAG. Do not spend effort now.

---

## `core/display/`

### `core/display/dpi.zig` (184 lines)
**Now:**
```
detectDpi(conn, screen) -> f32:
    read RESOURCE_MANAGER -> "Xft.dpi: N" -> N
    else physical-size guess from screen->width_in_mm
BarHeightPolicy = { min_px=20, max_px=200, default_px=24 }
clampBarHeight(px) -> u16            // both ends
scaleBarHeight(h, dpi)               // percent/px ScalableValue resolution
scaleFontPct(pct, screen_h)          // font % relative to 1080p baseline
```
**Verdict:** ★ — `BarHeightPolicy` already groups the three loose constants into one passable value; DPI resolution order (config override > Xft.dpi > physical guess) is a main.zig decision, correctly placed.
**Ideal:** unchanged. **Path:** none.

### `core/display/hz.zig` (~360 lines) — refresh-rate detection (value + probe)
**Now:**
```
detectedHz() -> f64               // 60.0 default until a probe publishes
publishDetectedRate(rate)         // sanity band [10, 1000] Hz, then store + log
ensureRefreshRateDetected(conn)   // one-shot boot arming (main.zig); subscribes
                                     // RandR notify on the root
randrFirstEvent() -> u8           // extension event base for the dispatcher
handleRandrNotifyEvent(event)     // CRTC-change fast path: mode id -> cached
                                     // mode table, zero X requests
runPendingRedetect(conn)          // debounced full re-detect, deferred out of
                                     // event dispatch
detectRefreshRate: pipelined — fire resources+primary, then all output-info
  cookies, then all crtc-info cookies (~3 blocking waits vs 1+2N)
cacheModes / rateForModeId        // mode table, capped at 256
```
**Verdict:** ★ — one file, one purpose: the display's refresh rate, both the value and the probe that discovers it. A display feature, not a bar one — the rate serves bar title pacing AND the floating drag throttle, so detection is compiled into every tree, armed once at boot, and the event loop forwards RandR events to it directly (the three RandR hooks left the `Surfaces` contract). The sanity band is enforced once, at the value, instead of re-derived per consumer.
**Ideal:** unchanged. **Path:** none. (Relocated during review from `src/hz.zig`, which contradicted its own header and failed `check-layers.sh` rule 1; the allowlist entry now points at this path.)

### `core/display/usable_area.zig` (180 lines)
**Now:**
```
claims: [N_SOURCES]{ edge, px }   // comptime-id-keyed _NET_WORKARED contributors
setClaim(id, edge, px) / releaseClaim(id)
surface_window: ?WindowId; setSurfaceWindow/clearSurfaceWindow/mappedSurfaceWindow
workAreaFrom(screen_w, screen_h) -> Rect   // screen minus max strut per edge
workArea(screen) -> Rect
```
**Verdict:** ★ — comptime claim ids make the struts table allocation-free and self-documenting; the surface-window exclusion keeps the bar's own strut from shrinking the work area it computes.
**Ideal:** unchanged. **Path:** none.

---

## `core/loop/` — event loop

### `core/loop/pipeline.zig` (550 lines) — model owner + transition layer
**Now:**
```
instance: Model (stack, no allocator)
init()            // instance = .{}; g_sink = { conn }; markModelReady(); ledger.init()
model() -> *const Model          // read-only export; panic before init
mut() -> Gate                    // private transition gate for actions/focus/tracking
getCurrentLayout() -> u8; getCurrentVariantIdx() -> usize
reconcileTick(opts)              // build Ctx, run reconcile, settle hooks
slot entry points (mapRequest, unmanage, ...) delegating to modules
```
**Verdict:** ◐ — the `*const`/`Gate` split is exactly right; size comes from being the single transition layer, which is the correct place for that code to live.
**Ideal:** same shape; if it grows past ~800 lines, split `pipeline_slot.zig` (map/unmanage entry points) from `pipeline.zig` (model + reconcile orchestration).
**Path:** none today; note the split point for the future.

### `core/loop/events.zig` (945 lines) — the event loop  **△**
**Now:**
```
run():
  loop while lifecycle.running:
    poll_timeout = Timers(sources).deadlineMs()
    event = xcb_poll_for_event / wait for fd with timeout
    batch-dispatch: core events (MapRequest, ConfigureRequest, DestroyNotify,
      ButtonPress/Release, MotionNotify, KeyPress/Release, ClientMessage,
      PropertyNotify, Expose, MappingNotify, FocusIn/Out, EnterNotify...)
    extension events (RandR -> hz.handleRandrNotifyEvent)
    consume lifecycle flags (reload -> config reload + reconcile)
    drainPendingSpawns(); reapPendingChildren(); signals.drainAndDispatch()
    hz.runPendingRedetect()
    settle pending focus / reconcile after batch
```
**Verdict:** △ — the loop mechanics (poll/batch/drain/settle) are entangled with a ~60-arm event dispatch `switch`. The dispatch table is the thing that grows with every new EWMH message.
**Ideal:**
```
handlers: [event_code]HandlerFn          // comptime-built dispatch table
run():
  while running:
    timeout = timers.deadlineMs()
    evt = poll(timeout)
    dispatch(evt)             // table lookup; extension base checked first
    drainFlags(); drainSpawns(); drainSignals(); runPendingRedetect()
    settle()
```
**Path:** (1) extract the per-event arms into a `handlers` table (array of fn pointers indexed by `response_type & ~0x80`), keeping the arm bodies verbatim; (2) move extension-event dispatch (`randr_first_event` range check) ahead of the core table as its own small branch; (3) keep drain/settle order identical. Each step independently testable via `events_test.zig`.

### `core/loop/timers.zig` (39 lines)
**Now:**
```
Source = *const fn () ?i32          // null = no wakeup wanted
Timers.deadlineMs() -> ?i32         // min over ALL sources (never short-circuits)
```
**Verdict:** ★ — the reduce-over-all-sources rule is the policy; absence is `null`, not a negative number, so "no timer" and "timer in -1ms" cannot be confused.
**Ideal:** unchanged. **Path:** none.

### `core/loop/diag.zig` (48 lines)
**Now:**
```
dumpState(): log focused window, total windows, suppress reason,
  per-ws window counts, tiling layout/kind, tiled count (gated on build_options)
```
**Verdict:** ★ — read-only snapshot; stack scratch array keeps `tracking` free of module-level mutable state.
**Ideal:** unchanged. **Path:** none.

### `core/loop/xtrace.zig` (123 lines)
**Now:**
```
watch: ?[]u32   // resolved lazily from HANA_XTRACE ("*" = all, else id list)
enabled() -> bool          // one-compare hot-path guard
trace(event, window, direction)   // logs event order for watched windows
```
**Verdict:** ★ — opt-in, zero-cost-when-disabled, lazy env resolution keeps getenv off the hot path.
**Ideal:** unchanged. **Path:** none.

---

## `core/proc/` — process concerns

### `core/proc/lifecycle.zig` (84 lines)
**Now:**
```
running: atomic bool            // SIGTERM/SIGINT -> false
should_reload: atomic bool      // SIGHUP / reload_config keybind
signal_write_fd                 // self-pipe write end (owned by signals.zig)
reload()                        // set flag + write wake_byte (0xff) to poke poll
quit(); consumeReload() -> bool
```
**Verdict:** ★ — the wake byte is a pure token (0xff collides with no signal byte), lossy-write is fine because the loop polls flags every iteration.
**Ideal:** unchanged. **Path:** none.

### `core/proc/signals.zig` (330 lines)
**Now:**
```
Plan = { sigterm, sigint, sighup, sigchld, ... }   // signalfd mask
setup()   -> signalfd; register write end with lifecycle
deinit()
readFd() -> fd
drainAndDispatch(fd):   // read signalfd bytes, set lifecycle flags,
                        // queue SIGCHLD reaps; never act inline
```
**Verdict:** ★ — signalfd moves signal handling onto the pollable main loop; dispatch happens at a controlled point, never inside a handler.
**Ideal:** unchanged. **Path:** none.

### `core/proc/spawn.zig` (400 lines)
**Now:**
```
executeShellCommand(cmd): fork + exec /bin/sh -c (async, child tracked)
execSynchronous(cmd):     fork + exec + wait (for one-shot applies)
pending_spawns: queue; drainPendingSpawns()   // reap via waitpid WNOHANG
reapPendingChildren()
readFds(fds)            // close everything except the exec'd child's needed fds
conversationFailed(data) -> bool   // detect "failed to spawn" dialogs from clients
```
**Verdict:** ◐ — correct CLOEXEC hygiene and a non-blocking reap path; the async/sync split matches the two use cases (keybind spawns vs slider commits).
**Ideal:** same, with the pending-spawn queue as a `BoundedList` (it is currently a small fixed array + count — equivalent; only worth changing if the queue ever needs iteration).
**Path:** none required; optional tidy in the same pass as the events.zig drain extraction.

### `core/proc/persist.zig` (531 lines)
**Now:**
```
saveSession(path, model, config_snapshot):
    JSON: version=5, per-window records { win, ws, mask, rect, kind,
      blobs: [ { ext_format_version, name=module.name, payload } ] }
loadToGlobal(path, alloc) -> adopted model state:
    arena-load; reject older/failed revisions; per-blob adopt by module
    name with magic-byte fallback scan
serializeWindow(win) / deserializeWindow(win, bytes)   // per-feature hooks
```
**Verdict:** ★ — self-identifying blob headers (module *name*, not registry index) survive module reordering/removal; versioned outer format rejected rather than migrated.
**Ideal:** unchanged. **Path:** none.

### `core/proc/restart.zig` (160 lines)
**Now:**
```
init()                       // resolve self path once
requestReexec() / consumeReexec() -> bool
selfPathZ() -> ?[:0]u8
restorePathFromEnv() -> ?[*:0]u8     // HANA_RESTORE env hand-off
currentHandoff(restore_path, config_snapshot) -> ?Handoff
execNext(handoff) noreturn           // set env, execv self
```
**Verdict:** ★ — env-based hand-off keeps the re-exec path allocation-free and testable; `currentHandoff` dedupes a redundant re-exec when nothing changed.
**Ideal:** unchanged. **Path:** none.

---

## `core/pure/` — allocation-free vocabulary (xcb-free)

### `core/pure/bounded.zig` (310 lines)
**Now:**
```
BoundedList(T, N): stack array + len
  append/insert -> bool (false when full)
  swapRemove/orderedRemove/removeWhere/removeValue
  indexOfScalar/indexOfByIdField
  upsertById(field, id, item); removeById; removeAllById
  pushFrontEvictingTail
Store(K, V, N): linear-probe list map
  get/has/put/remove + iterator
```
**Verdict:** ★ — the two containers the entire WM runs on; capacity-full is a returned `bool`/`error{CapacityFull}`, never a panic; no allocator anywhere.
**Ideal:** unchanged. **Path:** none.

### `core/pure/idmap.zig` (140 lines)
**Now:**
```
IdMap(V, N): open-addressed u32 -> V with tombstones
  get/contains/put/remove/count/clear + iterator
```
**Verdict:** ★ — tombstones keep probe chains intact across removes; `put` returns false on full so callers degrade gracefully.
**Ideal:** unchanged. **Path:** none.

### `core/pure/ids.zig` (70 lines)
**Now:**
```
WindowId = u32
WorkspaceId = struct { index: u8 }     // == model.WSId; no boundary conversion
fromIndex (lenient) / fromIndexChecked / isValid
isValidWorkspaceIndex(i)               // single validity notion
```
**Verdict:** ★ — one type per id across the core/model boundary; lenient vs checked constructors split by call-site kind (config/recovery vs internal).
**Ideal:** unchanged. **Path:** none.

### `core/pure/constants.zig`, `core/pure/dpi_math.zig`, `core/pure/scaling.zig`, `core/pure/time.zig`
**Now:** comptime limits (`max_workspaces`, `x11_max_keycode`, `baseline_dpi`, ...); pure DPI conversions; `scaleBorderWidth(ScalableValue, ref_dim)` (percent-of-reference or raw px); `monotonicNs()`/wall-clock helpers.
**Verdict:** ★ each — pure leaves, no dependencies but std.
**Ideal:** unchanged. **Path:** none.

### `core/pure/log.zig` (181 lines)
**Now:**
```
info/warn/err(...)   // routed through std.log; module tag = filename sans .zig
Collector = { items: ArrayList<Diagnostic> }   // installed via module-level pointer
  count(), line(d, buf)                        // --check-config counts warn/err
```
**Verdict:** ★ — the module-level collector pointer means the sixty-odd config warn sites need zero signature changes, and CI gates on a count instead of scraping text.
**Ideal:** unchanged. **Path:** none.

### `core/pure/paths.zig` (97 lines)
**Now:**
```
dirIterator($PATH) -> common_dirs first, then non-empty $PATH segments
                    not already covered (dedup via StaticStringMap)
configHome() etc.   // XDG resolution
```
**Verdict:** ★ — dedup between well-known dirs and $PATH is derived at comptime so the two lists cannot drift.
**Ideal:** unchanged. **Path:** none.

---

## `core/x11/` — X11 leaf layer

### `core/x11/xcb.zig` (26 lines)
**Now:** single `@cImport` of xcb/xcbext/randr/xkb; `Connection`/`Screen` aliases; `eventCast` narrowing.
**Verdict:** ★ — the only cImport in the tree; every other x11 module imports the hub, not `core`, so the layer stays a DAG root.
**Ideal:** unchanged. **Path:** none.

### `core/x11/masks.zig` (166 lines)
**Now:** modifier masks; `mod_mask_binding` (locks excluded so binds fire regardless of lock state); `lock_modifiers` = all 2³ subsets for grabs; modifier keysym band `[0xFFE0, 0xFFEF]` + `isModifierKeysym`.
**Verdict:** ★ — the lock-subset table is the correct grab-expansion combinatorics; the widened modifier band lets bare-modifier presses be dropped silently.
**Ideal:** unchanged. **Path:** none.

### `core/x11/atoms.zig` (92 lines)
**Now:**
```
AtomCache = { WM_PROTOCOLS, _NET_WM_NAME, _NET_SUPPORTED, RESOURCE_MANAGER, ... }
initAtomCache(conn):           // one intern per field, all cookies fired,
                               // then all replies collected (pipelined)
atom(name) -> u32              // @field lookup; field name == atom string
```
**Verdict:** ★ — field-name-as-atom-string means adding an atom is one field, no parallel arrays; pipelined interning is one round trip.
**Ideal:** unchanged. **Path:** none.

### `core/x11/ledger.zig` (175 lines)
**Now:**
```
SentEntry = { rect, has_rect, parked, bw, pixel, client_moved_while_parked }
ledger: IdMap/array of SentEntry per window; init(); record*(...)
```
**Verdict:** ★ — write-only diff base, explicitly *not* a server-truth cache; `has_rect` is a real flag (no sentinel rect that a legal 0-size window at the origin would collide with); bw/pixel survive parks so unpark doesn't flash the border.
**Ideal:** unchanged. **Path:** none.

### `core/x11/reconcile.zig` (380 lines) — the reconciler
**Now:**
```
run(model, ctx, opts):
  grabServer(conn)
  for every managed window:
    desired = compute from model (truthRect: geometry, border, stack, park off-screen)
    sent = ledger.entry(win)
    if desired != sent: emit via sink; update ledger
  ungrabAndFlush()
reconcileDragTick(model, snk, win)   // incremental drag path
truthRect(model, win) -> ?Rect
```
**Verdict:** ★ — the crown jewel: unconditional recompute from the model, delta-send against the sent ledger, atomic under a server grab. Model stays authoritative; the ledger only elides identical requests.
**Ideal:** unchanged. **Path:** none.

### `core/x11/sink.zig` (284 lines)
**Now:**
```
Sink = vtable { configure, borderWidth, borderPixel, park, stackOnly,
                setEwmhFullscreen, flush, grab, ungrab }
ConfigureWire = { mask, values[6] }        // protocol slot order, assertable
configureWire(c) -> ConfigureWire          // pure assembly
XcbSink.sink() -> Sink                     // one production impl; tests record
shims: each wraps its exact xcb pattern (park = X-offscreen + BELOW merged)
```
**Verdict:** ★ — the sanctioned seam where raw xcb calls are allowed; vtable exists so tests record requests without an X connection; `ConfigureWire` assembly is pure and unit-tested (slot order bugs are caught without a server).
**Ideal:** unchanged. **Path:** none.

### `core/x11/requests.zig` (249 lines)
**Now:** raiseWindow, setBorderPixel, grabServer/ungrabAndFlush, poll-first `collectPropertyReply`, `claimWindowManagerRole` (SubstructureRedirect + EWMH check), `advertiseEwmhSupport` (root properties), `flush`, `rectFromXcb`.
**Verdict:** ★ — allowlisted home for raw xcb calls; EWMH advertisement is comptime-proven a subset of `AtomCache` fields.
**Ideal:** unchanged. **Path:** none.

### `core/x11/cursor.zig` (53 lines)
**Now:** `setupRoot(conn, screen)` — libxcb-cursor context, load `left_ptr`, `XCB_CW_CURSOR` on root; silent fallback.
**Verdict:** ★ — correctly placed here (root decoration, not input policy); hand-written externs because `xcb_cursor_load_cursor` is a C static inline cImport cannot bind.
**Ideal:** unchanged. **Path:** none.

---

## Core subsystem summary

- **33 files; 28 ★ ideal, 4 ◐ near-ideal (core.zig, pipeline.zig, spawn.zig, events.zig is the one △).**
- The layering (pure → x11 leaf → loop → subsystems) is enforced by `dev/scripts/check-layers.sh` and honored throughout.
- The single genuine restructure available is **events.zig**: extract the dispatch switch into a table. Everything else is already at or near its ideal shape — much of it explicitly the product of prior refactor rounds (v1–v10 simplification plans in `dev/`).
