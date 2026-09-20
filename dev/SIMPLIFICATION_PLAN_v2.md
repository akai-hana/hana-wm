# hana — Simplification Task List v2 (second audit pass)

Fresh, line-by-line audit campaign over the post-v1 tree. The v1 campaign
(`dev/SIMPLIFICATION_PLAN.md`, Phases A/B/C/D) is largely applied in the working
tree; this list contains only items that are **still live** in the current tree
(verified with repo-wide `rg` + reads, headed "CONFIRMED") plus the deferred
decision items carried forward from v1.

Mandate (unchanged): reduce LOC while preserving identical behavior, or improve
human readability; zero regard for risk/effort; modularity-by-deletion, the sync
boundary, and XCB-free pure layers are inviolable. No TODO/FIXME.

## Verification gates (every change)

1. `zig fmt --check .` clean.
2. `zig build check` — exit 0 (runs `check-layers.sh` + fmt).
3. `zig build test` — 270 tests pass (X-gated via `dev/scripts/xtest.sh`).
4. `tokei src -f -s code --exclude src/test/` — LOC delta reported per change.
5. Module-deletion matrix where a removal touches optional-module seams.

## Already applied in v1 (verified live, DO NOT re-do)

- `events.zig` reload-cleanup collapsed to one `committed` defer (B1) — events.zig:295-332.
- Two motion-coalescing loops merged (B2) — `collapseMotionRun`.
- `dirSign` + named tiling steps (B25) — input.zig:365.
- `barChanged` includes `brightness_format` / `brightness_device` (B30) — config.zig:1641-1642.
- `handleRandrNotifyEvent` dropped dead `conn` param (A4) — refresh.zig:90.
- `GeometryCollector` removed (A3-core).
- `WindowedProfiler` tag restored to the 4-arg form the profit gate requires (D7 collapse).
- System-library self-comparison investigation documented; `.links` mirror still open (see Deferred).

---

## A. Latent defects (highest priority — fix first)

| # | Location | Problem | Fix | Confidence |
|---|----------|---------|-----|------------|
| D1 | `config.zig:1583-1590` `eqlRules` | **Reload bug.** Compares only `workspace` + `class_name`; the `float` field of `types.Rule` (types.zig:547-554) is omitted. A reload flipping `float` on/off (or a `float` class-rule vs a `workspace = 0` rule, which share `workspace == 0`) reports `tiling = false` and never rebuilds tiling state. Config-agent confirmed. | Replace body with `std.meta.eql(a, b)` (fixes the omission class) as part of D4. | HIGH — verified live |
| D2 | `parser.zig:178-188` `warnUnconsumed` | **O(n²) + nondeterministic.** Iterates the `pairs` hash map (per-process random seed) and calls `lineOfKey` (O(n)) per entry → quadratic, nondeterministic diagnostic order. | Iterate the parallel `keys_in_order`/`lines_in_order` arrays (both populated by `insertOrAccumulate`, parser.zig:431-445 — every pairs key gets exactly one entry); lookup `consumed.contains` per key. Delete the now-dead O(n) `lineOfKey` call in this fn. | HIGH — invariant verified (`pairs.put` only at :442) |

## B. Dead code removal (always safe)

| # | Location | What | Est LOC |
|---|----------|------|---------|
| B1 | `bar/bar.zig:1350` `pub fn winId()` | Zero callers (main.zig:131 comment is stale). Delete fn + fix comment. | 4 |
| B2 | `wire.zig:353` `fetchPropertyToBuffer` + `utils.zig:114` re-export | Zero callers (only a stale doc-comment ref at `wincache.zig:283`). Delete both + fix comment. | 35 |
| B3 | `tiling/tiling.zig:108-110` `fullInset` | Single-caller wrapper over `totalInset` (caller `scroll.zig:48`); inline it. | 4 |
| B4 | `xkbcommon.zig:9` `const keysyms = ...` | Unused import (keybind/input use `XkbState` + `keysymGetName` only). | 1 |
| B5 | `utils.zig:120` `pub const ungrabServer = x11wire.ungrabServer` | Zero callers repo-wide (only `wire.zig` itself uses it). | 1 |

## C. Duplication consolidation (safe; tests pin behavior)

