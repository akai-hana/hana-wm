# hana — Codebase Improvement Report

Compiled from a parallel audit by 7 specialist agents (simplicity, performance, architecture, core/config, bar/tiling, window/input, tests/build/hygiene). Each finding lists severity, location, the problem, and an actionable fix. Findings marked **(Phase 2)** are larger structural refactors to avoid in the first pass (high risk / many files touched); the rest are the recommended first-pass scope.

Line numbers were verified by the auditing agents against the live tree unless marked approximate.

---

## 0. Executive summary

- **Real bugs to fix now (memory / correctness):**
  - `persist.save` leaks every serialized window blob on every save (core/persist.zig:111-138).
  - `handleConfigReload` leaks the whole fallback `Config` when no user config exists (core/events.zig:364-380).
  - `Config` heap box is never destroyed on reload (events.zig:364, config/types.zig:601).
  - SIGPIPE left at default kill disposition (core/signals.zig:176-185).
  - Fullscreen focus cycle includes off-screen parked windows (window/focus.zig:702-714, tracking.zig:190-195).
  - `no_input` windows can capture model focus while X focus escapes to a hidden window (window/actions.zig:927, focus.zig:357).
  - Tiling snap-to-increment collapses sub-increment slots to 0×N (tiling/tiling.zig:59-63, applyHints:20-21).
  - Master overflow grid ignores column-width cap → windows drawn over master pane (tiling/modules/master.zig:264-292).
  - `_NET_WM_STATE` fullscreen toggle REPLACEs the whole property, clobbering coexisting atoms (core/sync/sink.zig:83-101).
  - Sync drag reconcile writes zeroed bw/pixel into the sent ledger → spurious re-send (core/sync/sync.zig:248-261).
  - Accepted client border-width ConfigureRequest is reverted by next reconcile (window/window.zig:1004 vs sync.zig:385-391).

- **Big structural wins (Phase 2, deferred):** split the three god files (bar/bar.zig 1614, config/config.zig 1520, window/window.zig 1349); break the config↔input import cycle by relocating `xkbcommon`; unify the three focus storages and the three window-bookkeeping stores; add dependency-graph enforcement to `check-layers.sh` and wire `check-modularity.sh` into `zig build check`.

- **Perf wins in first pass:** sent-ledger lookup O(N)→O(1) via slot-index table; skip one of the two back-to-back focus reconciles; early-out `focusCycle` for single window; avoid fullscreen fact bump on switches with no occupant; cache bar title widths; gate bar full-redraw on configured segments only.

- **Build/test/hygiene:** gate the two latency tests; fix tiling_test scroll gating; invert `visibility_test` self-skip; re-point `persist_test` to a leak-checking allocator; make scratch dir portable; add headless tests for `core/x11/masks.zig`, `borders`, `input` helpers and the vim editor; delete stray `.swp`, narrow `.gitignore` glob, add `.editorconfig`.

---

## I. Correctness & memory bugs (highest priority)

### [critical] persist.save leaks every window blob
- `src/core/persist.zig:111-138` — `save` frees the `WindowRecord` array but never `allocator.free(windows[i].ext)` for the per-window serialized blobs owned by `serializeWindow` (comment at :117 claims "freed below" — there is no such free). Every re-exec hand-off leaks the full serialized payload of every window.
- Fix: after stringify (and on error paths), loop the array and free each non-null `.ext` before freeing the array.

### [critical] handleConfigReload leaks fallback Config on no-user-config path
- `src/core/events.zig:364-381` — `alloc.create` + `errdefer new_ptr.deinit(cs.alloc)` at :366; the no-user-config branch does a plain `return;` (:380) so `errdefer` never fires. The heap box + keybinding actions + resolver maps + duped strings + tiling variants + workspace configs all leak on every reload attempt.
- Fix: `new_ptr.deinit(cs.alloc); return;` (mirror the xkb-stale branch at :390); fix the misleading comment at :372-373.

### [major] Config heap box never destroyed
- `src/config/types.zig:601` (`Config.deinit` never calls `allocator.destroy(self)`), `src/core/events.zig:364` (reload), `src/main.zig:68/88` (boot).
- Fix: `allocator.destroy(self)` at end of `Config.deinit`; add a boot-path `defer alloc.destroy(config)`.

### [major] SIGPIPE at default kill disposition
- `src/core/signals.zig:176-185` — HUP/TERM/INT/CHLD/USR1/USR2 are handled; SIGPIPE is not. Writes to the dead XCB socket (or a closed pipe during teardown) terminate the WM instantly, no diagnostics.
- Fix: `std.posix.sigaction(std.posix.SIG.PIPE, &.{ .handler = .ignore }, null)` at startup.

