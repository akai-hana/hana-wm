# Cross-cutting interconnection simplification audit (2026-09-22)

- **Scope**: whole-repo view of the seams *between* the per-subsystem concerns
  (bar / config / core / input / model / tiling / window): shared types and
  idioms duplicated across layers, build-gate/script/registry sync, doc ↔ tree
  drift, and repo hygiene. Peer audits own the subsystem internals; findings
  here are the interplay surface, idents `CC-v5-*`.
- **Method**: full reads of `build.zig` (1,648 lines / 80,190 B — the "~2,800"
  in the task brief is stale), `src/core/plugin.zig` (the four contracts),
  `dev/scripts/check-layers.sh`, `dev/scripts/check-modularity.sh`,
  `dev/SIMPLIFICATION_PLAN_v3/v4.md`, `IMPROVEMENTS.md`, `README.md`,
  `dev/plugin-template/{layout,provider,segment}.zig`, `.github/workflows/ci.yml`,
  plus targeted greps and manual rule re-sweeps. No builds were run (background
  `/tmp/opencode/buildcheck.out`: "check-layers: all layer rules pass"); the tree
  is WIP-modified on `dev`, and disk is trusted over history.
- **Constraints respected** (verified live, not assumed): sync boundary sacred
  (raw wire behind `src/core/sync/` + the `check-layers.sh` allowlist), pure
  layers (model/tiling/config) xcb-free (Rule 3's find now includes
  `src/config`), core never names an optional module, modularity-by-deletion
  (no go-between stubs), `zig fmt` clean (Rule 4).

## 1. Method note & applied state

### CC-v4-1..8 (authorized 2026-09-22) applied state

| ID | Authorized | Applied state (verified in the current tree) |
|---|---|---|
| CC-v4-1 (IN-11 allowlist src/input/xkbcommon.zig + pat1 `xcb_xkb_per_client_flags`) | both | **APPLIED** — allowlist entry at check-layers.sh:52-62 and pat1 member at :156, load-bearing: the file exercises `xcb_get_extension_data`/`xcb_xkb_id`/`xcb_xkb_per_client_flags(_reply)` at lines 49-69. |
| CC-v4-2 (check-modularity removal list) + 2b (loud-fail) | both | **APPLIED** — all removal paths verified on disk; `remove_paths` fails loudly on a missing path. |
| CC-v4-3 (re-triage IMPROVEMENTS.md:278/287/289) | both | **NOT APPLIED** — rows still read OPEN (see CC-v5-7). |
| CC-v4-4 (comptime single-binder asserts in generated registries) | both ("do both") | **NOT APPLIED** — rg finds no comptime asserts; "At most one module binds" remains prose-only (CC-v5-5). |
| CC-v4-5 (buildTilingSeamModule extraction) | both | **APPLIED** — build.zig:498-520; the `tiling.layoutModule` template matches it. |
| CC-v4-6 (scenario asserts + derive test_gates / ungated-test hard error) | both ("do both") | **PARTIAL** — scenario-existence asserts and the ungated-test hard error are in; `test_gates` is still hand-written (CC-v5-4). |
| CC-v4-7 (marker-strip) | both | **PARTIAL** — `(B1)`/`(C1)` gone; production `(B2)` survives at prompt.zig:1223; `(C1)` at parser_test.zig:134 is a deliberate test comment. |
| CC-v4-8 (typed `workspace_idx` → ids.WorkspaceId) | both | **APPLIED** — config/types.zig:210,217 typed; `fromIndex` casts at config.zig:1175,1276; `model.WSId` (model.zig:15) and `core.WorkspaceId` (core.zig:40) are now aliases of the single `ids.WorkspaceId`. |

### IMPROVEMENTS.md triage (rows inside this remit)

| Row | Classification | Evidence (current tree) |
|---|---|---|
| §IV:278 "three workspace-id types… config bare u8" | RESOLVED-in-tree (stale row) | one canonical `ids.WorkspaceId` (ids.zig:15) + two aliases (CC-v4-8 verified); no bare `u8 workspace_idx` remains. |
| §VII:363 "S01–S21 need recapture; CI continue-on-error" | RESOLVED-in-tree (stale row) | all 23 goldens S01–S23 present and committed; ci.yml harness job now *gating* ("parity drift now fails CI"); dev/harness clean. |
| §VII:362 "borders coverage OPEN" | PARTIALLY RESOLVED | `borders_test` + `borders_pure_test` exist and are gated; the parser-malformed-cases item is still open. |
| §VII:354 zon `.links` duplication vs SystemLibraries | RESOLVED-in-tree | `SystemLibraries.loadLinks` re-reads the real build.zig.zon at configure time (build.zig ~1619). |
| §IV:289 redundant/gate copies, dispatch helpers | PARTIALLY FIXED — the residue is the bar string-dispatch pair (CC-v5-2) | window: 4 enum-tag helpers (window.zig:39-78); bar: 2 comptime-string helpers (bar.zig:111-118). |
| §II:480 coveringOccupantOnWs not-cached | WRITEUP-only (measured, bench-pinned decision) | 480.8 vs 105.4 ns/call; both predicates deliberately stay (fullscreen.zig:219). |
| §IV:287 magic numbers | OPEN-still-true | sample sites unchanged, incl. slider probe constants (CC-v5-8). |
| §VII:353 `-Dbar=false`-style toggles | OPEN-still-true (by design) | exposed options are only `-Drelease`/`-Dprofile-key`/`-Dbench`; all `has_*` derive from discovery (build.zig ~64-113). |
| §III:233 import-adjacency Rule | OPEN-still-true (purity only is covered) | `assertPureLayerImports` enforces import *purity*; no cyclic-edge adjacency step. |
| §VII:355/357/358 dead `has_seg_*` / owner-contract derive / pure-layer asserts | FIXED (verified) | deriveOwnerContracts + assertPureLayerImports present; `has_seg_*` no longer published as build options. |

