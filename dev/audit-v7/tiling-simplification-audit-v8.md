# hana — tiling subsystem simplification audit (v8, tiling scope)

Date: 2026-09-23. Scope: `src/tiling/tiling.zig` (345 LoC) + the six layout
modules (`master` 330, `fibonacci` 106, `scroll` 105, `grid` 71, `leaf` 71,
`monocle` 34). RESEARCH ONLY — no files modified, no builds run, no tests run.

Pre-read: dev/SIMPLIFICATION_PLAN*.md, dev/audit-v7/*.md,
dev/plugin-template/layout.zig (the stable Layout contract), and the Layout
contract in src/core/contract.zig:475-577. Every claim below was verified with
`rg`/full-file reads against the live tree (HEAD `c5b0873c`).

## 0. Claimed-done verification (do NOT re-report, but confirm)

All v6 tiling items (TIL-01..09) verified **APPLIED** against current source:

| Item | Current-source evidence |
|---|---|
| TIL-01 contract doc | contract.zig:486-501 (by-value preReconcile, no phantom `params` param) |
| TIL-02 layoutByName doc | tiling.zig:242-247 (one sentence, "case-insensitive match") |
| TIL-03 defaultKind | gone; `layoutKindOf` = `layoutKindFallingBack(name, 0)` at tiling.zig:270-272 |
| TIL-04 emitRect | tiling.zig:206-213; used by master:306, grid:45, fibonacci:87, scroll:82 |
| TIL-05 master `blk:` | gone; plain `if/else` initializer at master.zig:41-44 |
| TIL-06 fib advance | `splitAndAdvance(ctx, …)` at fibonacci.zig:68 |
| TIL-07 master slice | `const stack_windows = windows[master_n..]` at master.zig:37 (hoisted) |
| TIL-08 LayoutCtx doc | tiling.zig:81-83 (no "every module needs" claim) |
| TIL-09 PMinSize policy | single-sourced in tiling.zig:13-14 + model SizeHints doc |

One **claimed-fixed item is still present** — see TIL-N5 (v5 NEW-16).

### Layout contract stability
No finding below touches any `contract.Layout` field (contract.zig:488-518), the
`View`/`List`/`Placement`/`Env` interchange types, the registry binding
(`tiling.layoutModule`), or the engine's public dispatch surface
(`compute`/`layoutBy{Name,Kind}`/`cycleKind`/`variantCount`/`moduleName`).

### N/A axes
- No error unions anywhere in the subsystem → "identical error branches" N/A.
- No big if/else chains that could be switches (largest is a 2-arm if/else at
  master.zig:51-54); all else-branches are ternary or single-purpose.
- No new bare-bool fn params except the pre-existing `appendPlacement`
  `visible: bool` (see DEFERRED/Q2).

---

## 1. Findings

### [TIL-N1] Med-High / High: master.zig:266 — last manual `2 * border` spelling
- **What:** `const min_col_w: u16 = ctx.min_dim +| 2 *| ctx.m.border;` is the
  only place in the tiling subsystem still hand-spelling `2*border`; everything
  else uses `utils.doubledBorder(m)` (master:240,240,280 path; fibonacci:43,75;
  leaf:28; grid:18; scroll:56; and `tiling.totalInset` at master:64, monocle:17,
  scroll:49). This is original-plan item B22 ("the straggler"), never applied
  through v6 (v6's TIL-01..09 list does not include it).
- **Why:** magic-arithmetic drift: three spellings of the same quantity coexist
  in master.zig alone (`2 *| ctx.m.border` :266, `m.border *| 2 *| count` :312,
  `2 *| m.border` :203 in `rowPitch`).
- **Concrete:** `const min_col_w: u16 = ctx.min_dim +| utils.doubledBorder(ctx.m);`
- **LoC delta:** 0 (consistency; closes the straggler).

### [TIL-N2] Med / High: fibonacci.zig:43,56 vs 75 — `border2` computed twice per pass; the too-small gate hand-recomputes `tiling.totalInset`
- **What:** `compute` computes `const border2 = utils.doubledBorder(m)` at
  fibonacci.zig:43 solely for the too-small gate at :56, while `splitAndAdvance`
  independently recomputes the identical `utils.doubledBorder(ctx.m)` at :75.
  Meanwhile the gate magnitude `m.gap *| 2 + border2` is exactly the value of
  `tiling.totalInset(m.gap, m)` (tiling.zig:109-111: `gap*2 + doubledBorder`),
  i.e. the shared "2×gap + 2×border" quantity is re-derived instead of reused.
- **Why:** one value appears as two shadowed locals in two functions; the gate's
  arithmetic duplicates the engine's own single-source helper.
- **Concrete:** hoist once — drop the :43 local and write
  `const need = tiling.totalInset(m.gap, m); if (last or cur.w < need or cur.h < need)`.
  Caveat: `m.gap *| 2 + border2` uses wrapping `+` on u16; `totalInset` uses
  saturating `+|`. Identical for all reachable margin values (an overflow here
  needs `gap*2 + border*2 ≥ 65536`), but flag the overflow corner for the owner
  if strict ReleaseFast overflow-proofing matters. Alternative that avoids any
  semantics question: keep the gate spelling and pass `border2` (or `need`) down
  instead of recomputing in `splitAndAdvance`.
- **LoC delta:** −0..−1 (line swap) plus removal of the duplicated compute.

### [TIL-N3] High / High: fibonacci.zig:72 — `splitAndAdvance` `gap` param duplicates `ctx.m.gap`
- **What:** `splitAndAdvance(ctx, win, dir, gap: u16, cur: *Region)` is called as
  `splitAndAdvance(ctx, win, dir, m.gap, &cur)` (fibonacci.zig:63), and `ctx.m`
  carries exactly `v.env.margins` (LayoutCtx.init, tiling.zig:90-92). The
  explicit param is pure re-state; all four bodies could read `ctx.m.gap`
  (`bisectRegion(dim, gap)`:82 and the `+| gap` updates :96-97, :99, :101).
- **Why:** dead-duplicate parameter; the module already threads `ctx` precisely
  so helpers don't take `(v, out)` pairs (that was the TIL-06 fold).
- **Concrete:** drop the param; use `ctx.m.gap` at :82/:96-101.
- **LoC delta:** −2.

### [TIL-N4] Med / High: leaf.zig:28,32 — `border2` computed at every recursion node but used only in the terminal `n == 1` branch
- **What:** `tileRegion` computes `const border2: u16 = utils.doubledBorder(ctx.m)`
  at :28 on every recursive call, then uses it in exactly one place — the
  `n == 1` leaf emit at :32 (`insetRect(..., border2, ...)`). The too-small gate
  (:48) does not use it (`ctx.min_dim * 2 + gap`).
- **Why:** value-with-enclosing-scope misplacement: the named const at function
  top advertises whole-body use while it serves only the leaf case; the multiply
  runs once per node instead of once per leaf.
- **Concrete:** move the declaration inside the `if (n == 1) { … }` branch.
- **LoC delta:** 0 (relocation; kills the per-node recompute, clarifies scope).

### [TIL-N5] High / High: leaf.zig:41-47 — dangling spliced comment (v5 NEW-16 still present)
- **What:** the 7-line overflow-gate comment ends with a parenthetical,
  "(split_y: dim==h checks the row height; split_x mirrors with dim==w, inset so
  a tight pane can't overlap its neighbor.)" (:44-46). There is no `split_y` /
  `split_x` identifier anywhere in leaf.zig (or bisectRegion, tiling.zig:173-177)
  and no per-axis gate — the branch tests one combined `dim` built at :40. The
  text also name-checks "fibonacci.zig's gap+border gate" twice (:43, :47),
  redundantly after already contrasting it (:44 start). v5 listed this as
  NEW-16 ("spliced double sentence (NEW-9 patch residue)…rewrite one coherent
  comment", Phase 1 DONE): **the splice survives in current source** — either
  the fix was applied elsewhere or incomplete; flag as claimed-fixed-but-present.
- **Why:** dead prose describing variables that don't exist; two modules users
  must reconcile against code.
- **Concrete:** cut the whole parenthetical (:44 second half–:46) and keep one
  sentence contrasting leaf's min_dim gate with fibonacci's gap+border gate:
  e.g. "Gate is a min_dim floor (a two-child pane needs both children plus the
  seam), unlike fibonacci's gap+border spiral gate; overflow hands the region to
  the focused window and parks the rest (same shape as fibonacci)."
- **LoC delta:** −3.

### [TIL-N6] Med / Medium: tiling.zig:182-184 — `paneCell` is single-owner (grid only); engine helper vs deletion-modularity
- **What:** `pub inline fn paneCell(total, count, gap)` is used only by
  grid.zig (:23, :24, :32 — rigid + relaxed widths). Per the project's
  deletion-modularity ideology, engine geometry helpers should serve ≥2
  modules; a one-owner helper should live with its owner so deleting grid leaves
  no dead engine export. (`bisectRegion`, `seamGap`, `totalInset`,
  `emitOverflowShare`, `showOneHideRest`, `insetRect`, `outerArea` all have ≥2
  owners and correctly stay in the engine.)
- **Why:** subsystem-level single-source vs module self-containment tradeoff;
  the v6-era consolidation (TIL-04) moved geometry INTO the engine and left
  this straggler that never gained a second owner.
- **Concrete:** move `paneCell` (4 lines + doc) into grid.zig as a private
  `inline fn`, updating the three call sites; keep grid import-clean.
- **LoC delta:** 0 net (engine −4, grid +4); improves deletability.

### [TIL-N7] Med / High: tiling.zig:129-131 — `satI16` pub with now-stale "shared by every module" doc
- **What:** after TIL-04 (shared `emitRect`), no module calls `satI16` directly
  — `rg` shows only tiling.zig itself (insetRect :136, emitRect :208). Its doc
  still claims it is "Shared by every module that builds utils.Rect from
  computed geometry", which stopped being true when modules moved to
  `emitRect`/`insetRect`.
- **Why:** stale comment + needless pub breadth on an engine-internal primitive.
- **Concrete:** de-pub (`pub inline fn` → `inline fn`) and reword the doc to
  "Internal narrow/clamp used by emitRect and insetRect."
- **LoC delta:** 0.

### [TIL-N8] Med / High: master.zig:311-314 — calcAvailableHeight re-derives rowPitch arithmetic
- **What:** `const overhead = m.gap *| (count + 1) +| m.border *| 2 *| count;`
  is algebraically `m.gap +| count *| rowPitch(m)` (rowPitch :202-204 =
  `m.gap +| 2 *| m.border`). master.zig already defines `rowPitch` for exactly
  this row layout; the overhead is "one leading gap + count row pitches".
- **Why:** a second spelling of `count*gap + count*2*border` (and the last
  `*2 border` spelling standing alone — with TIL-N1 applied this is the only
  one besides rowPitch itself).
- **Concrete:** `const overhead = m.gap +| count *| rowPitch(m);` (saturating
  ops preserved; identical for all inputs).
- **LoC delta:** 0 (single-source; aids the TIL-10 dense-register comment).

### [TIL-N9] Med / Medium: tiling.zig:292 — `[256]u8` re-declares `model.max_layouts`
- **What:** `cycleKind`'s scratch `var indices: [256]u8` spells the layout-name
  cap by hand; `model.max_layouts` is exactly 256 and tiling.zig already imports
  model (WindowId/LayoutParams). This is v3 TILING-10, deferred for "layering"
  — but tiling is already model-dependent, so no new coupling.
- **Why:** parallel truth that silently truncates cycle order if the two ever
  diverge (the `if (n < indices.len)` guard papers over it).
- **Concrete:** `var indices: [model.max_layouts]u8 = undefined;`
- **LoC delta:** 0.

### [TIL-N10] Low-Med / Medium: grid.zig:8, monocle.zig:8 — variant-index consts are unenforced parallel truths
- **What:** `const variant_relaxed = 1;` / `const variant_gaps = 1;` must track
  the value-string order in the adjacent `tiling.variantParse(&.{…})` lists
  ("must match variantParse order below" comments). A reorder silently flips
  variants at runtime.
- **Why:** 2 copies of a positional contract across two modules, none checked.
- **Concrete (optional):** a tiny comptime assert tying the parse list to the
  index, e.g. grid: `comptime { std.debug.assert(@typeInfo(@TypeOf(&.{"rigid","relaxed"})).array.len > variant_relaxed); }`
  — or keep as documented coupling (Low value).
- **LoC delta:** 0..+2.

### [TIL-N11] Low / High: grid.zig:59-64 — `calcGridShape` one-use wrapper returning an anonymous struct
- **What:** `inline fn calcGridShape(n)` is called exactly once (grid.zig:16)
  and returns `struct { cols: u16, rows: u16 }`; both fields are then read via
  `grid.cols`/`grid.rows` at :23/:24/:30/:38/:39/:40/:63.
- **Why:** an indirection + anonymous struct for a 4-line ceiling-sqrt; the
  callers' `screen_w/screen_h` context is lost (must be re-passed).
- **Concrete:** hoist the loop into `compute` producing plain `const cols/rows`
  (inlines to 5 references). Borderline — keep the fn if the n==3 special case
  reads better isolated.
- **LoC delta:** −2..−4 (optional, readability tradeoff).

### [TIL-N12] Low-Med / Medium: scroll.zig:23-27 — `maxOffset` derives one param from another (contract-adjacent)
- **What:** `maxOffset(n, slot_w, screen_w)` — `slot_w` is always
  `slotWidth(screen_w)` (scroll.zig:16-18), so every call site
  (:45, preReconcileHook :91-92) recomputes the unit that the callee could
  derive from `screen_w` alone. But `slotWidth`/`maxOffset` are registered
  `contract.Layout` hook fields (contract.zig:508-509) consumed by actions /
  the pipeline; changing the arity changes the contract.
- **Why:** a redundant param surface if the contract ever allows it; today it is
  the price of the stable hook typedef.
- **Concrete:** none while the contract is frozen — recorded so the next
  contract rev can fold `maxOffset(n, screen_w)` and derive `slot_w` inside.
- **LoC delta:** 0 (deferred; see DEFERRED/Q1).

---

## 2. DEFERRED / QUESTIONS

- **Q1 — `maxOffset` arity vs the Layout contract (TIL-N12).** Folding the
  derived `slot_w` param needs a `contract.Layout.maxOffset` type change
  (contract.zig:509). Preserve-the-contract mandate says hold; owner to rule if
  a future contract rev wants `fn (usize, u16) i32`.
- **Q2 — `appendPlacement`'s `visible: bool` (v3 TILING-5, H, never applied).**
  I re-derived the tradeoff and recommend **keeping** it: the helper dedupes the
  "append-or-silently-skip-at-capacity" guard shared by `emitView`/`emitHidden`;
  inlining both callers costs ~+4 lines to delete one bool param. Reverse of the
  v3 recommendation; not a simplification on balance.
- **Q3 — fib/leaf asymmetric overflow gates.** leaf:48 is `min_dim*2 + gap`;
  fib:56 is `gap*2 + border*2` (the `last` case merges the exhausted-remainder
  path). Both are "region can't hold two children" but intentionally differ
  (fib's own comment cross-references leaf's). Unifying the threshold is a
  behavior change — recorded, not proposed.
- **Q4 — `focusedElse` fallback conventions (monocle: tail, fib: remainder
  head, leaf: list head).** Documented per site ("focusedElse: fallback is …").
  v4 NEW-10 left this open for a topology decision; I flag only that the three
  inline conventions will keep drifting — owner call on whether to unify.
- **Q5 — `paneCell` relocation (TIL-N6) vs engine vocabulary.** Moving it into
  grid contradicts the "shared geometry vocabulary" tiling.zig header grouping;
  it is a judgment between engine-vocabulary consistency and per-module
  deletion-modularity. Recommend the move; owner to confirm.
- **Q6 — `layoutKindOf` one-line alias after TIL-03.** `layoutKindOf(name)` is
  now just `layoutKindFallingBack(name, 0)` with a 6-line doc; its second
  external consumer is pipeline.zig:82 / actions.zig:737 (they could call the
  falling-back form with `0`). Folding would delete the alias + doc (−5..−6)
  at the cost of reading intent ("neutral default") at each call site. Sent
  here because it is the same shape TIL-03 collapsed and was itself worth
  3 lines in v6.
- **Q7 — test seam mirrors master geometry.** src/test/helpers.zig:125-133
  documents that its goldens mirror `totalInset`/`stackSeamMargin`. Test code is
  out of scope; cross-ref is current and correct — no action.
- **Q8 — N/A axes confirmation.** No error unions, no if/else→switch
  candidates, no new bare-bool params (only Q2's pre-existing one).

### Honest bottom line
This subsystem was heavily consolidated by the v3-v6 campaigns (all of TIL-01..09
plus earlier pane/emit/overflow works verified applied). Remaining candidates are
mostly 0-LoC hygiene (spelling, scope, doc, single-source) with two real deletions
(TIL-N3 −2, TIL-N5 −3) and one arithmetic sign-off (TIL-N2's saturation corner).
No finding changes geometry output or the Layout contract.