### [major] Fullscreen focus cycle includes off-screen parked windows
- `src/window/focus.zig:702` (`appendVisible`), `:714` (`collectVisibleWindows`), predicate `src/window/tracking.zig:190-195`. `appendVisible` only checks model `presence != .parked` + mask; fullscreen parks every non-covering ws window *geometrically off-screen* with presence still `.present`, so Mod+k can focus an invisible window and leave `last_applied` wrong after exit.
- Fix: when a covering occupant exists on the current ws, admit only the occupant; otherwise keep the existing predicate.

### [major] no_input window focus escape / model.focused divergence
- `src/window/actions.zig:927` (`model_mod.setFocus`) + `src/window/focus.zig:357` (`.no_input` early return). Model focus is committed unconditionally, then `prepareFocus` returns `.none` — X focus is never moved for the dock, or on `switchTo` the *previous* workspace's hidden window keeps X input focus.
- Fix: only commit model focus when the prepare result != `.none`; on `.none` with an empty ws, explicitly refocus root.

### [major] Tiling snap-to-increment collapses slots to zero
- `src/tiling/tiling.zig:59-63` (`snapDimToIncrement: (dim / inc) * inc`), applied in `applyHints` (:20-21), emitted at :175. Slots smaller than `inc_width`/`inc_height` (or the aspect re-snap :54) snap to 0; nothing re-floors → 0×N configured window.
- Fix: floor snapped result: `if (dim > 0 and snapped == 0) snapped = 1`.

### [major] Master overflow grid ignores the column-width cap
- `src/tiling/modules/master.zig:264-292` — `cols_in_row = max(1, min(cols_by_count, cols_by_width))` only sizes `col_w`; the emit loop places a column for every `cols_by_count` column → columns at/after the width cap are drawn over the master pane or off-screen. Comment claims "surplus spills"; no spill exists.
- Fix: cap emitted columns at `cols_in_row` and spill surplus into remaining rows.

### [major] `_NET_WM_STATE` REPLACE clobbers coexisting atoms
- `src/core/sync/sink.zig:83-101` — `xcb_change_property(... XCB_PROP_MODE_REPLACE)` writes the fullscreen atom (or zero atoms), erasing `_NET_WM_STATE_ABOVE`/`_STICKY`/`_SKIP_TASKBAR` set by clients.
- Fix: read the property, then REPLACE with set-minus/plus the fullscreen atom (EWMH append/remove semantics).

### [major] Sync drag reconcile writes zeroed bw/pixel into the sent ledger
- `src/core/sync/sync.zig:248-261` (`reconcileDragTick` → `markSentVisible(g, win, rect, 0, 0)`). Next full reconcile sees `last.bw != bw` and re-sends border/color that didn't change.
- Fix: look up the existing ledger bw/pixel and preserve them in the drag write.

### [major] Accepted client border-width ConfigureRequest reverted by next reconcile
- `src/window/window.zig:965-1008` (esp. :1004) vs `src/core/sync/sync.zig:385-391`. Client border-only request is honored (cached in `wincache.applied_border_width`), but the ledger still holds the old value → next reconcile re-sends the WM width.
- Fix: after accepting a border-only request, also update the ledger's `bw`.

### [major] Tiling_test / latency test gating break the modular-removal claims
- `src/test/latency/tiling_latency_test.zig:18` imports `tiling` unconditionally with no `test_gates` row (build.zig:180-192); `tiling_test.zig:16` prunes `scroll` to `struct {}` but its scroll tests call `scroll_algo.slotWidth(...)`.
- Fix: add `.{ .name = "tiling_latency_test", .gate = has_tiling }` and the equivalent `focus_latency_test`; gate scroll-specific tests on `has_layout_scroll`.

