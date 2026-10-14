# src/PLAN.md — Pre-Implementation Review

Reviewed against the tree at commit `da782a0` (2026-10-12). Baseline verified
before writing this report:

| Gate | Result |
|---|---|
| `zig build check` | **passes** (layer guards + plugin-template gate green) |
| `dev/scripts/xtest.sh zig build test --summary all` | **passes** — 144/144 steps, **600/601 tests passed, 1 skipped** (plan says "598 tests" — stale) |
| `zig build modules` | runs clean; no stem conflicts today (`model`, `diagnostic`, `model_seeding` are all free) |

**Verdict: do not implement as written.** Items 1, 2, 5, 8 and 10 each contain
at least one change that will fail a gate (`zig build check`, `check-plugin-template`,
or `check-modularity`) or break compilation if executed per the plan's stated
scope. Item 6 appears to be already done (no-op). Items 3, 4, 7 are sound after
scope corrections. Details below.

A practical note for all verification steps: plain `zig build test` prints
**nothing** on a green run (Zig 0.16 default summary is failures-only), so the
checklist's test counts cannot be observed without `--summary all`. This is
likely how the "598" figure went stale.

---

## 1. Blockers (will fail a gate if done as written)

### Item 1 — `wm_state.zig` → `model.zig`: scope misses `build.zig`, `check-layers.sh`, plugin templates

The rename changes the module *stem* (`wm_state` → `model`), which is load-bearing
in two functional places the plan never mentions:

1. **`build.zig:2315-2316`** — `assertPureLayerImports` classifies a file as the
   `"model"` pure layer only when `rel_path` ends with
   `src/core/wm_state.zig`. After the rename, `model.zig` falls through the
   `else return` branch: **the pure guard silently stops covering the model
   facade** (no failure, just lost coverage).
2. **`build.zig:2360`** — `pureLayerAllows` whitelists the dep name
   `"wm_state"`. 5 files under `src/config/` (`action`, `config`,
   `parse/schema`, `sections/tiling_sections`, `types`) and 6 under
   `src/tiling/` import it. After the rename those edges are checked as
   `"model"`, not whitelisted → **immediate `LayerGuardViolation`, `zig build
   check` red**.
3. **`dev/scripts/check-layers.sh:287`** — Rule 3's sweep is
   `find … src/core/wm_state.zig … -name '*.zig'`. With the file gone, `find`
   errors (swallowed by `|| true`) and **`model.zig` silently drops out of the
   xcb-token sweep** — another quiet guard loss, not a failure. Comments at
   check-layers.sh:248-263 also reference `wm_state.zig`.
4. **`dev/plugin-template/provider.zig:30` and
   `layout.zig:28`** — both do `@import("wm_state")`. The plugin-template gate
   (part of `zig build check`) compiles them against the real module table →
   **gate fails** until updated.
5. **`core.zig:41,45,50`** re-exports — the plan does mention these (✓).

Corrected scope for step 1:

- ~68 files under `src/` import `@import("wm_state")` (plan says "~60"; the
  list also includes 2 files that mention it only in comments:
  `bar/wire/win.zig`, `core/architecture/domain.zig`).
- `build.zig` lines 2316 and 2360 (functional, mandatory).
- `dev/scripts/check-layers.sh` line 287 path + comment block (mandatory,
  else silent guard loss).
- `dev/plugin-template/{provider,layout}.zig` (mandatory for the gate).
- Docs/comments: `AGENTS.md:65,77`, `MESSAGE_BOARD.md`,
  `dev/actions-dissolution.md`, `dev/review-r2/01-core.md` &
  `06-bar-core.md`, `src/window/PLAN.md`, plus in-file doc comments across
  many importing files.
- Note `dev/harness/tools/ewmhfs.c:24` also has an identifier `wm_state` but
  it is the `_NET_WM_STATE` atom — **do not touch**.

### Item 2 — move `seed.zig` → `config/model_seeding.zig`: triggers the pure-layer import guard, and the import list is wrong

- `seed.zig:7-14` imports `core`, `pipeline`, `tiling_seam`, `contract` (plus
  `wm_state`, `types`, `log`, `build_options`). Today it lives at
  `src/core/architecture/seed.zig`, which `assertPureLayerImports` does **not**
  classify as any layer → unchecked. Once it lands under `src/config/`, it is
  scanned as the `"config"` layer, and `core`/`pipeline`/`contract`/`tiling_seam`
  are all forbidden (`pureLayerAllows`, build.zig:2351-2376; `contract` is only
  whitelisted for the *tiling* layer, build.zig:2368) → **`zig build check`
  fails**. Seed is an orchestration module, same species as
  `config/reload.zig`, which is exempted by name at build.zig:2314.
  **Required**: add an equivalent documented carve-out for
  `src/config/model_seeding.zig`, or drop the move and keep it in
  `architecture/`. (Rule 3's xcb-body sweep will newly cover it under
  `config/` — fine, it has no xcb tokens.)
- **Wrong import list.** Actual `@import("seed")` sites are exactly three:
  `main.zig:32`, `config/reload.zig:22`, `test/core/seed_test.zig:18`.
  The plan's list (`pipeline.zig`, `window.zig`, `admission.zig`) is wrong —
  none of them import seed (`workspaces.zig:10` only mentions it in a comment).
  `seed_test.zig` would be missed entirely, leaving the test suite red.
- Comment references to update: `reload.zig:11`, `workspaces.zig:10`,
  `contract.zig:788`, `seed_test.zig:1`.
- `build.zig` has no explicit `architecture/seed.zig` path (the plan's
  conditional "if path was explicit" is vacuous for this item) — but the
  carve-out above is mandatory.

### Item 5 — deleting `toggleBarScreenPosition()` breaks `bar.zig`

