# Hana `src/core` Simplification Audit

Date: 2026-09-20
Method: full read of all 24 files in `src/core/` (~5,480 LOC), caller verification by
`rg` across `src/`, `src/test/`, `dev/plugin-template/`, `build.zig`,
`dev/scripts/check-layers.sh`. Baseline gates: `zig build check` and `zig build test` both
pass. Every proposal below was checked against `check-layers.sh` rules 1-4 (wire sends /
server grabs / pure-layer xcb / fmt); none violates them.

## Constraint acknowledgements

- **Sync boundary is sacred.** Raw wire-mutating sends must stay behind `src/core/sync/`
  (sink) plus the documented allowlist. No proposal here moves a wire send across it.
- **Pure layers** (model/tiling/config) must stay xcb-free and core must never name an
  optional module by import (deletion-modularity). Nothing below touches that.
- #3 alters a contract signature; it is mechanically verified by the `check-plugin-template`
  step inside `zig build check`, so drift self-fails.

## Verified: not dead (checked so the report's claim is precise)

- Every `WindowModule` hook (40 fields across 6 families) is bound by exactly one module
  and dispatched somewhere (events/persist/pipeline/window/bar). No dead hooks.
- `masks.*` modifier constants, `constants.*` limits, `screen.*` API, `scale.*`, `refresh.*`
  are all consumed.
- `WindowedProfiler` has exactly two instantiations (key-dispatch in input, retile in sync).
- Both `sync.Stack` values and the ledger's three contract reads (orphan keep-last, winner
  raise, lastRectFor/truthRect) are live.

---

## Findings by file

### `src/core/sync/sync.zig`

- **Location**: `sync.zig:137-355` (SentEntry/SentIndex + sentIndexInsert/Remove/Move/
  Rebuild, sentGetOrPut/sentSwapRemove/sentGet/forget/sentFind/sentIndexOf/sentHash)
- **Category**: DUPLICATION / CONSOLIDATION
- **Issue**: A second open-addressed window-ID hash map is hand-rolled here (tombstones,
  power-of-two slots, rebuild-on-tombstone-full, mask wrap) next to the identical shape in
  `utils/idmap.zig` (`IdMap(V, capacity)`: same probe, tombstones, rehash, fixed capacity).
  `st.sent` (BoundedList) + `st.sent_index` together are exactly `utils.IdMap(SentEntry,
  model.store_capacity)` — `SentEntry.id` even duplicates the map key. sync.zig uses low-bit
  hashing (`win & (cap-1)`), notably weaker than IdMap's Fibonacci mixing for arbitrary XIDs.