### [minor] Spawn queue-full leaves grandchild untracked
- `src/core/spawn.zig` (`requestSpawn` queue-full path): intermediate child is reaped but grandchild never associated with a workspace.
- Fix: refuse the spawn (don't fork) when the queue is full.

### [minor] Border color/border-width dedup stores diverge
- `src/window/wincache.zig:172` (`border`) vs `src/core/sync/sync.zig:390` (sink.borderPixel bypass). Also `applied_border_width` (wincache:128-135) vs ledger `bw` (sync:385) both answer "what's on the wire".
- Fix: single border-color writer (record sink sends into wincache, or drop the wincache store); derive border width from the ledger; add a steady-state test asserting agreement.

### [minor] ICCCM drainWMProtocolsReply drops WM_DELETE on TAKE_FOCUS atom hiccup
- `src/window/icccm.zig:388-397` (`focusAtoms() orelse return .{}`) and :277-281: all-or-nothing atom pair.
- Fix: resolve `WM_DELETE_WINDOW` independently; make atom fetch best-effort per atom.

### [minor] Leaf split overflows parent when pane can't hold two min-dim children
- `src/tiling/modules/leaf.zig:25-65` — when `dim < 2*min_dim + gap` both halves clamp to min_dim and `first + gap + second > dim`, overlapping neighbors.
- Fix: hand the whole region to the first child and park the rest when the pair can't fit.

### [minor] Aspect cross-clamp can exceed the allocated slot
- `src/tiling/tiling.zig:28-37` + `clampAspectDim :52-57` — max_aspect cross-product can size a window wider than its slot.
- Fix: clamp the aspect-resolved dimension to the slot dimension too.

### [minor] Scroll slot flares past its boundary
- `src/tiling/modules/scroll.zig:66-79` — `content_w = max(avail, min_dim)` draws min_dim-wide in a slot that can't hold it.
- Fix: inset by `min(slot_inner, min_dim)` (width ≤ available).

### [minor] calcAvailableHeight fallback can exceed the pane
- `src/tiling/modules/master.zig:296-301` — `count *| min_dim` can exceed `total_h` on degenerate margins.
- Fix: clamp fallback to `total_h`.

### [minor] Floating drags ignore PMinSize/PMaxSize
- `src/window/window.zig:1185` (`parseSizeHintsIntoCache`) + `src/window/modules/floating.zig`. Tiling intentionally owns dims, but floating can be resized below/above declared hints.
- Fix: clamp floating drag/resize results to min/max size in the floating module only.

### [minor] minimize restore() targets the wrong workspace
- `src/window/modules/minimize.zig:93` — `lowestBit(e.mask)` restores to the lowest tagged ws, not the one the user is on.
- Fix: prefer current ws when the mask covers it, else lowestBit.

### [minor] Fullscreen Rec.anchor is write-only in the live path
- `src/window/modules/fullscreen.zig:30-42` — covering state duplicated in model entry + module store; anchor never replayed on OFF.
- Fix: keep the covering claim in one place; replay or drop the duplicate anchor.

### [minor] Non-fullscreen floatings keep a border during fullscreen
- `src/window/borders.zig:17-23` — pixel 0 only for the covering occupant.
- Fix: when a covering occupant holds the ws, return 0 for all ws members.

### [minor] minimize home_ws nulled for floating windows
- `src/window/modules/minimize.zig` — restore depends on `findHome` repair.
- Fix: clear `home_ws` only for tiled windows.

### [nit] DestroyNotify double-dispatches module onWindowGone
- `src/core/events.zig:99-103` + `src/window/window.zig:871`.
- Fix: single dispatch in `unmanageWindow` (or pass an already-handled flag).

### [nit] Ledger-full path loses the record
- `src/core/sync/sync.zig:399` — sends applied but record lost; orphan re-sends / parking mistakes.
- Fix: evict least-recently-sent parked entry on full; never lose geometry.

### [nit] SwitchTo bumps fullscreen fact unconditionally
- `src/window/actions.zig:808` — re-runs a no-op border sweep on every ws switch.
- Fix: bump only when the ws actually has a covering occupant.

### [nit] readlinkat truncation undetected
- `src/core/restart.zig:57` — a max-length self path yields a truncated exec path.
- Fix: treat `n == buf.len` as an error.

### [nit] XKB detectable-auto-repeat hand-marshalling
- `src/input/xkbcommon.zig` (opcode 34) — byte-by-byte assembly, no fallback when unavailable.
- Fix: typed `extern struct` + named opcode const; validate the reply; (optional) monotonic-time debounce fallback.

### [nit] isRandrEvent raw first-byte compare
- `src/core/events.zig:154-157` — 0x80 send-event bit not masked; forged events misclassified when RandR base ≥ 128.
- Fix: require in-range AND `(t & 0x80) == 0`.

### [nit] Config parser CRLF-only endings unsupported
- `src/config/parser.zig` — strict `\n` split yields silent blank sections.
- Fix: normalize `\r\n` (tolerate lone `\r`).

### [nit] readFileAlloc stat-then-read race
- `src/config/config.zig` — growing file read only `known_size` bytes.
- Fix: fall back to the growth path (realloc until EOF).

### [nit] Motion-coalescing batch budget off-by-one
- `src/core/events.zig:506-524` — final `dispatchOwned` after cap exit is uncharged.
- Fix: charge the final dispatch.

### [nit] Scale retry runs even when first reply was complete
- `src/core/scale.zig:83-89` — only retry when `value_len == resource_manager_max_len` (possibly truncated).
- Fix: have `probeXftDpi` report truncation and gate the retry on it.

### [nit] Parser/spawn/config misc
- `spawn.zig` tag-message write return ignored → check bytes written.
- Config `include` depth-1 silently skipped → warn on unconsumed include in an included doc.
- `refresh.zig:146-158` mode table truncated at 256 → warn and/or targeted get-mode fallback.
- `persist.zig:94-99/186-195` restore file world-readable → open with mode 0o600.
- `wire.zig` truncation warn false positive at exactly `max_property_length` → key off `bytes_after > 0`.
- SIGPIPE teardown: gate teardown X traffic on `!xcb_connection_has_error`.

---

## II. Performance

### [major] Cycle-focus runs two back-to-back grabbed reconciles
- `src/window/focus.zig:742` (`focusNext`) + `input.zig:349-352` (`snapViewportToFocused`) — two sequential server-grab reconciles per Mod+k.
- Fix: fold the viewport snap into the same reconcile pass (one grab, one pass).

### [major] Focus changes run a full-model reconcile inside a global server grab
- `focus.zig:612-618`/`658-659`, `sync.zig:225`/`334-400` — XGrabServer around compute of every stored window + ledger diff.
- Fix: compute desired state before the grab; grab only when a geometry/restack change is pending.

### [minor] Sent-ledger get-or-create is O(N) per window → O(N²) per reconcile
- `sync.zig:346` (`sentGetOrPut`), `:171-198` (BoundedList scan). Up to 128×128 compares per pass under the grab.
- Fix: mirror `pl_of_slot` (sync.zig:282): a fixed `sent_of_slot` array indexed by store slot.

### [minor] coveringOccupantOnWs whole-store scan per reconcile
- `sync.zig:268` → `model.zig:307`; also re-derived in `bar/visibility.zig:23`.
- Fix: workspace-keyed fullscreen-occupant cache invalidated on toggle/adopt/close. (Phase 2-lite.)

### [minor] HintsView.forWin O(N) scan per placement → O(N²) layout compute
- `plugin.zig:399-405`, consumed by layout engine + `master.zig:152/204`. Hints are index-aligned with the order slice.
- Fix: use the loop index directly (hints[i] aligned with order[i]).

### [minor] master fillHeights worst-case O(n²) on hard-capped windows
- `master.zig:143-162`.
- Fix: accumulate capped cost up front / retire capped windows to a compact list.

### [minor] findManagedWindow blocking tree walk on first hover into child windows
- `window.zig:218-245` (blocking per-level query tree, depth 10).
- Fix: async query resolved next batch; or larger child_cache.

### [minor] ICCCM prop cache is a 512-slot linear-scan list
- `icccm.zig:27` `BoundedList(CacheSlot, 512)` vs `wincache.zig:42` AutoHashMap.
- Fix: reuse the hashmap / slot-index table. (This overlaps the icccm→wincache merge; Phase 2.)

### [minor] Bar dirty frames re-etch every title: snapshot + sort + Pango measure
- `bar.zig:658` scanLiveFrame, `segment.zig:193-213` sort per frame, `title.zig:259-265`.
- Fix: per-frame cached sorted list invalidated on window add/remove/focus; re-measure only dirty titles.

### [minor] Bar marquee frames re-run live-frame scan every 60 Hz
- `bar.zig:962-973` + `:634-649`.
- Fix: animation ticks reuse the last frame snapshot (skip scan when nothing else dirty).

### [minor] First prompt activation scans every $PATH executable on the main loop
- `prompt.zig:535-541` + `:592-627`.
- Fix: background / incremental completion scan (or lazy on first keystroke). (Phase 2-lite; keep synchronous for now if risky.)

### [minor] Config reload probes locations twice
- `events.zig:296-326` vs `loadConfigDefault`.
- Fix: `loadConfigDefault` reports the location it loaded instead of probing twice.

### [minor] Any window-fact change triggers a whole-bar clear+blit
- `bar.zig:497-500` + `:560-572` + prompt overlay't dirty bit never clears → `isFullDirty()` always true.
- Fix: base full-redraw on configured (layout-rendered) segments only.

### [minor] Title cells re-measured with Pango every redraw
- `title.zig:282-291`.
- Fix: cache measured widths keyed by title revision; invalidate on rename.

### [nit] RateForModeId linear scan (small N); cursor-blink poll wakeups flush+tick every iteration
- `refresh.zig:162-163`; `events.zig:639-641, 655`.
- Fix: skip flush when no X queued; fold clock into same wake.

### [nit] persist always serializes all 64 workspaces
- `persist.zig:20-21, 81, 143` — sparse (zig-zag) map of live workspaces. Exit-time; low value.

### [nit] Restart re-execs unconditionally; spawn drain every batch; etc.
- `restart.zig:57/85`; `spawn.zig:160`; `events.zig:554` — gate drains on pending flag.

---

## III. Architecture & structure

### Structural overview (from architecture audit)
- Hub-and-spoke around a single core `Model` + a sync boundary; `core/sync/sink.zig` is the only sanctioned raw-XCB surface; `model/`+`tiling/` are xcb-free; `core/plugin.zig` defines the `WindowModule`/`Segment`/`Layout`/`Surfaces` contracts.
- Build-generated registration modules (`plugins`, `window_modules`, `tiling_modules`, `bar_modules`) make files drop-in; `has_*` booleans gate 89 sites.
- The good parts to preserve: `plugins.Surfaces` seam, fact revisions (`core.focus.rev()/bump()`), the drift-proof reconcile + sent ledger, bounded-work discipline, comptime-gated registries.
- Deletion-modularity is verified by `dev/scripts/check-modularity.sh` but **not wired into `zig build check`**; `check-layers.sh` enforces wire policy, **not import edges**.

### [critical] Hard import cycle config ↔ input via xkbcommon
- `src/config/config.zig:13`, `src/config/types.zig:8` (`@import("xkbcommon")`) ↔ `src/input/input.zig:14` (`@import("config")`). Config can't exist without XKB; input can't be removed without touching config.
- Fix (Phase 2): move `xkbcommon.zig` to a neutral leaf (e.g. `core/x11/xkb.zig`); hand input a pre-resolved keybinding table at boot.

### [critical] Window subsystem fused into core
- `core/events.zig:15-32`, `core/pipeline.zig:15-18`, `core/spawn.zig:22-23`, `core/signals.zig:8-9` import `window/*` by name; window addon registry consumed directly by events.
- Fix (Phase 2): route window-layer entry points behind a core-owned contract mirroring `Surfaces`.

### [major] Optionality not on the default gate; no import-policy checker
- `build.zig:241-248` (`check` doesn't run `check-modularity.sh`); `dev/scripts/check-layers.sh` does not check import edges.
- Fix: add modularity as a `check` dependency; add a Rule that builds the `@import` adjacency graph and fails on cyclic edges outside the blessed core↔window pair.

### [major] God files
- `bar/bar.zig` (1614 LOC), `config/config.zig` (1520 LOC, 12 responsibilities), `window/window.zig` (1349 LOC, lifecycle+dispatch+EWMH+hints).
- Fix (Phase 2): split bar into layout/metrics/clicks; config into keybindings/files/tiling_cfg; window into registry/hints/ewmh.

### [major] ~66 file-scope `var` singletons, no DI
- `focus.zig:59-63` documents the module-global + explicit init/deinit pattern. Tests must hand-reset singletons (`test/helpers.zig:23-28`).
- Fix (Phase 2): expose explicit `State` structs; centralize model/pipeline/ledger into an owned context.

### [major] Boot order is an undocumented procedural sequence
- `main.zig:41-144` — xkb/config interleave; strict init order with zero declaration.
- Fix (Phase 2): data-driven init sequence / explicit dependency array.

### [minor] actions.zig is the command layer but filed under window/
- `src/window/actions.zig` (961 LOC) is the de-facto command bus consumed by core.
- Fix (Phase 2): relocate to its own subsystem (or core/).

### [minor] input/input.zig has the widest fan-in (~12 imports) incl. events↔input mutual
- `input.zig:14-35`. Fix (Phase 2): move grabKeybindings into input, break the mutual with events.

### [minor] 14 inline body-level @imports defeat dependency analysis
- `window.zig:641,856,928,970,1228`, `focus.zig:85,561,616,624,654,662`, `actions.zig:804,881`, `input.zig:412`, `config.zig:358,928`, modules.
- Fix: normalize to top-level `const` imports (documented comptime-gated exceptions).

### [minor] Window add-ons cross-import each other instead of the registry
- `minimize.zig:114,150` ↔ `fullscreen.zig:97,376,405,414` ↔ `workspaces.zig:43,56,69,83` ↔ `floating.zig:156,161,356`.
- Fix (Phase 2): route cross-add-on queries through registry helpers.

### [minor] Fact revisions hand-diffed per consumer
- `bar.zig:419-431,1423-1449`, `events.zig:568-575`. Sentinel `maxInt(u32)` init trick replicated.
- Fix (Phase 2): add `core.watch(rev, cb)` helper.

### [minor] Config struct doubles as live runtime bar state
- `bar.zig:93-95,139,1189-1228` mutates `config.bar.scaled_font_size`/`bar_position`.
- Fix (Phase 2): move runtime state into `bar/State`; keep BarConfig read-only.

### [minor] events.zig entangles poll loop with reload/reexec/drain/border-sweep
- `src/core/events.zig` (657 LOC). Fix (Phase 2): extract `reload.zig`.

### [minor] sync.st is a public mutable global
- `sync.zig:159` `pub var st: State`. The "exactly three behavioral reads" contract is discipline-only.
- Fix: make it private; expose the three reads as functions.

### [minor] bar/segment.zig imports pipeline (core)
- `segment.zig:24`. Fix (Phase 2): move truth-rect/title-anchor helpers behind the DrawCtx.

### [minor] persist.zig reads config + window-addon registry; restores via HANA_RESTORE only
- `persist.zig:27,42,251`. Fix (Phase 2): fine as-is; note restore is only exercised on re-exec.

### [minor] Engine tests gated on all add-ons presence
- `build.zig:186` (`model_test` needs minimize+fullscreen+floating+workspaces).
- Fix: split model_test into add-on-free parts.

### [nit] Repeated Gate provenance comments; magic work-budget constants scattered; warn-once latches; signal-pipe triplicated; re-exec second boot path; zoned links duplication
- Consolidations worth doing in a later pass; see full architecture audit.

---

## IV. Simplicity & readability

### [major] Self-reflecting config change-detection hasher
- `config/config.zig:1411` (`hashValue`), `:1460/1467` (listLike/mapLike shape-guessing), `:1480` (`detectChanges`), seeds `0x626172/0x74696c/0x6b6579` ("bar"/"til"/"key"). ~60 lines of reflection to decide "did bar/tiling/keys change".
- Fix: replace with `std.meta.eql` over the actual fields (tiling/bar/keys), or re-grab unconditionally.

### [major] Three workspace-id types across layers
- `model.zig` (`WSId=u16`), `core.zig` (`WorkspaceId { index: u8 }`), `config.zig` (1-based usize parsing), `workspaces.zig` (0-based index).
- Fix: one canonical 0-based id + `from1Based()` only at the parse boundary.

### [major] Focus truth stored three times
- `focus.zig` `last_applied`/`net_active_window`/async-reply caches vs `model.focused`.
- Fix (Phase 2 with focus refactor): single source; derive protocol state at use.

### [minor] Sink vtable with exactly one implementation
- `sink.zig` (XcbSink, erased `{ptr, vt}`, `@ptrCast(@alignCast(ptr))` on every call). NOTE: architecture/perf audits treat sink.zig as load-bearing; the layering itself is sound.
- Fix (considered, NOT recommended this pass): keep the vtable; it is the documented single-sink contract. Optional later.

### [minor] Magic numbers
- `events.zig` fd_xcb=0/fd_signal=1 + batch sizes 128/256 → derive poll array from actual fds, name budgets.
- `core/core.zig` `XK` keysym hex literals → re-export once from the x11 layer.
- `monocle.zig`/`grid.zig` `variant_idx == 1` → named variant const or `variantByName("gaps")`.
- `icccm.zig` WM_HINTS bit/offset literals → packed `WmHints` struct.
- `config.zig:1159` max_layouts=256 duplicated as `u8` kind in model → single home in model.
- `config.zig:1124/1179` two 32-byte layout-name buffers → one `max_layout_name` const.
- `clock.zig` `clock_measure_string` magic + pointer-identity staleness → derive from format / use eql.
- `tags.zig` fallback_width 270 → config default with comment.
- `proc.zig` wake_byte, `xkbcommon.zig` max_attempts=3 → commented named constants.
- `config.zig:1278` dupeNum re-copies via 24-byte buffer → `allocPrint`.

### [minor] Redundant/Gate copies, dispatch helpers, blob encoding
- `pipeline.Gate` copy-pasted in 4 window files → export once from pipeline.
- `actions.zig` 7 dispatch wrappers (callHook/callHookBool/dispatchAll/dispatchFirstTrue/callFirst/isCoveringMode/currentCoveringOccupant) → one generic dispatch returning a tagged result.
- `plugin.zig` deserializeWindow takes `*anyopaque` (modules @ptrCast back) → pass `*model.Model`, return `enum { unclaimed, claimed }`.
- `minimize.zig` hand-packed blob with maxInt sentinel → serialize the struct directly / single "no slot" encoding.
- `layout.zig`+`variants.zig` shared width/store pattern → shared helper.
- `segdraw.zig` `widthState` consumes `tag` via `const _ = tag;` → drop the param.
- `clock.zig` stale() by pointer → `std.mem.eql`.
- `workspaces.zig` "test-only" switchTo in production tree → move under test or real action path.
- `borders.zig` `w == 0` double-meaning short-circuit → compare `applied_border_width` optionals.
- `floating.zig` DragState 12 flat fields → group into Start/Last sub-structs.
- `pipeline.zig` `else struct {}` anonymous tiling fallback → named `NoTiling`.
- `window.zig` aspect inversion (dwm min_aspect=y/x) confusing names → store sane fractions, invert only at the constraint site.
- `input/xkbcommon.zig` hand-marshalled wire request → typed extern struct + named opcode.
- `x11/masks.zig` 8 hand-written modifier subsets → comptime fold; keysym range const next to XK.
- `core.zig`/`masks.zig`/`focus.zig`/`icccm.zig` protocol constants scattered → centralize in x11 layer.
- `bar/drawing.zig` hand-written `extern fn` cairo/pango → `@cImport` once.

### [nit] Naming/readability
- `vim.zig` `Awaiting`/`PendingCmd` near-synonyms → concrete (WaitingForCount/WaitingForMotion).
- `config.zig` `parseLayoutsArray` manual `i += 1` peek-based loop → explicit mini-parser with `nextOpt()`.
- `config.zig` `appendDupedStrings(…, comptime warn)` → two concrete functions.
- `config.zig` `parseWorkspaceRuleSection` parseInt-catch-as-type-discrimination → explicit numeric-prefix check + warn.
- `config.zig` `checkWorkspaceBound`/`workspace_number_1based` re-check → type-enforced range at parse boundary.
- `model.zig` `ALL_MASK` sentinel vs pinning policy → `Model.isPinned(e)` predicate.
- `proc.zig` wake_byte vs `events.fd_signal` naming split → single accessor.
- Multiple files: normalize layout-name lowercase+cap helper.

---

## V. Bar & tiling specifics

### [major] Tiling snap-to-increment → zero-size (see §I)
### [major] Master overflow grid cap (see §I)
### [minor] Center-layout segments overlap the right cluster
- `bar.zig:854-898` — one `remaining` for the title slot; later center segments draw at the right cluster's edge. Fix: `remaining -= consumed` per drawn center segment; reject >1 center-slot segment.
### [minor] Click targets beyond the 8th are silently dropped
- `bar.zig:376-380, 588-598` (`max_click_bounds`). Fix: size to the registry count or scan segments at hit-test.
### [minor] Marquee teleports after hide/show
- `carousel.zig:60-91` + `bar.zig:952-964` — `dt_ms` uncapped across the hidden gap. Fix: cap dt/max period or reset `last_frame_ms` on show.
### [minor] First frame after reload lays out zero-reserved segments
- `bar.zig:606-613` (`naturalWidth` returns 0 pre-cache-prime) pushes downstream segments. Fix: prime cache on measure.
### [minor] Omit-gap failure path leaves x unadvanced
- `bar.zig:738-765` — title failure desyncs the center cluster. Fix: return `x_before + w` on failure.
### [minor] Multiple right layouts reserve an extra trailing spacing
- `bar.zig:294-320` measure subtracts one spacing per layout, draw consumes one total. Fix: match draw.
### [minor] Non-vim insert swallows every Ctrl-key
- `prompt.zig:450-456` — Ctrl-C can't cancel. Fix: route Ctrl-C to deactivate (Ctrl-W/U optional).
### [minor] block: first prompt activation PATH/history scan stalls the loop
- (see §II) keep synchronous or defer — Phase 2-lite.
### [minor] Fibonacci duplicates leaf's bisection math
- `fibonacci.zig:69-104` vs `leaf.zig:25-65` → extract shared `bisectRegion(dim, gap)`.
### [nit] Sized-font cache stale on failed reload
- `drawing.zig:424-441` + `bar.zig:1121-1134` → rebuild sized font when resolved font differs.
### [nit] max_rendered_title_windows guard unreachable
- `title.zig:251-256` (vs bar.zig:388) → drop or bound by frame constant.
### [nit] Bar window event mask omits BUTTON_RELEASE
- `win.zig` → add BUTTON_RELEASE (+POINTER_MOTION if desired).
### [nit] History ring allows consecutive duplicates
- `prompt.zig` histPrepend → skip when head equals new line.
### [nit] Vim backward-range operators include char under cursor (documented deviation — keep).
### [nit] ensureAlloc comment misstates 512KB budget → correct the comment.
### [nit] Variants/layout magic width/position indexing → named consts.

---

## VI. Window & focus specifics

- (see §I for focus lifecycle, no_input, fullscreen-cycle, border-width, minimize/restore, floating hints.)
- `focus.zig:698` `cycle_buf` sized `max_tiled_windows` → size by `model.store_capacity` (floating tail dropped above 64).
- `focus.zig:346/353` dedup precedes raise-on-click + liveness guard → reorder: run mapped-guard first; keep raise decision when `last_applied == win`.
- `focus.zig:728-739` single-window cycle still grabs → `if (len == 1) return;`.
- `focus.zig:370-374` `prepareClearFocus` targets last_applied vs model → derive from model; assert `m.focused == last_applied` invariant at clear entry + steady-state test.
- `window.zig:914-923/951-955` resolveConfigureGeometry → delegate to `sync.truthRect` (one precedence implementation).
- `tracking.zig` facade predicates vs ledger visibility → parity test across ws switch/minimize/fullscreen.
- Three-way redundancy (model.Store + wincache + sync ledger) and focus ownership → codify one "live on-screen" authority; model-level covering claim only. (Phase 2.)
- `windows.zig` doesn't exist; window modules = fullscreen, workspaces, minimize, floating. Ensure cross-add-on queries go through `window.providerOf`.

---

## VII. Tests, build & hygiene

### Build
- Gate `tiling_latency_test` + `focus_latency_test` in `test_gates` (build.zig:180-192).
- Fix `tiling_test.zig` scroll-prune vs scroll tests desync (gate scroll tests on `has_layout_scroll`).
- Derive gates programmatically instead of a hand-maintained table (or at least add all missing rows: config/parser/persist/schema/visibility + both latency tests).
- No `-Dbar=false`-style toggle (only `-Dprofile-key`). Add optional `b.option(bool)` folds into `has_*` (default auto-detect).
- build.zig.zon `.links` duplicates `SystemLibraries`; nothing enforces equality → emit from one source or add a build test comparing both.
- `has_seg_clock` computed but never referenced by source → delete or document.
- Inconsistent `has_*` probes (`pathExists` vs `discovery.modules.contains`) → one source of truth.
- `owner_contracts` manual table for new owners → derive from naming convention. (Phase 2.)
- Import-wiring duplicated across three build spots → one shared passthrough.
- `catch unreachable` mixed with `try` for build-time OOM → standardize on `try`.

### Tests
- `input/` has zero tests; bar rendering core untested (`bar.zig`, `drawing.zig`, `segdraw.zig`, `segment.zig`, `win.zig`, layout/tags/title/variants/prompt/vim); window `borders.zig`/`tracking.zig`/`wincache.zig` untested; core `events/plugin/refresh/restart/spawn/scale/signals/masks.zig` untested.
- Add headless tests first-priority: `core/x11/masks.zig` (pure), `window/borders.zig` color resolution, `window/wincache.zig` map, `input` pure helpers (modifier fusion, key→action), `bar/modules/prompt/vim.zig` editor state machine, `config` parser malformed-input cases, `bounded.zig`.
- `persist_test.zig:9-17` documents a leak already fixed; :27 foregoes leak-checking → re-point `save` to `std.testing.allocator`, update the doc.
- `visibility_test.zig:28` self-skips exactly when fullscreen IS present — invert.
- Latency tests (focus/tiling/perf) print timings, assert nothing, run on every `zig build test` → gate to an opt-in bench step; add coarse bounds.
- `scratch.zig:4` hardcodes `/tmp/opencode` → `std.testing.tmpDir` / unique subdir.
- Fixture X-gated skip is silent (only `HANA_REQUIRE_X` flips) → print a skip banner; document in README Tests section.
- Duplicated fixture geometry/pixel conventions across sync_test/perf_test/tiling_latency_test → parameterized helpers.
- `tiling_test` `layoutByName(...) orelse 0` silently falls back to master → assert non-null in named-layout tests.
- Golden constraints baked to store_capacity/128 wrap → derive from constant.
- `helpers.test_cycle_names` hardcodes layout list → generate from registry.
- `model_test` magic ids → named constants / push helpers.

### Hygiene
- Delete stray `.swp` (12 KB vim swap at repo root).
- `.gitignore:13` `*.sw*` over-broad → explicit `.swp`/`.*.sw[a-p]` patterns.
- No LICENSE / `.editorconfig`; build.zig.zon has no `.license` → add `.editorconfig`; add LICENSE + `.license` field.
- README `TODO:` markers (docs section, GIF, IPC) are the real work list; code is TODO-clean — make the claim accurate.
- `.gitattributes` only covers the demo GIF → add `* text=auto`, `*.zig text eol=lf`.
- `dev/scripts/*` not wired into CI / README → document the canonical pre-push steps; wire modularity check into `zig build check`.
- `git status` shows an uncommitted `config/config.toml` edit — commit or revert.

---

## VIII. Implementation plan (first pass — synchronous agents, disjoint file sets)

1. **Core lifecycle & memory** — persist.zig, events.zig, main.zig, signals.zig, spawn.zig, restart.zig, scale.zig, refresh.zig, x11/wire.zig, x11/masks.zig, sync/sink.zig, sync/sync.zig (drag-ledger + sent-slot table), core.zig (constants only, if safe).
2. **Window & focus & sync** — focus.zig, actions.zig, window.zig, borders.zig, wincache.zig, icccm.zig, tracking.zig.
3. **Tiling** — tiling.zig + modules/* (geometry bugs + bisect dedup + named variants).
4. **Bar** — bar.zig, drawing.zig, segdraw.zig, segment.zig, win.zig, modules/* (layout bugs, prompt/vim fixes, cache perf).
5. **Config & input & model** — config/config.zig, config/parser.zig, config/schema.zig, config/types.zig, config/fallback.zig, input/input.zig, input/xkbcommon.zig, model/model.zig.
6. **Build, tests & hygiene** — build.zig, build.zig.zon, src/test/*, .gitignore, dev/scripts doc, delete .swp, add .editorconfig.

**Verification per agent:** `zig fmt` on changed files, `zig build`, and `zig build test` (X-gated tests skip headless).