The plan's premise ("`surfaces.toggleBarSegmentAnchor()` already handles this",
"no import changes needed") is **false**:

- `bar/bar.zig:567-570`:
  ```zig
  pub fn toggleBarSegmentAnchor() void {
      _ = core.toggleBarScreenPosition();   // <-- THE config mutation
      _ = applyBarScreenPosition();
  }
  ```
  The bar hook *delegates to core*; core.zig:220-227 is the single writer of
  `config.bar.bar_position`, and its doc comment (core.zig:212-219) records
  that as a deliberate decision ("the flip is a config decision, so it is made
  where the config lives").
- `dispatch.zig:46-47,176` calls `surfaces.toggleBarSegmentAnchor()` — as the
  plan says — but that path reaches the core function through bar.

Deleting the core function as scoped **breaks compilation of `bar.zig`**.
Correct implementation: move the `bar_position` flip into
`toggleBarSegmentAnchor` (or a config-layer helper it calls), then delete the
core function, update the core.zig:212-219 doc comment and the bar.zig:565
comment, and re-check that the "single writer" invariant is restated at the
new home. Before reversing this, read the recorded rationale in
`dev/review-r2/06-bar-core.md` and `bar.zig:565-566` to make sure the
ownership flip is intended, not accidental.

### Item 8 — splitting contracts by engine breaks the feature-deletion matrix

Two independent problems:

**(a) `tiling_contract.zig` cannot live under `src/tiling/`.**
`check-modularity.sh` deletes `src/tiling` wholesale (scenario
"tiling (entire subsystem)", check-modularity.sh:206-208, and
"bar + tiling (both)", :218-221). The plan puts the tiling contract *inside*
that directory, but the Layout-family vocabulary is consumed **outside** tiling
by code that must still compile with tiling absent:

| Consumer | Contract decls used |
|---|---|
| `core/x11/reconcile.zig` | `Env`, `List`, `Placement`, `View`, `activeLayoutKind`, `parked_rect` |
| `core/loop/pipeline.zig` | `Env`, `activeLayoutKind`, `moduleOf`, `default_kind` |
| `core/proc/session.zig` | `WindowModule` (→ window_contract, OK), `default_kind` |
| `core/architecture/seed.zig` (→ `config/` after item 2) | `moduleOf`, `default_kind` |
| `window/admission.zig` | `moduleOf` |
| `window/sync/reconcile_tails.zig` | `moduleOf` |
| `bar/modules/layout/{layout,variants}.zig` | `activeLayoutMeta` (breaks the *tiling-only* deletion while bar stays) |

With the file deleted, `@import("tiling_contract")` resolves to no module →
build fails → **the "tiling (entire subsystem)" and "bar + tiling" scenarios
fail; the 31/31 matrix goes red.** These cross-engine decls must stay in core
(e.g. in `contract_dispatch.zig`, or behind the always-present generated
`tiling_seam`), not in a deletable directory. The plan shows no awareness of
this; its "why" ("delete bar/ → bar_contract.gone") only reasons about the
bar half.

**(b) Mandatory `build.zig` / gate updates the plan omits.**
- `pureLayerAllows` build.zig:2368 whitelists tiling's import of dep
  `"contract"`; after the split tiling files import `tiling_contract` (same
  layer, covered by :2367) **but `contract_dispatch` sits under
  `src/core/architecture/` → not same-layer, not whitelisted →
  LayerGuardViolation.** Add `contract_dispatch` to the tiling allowlist (and
  consider config, which will import it via `model_seeding`).
- `check-layers.sh:287` sweeps exactly `src/core/architecture/contract.zig`;
  after the split `contract_dispatch.zig`, `window_contract.zig` and
  `bar_contract.zig` are outside the find list. Rule 3's documented coverage
  of contract vocabulary (check-layers.sh:263-266) is silently lost unless
  the find list is updated.
- Plugin templates: `segment.zig:171` uses `@import("contract").Segment`,
  `provider.zig` uses `contract.WindowModule`, `layout.zig` imports `wm_state`
  (+ likely Layout types). The gate compiles them → must be repointed.
- `AGENTS.md` rule 6 says contracts live in `src/core/architecture/contract.zig`
  (`contract_x11.zig` for the X-typed half — that file doesn't even exist
  anymore; the doc is already stale). Rule 6 must be rewritten for the new
  layout.

**(c) The split spec is incomplete.** contract.zig is 880 lines; the target
structure assigns only `WindowModule`, `Segment/BarOverlay/Frame/ClickCtx`,
`Layout/View/Env/Placement/List/HintsView`, `providerOf/callAll`. Unassigned:
`tiling_mods`, `moduleOf`, `activeLayoutKind`, `activeLayoutMeta`,
`default_kind`, `parked_rect`, `DirtySources`, `Painted`, `KeyPressEvent`,
`HintsView`-adjacent helpers. (`Painted`, `KeyPressEvent`, `DirtySources` are
bar-only — fine for bar_contract; the first five are the cross-engine set from
table (a).) A complete symbol→file map should be written before starting.

**(d) Institutional history.** The contract has been split before and merged
back: `contract_window.zig` / `contract_segment.zig` were folded into
`contract.zig` on 2026-10-08/09 (documented at check-layers.sh:269-271,
commit `e9db07b`), and `library/structure-audit-2026-10-08.md:89` records the
"file names are global API" lesson from that episode. Item 8 should state
explicitly why this split is different from the reverted one (the modularity
placement rule above is the new constraint the old split didn't face).

### Item 10 — migrating operations into *deletable* modules breaks callers and the pure-layer guard

**(a) Destinations chosen for rows 3-6 are feature-deleted by the matrix.**
`check-modularity.sh` deletes `src/window/modules/workspaces.zig`,
`fullscreen.zig` (individually and together with floating/minimize,
:236-253). But the operations have callers in non-deletable code:

| Operation | Non-deletable callers (sample, production only) |
|---|---|
| `register` | `window/admission.zig:438` |
| `unregister` | `window/window.zig:336` (unmanage) |
| `visibleOn` | `window/protocol/client_events.zig:143` |
| `visibleEntry` | `core/x11/reconcile.zig:245,305` (core → deletable module!) |
| `tiledCountOnWs` | `core/loop/pipeline.zig:194`, `window/window.zig:481` (incl. dumpState), `window/sync/reconcile_tails.zig:211` |
| `coveringWsOf` | `window/window.zig:333` |
| `isCovering` | `window/protocol/borders.zig:50`, `window/modules/floating.zig` |
| `coveringOccupantOnWs` | `bar/visibility.zig:39`, `core/x11/reconcile.zig:177` |
| `coveringOccupants` | `window/sync/border_sweeps.zig:31` |
| tiling ops (`reorderTiled`, `stepTiled`, `swapFocusedWithPrevious`, `adjustPrimaryWidth`) | `window/admission.zig:479`, `window/sync/reconcile_tails.zig:136,166,182` — these survive only if the tiling *ops* are routed through `tiling_seam` with comptime gating; the plan says "via tiling_seam" but doesn't specify who provides the no-tiling stub |

Moving these implementations into `workspaces.zig` / `fullscreen.zig` makes
every scenario in Tier 2 fail to compile (direct `@import("workspaces")` from
core/window/bar code dangles when the module is deleted).

**(b) The re-export list contradicts the pure-layer guard.** The plan says
`model.zig` should re-export `visibleOn`, `visibleEntry`, `tiledCountOnWs`,
`coveringOccupantOnWs`, `coveringOccupants` after they move. That requires
`model` (a pure layer) to import `window/modules/*`, but `pureLayerAllows` has
`if (layer == "model") return false;` (build.zig:2362) — only the shelf and
`wm_state`/`domain` are permitted. **`zig build check` fails**, and even if
whitelisted, deleting workspaces/fullscreen would dangle the re-exports.
It also directly contradicts the item's own verification line
("No callers import `model` for migrated operations").

**(c) Table inaccuracies:**
- `capPrimaryCount` is **not** in `model.zig:519-533` — it is defined in
  `domain.zig:314` (pure vocabulary) and re-exported at `wm_state.zig:55`.
  Moving it to `config/model_seeding.zig` strips a pure helper from the
  vocabulary root; decide deliberately (it is seed-only, so either home works,
  but the plan's stated source is wrong).
- `applyParamsDelta` (`wm_state.zig:342`, called from
  `core/loop/pipeline.zig:196`) is a Model mutation that fits neither the
  table (not migrated) nor the keep-list (not a "minimal query") — item 10's
  inventory of the 22 `pub fn`s in `wm_state.zig` is incomplete. Same for the
  struct methods (`isManaged`, `getFocused`, …, wm_state.zig:102-118 — those
  are correctly on the keep list).
- Focus row is fine: `setFocus`/`clearFocus`/`fallbackFocusCandidate`/
  `collectCyclePool` are called *only* from `window/protocol/focus.zig`
  (756, 767, 781, 919, 985) — trivially movable. `focusedBorderColor` is
  called from `core/loop/pipeline.zig:171` and `window/protocol/borders.zig:61`
  — core→focus import is allowed (hub-and-spoke), destination is not deletable,
  so this row is sound.

**Recommended re-scoping:** send rows for `register`/`unregister`/`visible*`/
`covering*`/`tiledCountOnWs` to non-deletable window code
(`src/window/state/` or `src/window/protocol/`), or expose them through the
generated `window_modules` registry; keep tiling ops behind `tiling_seam`
with explicit `has_tiling` stubs; drop the model re-export list (update
callers instead, as the verification section already demands).

---

## 2. Stale or wrong claims (re-verify; likely drop/simplify)

### Item 6 — `title_cache` re-exports don't exist (probably already done)

- `window.zig:33` is a **private** `const title_cache = @import("title_cache")`
  (used internally at 207, 224, 360, 399). There is **no** `pub const
  peekTitle`/`refreshTitle` re-export anywhere in `window.zig` (checked all
  `pub` decls). Claimed lines 32 / 390-392 point at unrelated code.
- `bar/render/render.zig:29` already imports `title_cache` directly; no file
  calls `window.peekTitle`. The named target `bar/modules/title/title.zig`
  never touches the cache at all.
- `title_seam` (named twice as the import path) **does not exist** — it is a
  future idea mentioned in `MESSAGE_BOARD.md:257` only.

**Action:** re-verify against the tree; expected outcome is "nothing to do —
delete item 6 (keep 'bar titles render' as an ordinary regression check)".
This and the stale line numbers elsewhere (below) indicate the plan was
drafted against an older revision.

### Item 7 — `dumpState` move is feasible; the dispatch instruction is wrong

- `dumpState` is at `window.zig:452-472` (plan says 395-420), called only from
  `dispatch.zig:121` ✓, "no production code depends on it" ✓.
- **Cannot** "Update `dispatch.zig` import: `@import("window")` →
  `@import("diagnostic")`": dispatch uses `window` for many other things
  (`updateWorkspaceBorders`:54, `updateFloatingWindowBorders`:67,
  `supportsWMDeleteCached`:78, `callHook`/layout actions:136-146). The change
  is *add* `@import("diagnostic")`, keep window.
- Implementation note: `dumpState` uses `tiling = @import("tiling_seam").tiling`
  (`window.zig:47`) and guards with `build_options.has_tiling` — the new
  `core/diagnostic.zig` must use the seam too (never `@import("tiling")`
  directly, per build.zig:386-391), plus `query`, `focus`, `pipeline`, `log`.
  Core→window imports are sanctioned (check-layers.sh:3-5), so no layer issue.
- New stem `diagnostic` is free ✓.

### Items 3 and 4 — sound moves, but the stated scope is both wrong and unnecessary

- **Stem-based imports mean directory moves need no code changes.** All
  callers use module names (`@import("scaling")`, `@import("spawn")`, …);
  there are zero path-style imports in the tree (`@import("./…")` /
  `@import("../…")` → none).
- **Item 3**: `scaling`'s stem doesn't change → **zero import updates**. The
  plan's list is also factually wrong: `reconcile.zig`, `border_sweeps.zig`
  and `bar/render/render.zig` do not import scaling at all. Actual importers
  (13): `core/core.zig`, `core/display/dpi.zig`, `core/loop/pipeline.zig`,
  `window/modules/floating.zig`, `window/protocol/reply.zig`,
  `tiling/tiling.zig`, `tiling/modules/master.zig`, `config/{config,types}.zig`,
  `config/parse/schema.zig`, + 3 tests. Real work: `git mv`, then fix comments
  (`config/types.zig:611` cites `core/pure/scaling`; build.zig:2270/2301/2337
  describe the shelf as "siblings in src/core/pure/" while `scaling` stays in
  the `pureLayerAllows` shelf list — the *name*-based whitelist still works,
  but the comment becomes inaccurate).
- **Item 4**: stems `process`, `spawn`, `session` are unchanged → **zero
  import updates**. No `@import("proc")` exists; no build script or
  check-layers entry names `core/proc`. Remaining work is comment-only
  references (`proc/process.zig:194`, `bar/modules/prompt/completion.zig:463`,
  `window/state/query.zig:12`, `test/core/session_test.zig:12-14`). The
  plan's import list (main/dispatch/admission/window/modules/*) is incorrect
  — those files import `spawn`/`session` by name, which doesn't change.

### Item 11 (post-plan) — several claims are wrong, and the flag removals are behavior changes

- `fullscreenEnabled()`, `dragEnabled()`, `workspacesEnabled()` **do not
  exist** anywhere in the tree. The runtime flags are read inline:
  `fullscreen.zig:392` (`config.fullscreen_enabled`), `floating.zig:160`
  (`config.drag_enabled`), `border_sweeps.zig:21` (`config.tiling.enabled`),
  `dispatch.zig:160` comment (`config.workspaces.enabled`). Only
  `core.tilingEnabled()` (core.zig:130-131) and `borderWidth()` (core.zig:135)
  exist as functions. The table must be rewritten in terms of call sites.
- **Removing the runtime flags is a user-visible behavior change**, at odds
  with the plan's header ("no behavior changes") even if #11 is post-plan:
  - `tiling.enabled = false` is currently the *only* way to run floating-only
    with `src/tiling/` present (build.zig:234 derives `has_tiling` from file
    presence — no `-D` override). Deleting the knob removes that capability.
  - Schema/types churn: `config/parse/schema.zig:105-123` (4 knobs),
    `config/types.zig:680-681`, plus tests `config_test.zig:426`,
    `schema_test.zig:48,159,579`, and existing user TOMLs that set these keys
    (check the parser's unknown-key policy before deciding).
- DPI move (`dpi()`, `setDpi()`, `baseline_dpi` → `display/dpi.zig`): note
  `dpi.zig:19` currently *imports* the value from core; the move flips that
  edge and touches callers (`core/loop/events.zig`, `bar/render/metrics.zig`,
  `bar/wire/win.zig`, `test/harness/fixture.zig`). Fine as an incremental
  refactor, but it needs a caller list the plan doesn't give.
- `dispatch.zig` "reduce coupling" suggestions are partly descriptions of the
  status quo ("already uses registry" ×3) — only the
  `process.reload/requestReexec` hook move is new work.

---

## 3. Internal inconsistencies in PLAN.md itself

1. **Both "final structure" diagrams contradict item 2.** Lines 107 and 327
   place `model_seeding.zig` under `src/core/architecture/`, while item 2
   (line 28) moves it to `src/config/model_seeding.zig`. Pick one (item 2's
   destination is presumably intended — the diagram must change).
2. **Architecture-clarification table (line 272) is self-contradictory:** the
   `model.zig` "Owns" column lists `coveringOccupantOnWs` / `coveringOccupants`
   as minimal queries; the "Does NOT Own" column of the *same row* says they
   belong in `workspaces.zig`/`fullscreen.zig`.
3. **Item 10 re-export list vs its own verification** ("No callers import
   `model` for migrated operations") — see blocker above.
4. **Three execution-order tables** (original ~line 88, "Updated" ~line 249,
   "Updated" ~line 305) and **two verification checklists** (~line 133 and
   ~line 354, with different contents). Item 9 is a stub that duplicates item
   5. The final table should be the only one; delete the superseded ones
   before implementation so steps aren't executed twice or in the wrong order.
5. **Header claim "no behavior changes"** — true for items 1-4 and 8; item 5
   deletes a live code path (needs the move described above); item 11 is
   explicitly behavior-changing. Worth restating scope honestly.
6. **Stale line numbers/measurements:** `window.zig` "398 lines" (actually
   485), dumpState "395-420" (452-472), title_cache "32, 390-392" (nothing
   there). The `wm_state.zig` line refs in item 10 are largely accurate
   (register:151 ✓, setFocus:304 ✓, reorderTiled:457 ✓, applyConfigReload:522
   ✓; `collectCyclePool` is at 378, plan says 419-447 which covers
   `fallbackFocusCandidate` at 419 only).
7. **Checklist counts:** "598 tests" (actual 601 total / 600 pass / 1 skip);
   "31/31" modularity scenarios — the script has 30 `run_scenario` call
   sites *before* the last one plus trailing cases; recount when the checklist
   is refreshed rather than hard-coding a number.

---

## 4. Cross-cutting omissions (apply to multiple items)

- **Guard/scripts that must be edited in lockstep** (none mentioned by the
  plan): `build.zig` (assertPureLayerImports + pureLayerAllows),
  `dev/scripts/check-layers.sh` (Rule 3 find list + allowlist comments),
  `dev/plugin-template/*`, `AGENTS.md` (rules 4/5/6 wording — rule 6 still
  describes `contract_x11.zig`, which no longer exists), `MESSAGE_BOARD.md`.
- **Docs with `wm_state` path claims:** `AGENTS.md:65,77` is the important
  one (it is the agent-facing contract for this tree).
- **Use `git mv`** for every rename/move so history follows (the repo's
  `zig build modules` and `importEdgesOf` don't care, but reviewers do).
- **Verification additions:**
  - Use `dev/scripts/xtest.sh zig build test --summary all` when a count is
    quoted; otherwise green runs are silent.
  - Run `zig build check-modularity -j 4` (or
    `dev/scripts/check-modularity.sh -j 4`) **after steps 8 and 9**, not only
    at the end — those are the two steps that touch deletable code.
  - `zig build modules` after step 1 (stem rename) — cheap, catches the
    `model` collision class early.
- **Suggested per-step scope fixes (summary):**

| Step | Add to scope | Remove from scope |
|---|---|---|
| 1 rename → `model` | build.zig:2316+2360; check-layers.sh:287+comments; plugin-template ×2; AGENTS.md; doc comments | "~60 files" → ~68 + gates |
| 2 seed → `config/` | build.zig carve-out for model_seeding (or drop the move); fix import list: `main.zig`, `config/reload.zig`, `test/core/seed_test.zig`; comment refs | `pipeline/window/admission` (wrong) |
| 3 scaling → `display/` | comment fixes (types.zig:611, build.zig shelf comments) | all "update imports" work (stem unchanged) |
| 4 `proc/` → `process/` | 4 comment references | all "update imports" work (stems unchanged) |
| 5 bar-position toggle | move the mutation into bar (or config) **before** deleting; update core.zig:212-219 + bar.zig:565 comments; read review-r2/06 rationale | "delete only / no import changes" (breaks bar.zig:568) |
| 6 title_cache re-export | — | entire item (verify then drop) |
| 7 dumpState → `diagnostic` | keep `@import("window")` in dispatch, **add** diagnostic; use `tiling_seam` in the new file; correct line refs | "replace window import" |
| 8 contract split | complete symbol→file map; keep cross-engine Layout decls in core or behind `tiling_seam`; pureLayerAllows (`contract_dispatch`), check-layers find list, plugin templates, AGENTS rule 6; explain divergence from the 2026-10-08 merged-back split | `tiling_contract` inside `src/tiling/` as drawn |
| 10 migrate ops | destinations in non-deletable files (`window/state/`, `window/protocol/`) or registry hooks; `tiling_seam` stubs for tiling ops; fix `capPrimaryCount` source; add `applyParamsDelta` decision | re-exporting migrated ops from `model.zig` (guard violation + cycle) |
| 11 (post-plan) | rewrite in terms of actual call sites; treat flag removal as a behavior change with config-compat decision | `fullscreenEnabled()`/`dragEnabled()`/`workspacesEnabled()` rows (don't exist) |

---

## 5. Recommended execution order (revised)

1. Step 1 (`wm_state` → `model`) **with** build.zig/check-layers/templates/AGENTS
   in the same commit; verify `zig build check` + `zig build modules` + tests.
2. Step 4 (`proc/` → `process/`) — pure `git mv` + comments; cheapest.
3. Step 3 (`scaling` → `display/`) — pure `git mv` + comments.
4. Step 2 (seed → `config/`) — only after deciding the guard carve-out.
5. Step 7 (`dumpState` → `diagnostic`) — independent, small.
6. Step 5 (bar-position toggle) — move-then-delete as described; manual check
   of `.toggle_bar_position` in a harness session.
7. Step 6 — verify, then drop.
8. Step 8 (contract split) — largest; do symbol map first, then
   `check` + plugin gate + **modularity matrix**.
9. Step 10 (operation migration) — same gates + modularity matrix; adjust
   destinations per this report.
10. Full suite with `--summary all`, refresh the checklist numbers, update
    `AGENTS.md`/`src/PLAN.md` (the plan file itself will need its diagrams,
    tables and counts reconciled once the work lands).

Items 3/4/7 are safe to start immediately; items 1/2/5/8/10 must be re-scoped
before any file is touched; item 6 should be closed as already-satisfied after
a quick re-verification.

---
---

# Round 2 — Review of the Revised PLAN.md

Reviewed the planner's revision (276 lines, "Revised Post-Review"). Baseline
re-verified unchanged (`zig build check` green).

## Verdict

Large improvement. **Items 1-7 are now sound** — go, with the minor nits
below. **Items 8 and 10 still contain gate-breaking defects** (one wrong
allowlist name; one unresolved contradiction that re-creates the round-1 pure
guard violation). **Item 9's call-site list is wrong in both directions** and
**item 11 still references three functions that do not exist**. Two internal
contradictions survive in the document itself.

## What the revision fixed (confirmed)

| Item | Fix verified |
|---|---|
| 1 | build.zig:2315-2316 + 2360, check-layers.sh:287 + comments, plugin templates, AGENTS.md all in scope; `zig build modules` added to verification ✓ |
| 2 | Carve-out at build.zig:2314 specified; correct importer list (`main.zig:32`, `config/reload.zig:22`, `seed_test.zig:18`); comment refs listed ✓ |
| 3/4 | Correctly scoped as `git mv` with zero import updates; comment fixes enumerated ✓ |
| 5 | Move-then-delete order; comment updates; read review rationale ✓ |
| 6 | Dropped as already-done ✓ |
| 7 | Add `diagnostic` import, keep `window`; `tiling_seam` noted; correct line numbers ✓ |
| 8 (partial) | `tiling_contract` moved out of `src/tiling/` into `core/architecture/` ✓ — this resolves the modularity-matrix blocker from round 1. (Its `tiling_modules` import mirrors today's `contract.zig:33`, a shape the green matrix already proves safe.) |
| 9 (partial) | Now explicitly labeled a behavior change / opt-in ✓ |
| 10 (partial) | Mutations no longer routed into deletable modules; re-export ban *stated* ✓ (but see blocker below) |

## Remaining blockers

### #8 — wrong allowlist name; incomplete symbol map; missing test-file updates

1. **`pureLayerAllows` entry must be `tiling_contract`, not `contract_dispatch`**
   (plan line 145). After the split, tiling files (`tiling.zig`,
   `tiling/modules/*`) import `tiling_contract` (for `Layout`, `moduleOf`,
   `tiling_mods`, …). That dep name resolves to
   `src/core/architecture/tiling_contract.zig` — not same-layer, not
   `"contract"` → **LayerGuardViolation, `zig build check` red**. Verified:
   **no** tiling or config file imports `providerOf`/`callAll`, so the
   `contract_dispatch` entry the plan adds is the unnecessary one. Add
   `tiling_contract` (keeping `contract_dispatch` is harmless).
2. **Four decls are unassigned and `contract.zig` is deleted wholesale**
   (line 273): `tiling_mods` (users: `tiling.zig:33`-area,
   `test/tiling/tiling_test.zig:56,630,698` → tiling_contract),
   `Painted` (`test/bar/width_state_test.zig:102` + bar modules),
   `DirtySources` (`bar/segment.zig`), `KeyPressEvent` (`bar/bar.zig`,
   `bar/segment.zig`, `bar/modules/prompt/prompt.zig` → bar_contract).
   Lines 131-136/133 assign `WindowModule`, `Segment/BarOverlay/Frame/ClickCtx`
   and the Layout family, but not these. Assign them explicitly or the split
   will stall mid-step.
3. **Three test files import `contract` and are not in scope** (lines 147
   lists only plugin templates):
   - `src/test/core/seed_test.zig:23` (`contract.default_kind` → tiling_contract)
   - `src/test/tiling/tiling_test.zig:19` (+ `tiling_mods` → tiling_contract)
   - `src/test/bar/width_state_test.zig:13` (`Segment`/`Painted` → bar_contract)

   The modularity matrix only runs `zig build` (tests aren't compiled), so
   these would only surface in the full suite — easy to miss.

### #10 — the keep-list still re-exports five migrated ops (round-1 defect, renamed not resolved)

Plan line 193: "model.zig re-exports only minimal queries (`… visibleOn,
visibleEntry, tiledCountOnWs, coveringOccupantOnWs, coveringOccupants …`).
**No re-exports of migrated ops.**" — but the table (lines 187-188) migrates
exactly those five to `src/window/state/`. Both halves cannot hold:

- Re-exporting them makes `model` import `window/state/*` →
  `pureLayerAllows` model branch (`build.zig:2362`, only shelf +
  `wm_state`/`domain` allowed) → **`zig build check` red** — the identical
  violation flagged in round 1.
- Deleting workspaces/fullscreen would dangle the re-exports anyway.
- The sentence contradicts itself ("no re-exports of migrated ops" while
  listing five).

**Decide before starting step 9.** Two coherent options:

- **Option A (recommended):** the table's rows 3-4 are split by kind —
  *mutations* move (`register`, `unregister`, `applyParamsDelta`,
  `setFocus` family, tiling ops, `applyConfigReload`); *pure queries* on
  `Model` state (`visibleOn`, `visibleEntry`, `tiledCountOnWs`,
  `coveringWsOf`, `isCovering`, `isCoveringOn`, `coveringOccupantOnWs`,
  `coveringOccupants`) **stay in `model.zig`** as minimal queries. They are
  state predicates, no different from `entry()`/`findHome()`; this needs no
  caller churn, no guard change, and no new bar→window edge.
- **Option B:** move the queries too, **delete them from the keep-list**,
  and update every caller — including a **new bar→window edge**
  (`bar/visibility.zig:39` would import `window/state/` directly). That edge
  deserves a conscious sign-off given item 8's own rationale against
  cross-engine coupling.

Also missing from item 10's scope:

- **Destination file/stem is unspecified.** `src/window/state/` currently
  holds only `query.zig` (whose header declares it a *read-only* surface —
  wrong home for mutations like `register`). A new file means a new global
  stem (rule 4); name it explicitly in the plan.
- **"via `tiling_seam`" requires editing the generated seam.** The seam is
  produced by `buildTilingSeamModule` (build.zig:393-397); moving
  `reorderTiled`/`stepTiled`/`swapFocusedWithPrevious`/`adjustPrimaryWidth`
  into `src/tiling/` means extending that generator plus `has_tiling`-gated
  stubs for the window-side callers (`admission.zig:479`,
  `reconcile_tails.zig:136,166,182`). None of that is in scope.

### #9 — call-site list wrong in both directions; overlaps item 11

- **Missing real reader:** `core.zig:130-131` (`tilingEnabled()` reads
  `config.tiling.enabled`). The flag field cannot be removed without touching
  it — which item 11 separately promises to turn into a comptime return.
  Item 9 and item 11's `tilingEnabled()` row are the same work; merge them.
- **Phantom call site:** `dispatch.zig:160` is a *comment*, not a read.
- **`workspaces.enabled` has zero production readers** — only the schema knob
  (`config/parse/schema.zig:116`) and `schema_test.zig:159` exercise it. It is
  a dead knob; removal is a pure config-surface change (parser/TOML compat),
  with a different risk profile than the three live flags. State that.
- Actual live readers: `fullscreen.zig:392`, `floating.zig:160`,
  `border_sweeps.zig:21`, `core.zig:131`.

### #11 — phantom functions still present

`fullscreenEnabled()`, `dragEnabled()`, `workspacesEnabled()` (plan lines
205-207) **do not exist anywhere in the tree** (flagged in round 1, not
fixed). Only `tilingEnabled()` (core.zig:130) is real. Rewrite those rows in
terms of the actual call sites, or fold the whole table into item 9.

## Internal inconsistencies that survive in the document

1. **Line 276 vs item 2:** the closing note says
   "`core/architecture/` only holds `domain.zig` + `contract_dispatch.zig` +
   `tiling_contract.zig` + **`model_seeding.zig`**", but item 2 moves
   `model_seeding.zig` to `src/config/` and line 273 says "config/ gains
   model_seeding.zig; core/architecture/ loses seed.zig". Same
   diagram-vs-item mismatch class flagged in round 1.
2. **Item 5:** two steps are numbered "3" (lines 89-90).
3. **Item 8 wording:** "Create 3 engine contracts (`window_contract.zig`,
   `bar_contract.zig`) + `tiling_contract.zig`" — that is 2 engine contracts
   + 1 core file; and line 144's "update build.zig to scan window/, bar/" is
   a no-op (the single `src/` walk already covers them) — the real build.zig
   work is the allowlist entry, which is currently the wrong name.

## Nits

- Item 4's verification omits the test suite (a zero-import-change `git mv`,
  so `zig build check` is arguably enough — but be consistent with item 3).
- Item 10 has no Verification block (the execution table's step 9 covers it).
- Docs still unlisted for the contract work: `src/core/PLAN.md` and
  `src/core/TODO.md` carry stale `contract_x11.zig` material that item 8
  should reconcile, alongside AGENTS.md rule 6.
- Cross-cutting section is otherwise accurate and complete (lockstep files,
  `git mv`, `--summary all`, modularity after steps 8-9).

## Go / no-go after revision

| Item | Status |
|---|---|
| 1 rename → `model` | **Go** |
| 2 seed → `config/` (carve-out) | **Go** |
| 3 scaling → `display/` | **Go** |
| 4 `proc/` → `process/` | **Go** |
| 5 bar-position toggle | **Go** (fix the duplicate step numbering) |
| 6 title_cache | **Go (drop)** |
| 7 dumpState → `diagnostic` | **Go** |
| 8 contract split | **No-go** until allowlist says `tiling_contract`, the 4 unassigned decls get homes, and the 3 test files join scope |
| 9 flag removal | **No-go** until call sites are corrected (`core.zig:131` in, `dispatch.zig:160` out, `workspaces.enabled` flagged as dead-knob-only) and merged with item 11's `tilingEnabled()` row |
| 10 op migration | **No-go** until the keep-list/migration-table contradiction is resolved (option A or B) and the new file stem + `tiling_seam` generator work are specified |
| 11 incremental | Fix the three phantom function rows before it is treated as guidance |

Suggested amendment sequence: patch items 8/9/10/11 and line 276 as above,
then execute steps 1-7 in the plan's order, then 8 → modularity matrix →
10 → modularity matrix again → 9 (opt-in) → full suite.

---
---

# Round 3 — Review of the "Final" PLAN.md

Reviewed the third revision (393 lines, "Final — All Blockers Resolved").

## Verdict

**Items 1-7, 9 and 10 are now executable as written** (nits only). **Item 8
remains no-go**: this review found previously-unaudited `build.zig` *codegen*
that hardcodes the `contract` stem — without which `zig build` fails at
configuration time, before any gate even runs. Also, the document carries
duplicate sections (flags written three times, two sections numbered "11",
two identical checklists) that should be cleaned before an implementer picks
it up.

## Round-2 blockers — verified fixed

| Round-2 issue | Now |
|---|---|
| #8 allowlist wrong name | Fixed: line 145 adds `tiling_contract`, explicitly not `contract_dispatch` ✓ |
| #8 unassigned decls | Fixed: `Painted`/`DirtySources`/`KeyPressEvent` → bar_contract (line 133); `tiling_mods` → tiling_contract (line 136) ✓ |
| #8 missing test files | Fixed: line 149 lists `seed_test`, `tiling_test`, `width_state_test` ✓ |
| #9 call-site list | Fixed: correct table at 177-183; `core.zig:131` in, `dispatch.zig:160` labeled a comment, `workspaces.enabled` flagged dead-knob ✓ |
| #10 keep-list contradiction | Fixed by Option A: table migrates mutations only; pure queries stay in `model.zig`; no re-export of migrated ops ✓ |
| #10 unspecified stem | Fixed: `window_state_ops` named (line 208); stem verified free ✓ |
| #10 seam work | Fixed: `buildTilingSeamModule` extension + `has_tiling` stubs in scope (211-212); the generator (build.zig:848-870) is a one-line `pub const tiling = if (has_tiling) @import("tiling") else struct {}` — trivially extensible ✓ |
| Line 276 architecture contradiction | Fixed: notes (390-393) and final diagram (327-356) consistent with item 2 ✓ |

## Blocker (newly found): item 8 misses the build.zig contract codegen/classifier

Four sites hardcode the module stem `"contract"` in *generated* code and in
the source classifier. After the split, `zig build` dies at configuration
time — `deriveOwnerContracts` would report "could not derive the module
contract for owner 'window'/'bar'/'tiling'" — before `zig build check` is
even reachable:

| Site | What it does today | Required change |
|---|---|---|
| `classifyFile` (build.zig:1052, needle at :1056) | Matches the literal `pub const module: @import("contract").` to record each module's contract | Accept `@import("window_contract").` / `@import("bar_contract").` / `@import("tiling_contract").` and record which one (error text at :1113 also hardcodes the old form) |
| `deriveOwnerContracts` (build.zig:1145-1203) | Fails the build if no `contract` is derived per owner (uses `fc.contract` at :1175) | Follows from the classifier; verify mixed-contract detection still works |
| `buildOwnerRegistryModule` (build.zig:1601, :1609) | Generated registry preamble is `const contract = @import("contract");` and `pub const modules = [_]contract.{T}{…}` | Emit the per-owner contract import and type prefix (`bar_contract.Segment`, etc.) |
| Registry module wiring (build.zig:1696) | `discovered.get("contract")` injects the contract module into each generated registry | Wire `window_contract`/`bar_contract`/`tiling_contract` as derived |

(Alternative: keep a thin `core/architecture/contract.zig` facade that
re-exports the three new modules so the codegen keeps working — but then the
plan's "architecture loses contract.zig" note and the true-split rationale
need adjusting. Either way, item 8's scope must name this work.)

Also unstated: the **blanket repoint of ~32 `@import("contract")` sites**
(only 3 plugin templates + 3 tests are listed). Production importers include
`window/registry.zig`, `window/admission.zig`, `window/sync/reconcile_tails.zig`,
`window/modules/{floating,fullscreen,minimize,workspaces}.zig`,
`core/x11/reconcile.zig`, `core/loop/pipeline.zig`, `core/proc/session.zig`,
`config/model_seeding.zig` (post step 4), `tiling/tiling.zig`, and ~12 bar
files. Add one scope line: "repoint every `@import("contract")` to the
owning engine contract / `contract_dispatch`."

## Document hygiene (fix before handing to an implementer)

1. **Flag removal is written three times**: item 9 (158-185), a second
   section literally titled "## 11. Remove Redundant Runtime Feature Flags"
   (221-249, near-identical copy), and again inside "## 11. Incremental
   Refactors" → "config/ — Consolidate & Remove Redundant Flags" (274-277).
   Keep item 9 only; delete the other two.
2. **Two sections numbered "11"** (flags at 221, incremental at 252).
3. **Two identical "Verification Checklist" blocks** (299-310 and 360-371)
   and **two identical "Cross-Cutting Requirements" blocks** (314-320 and
   375-381). Delete the second pair.
4. **Phantom functions still in the incremental table** (261-263):
   `fullscreenEnabled()`, `dragEnabled()`, `workspacesEnabled()` do not exist
   anywhere; the live reads are `fullscreen.zig:392` and `floating.zig:160`
   (already recorded correctly in item 9's table). Drop or reword these rows —
   they are the last round-1 error surviving in the document.
5. **Item 5** still has two steps numbered "3" (89-90).
6. **Item 10 keep-list** (line 201) lists `findHome` twice.
7. **Final diagram** (line 355) shows `xcb.zig` directly under `src/core/` —
   no such file; the real one is `src/core/x11/xcb.zig` (it will appear under
   `x11/`, which the diagram already lists).
8. Item 8 wording: "Create 3 engine contracts (`window_contract.zig`,
   `bar_contract.zig`)" is 2 engine contracts + 1 core file (142); "update
   build.zig to scan window/, bar/" (144) is a no-op — the single `src/` walk
   already covers them; the real build.zig work is the four sites in the
   blocker table above plus the allowlist entry.
9. Item 8 verification reintroduces "(31/31)" (154) — the scenario count was
   to be recounted, not assumed.
10. Nits carried over: item 4 has no test run in verification; item 10's
    `focusedBorderColor` is a pure *computation* moving under a
    "mutations only" banner (harmless — destination is non-deletable);
    `swapPrimary`'s only callers are `model_test.zig`, so its seam
    stub/test wiring deserves a sentence; `src/core/PLAN.md` +
    `src/core/TODO.md` (stale `contract_x11.zig` material) still unlisted for
    the item-8 doc sweep.

## Go / no-go after round 3

| Item | Status |
|---|---|
| 1 rename → `model` | **Go** |
| 2 seed → `config/` (carve-out) | **Go** |
| 3 scaling → `display/` | **Go** |
| 4 `proc/` → `process/` | **Go** |
| 5 bar-position toggle | **Go** (fix duplicate step "3") |
| 6 title_cache | **Go (already dropped)** |
| 7 dumpState → `diagnostic` | **Go** |
| 8 contract split | **No-go** until the build.zig classifier/codegen sites (classifyFile:1056, deriveOwnerContracts, buildOwnerRegistryModule:1601/1609, wiring:1696) are added to scope, and the ~32-importer repoint is stated |
| 9 flag removal | **Go** (delete its two duplicates, item 11-flags + incremental config section) |
| 10 op migration | **Go** (Option A is coherent; remove the duplicate `findHome`) |
| 11 incremental | **Go after** deleting phantom-function rows and de-duplicating section numbering |

Recommended sequence unchanged: steps 1-7 in order → 8 (after the scope
amendment above) + modularity matrix → 10 + modularity matrix → 9 (opt-in)
→ full suite with `--summary all`.