- **Proposal**: delete `sent` + `sent_index` + all `SentIndex*`/`sentIndex*` helpers; back
  `State.sent` with `utils.IdMap(SentEntry, model.store_capacity)` and keep the same public
  API names (`sentGet`, `sentGetOrPut`, `forget`, `sentSwapRemove`, `markSentBorderWidth`).
  Rehash leaves the in-flight `gop` pointer stable (rehash happens inside `put`, before the
  pointer is handed out; per-iteration writes are done before the next window's insert).
  Drop `SentEntry.id` (key carries it).
- **Effect**: -~150 LOC in core; one hash implementation instead of two; stronger hash;
  swap-remove/move relocation machinery disappears entirely.
- **Confidence**: MEDIUM-HIGH (hot path; the "exactly one get-or-put per window per pass"
  perf contract in `test/latency/perf_test.zig` survives; `test/engine/sync_test.zig`,
  `tracking_test.zig`, `pipeline_test.zig` re-verify ledger semantics)
- **Constraint risk**: none.

- **Location**: `sync.zig:190-196` (`init`/`deinit`)
- **Category**: DEAD CODE (production) / API ERGONOMICS
- **Issue**: `pub fn deinit()` is invoked nowhere in production (no reconnect path exists);
  it is purely a test convenience that calls `init()`. `init()` is called from
  `pipeline.init` and `sync_test/latency` tests.
- **Proposal**: drop `sync.deinit` (tests call `sync.init()` between cases, as several already
  do), or mark it `/// test-only remap of init()`.
- **Effect**: -2 LOC; removes a misleading re-init/undo pairing.
- **Confidence**: HIGH
- **Constraint risk**: none.

### `src/core/sync/sink.zig` + wire boundary

- **Location**: `sink.zig:1-11` vs `wire.zig:1-5` vs `sync.zig:1-4`
- **Category**: COMMENT QUALITY / READABILITY
- **Issue**: Three headers each claim to describe "the sanctioned boundary" with three
  different topologies: sync.zig says "every raw XCB request lives in the sink file";
  sink.zig lists its shims as "~ utils.configureWindow / borders.applyWidth / raiseWindow";
  wire.zig says it is "the ONLY xcb-dependent half". The truth is a split primitive home
  (raw `xcb_configure_window`/`change_attributes`/flush in wire.zig; raw
  `xcb_map_window`/`change_property`/`get_property` in sink.zig; both allowlisted). A reader
  cannot tell which file is the seam and which is the primitive home.
- **Proposal**: adopt one sentence everywhere: "the sanctioned seam is src/core/sync/
  (dispatch), whose raw XCB shims live in src/core/x11/wire.zig (primitive home, also
  allowlisted for ConfigureRequest/borders/icccm)."
- **Effect**: 0 LOC; removes a three-way contradiction.
- **Confidence**: HIGH (comment-only)
- **Constraint risk**: none.

### `src/core/utils/utils.zig`

- **Location**: `utils.zig:120` (`pub const ungrabServer = x11wire.ungrabServer;`)
- **Category**: DEAD CODE
- **Issue**: Zero callers of `utils.ungrabServer` anywhere in the tree (verified: only
  wire.zig's own `ungrabAndFlush` uses the primitive; bar.zig grabs via
  `utils.grabServer`; everyone ungrasps through `ungrabAndFlush`). The export exists only
  because `check-layers.sh` pat2 scans the name.
- **Proposal**: remove the re-export; make wire.zig `ungrabServer` private (or leave it pub
  with a note). The pat2 regex simply stops matching — no guard change needed.
- **Effect**: -1 LOC export surface; removes a misleading primitive (ungrabbing without
  flush is never wanted by anyone).
- **Confidence**: HIGH
- **Constraint risk**: none (Rule 2 unaffected; the scan name disappears).

- **Location**: `utils.zig:71-103` (`WindowedProfiler`), call sites `sync.zig:367`,
  `input.zig:key_profile`
- **Category**: DEAD CODE (param) / minor
- **Issue**: The `tag` parameter is discarded (`_ = tag;`); only `enabled`/`fmt`/`logFn` are
  used.
- **Proposal**: drop the `tag` param from the factory; update the two call sites.
- **Effect**: -2 LOC; honest signature.
- **Confidence**: HIGH
- **Constraint risk**: none.

### `src/core/x11/wire.zig`

- **Location**: `wire.zig:349-386` (`fetchPropertyToBuffer`), re-export at `utils.zig:114`
- **Category**: DEAD CODE
- **Issue**: No caller anywhere. The window layer fetches properties through its own
  `icccm.firePropQuery` / `wincache.zig` paths (which use `collectPropertyReply` +
  `constants.property_max_length`/`property_no_delete` directly). `wincache.zig` references
  the function only in a comment.
- **Proposal**: delete `fetchPropertyToBuffer` and its `utils` re-export. Keep
  `collectPropertyReply` (live) and the constants (live in window layer).
- **Effect**: -35 LOC; removes a second, unused 8-bit fetch vocabulary.
- **Confidence**: HIGH (if it is intended future abstraction for a property fetch, the
  window layer's existing firePropQuery already covers it)
- **Constraint risk**: none.

### `src/core/pipeline.zig`

- **Location**: `pipeline.zig:154-314` (nine public seams)
- **Category**: API ERGONOMICS / DUPLICATION
- **Issue**: The grab/reconcile seam zoo. Four public wrappers
  (`reconcileUnderGrabNow`, `reconcileGrabFocus` pair, `reconcileUnderGrabNowWithFocusDuty`,
  `focusOnlyCommit`) plus `reconcileUnderGrabNow`, `reconcileUnderGrabNowFullscreen`,
  `reconcileNow`, `grabCtx`, `reconcileUnderGrabNowWithFocusAfter` repeat the same
  `grabServer()` / `defer ungrabAndFlush()` body with different (focus_before, duty,
  fullscreen) decorations. `reconcileUnderGrabNowWithFocus`,
  `...WithFocusAfter`, and `...WithFocusDuty` differ only by two booleans.
- **Proposal**: keep one general seam `reconcileUnderGrab(o, t: focus.FocusTransition,
  focus_before: bool, duty: ?*const fn() void)` behind the existing named wrappers, or a
  private `fn withGrab(f: *const fn (*sync.Ctx) void) void` for the shared body. The
  fullscreen variant is genuinely special (EWMH writes + bar hide inside the grab) and
  stays as-is.
- **Effect**: -40-60 LOC of duplicated grab plumbing; preserves named readability if thin
  wrappers remain.
- **Confidence**: MEDIUM (the ordering comments are subtle; do it with the latency tests on)
- **Constraint risk**: none (grabs continue via `sink.grabServer`).

### `src/core/plugin.zig`

- **Location**: `plugin.zig:41-44` (`modelPtrOf`), `plugin.zig:124`
  (`deserializeWindow (u32, []const u8, *anyopaque)`), `window.zig:771-772`,
  `fullscreen.zig:328`
- **Category**: API ERGONOMICS / OVER-ENGINEERING
- **Issue**: The deserialize seam round-trips a *known* type through `*anyopaque`: window.zig
  already holds `*model.Model` and does `@ptrCast(model)`; fullscreen.zig undoes it with
  `plugin.modelPtrOf(ptr)`. `plugin.zig` already imports `model`, so the contract can name
  the type. Nothing about "may WRITE model state" (the stated rationale) requires opacity —
  the serialize side already passes a typed `*const model.Model`.
- **Proposal**: type `deserializeWindow` as `fn (u32, []const u8, *model.Model) bool`; delete
  `modelPtrOf`; drop the casts in window.zig and fullscreen.zig.
- **Effect**: -5 LOC; kills two casts; the opaque-value seam survives only where the type is
  genuinely cross-layer (`Segment.draw` ctx, `Frame`/`Env`).
- **Confidence**: HIGH (type-checked by the `check-plugin-template` build gate)
- **Constraint risk**: none (contract stays inside the window hub; model stays pure).

- **Location**: `plugin.zig:106-219` (WindowModule overload, 40 nullable hooks)
- **Category**: OVER-ENGINEERING (judgment)
- **Issue**: The flat all-optional-hook contract is large. Verified: every hook is bound and
  dispatched — none is dead, and it is the mechanism that keeps core free of optional
  imports. The cost is a long null-for-declaration ceremony per module.
- **Proposal**: keep as-is (architecture-correct); optionally tighten the family grouping
  comments (Lifecycle/Persistence/Fullscreen/Hide-Restore/Covering/Workspaces/Floating)
  into one banner so scanning is cheap. Document rather than refactor.
- **Effect**: 0 LOC or -0; maintainability note.
- **Confidence**: HIGH (this is a "do not touch" verification)
- **Constraint risk**: none.

### `src/core/events.zig`

- **Location**: `events.zig:449-569` (`handleXcbEvents`)
- **Category**: READABILITY
- **Issue**: Two near-identical drain loops (batch via `xcb_poll_for_event`,
  `events.zig:473-495`; queued drain via `xcb_poll_for_queued_event`, `events.zig:518-539`)
  share `collapseMotionRun` but differ in budget charging (`charge_tail`), and the
  `pending` stashing semantics are subtle (C15 traps). This is the single densest
  scheduling code in core.
- **Proposal**: leave the semantics, but add a short banner comment stating the two-loop
  structure (socket read-ahead vs XCB internal queue) and why they cannot be one pull; this
  is the same "document, don't refactor" treatment as the fullscreen grab paths.
- **Effect**: 0 LOC; the riskiest touch is the queue-drain boundary, so no merge is
  recommended.
- **Confidence**: HIGH (comment-only); MEDIUM that any unify is worthwhile
- **Constraint risk**: none.

- **Location**: `events.zig:268-369` (`handleConfigReload`)
- **Category**: COMMENT QUALITY
- **Issue**: The C1/C2/C3 ordering markers + `committed` flag are dense but load-bearing
  (documented use-after-free history). This is *good* documentation; only the bare codes
  are opaque. See the cross-cutting comment finding below.

### `src/core/persist.zig`

- **Location**: `persist.zig:111-216` (`save`)
- **Category**: ALLOCATION (cold path, LOW priority)
- **Issue**: Several transient allocations on the re-exec hand-off: `windows` record array,
  per-window `ext` blob dupes, per-workspace `tiled`/`mru` dupes, then `std.json` stringify
  into an `Allocating` writer + `toArrayList()` in RAM, then one `writeStreamingAll` to the
  file. The whole serialized session sits in memory once (plus the indent_2 expansion).
- **Proposal**: stream the JSON to the file fd (a `std.Io.Writer` over the temp file)
  instead of buffering the entire dump; the temp-file+rename safety already exists in the
  create/rename dance, so partial-write safety is preserved.
- **Effect**: ~halves peak memory during a save; save happens once per re-exec, so this is
  polish.
- **Confidence**: LOW-MEDIUM (Zig 0.16 streaming-JSON ergonomics + the blob lifetime
  dance make this the most fiddly of the bunch for the least payoff)
- **Constraint risk**: none.

### `src/core/core.zig`

- **Location**: `core.zig:87-101` (`factAccessors` comptime generator)
- **Category**: OVER-ENGINEERING (micro)
- **Issue**: A comptime `factAccessors("focus_rev")` factory generates `rev()`/`bump()` for
  four counters. The generator (12 LOC) is about as long as four hand-written fn pairs and
  indirection is net-negative at this size.
- **Proposal**: replace with four plain `pub inline fn` pairs (or a 4-entry shared helper).
- **Effect**: -0 to -5 LOC; removes one indent of metaprogramming for negligible gain.
- **Confidence**: MEDIUM (subjective; the generator also enforces the `+%= 1` wrap policy
  in one place)
- **Constraint risk**: none.

### Cross-cutting

- **Location**: markers `C1`..`C15`, `P1`, `P5`, `W3`, `Gap 2` across events.zig,
  sync.zig, sink.zig, signals.zig, restart.zig, refresh.zig, persist.zig, spawn.zig,
  wire.zig, scale.zig, pipeline.zig
- **Category**: COMMENT QUALITY
- **Issue**: ~25 bare change-note codes with no index anywhere in the tree; a new reader
  can't resolve "C15"/"Gap 2" to anything. The explanatory prose attached to each is
  valuable and must stay.
- **Proposal**: either (a) replace the code prefixes with the prose already present
  ("C15:" → "batch-budget:", "P5:" → "border-sweep:", "Gap 2:" → "fullscreen-grab:"), or
  (b) keep the codes but add one indexed legend to src/core/README or the first header.
  Prose-only (a) is the higher yield; it touches comment lines only.
- **Effect**: 0 LOC; readability gain across every core file.
- **Confidence**: HIGH it is safe (comment-only); MEDIUM that the project wants the codes
  dropped vs indexed.
- **Constraint risk**: none.

### Clean (no findings warranted)

`screen.zig`, `scale.zig`, `refresh.zig`, `signals.zig`, `spawn.zig`, `restart.zig`,
`x11/masks.zig`, `x11/xcb.zig`, `utils/bounded.zig`, `utils/constants.zig`,
`utils/debug.zig`, `utils/ids.zig`, `utils/paths.zig`, `utils/proc.zig` — read in full;
small, single-purpose, their constants/APIs all verified live. Two one-line nits kept out
of ranking: `xcb.xcb` names the cImport decl after its own module (spawn/restart use `c`,
which reads better), and `sync.Stack` naming for a single-value enum is tie to the
`geom`/`stack_only` signatures (fine as-is).

Note (outside src/core scope, for awareness): `build.zig.zon` carries a `// TODO` about the
`.links` mirror not being enforced, while `SystemLibraries.comptime` block in build.zig
*does* mechanically enforce it — the TODO may already be stale, and a TODO in the repo is
in tension with the documented "no TODO by design" posture.

---

## Top 10 highest-yield simplifications (ranked)

| # | File:Line | Category | Proposal | Effect | Conf. |
|---|-----------|----------|----------|--------|-------|
| 1 | sync/sync.zig:146-355 | DUPLICATION/CONSOLIDATION | Rebuild the sent-ledger on `utils.IdMap(SentEntry, store_capacity)`; delete `sent`+`SentIndex`+7 helpers | -~150 LOC, one hash map instead of two, better hash | MED-HIGH |
| 2 | x11/wire.zig:349-386 | DEAD CODE | Delete `fetchPropertyToBuffer` + its utils re-export (zero callers) | -35 LOC | HIGH |
| 3 | plugin.zig:124 + window.zig:772 + fullscreen.zig:328 | API ERGONOMICS | Type `deserializeWindow` as `*model.Model`; drop `modelPtrOf` and both casts | -5 LOC, two casts gone, gate-verified | HIGH |
| 4 | utils/utils.zig:120 | DEAD CODE | Delete dead `utils.ungrabServer` re-export; privatize/annotate wire primitive | -1 LOC, honest surface | HIGH |
| 5 | pipeline.zig:154-314 | API ERGONOMICS/DUPLICATION | Collapse the 4 grab-wrappers onto one `withGrab`/duty-carrying seam | -40-60 LOC | MED |
| 6 | sync.zig:1-4 vs sink.zig:1-11 vs wire.zig:1-5 | COMMENTS | One canonical "sanctioned seam vs primitive home" statement | 0 LOC, resolves contradiction | HIGH |
| 7 | events.zig, sync.zig, persist.zig, signals.zig, ... (C1-C15, P*, W3, Gap N) | COMMENT QUALITY | Replace opaque marker codes with the prose already attached, or add one legend | 0 LOC, whole-file readability | HIGH |
| 8 | utils/utils.zig:71-103 | DEAD CODE (param) | Drop the unused `tag` param of `WindowedProfiler` | -2 LOC | HIGH |
| 9 | persist.zig:111-216 | ALLOCATION | Stream JSON to the temp file instead of buffering the full dump | ~50% save-path peak memory | LOW-MED |
| 10 | core/core.zig:87-101 | OVER-ENGINEERING | Replace the `factAccessors` comptime generator with 4 plain fn pairs | -0-5 LOC, one less indirection | MED |

Constraint check for every entry: none moves a wire send or server grab across the sync
boundary, none touches model/tiling/config purity, and #3's signature change is
self-verifying via the `check-plugin-template` step inside `zig build check`.

Estimated total: ~230-270 LOC removed from src/core (~5,480 LOC, ~4-5%), concentrated in
the sync layer, plus a contract that is easier to read at every call site.