## 2. Findings

| ID | Location | Axis | Issue | Fix | Est LOC | Conf |
|---|---|---|---|---|---|---|
| CC-v5-1 | src/model/model.zig:10, src/core/core.zig:31 | simplification (type unify) | `WindowId = u32` is independently redeclared in two layers; the WorkspaceId precedent (one `ids.zig` authority + aliases, CC-v4-8) has no WindowId twin | add `pub const WindowId = u32` to src/core/utils/ids.zig; alias it in both layers (the contract already speaks `model.WindowId`) | ~4 (2 files + ids) | HIGH |
| CC-v5-6 | src/bar/modules/prompt/prompt.zig:1223 | hygiene | CC-v4-7 strip missed a production `(B2)` marker in a comment ("the user's typing (B2).") | delete the marker literal | 1 | HIGH |
| CC-v5-3 | src/core/logs/atlauncher.log | hygiene / repo | a 5,663-B ATLauncher JVM log is committed under src/core (git ls-files); unrelated runtime artifact in the trusted tree | `git rm` it and ignore `logs/` (no checker references the dir) | 1 file + 1 line | HIGH |
| CC-v5-8 | plugin.zig:330, bar/segdraw.zig:78, bar/modules/slider/slider.zig:313,404 | duplication (naming) | natural-width concept in 3 spellings: contract `naturalWidth` / segdraw option `natural_width` / slider fn `probe_natural_width`, with brightness=44 / volume=56 capacity probes hardcoded (BAR-3 carry-forward, still open) | rename the slider fn → `naturalWidth` (3 sites); keep `natural_width` as the TOML/config-name spelling; cross-ref in one comment | ~5 | HIGH |
| CC-v5-9 | model.zig:370, window/modules/fullscreen.zig:219, window/actions.zig:39-41, window/borders.zig:25 | duplication (predicate family) | occupant-query in 4 spellings with 2 semantics: model-AND `coveringOccupantOnWs` (consumed by sync.zig:302, actions.zig:857, focus.zig:644, borders.zig:33-34) vs fullscreen-OR `fullscreenOccupantOnWs`; registry first-provider `currentCoveringOccupant`; `coveredByOccupant` facade (WINC-10 carry) | doc-only now: a cross-ref note on `model.coveringOccupantOnWs` naming the siblings and the AND/OR difference; predicate unification is later and semantics-affecting (owner-bless) | 1 (doc) | HIGH |
| CC-v5-2 | window/window.zig:39-78 vs bar/bar.zig:111-118 | duplication (dispatch idiom) | two full dispatch-helper families for the same first-match/fan-out matrix: enum-tag `callHook`/`callHookBool`/`dispatchAll`/`dispatchFirstTrue` vs comptime-string `runVoidHook`/`anyBoolHook`; plus the `providerOf` wrapper (window.zig:33-37) | acceptable today — cross-reference comments; a shared `dispatch(T, FieldEnum(T), registry)` generic is a phase-2-lite consolidation, not urgent | 10 (docs) / ~120 (unify) | MED |
| CC-v5-5 | plugin.zig:135,148,156,180,185,190 (hideWindow / restoreOnWs / collectHiddenSet / coveringOccupantOnWs / moveCoveringTo / sendToWs), Segment role prose 292-297,374 | build-gate / contract **[DEF]** | "At most one module binds this / SHOULD claim" is prose-only; two modules binding a single-binder hook compile and silently first-match by registry scan order | emit comptime asserts in the generated registries: for each single-binder field, `countTrue(non-null binders) <= 1` over the discovered modules | ~25-40 (registry generator) | HIGH |
| CC-v5-4 | build.zig:239-273 | build-gate / doc-sync **[DEF]** | `test_gates` is still a hand-written table; adding/renaming a `src/test/**` module needs a second-site edit and stale rows fail silently; the five-"surfaces" aggregate pointer comment (prior cross-cutting-audit §2) is still absent | derive the table keys from discovered `*_test` stems and assert `table keys == discovered stems` (the ~395 segmentation-verify already proves this pattern); add the 5-surfaces comment block at build.zig ~361 | ~30 | HIGH |
| CC-v5-10 | dev/scripts/check-layers.sh:60,156 | build-gate / doc-sync **[DEF]** | Rule-1 allowlist comment says "Rides pat-wide via the `xcb_xkb_` family" but pat1 carries `xcb_xkb_per_client_flags` only; `xcb_get_extension_data` (same file, xkbcommon.zig:49-69) is not a pat1 member — the "pat-wide" claim is half-false | either add `\|xcb_get_extension_data` to pat1 (line 156) or tighten the comment to name the allowlist as the coverage mechanism | 1-2 | HIGH |
| CC-v5-7 | IMPROVEMENTS.md:278, 362, 363 (+ §IV:289 δ) | doc-sync | CC-v4-3 re-triage never ran; rows claiming three workspace-id types / S01–S21-need-recapture / CI-non-gating / borders-uncovered are now false in-tree | re-triage those rows at next report maintenance (this report is the hook) | docs | HIGH |

