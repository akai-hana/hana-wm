# MOD-EP audit — model + entrypoint simplification candidates

Date: 2026-09-23. Research-only campaign. Scope: `src/model/model.zig` (426 ln),
`src/main.zig` (191 ln), plus the model's **query surfaces** (the window-layer
`tracking.zig` facade, which reads/writes through `pipeline.model()`/`instance`)
and interop where consumers interface with the model's `Store`/`Entry`/predicate
surface (sync/pipeline/input/window/borders). `src/test/` and `src/core/` were
not modified; items landing inside core/sync/pipeline are reported as interop
only. No files were changed.

Prior campaigns re-verified against current source (see §Verify) — all
MODAud-01..12 and the Phase-2/3 ledger/FULL-01 claims hold; nothing re-reported.

Method: both files read in full; every "dead/single-consumer" claim backed by
tree-wide `rg` (production `src/` incl. `dev/plugin-template`, excluding
`src/test/` where noted). Public API of `model.zig` preserved exactly; the
`tracking.zig` facade members below are window-layer, not model, so deletion is
permitted without violating the "preserve model public API" rule.

Est. total LoC delta for numbered items: ≈ −45 (code) plus ≈ −30 (comments).

---

### [MOD01] High/High: `src/window/tracking.zig:183-190` — `isOnCurrentWorkspaceAndVisible` is production-dead
- What: `pub fn isOnCurrentWorkspaceAndVisible(win) bool` exists solely for
  `tracking_test` (10 assertions: tracking_test.zig:98,101,104,129,132,155,159,186,190).
  Tree-wide `rg` finds **zero** callers in `src/` production (window, bar, input,
  focus, actions) or `dev/plugin-template`. Its body is `isOnCurrentWorkspace`
  + `presence != .parked` — a current-workspace specialization that **shadows**
  `model.visibleOn` (diverges when `all_view_active` is true: `visibleOn` turns
  true for a window tagged elsewhere, this predicate stays false; and it is
  parked-agnostic about tag edits while `visibleOn` folds parking in).
- Why: dead public surface with a near-twin predicate in the model;
  a reader must hold both of them and the divergence in mind.
- Concrete: delete the fn + doc; delete the 10 test assertions (they pin a
  predicate nothing in production uses).
- LoC delta: −6 (fn+doc) −10 (tests) ≈ −8..−10. Confidence: call-site proof.

### [MOD02] High/High: `src/window/tracking.zig:55-59` — `getWindowWorkspaceMask` pub, single internal consumer
- What: `pub inline fn getWindowWorkspaceMask(win) ?u64` returns `e.mask`.
  Production callers: exactly one — the private `isWindowOnWorkspace`
  (tracking.zig:166), itself a one-use wrapper feeding `isOnCurrentWorkspace`
  (tracking.zig:178-181). The only external reference is the test
  (tracking_test.zig:91). `bar.zig`/`window.zig`/`focus.zig` all read masks via
  their own held `Entry`/`mask` and never call this.
- Why: a 5-line pub facade serving one internal line; two-hop read-through.
- Concrete: fold the body into `isOnCurrentWorkspace` (inline
  `getWindowWorkspaceMask` + `isWindowOnWorkspace`, 3 lines), de-pub; repoint
  tracking_test.zig:91 at `m.store.get(w).?.mask` or drop it.
- LoC delta: −6..−7 (2 fns + docs) with the test edit. Confidence: HIGH.

### [MOD03] Medium/High: `tracking.windowCount` (61-64) + `tracking.countWindowsOnWorkspace` (143-149) — read-through cluster alive only for the debug dump
- What: two pub facade reads with **one production consumer each**, both inside
  `input.dumpState` (input.zig:445 `tracking.windowCount()`, input.zig:455
  `tracking.countWindowsOnWorkspace(...)`, reachable only from the
  `.dump_state` action, input.zig:374). `countWindowsOnWorkspace` re-derives the
  model tag test over the `allWindows()` snapshot (the workspace-count
  read-through the campaign targets); `windowCount` = `m.store.count()`.
- Why: two more spelling-surfaces of `store.count()`/`maskedOn(e.mask, ws)`
  that ship model logic in a third form, exercised once per manual `dump_state`.
- Concrete: fold into `dumpState` — count windows inline from a single
  `tracking.allWindows()` pass and log `pipeline.model().store.count()` for the
  total (or drop the per-ws line). Delete both fns + docs; repoint
  tracking_test.zig:82 at `m.store.count()`.
- LoC delta: −11..−13 (2 fns + 2 doc blocks + the dump lines that fold in).
  Confidence: HIGH on deadness (rg-verified); MEDIUM on whether the facade was
  intended API for a future consumer.