| # | Location | What | Est LOC |
|---|----------|------|---------|
| C1 | `core/sync/sync.zig:146-355` hand-rolled `SentIndex` | **The crown jewel (carried forward from v1 B3, still live — 18 hits).** Custom open-addressing table (`SentIndexCell`, `sentHash`, `sentIndexOf`, `sentIndexInsert`, `sentIndexRemove`, `sentIndexRebuild`, `sentIndexMove`) duplicates `utils.IdMap` (idmap.zig: same tombstone+probe+rehash, u32 keys, 256 slots). Replace with `utils.IdMap(usize, model.store_capacity)`; `sync_test`/`tracking_test`/latency pin behavior. | ~150 |
| C2 | `core/sync/sync.zig:683-696` `storeSlotOf` | Hand-carried binary search mirroring private `model.Store.exactAt` (model.zig:130). Expose `slotOf` (or `exactAt`) on the model, delete the mirror. | 17 |
| C3 | `config.zig:1524-1601` 10 hand-rolled eql helpers | Half are exact `std.meta.eql` equivalents: `eqlRules` (→ D1), `eqlOptionalString`, `eqlScalableOpt`/`eqlScalable`, `eqlLayoutOverrides`, `eqlMasterCountOverrides`, `eqlStrings`. Keep only: `eqlBarLayouts` (must compare `segments.items`, not capacity/bookkeeping), and ONE generic unordered-map helper replacing `eqlVariantMap` + `eqlSegmentColors` (StringHashMapUnmanaged can't be `std.meta.eql`-ed). | ~45 |
| C4 | `input/input.zig` | Two inline f32 steps (`0.025` master-width, `0.5` stack-balance) beside the i32 `dirSign` — add `dirSignF`, promote to constants.zig (v1 B25 handled the integer side only). Verify live lines during impl. | ~5 |
| C5 | tiling layout-name resolution | Same resolve+warn+fallback copy in `tiling.zig`, `pipeline.zig`, `actions.zig`. Hoist a shared `resolveLayoutName` in the tiling package (tiling is the pure owner; window/core import it, not vice versa). | ~20 |

## D. Named constants (fresh; v1's list already folded in)

| # | Location | What |
|---|----------|------|
| N1 | `input/xkbcommon.zig` | `x11_min_keycode = 8`, `keymap_health_hi = 128` (v1 C14 — verify live; if folded, skip). |

## E. Deferred items & questions (for the user)

These carry design ambiguity or hot-path risk; not attempted without a decision.

1. **v1 questions D.1–D.10** (carried forward, still open):
   - `computeDesire` restructure to a presence/anchor `switch` (hot path) — restructure or keep the single-written if-chain?
   - Full reload-detector derivation (`barChanged`/`tilingChanged`/`keysChanged` from `schema.knobs`) vs stop at the D1/D4 eql consolidation?
   - `RestoreOrder` unification home: `config/types.zig` or `model/model.zig`?
   - `Store.iterator()` (B29) migrate the ~8 row-iteration sites — proceed or keep explicit idiom?
   - systatus/slider shared polled-segment scaffold — extract or leave documented twins?
   - `segdraw.clickHook` unreachable null branch — remove or keep as comptime guard?
   - Fullscreen occupant-scan collapse vs module-local scan (correctness-first)?
   - Privatize `sync.st` or accept the documented public-global seam?
   - Keep deletion-by-source-file with no `-D` toggles? (Recorded as intended design.)
   - Annotate test-only seams in place vs relocate into test files?
2. **`build.zig:1576` `SystemLibraries.comptime`** — self-comparison (compares two arrays both hardcoded in build.zig); can never catch `.links` drift. Fix requires reading the real `.zon` `.links` (IMPROVEMENTS.md:346 flags OPEN). Decision needed: wire the read now (medium, touches build) or defer.
3. **RandR machinery unconditional** (`events.zig`, `refresh.zig`) with zero consumers in bar-less builds; `poll(-1)` blocks forever without `has_bar` (time is a bar feature). Cross-cutting agent flagged; changing this touches the event-loop contract — decision needed.
4. **Model audit retraction**: `model.applyConfigReload` (model.zig:483) is NOT dead — it is the reload path (`actions.applyConfigReload` → `model.applyConfigReload`, engaged at events.zig:351). Do not delete.
5. **systatus/slider B3 v1 item** confirmed not folded — see 1.

---

*Execution order for this campaign: A (D1+D2) → B (dead code) → C (C1/C2/C4/C3,C5) → D → report. Every item gated by `zig fmt` + `zig build check` + `zig build test` + tokei delta. Items not attempted land in the Deferred / questions section of the final report.*

## Execution status (2026-09-20, this pass)

Implemented and verified (`zig fmt` clean, `zig build check` exit 0 incl. check-layers.sh all-rules, `zig build test` 270/270):
- **D1+D4** — `eqlRules` reload bug fixed; the 10 hand-rolled eql helpers collapsed: optional/scalar/rule/string/override comparators now `std.meta.eql`, the variant + segment-color map comparators merged into one `eqlStringMap(comptime V, ...)`.
- **D2** — `warnUnconsumed` now iterates the document-order `keys_in_order`/`lines_in_order` arrays: deterministic warnings, O(n) instead of O(n²), per-key first-decl line preserved.
- **B1–B5** — deleted `bar.winId`, `wire.fetchPropertyToBuffer` (+ re-export + stale refs), `tiling.fullInset` (inlined into `totalInset`), unused `keysyms` import, `utils.ungrabServer` re-export.
- **C1** — hand-rolled `SentIndex` (7 fns, ~150 lines, 3-way cell enum, manual tombstone rebuild) replaced with `utils.IdMap(usize, model.store_capacity)`; same tombstone/probe recipe as the ICCCM cache. `sentGetOrPut`/`sentSwapRemove`/`forget` external behavior unchanged.
- **C2** — `sync.storeSlotOf` binary-search mirror deleted; `model.Store.slotOf` exposed; 2 call sites switched.
- **C5** — layout-name resolve+warn+fallback hoisted to `tiling.layoutKindOf`; `pipeline.defaultIndexForLayoutName` and `actions.seedParamsFromConfig` delegate; pipeline's now-dead `debug` import dropped.
- **C4/N1** — verified already folded by the v1 campaign (constants.master_width_step / stack_balance_step / x11_min_keycode / keymap_health_hi all live); no action.

Footprint: code lines 16,713 → 16,513 (−200) with identical behavior (270 tests, layer rules, fmt). Aggregate with v1: ~16,513.

**Audit corrections recorded this pass:** `model.applyConfigReload` is NOT dead (reload path via `actions.applyConfigReload`, events.zig:351) — retracted. `fetchPropertyToBuffer` WAS a live finding (v1's A3 removed only GeometryCollector).

## Batch 3-4 status (store / reload / test-seams / build / RandR)

All further items in `simplification-audit.md`'s numbered pass were taken; each verified with `zig fmt`, `zig build check` (layer rules + plugin template), and `zig build test` 270/270. Where a change traded structure for risk, the resolution is documented below (STOP + rationale in the two cases that were decided, not implemented).

- **Store row-scan migration** — `model.Store.Iterator` (`next()` → `Item`) + public `slotOf` added; the hand-rolled `0..count()/at()` scans migrated (coveringOccupantOnWs, focus-fallback floating tier, tracking.allWindows, persist membership-repair + snapshot loop, model fallback scans). Reconcile hot pass stays index-based (`at(i)` feed to `pl_of_slot`).
- **`computeDesire` restructured** to an explicit `presence` switch — and this change carried a regression that only the suite caught: `.present` siblings stopped hitting the outer `fs_win != null` → parked arm, so covered windows sent no park during fullscreen (3 sync fullscreen tests + 1 tracking ledger test failed). The guard is now an explicit `.present` sub-arm; full suite back to 270/270.
- **persist.save split** — `Snapshot` (owning, single `deinit`), `saveSnapshot` (row-local errdefer), `stringifySnapshot` (scalars read live), `atomicWrite` (temp + O_EXCL + rename); `save()` composes.
- **Test-only seams** — `sync.deinit` deleted (9 test call sites → `sync.init()`); `Slot`/`slotAt` relocated into `slider_test.zig`; `protocolParityHolds` / `coverageOn` / `resetForTesting` annotated in place (read private module state; cannot relocate).
- **build.zig real `.zon .links` read** — `SystemLibraries.loadLinks` parses `build.zig.zon` (full-shape `Zon`, diag-based) instead of a comptime mirror; mirror + self-check deleted.
- **RandR is a bar feature** — `refresh.zig` moved `src/core/` → `src/bar/`; core reaches it only via the `Surfaces` seam (3 hooks); events/redetect gated on `has_bar`. check-layers allowlist updated.
- **Time-polling is a bar feature** — `cursor_is_blinking` renamed `bar_deadline_active`, derived from `pollTimeoutMs() >= 0`.
- **systatus/slider scaffold** — documented twins, no extraction (read-only fixed-cadence vs interactive drag/scroll/throttle; matches the fullscreen precedent).
- **Fullscreen occupant scan** — kept module-local + documented divergence (`coveringOccupantOnWs` = anchored OR visible; module = anchored AND visible).
- **Reload detectors (E-series question)** — resolved STOP at the D1/D4 eql consolidation: knobs-derived reflection would still need hand overlays for the non-scalar bar/tiling content and the bespoke pair-based keys logic, replacing plain `!=` lists with reflection + a second list; rationale documented above `barChanged`.
- **Earlier pass items verified** — sentGetOrPut non-error collapse, segdraw strict clickHook, XKB retry collapse, fixture `tilingEnv`, `withServerGrab`, buttonPress decompose, prompt fixed arrays, deserializeWindow typed, sync.st private, RestoreOrder single-home.

Footprint after this batch: 16,553 code lines (16,513 → +40): the new `Surfaces` seam hooks + bar proxies, `Snapshot`/`Zon`/`Iterator` types and the `detectChanges` rationale outweigh the deleted mirror/helpers — the deletions landed as intended (SentIndex, storeSlotOf, eql helpers, deinit, refresh import, `.links` mirror) while net adds are the seam surface the closed-core layout trades with.