`[DEF]` = the change touches build-gate policy / a guard script / a contract,
and needs the owning contributor's blessing (one-line questions in §3).

## 3. DEFERRED / needs-owner-input

1. **CC-v5-4** — Q: bless deriving `test_gates` from the discovered `*_test`
   stems (assert-equal with the table) in build.zig, replacing hand-sync? This
   is the unlanded "derive" half of CC-v4-6.
2. **CC-v5-5** — Q: bless emitted comptime `countTrue <= 1` asserts in the
   generated registries for the single-binder hook set? This is the unlanded
   CC-v4-4 "do both" half.
3. **CC-v5-10** — Q: widen pat1 with `xcb_get_extension_data`, or correct the
   allowlist comment only (guard-script edit either way)?
4. **CC-v5-9** — the occupant-query family (4 spellings, AND vs OR semantics)
   stays split by decision; the doc cross-ref lands without a bless, predicate
   unification needs an owner call on the live behaviors.
5. **CC-v5-2** — dispatch-helper unification is optional phase-2-lite, low
   value; only cross-reference docs for now.
6. **§VII:353 `-Dbar=false`-style toggles** — module presence is auto-detected
   by design; owner to confirm no explicit `-D` toggles are wanted.

## 4. Verified worthy-of-keeping (do NOT re-flag)

- RandR machinery is gated on `has_bar` everywhere (events.zig:80,85,159-160,
  179,356,570,607,647,660-662) with the "RandR is a bar feature" rationale
  comments (157,658) — the prior cross-cut §4.1/#3 is RESOLVED in-tree.
- `tracking.workspaceBit` is gone; `model.bit(WSId)` (model.zig:18) is the
  single workspace-mask math — prior cross-cut §4.4/#5 RESOLVED.
- zon `.links` is single-sourced: `loadLinks` re-reads build.zig.zon at every
  `zig build` (unparsable/empty fails the build) — prior cross-cut §3/#1
  RESOLVED.
- Pure-layer import purity is structurally enforced by `assertPureLayerImports`
  on the same edges `wireAll` derives — a config↔xkbcommon cycle stays
  impossible.
- Owner-contract tables are DERIVED in build.zig (`deriveOwnerContracts`), not
  hand-maintained; an empty owner falls back to a documented element-type
  default; disagreement is a loud build error.
- The contracts have no dead slots: every field of Surfaces / WindowModule /
  Segment / Layout (incl. handleKeypress, onBarShown, consumeRedrawRequest,
  overlay, onScroll/onDragEnd, preReconcile, variant_parse) has a live
  consumer; `plugin.providerOf` (plugin.zig:233-239) is the single registry
  lookup, with a window-layer wrapper.
- Templates are drift-locked to the contracts: template `segment.zig:117`
  `naturalWidth(frame:*const anyopaque,u16)u16` == plugin.zig:330;
  `tiling.layoutModule` template == `buildTilingSeamModule`; `check-plugin-template`
  compiles all three templates in `zig build check` (background buildcheck run:
  all layer rules pass).
- Guard scripts self-assert: `check-modularity.sh` loud-fails on a missing
  removal path; manual Rule 1/2 re-sweeps are clean (wire sends outside sync +
  allowlist: none; grabs only bar.zig:1309,1526 plus the wire.zig:90 primitive);
  Rule 3's find now covers `src/config`.
- Harness: all S01–S23 goldens committed; the CI parity job gates on `dev`
  pushes (not continue-on-error); per-scenario `*.config.toml` overrides are
  wired (S15); `dev/harness/{out,.cache}` gitignored.
- Dispatch-handled facts verified present with site comments: DestroyNotify
  double-fire idempotence, focus failover to the covering occupant, and the
  model-truth-vs-sent-ledger parity test (`src/test/engine/tracking_test.zig`).
- Bar wire discipline stays "at most one grab owner": the bar's own grab family
  deliberately uses the no-grab reconcile variant; the D3 `withServerGrab`
  choice was decided (COREP-07) and documented, not re-opened.