### [MOD04] Medium/High: `src/window/window.zig:319-321` — same-name passthrough `isOnCurrentWorkspace` re-export
- What: `inline fn isOnCurrentWorkspace(win)` whose entire body is
  `return tracking.isOnCurrentWorkspace(win);` — a private wrapper with the
  facade's exact name, one caller (window.zig:1186).
- Why: same-name indirection layer; readers must resolve which
  `isOnCurrentWorkspace` is in scope per file. Pure interop passthrough.
- Concrete: call `tracking.isOnCurrentWorkspace(win)` directly at :1186 and
  delete the local fn.
- LoC delta: −3. Confidence: HIGH (trivially behavior-identical).

### [MOD05] Medium/High: `src/model/model.zig` — comment bloat: 4 doc blocks re-explain code
- What (four verbatim targets, all doc-only, zero behavior):
  1. `coveringOccupantOnWs` (model.zig:235-246): 12-line doc for an 8-line
     scan; the second paragraph (241-245) restates the OR-vs-AND contrast that
     is already single-sourced across the two fullscreen/borders/sync comments
     (WCD-03 trail) → compress to a 3-line "OR union of anchor-or-visibility"
     + one cross-ref line.
  2. `register` (169-182): ~14 doc/comment lines for a 10-line membership
     insert; lines 177-182 re-narrate the two `put`-then-append ordering steps
     the code states literally.
  3. `fallbackFocusCandidate` (312-321 doc + 323-341 tier comments): ~19
     comment lines around a 27-line body; the three-tier bullets literally
     repeat the three loops.
  4. `Store` re-export (116-120): 5 lines to say "alias from bounded.zig".
- Why: nearly a third of the file is commentary restating the statements (426
  ln total, ~135 comment lines); the audit's comment-quality axis.
- Concrete: keep policy notes (SizeHints floor, viewport-preserve, home_ws
  ordering), drop the rest. No code change.
- LoC delta: −12..−16 (comment lines only). Confidence: HIGH (no drift found —
  it's volume, not falsity).

### [MOD06] Medium/High: `src/model/model.zig:213-215` — `taggedOn` doc over-claims "window/sync layers share one spelling"
- What: the doc says the window/sync layers use `taggedOn` "instead of
  re-deriving `e.mask & bit(ws)`", but the window layer's own facade
  (tracking.zig:146) and window core (window.zig:1354, plus focus.zig:623)
  re-derive the identical test as `model.maskedOn(entry.mask, ws)` — forced,
  because they hold the pruned `tracking.Entry {win, mask, presence}` which
  cannot be passed to `taggedOn` (wants full `model.Entry`).
- Why: doc-vs-reality drift on a *willful* split (raw-mask form for the pruned
  facade vs entry form for the model). Readers learn the two-spelling split
  only by reading all four sites.
- Concrete: amend the doc to name the split explicitly ("facades holding a
  pruned Entry use `maskedOn(e.mask, ws)`"). Optional follow-up: give the
  facade a `tagged(win, ws)` helper so the re-derivation disappears — that
  touches `tracking.Entry`, so it is the owner call (see MOD-D2).
- LoC delta: −1 (doc) / 0 (or +2 for the facade helper). Confidence: HIGH on
  the drift; the fix scope is the question.

### [MOD07] Medium/Medium: interop — `m.ws[m.current.index].params` idiom spelled 9×
- What: `rg` finds the current-workspace params read/write in 9 places:
  model.zig:408 (`adjustPrimaryWidth`), sync.zig:309, actions.zig:518,526,544,551,
  663,683, bar/modules/layout/variants.zig:32, plus pipeline.zig:70/124 (read in
  the `model().ws[model().current.index]` shape — see MOD-EP note).
- Why: the "current ws params" read-through is the private-sector twin of the
  public `model.current`/`model.tiledCountOnWs` vocabulary; every new layout
  touch point respells three field hops.
- Concrete: add to model.zig
  `pub inline fn currentParams(m: *Model) *LayoutParams { return &m.ws[m.current.index].params; }`
  (and a `*const` accessed via the same call — Zig infers from the receiver
  form), then swap the 9 sites. Public API is additive (no removal). Net LOC
  ≈ +2; the value is single-spelling + one documented home for the idiom.
- LoC delta: ≈ 0..+2 (readability/consolidation). Confidence: MEDIUM (style
  judgment; the 9-site census is exact).

### [MOD08] Medium/Medium: interop — `Store.Iterator`'s "no bounds dance" promise unmet by the busiest pass (sync fused loop)
- What: `bounded.zig:285-287` documents the sorted-key `Iterator` as existing
  "so scans never hand-roll the `0..count()`/`,at(k)` bounds dance," yet the
  tree's hottest store scan is precisely that hand-roll: sync.zig:350-356
  `const count = m.store.count(); for (0..count) |i| { const it = m.store.at(i); ... }`.
  The reason `Iterator` can't be used there is real: the fused pass needs the
  **slot index** to index the `pl_of_slot` table (sync.zig:383), and
  `Iterator.Item` yields only `{key, val}`.
- Why: doc claim + surface gap — either the Iterator should yield the index
  (making the claim true and the hot loop a 3-line iterator) or the doc must be
  trimmed so nobody "fixes" toward a false promise (MODAud-07-era work tracked
  `at`/`count` as sanctioned for slot-index consumers).
- Concrete (preferred): extend `Item` with `idx: usize`; rewrite the fused loop
  and the tiled-slot loop (sync.zig:294-307) onto `iterator()`. No model API
  change (Store lives in core/utils/bounded.zig, surfaced via `model.Store`).
- LoC delta: −5..−7 (sync passes) or 0 (doc trim only). Confidence: MEDIUM
  (correctness-neutral either way; touches the perf-pinned sync path).

### [MOD09] Low/High: `src/main.zig:17-21` vs `114-115` — duplicated surfaces/boot-guard commentary
- What: the `surfaces` import doc (lines 17-21, 5 lines: "optional chrome
  surface's boot lifecycle... when the bar is absent surfaces is the comptime
  null type and the guarded calls below compile away") restates the inline
  comment at 114-115 ("Direct subsystem init: only the bar ever registered
  hooks (no plugin registry anymore)") and the two `if (build_options.has_bar)`
  guards themselves, which are the codebase's standard `has_bar` idiom
  (input.zig:180/209/418-420, events.zig:86-91/367/588/625 — 19 sites).
- Why: same fact in two comment layers; the entrypoint file earns its doc tax
  twice for one mechanism.
- Concrete: keep the import doc's first sentence, delete the "guarded calls
  below compile away" restatement; shrink 114-115 to one line or drop it.
- LoC delta: −4 (comment lines). Confidence: HIGH (textual).

### [MOD10] Low/High: `src/main.zig:106` — opaque slogan comment "owns the model; the model path IS the path"
- What: `pipeline.init(); // owns the model; the model path IS the path`
- Why: "the model path IS the path" is a slogan, not the load-bearing fact; the
  reader must infer it means "pipeline.init() must precede
  `actions.seedParamsFromConfig()` and any `pipeline.model()` use" (true:
  seedParamsFromConfig writes through the model, main.zig:112).
- Concrete: rewrite as the causal dependency (e.g. "model owner; must run before
  seedParamsFromConfig/model()"), or drop the tail.
- LoC delta: 0 (rewrite). Confidence: HIGH.

### [MOD11] Low/High: `src/model/model.zig:184-189` — `unregister` defeats the `home_ws` cache, then pays a full 64-ws scan
- What: `unregister` calls `m.store.remove(win)` **before** `findHome(m, win)`;
  the entry is already gone, so `findHome`'s cache path (`home_ws`) is dead and
  it scans all 64 `tiled_order` lists. The cache exists precisely for this kind
  of call (register:177-179). Behavior identical if the lookup is captured
  first: `const home = findHome(m, win); if (!m.store.remove(win)) return; if (home) |h| removeValue(...)`.
- Why: the only full-store scan on the unmanage/close hot path, on the promise
  of a cache the ordering defeats; reordering also makes "captured home before
  the entry dies" structurally explicit.
- LoC delta: 0 (2-line reorder) — perf + clarity, not deletion. Confidence:
  HIGH on the cache-defeat (read the ordering), LOW on value (bound 64, so it
  is a micro-opt; flag if unmanage volume is a concern).

---

## DEFERRED / QUESTIONS

- **MOD-D1 — `model.clearFocus` (model.zig:299-301) is a 1-line pub wrapper**
  (`m.focused = null;`) with 2 production callers (actions.zig:164, focus.zig:474)
  and heavy call-site doc (focus.zig:397,472) already explaining the ordering.
  Inlining both sites would delete 5 lines, but the member is live public model
  API (tests + the focus layer treat the name as the "model-side focus drop"
  contract). Owner call: keep (API preservation) or inline.
- **MOD-D2 — `model.visibleEntry` predicate re-derived at two recovery edges.**
  focus.zig:620-623 ("Mirrors model.visibleEntry") and window.zig:1186
  (`!isOnCurrentWorkspace(win) and !all_view_active`) both re-spell the
  "not-parked-and-(tag OR view-all)" test on the pruned `tracking.Entry`; a
  parked-on-current window also diverges (focus: continues, window: returns)
  from a literal `visibleOn`. A mask+presence-form predicate in model (e.g.
  `visibleFrom(m, mask, presence, ws)`) would single-source it, but it adds a
  public member and re-targets a hover/focus hot check — measure-first, or keep
  the mirrors + fix the comments to cite each other.
- **MOD-D3 — `persist.WindowRecord` (persist.zig:84-93) is a field-for-field
  mirror of `model.Entry`** (`mask`, `anchor`, `presence`, `covering_ws`).
  Merging is wrong (it is the serialized, versioned re-exec format), but the
  hand-maintained twin could drift (new Entry field silently unsaved). Question:
  add a comptime shape guard (`std.meta.fields(WindowRecord)` ⊆ Entry fields +
  `home_ws`/`size_hints` derivation), or annotate the DTO as deliberately pinned?
- **MOD-Q1 — `input.dumpState` (input.zig:442-464) is the sole production
  consumer of `tracking.windowCount` and `countWindowsOnWorkspace`**, and it
  also reads `model.tiledCountOnWs` (input.zig:464) + `tracking.getWorkspaceCount`
  (input.zig:449). If the debug dump is treated as a first-class surface, these
  two facade members could stay and MOD03 becomes a no-op — owner preference on
  "debug-only surface" policy.

---

## §Verify — v6 claimed-fixed items, re-checked against CURRENT source

All pass; no HIGH regression found (this is the "don't re-report, but verify"
gate):

- **MODAud-01** single-search `Store.put` + `exactAt = lowerBound + equality`:
  bounded.zig:253-268/219-223 ✓
- **MODAud-02** pointer-relocation contract rewritten: bounded.zig:207-210 ✓
- **MODAud-05** `swapPrimary` labeled test seam: model.zig:373-377 ("production
  never calls this"); `rg swapPrimary` = model_test only ✓
- **MODAud-06** `bit()` <64 precondition documented: model.zig:20-21 ✓
- **MODAud-07** cross-ref added: tracking.zig:140-142 ✓
- **MODAud-08** `maskedOn` in use: tracking.zig:146,167; window.zig:1354;
  focus.zig:623; bar.zig:835,843 ✓
- **MODAud-09** `Store.clear` gone (survives only on `BoundedList`, tracked:
  tracking.zig:96 etc.) ✓
- **MODAud-10** `max_tiled_windows` doc per-ws: constants.zig:107-110 ✓
- **MODAud-11** named `max_primary_count`: actions.zig:542 ✓
- **MODAud-12** capacity rationale comments: model.zig:122-127 ✓
- **C-02** `State.sent` is `model.Store(...)`; `SentEntry.id` dropped:
  sync.zig:150-163, `forget` single-store-remove ✓
- **FULL-01** fullscreen modules drive `presence`/`covering_ws` on the model
  entry directly (fullscreen.zig:80+); `g_recs` gone from fullscreen ✓
  (minimize's own `g_recs` is a separate record, untouched).

## Final digest of this report

- **MOD01** −8..−10 — `tracking.isOnCurrentWorkspaceAndVisible`: production-dead
  facade, near-twin of `model.visibleOn` (rg: tests only).
- **MOD02** −6..−7 — `tracking.getWindowWorkspaceMask`: pub, one internal
  consumer; fold into `isOnCurrentWorkspace`.
- **MOD03** −11..−13 — `tracking.windowCount` + `countWindowsOnWorkspace`: both
  alive solely for `input.dumpState` debug (445/455); fold into the block.
- **MOD04** −3 — `window.zig:319-321`: same-name passthrough of
  `tracking.isOnCurrentWorkspace`; call the facade directly.
- **MOD05** −12..−16 — comment bloat across model.zig (coveringOccupantOnWs
  doc, register, fallbackFocusCandidate tier bullets, Store alias doc).
- **MOD06** −1 — `taggedOn` doc over-claims single-spelling; window layer
  re-derives `maskedOn(e.mask, ws)` at tracking.zig:146 / window.zig:1354.
- **MOD07** ~0 — `m.ws[m.current.index].params` idiom at 9 sites →
  `model.currentParams(m)` accessor (additive API).
- **MOD08** −5..−7 or 0 — `Store.Iterator` doc promise unmet: sync.zig:350-356
  hand-rolls `count`+`at`; iterator should yield the slot index.
- **MOD09** −4 — main.zig:17-21 vs 114-115 duplicated surfaces/boot-guard prose.
- **MOD10** 0 — main.zig:106 slogan comment; state the real dependency.
- **MOD11** 0 — unregister defeats `home_ws` cache (scan after entry removal);
  reorder to capture before.

Top items to execute first: MOD01, MOD02, MOD04, MOD03 (all deletions,
rg-verified, no model-API surface touched). Then the doc batch MOD05/06/09/10.
MOD07/08 need owner ruling (API additions / perf-gated sync path). Deferred:
MOD-D1 (clearFocus inline), MOD-D2 (visibleEntry mirrors), MOD-D3 (persist DTO
guard), MOD-Q1 (debug-surface policy).
Net: ≈ −45 code LOC, ≈ −30 comment lines, all behavior-preserving.