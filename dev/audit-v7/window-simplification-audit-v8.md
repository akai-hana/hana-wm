# Window-Simplification Audit v8 — `src/window/` (hana, X11 WM)

- Date: 2026-09-23 (session run)
- Scope: read-only audit of `src/window/` (window, actions, focus, icccm,
  tracking, wincache, borders, modules/{floating,fullscreen,minimize,
  workspaces})
- Baseline: tree at cwd (HEAD `46f85d5`, "…remove task-tag references";
  uncommitted doc/config edits outside `src/`).
- Constraints honored: no writes outside this report; no build/test runs; did
  NOT touch `src/test/`, `src/core/`, `src/config/`, `src/bar/`, tiling/input;
  the plugin seam (`providerOf`/`callHook*`/`serialize`/`deserializeWindow`)
  is preserved throughout — no finding proposes removing it.
- Done-list reconciliation basis: `dev/SIMPLIFICATION_PLAN_v6.md`
  (Phases 1-4 + §C batch COMPLETE; §B window batch, window modules, CC-01..05
  all DONE; FULL-01 restructure, MOD-12 sync `Store` alignment,
  `Store.indexOf`/`Store.clear`, tombstones ledger press, PIP-02
  `pipeline.FullscreenKind`, extractFieldPair use-after-return fix all landed)
  and `dev/window-tree-simplification-audit.md` (owner-ruled items). No item
  already marked done/blessed is re-reported below.

## Findings

### [WIN01] M/H — `src/window/modules/fullscreen.zig:159-161` — `fullscreenOccupantOnWs` is a near-duplicate of `model.coveringOccupantOnWs` (OR-union vs anchor-or-visibility)
- What: `fullscreenOccupantOnWs` (def lines 159-163) re-implements the covered
  occupant scan that `model.coveringOccupantOnWs` already provides; its doc
  comment (159-160) verbatim says "Contrast `model.coveringOccupantOnWs`
  (OR: anchor-or-visibility union)" and it is re-published as the module's
  `.coveringOccupantOnWs` in `modules/fullscreen.zig:280`'s provider table.
- Why: two live implementations of "which fullscreen-covering occupant is on a
  workspace" — the model's pure scan (used by borders.zig:37-38, focus.zig:613,
  workspaces.zig:60-61, actions.zig:40-41, window.zig:860) and the module's
  variant. Worked in parallel, they drift lockstep (ever happened with the
  anchor seam) and give the seam a second, 90%-identical branch.
- LoC cost: duplicates the ~8-12 line occupant-scan body and its workbook
  comment block (159-163).
- Concrete simplification: fullscreen module should delegate to the model scan
  (like workspaces.zig:60-61 / actions.zig:40-41 / borders.zig:37 do) and ship
  `fullscreenOccupantOnWs` only as a thin binder, or — since
  `coveringOccupantOnWs` already is a pure store scan — drop the module copy so
  `model.coveringOccupantOnWs` is the single occupant query. `isCoveringMode`
  (window.zig:75, callHookBool) stays the cheap gate.
- Est. LoC delta: −8..−12.

### [WIN02] M/H — `src/window/modules/minimize.zig:135,175` + `src/window/modules/floating.zig:160` vs `src/window/window.zig:75` — same `isCoveringMode` hook routed two different ways (seam hygiene)
- What: the covering-mode query is read THREE ways: (a) the batch-dispatch
  surface `window.isCoveringMode` → `callHookBool(.isCoveringMode)`
  (window.zig:75-76), (b) direct `providerOf(.isCoveringMode)` pokes in
  minimize.zig:135-136 and 175-176 and floating.zig:160-161 — these bypass the
  dispatch layer and call the provider closure directly.
- Why: mixed access to one hook creates two failure surfaces: the direct
  pokes miss whatever `callHookBool` does (gating / fallback-when-absent) and
  any future hook-semantics change splits. The codebase already routes the
  same hook through the dispatch surface at borders.zig:47,55.
- LoC cost: 3-4 duplicated `providerOf` closure-invocation snippets
  (minimize:135-136,175-176; floating:160-161).
- Concrete simplification: make those three call sites use
  `window.isCoveringMode(m, win)` (the published dispatcher) exactly like
  borders.zig does; the providerOf closures stay in the modules'
  provider tables but are no longer poked directly.
- Est. LoC delta: −4..−6.

### [WIN03] M/H — `src/window/actions.zig:39-41` — `currentCoveringOccupant` is a one-call-seam shim that adds a second routing point
- What: `currentCoveringOccupant(m)` expands to `providerOf(.coveringOccupantOnWs).coveringOccupantOnWs(m, m.current)` and is consumed at 3 sites (205, 237, 277); separately `model.coveringOccupantOnWs(m, m.current)` is called directly at window.zig:860 and focus.zig:613.
- Why: two spellings of the same "occupant on current ws" read — one via the
  actions-local shim, one via the model directly. The shim was born as the
  seam-prefix provider routing; since the seam keeps the model scan the source
  of truth, the shim is a redundant forwarding hop that the audit already
  centralizes everywhere else (borders/focus/workspaces call the model scan
  directly).
- LoC cost: ~4 lines + 3 call sites carrying {}.
- Concrete simplification: replace the 3 `currentCoveringOccupant(m)` calls
  with `model.coveringOccupantOnWs(m, m.current)` inline (the exact expansion);
  delete the helper. Any provider-seam intent is already preserved by
  borders/actions provider tables.
- Est. LoC delta: −5..−7.

### [WIN04] M/M — `src/window/actions.zig:91-96` — `RetileOpts` struct duplicated against the `window.zig` retile surface
- What: `RetileOpts = .{ restack, full_redraw, with_focus, bump_fullscreen }`
  at actions.zig:91-96 governs `retile` (98) and is a sibling of the
  window.zig `retile` (documented as behaving like `Model.retileTilingOpts`).
  Each `retile` caller builds a nearly-identical opts literal; `full_redraw`
  + `bump_fullscreen` recomputation is re-derived at several call sites.
- Why: two modules own "what a retile is" with separate opts structs; the
  flag set is small, but its duplication means a new retile dim (already
  foreshadowed by `.bump_fullscreen`) must be threaded through two structs and
  N literal sites.
- LoC cost: duplicated struct (~6 lines) + repeated literal construction.
- Concrete simplification: single `RetileOpts` type (re-exported, one owner)
  with the current defaults; have `retile` accept it by value like it does
  today, so there's exactly one spelling of the flag set. (Seam-safe: retile is
  a synchronous action, no provider required.)
- Est. LoC delta: −5..−8.

### [WIN05] M/H(LoC)/M(conf) — `src/window/window.zig:94` + `src/window/wincache.zig` — SizeHints `p_*` flag constants duplicated between window core and cache
- What: window.zig:88-92 define XSizeHints flags (`p_min_size=0x10`,
  `p_max_size=0x20`, `p_resize_inc=0x40`, `p_aspect=0x80`, `p_base_size=0x100`)
  and window.zig:94 a `wm_normal_hints_long_length`; the same SizeHints/PWMs
  are mirrored in `wincache.zig:24` (`pub const SizeHints = model_mod.SizeHints;`
  re-export) and parsed in window.zig's `extractFieldPair`
  (window.zig:1300-1303 using `want_min/want_base/want_max/want_inc`).
- Why: two homes for the same hint grammar — window core opens with the raw
  flags to drive `extractFieldPair`, while wincache re-exports the model's
  SizeHints. The p_* values are a compile-time protocol constant that should
  live once (with the ICCCM/WM_SIZE_HINTS atom owner) and be imported at the
  two consumers.
- LoC cost: 5 consts + 1 long_length const, 1 re-export line (small).
- Concrete simplification: keep the p_* flag set + `wm_normal_hints_long_length`
  in ONE owner module (the WM_SIZE_HINTS/ICCCM owner, `icccm.zig`, which
  already owns `wm_hints_long_length: u32 = 9` at icccm.zig:19); window.zig's
  `extractFieldPair` imports them instead of re-declaring; drop the redundant
  re-export line if import is direct.
- Est. LoC delta: −6.

### [WIN06] L/M — `src/window/borders.zig:17,56` — `borderColorOf` pure helper is a 1-caller trivial wrapper
- What: `borderColorOf(focused, focused_px, unfocused_px)` is a two-way
  ternary (17) used at exactly one production site (56) plus its own test
  (`test/window/borders_pure_test.zig:39-41`).
- Why: a pure 1-liner with a single caller and its own test = a fragile
  "pure seam" line for no current consumer gain; it forces borders.zig to keep
  a test-suite import graph node for one ternary.
- LoC cost: ~ socorro small.
- Concrete simplification: inline the ternary at the single call site and let
  the pure logic move into whatever test helper (or the caller) needs it; or
  keep it ONLY if a second concern (layer rule: pure border-color decision
  isolated from X11) is explicitly wanted — in which case leave as-is.
- Est. LoC delta: −1..−4.

### [WIN07] L/M — `src/window/window.zig:988-1014 / 1399-1402` — `warnOnce` latches: 8-slot mask but only 2 bits used
- What: `var warned_once: u8 = 0` + `inline fn warnOnce(comptime bit: u3,…)`
  (1399-1402) carves an 8-slot bitmask; currently only bits 0 and 1 are used
  (calls at 1413 and 1428). The u3 mask + `@as(1)<<bit` arithmetic is
  over-generalized for a 2-slot need.
- Why: comptime bit-slot machinery (shift-by-comptime, overflow-type docs) for
  two occurrences is heavier than a pair of bools/counters; also mixed in the
  same file as a separate numeric-parse trick, so it reads as two idioms.
- LoC cost: ~4 lines.
- Concrete simplification: two `var warned_*: bool` guards (or fold into the
  two existing sites), drop the inline fn + u3 mask. (Keep one warnEach-per-call
  semantics.)
- Est. LoC delta: −3..−4.

### [WIN08] L/H — `src/window/memory: window.zig:109 (spawn_queue 64)` + workspace scan literals — file-scan literals 64 are the only magic numbers; no others
- What: the only literal `64` in the window tree are `spawn_queue_capacity: usize = 64` (window.zig:109) and `child_cache_capacity: usize = 64` (window.zig:179). No workspace-cap literal, no magic WS count anywhere in window/.
- Why (proposal): these ARE named constants with the capacity intent, so this
  isn't a defect; item is informational — confirms the file-scan "64" surfaces
  elsewhere (tiling/input) but NOT under window/, so window-layer audits need
  not chase magic 64s.
- Concrete simplification: nothing to change; optional: comment tying the two
   64s to the same slot-capacity rule (they already read as one idiom).
- Est. LoC delta: 0 (informational).

### [WIN09] L/H — `src/window/actions.zig:33,40-41` + `src/window/modules/workspaces.zig:60` — `providerOf` is the ONLY foreign-module binding, correctly localized but grep-shadowed
- What: `const isCoveringMode = window.isCoveringMode;` (actions.zig:33) and
  the `providerOf(.coveringOccupantOnWs)` usages (actions.zig:40-41,
  workspaces.zig:60-61) are the entire cross-module seam surface for the
  covering/occupant family.
- Why: this is the seam doing its job; the recurring `providerOf` calls
  (borders.zig:37-38, focus.zig:613, actions.zig:40-41, workspaces.zig:60-61,
  fullscreen.zig:102) LOOK like duplication in greps but are all reads of ONE
  model scan. No duplication to fix here beyond WIN01's module-copy; item is
  to prevent a future audit from "deduplicating" the seam.
- Concrete simplification: none (informational; keep the seam).
- Est. LoC delta: 0.

### [WIN10] L/M — `src/window/modules/fullscreen.zig:93-116` + `src/window/modules/minimize.zig:133-136` — "coveringMode" recompute loops happen per-module
- What: fullscreen.zig:93-116 (occupant election on covering bumps) and
  minimize.zig:133-136/175-176 (skip covering-mode windows during pass/restore)
  each re-derive the "is some covering occupant present" test rather than
  calling a single `model.coveringOccupantOnWs` at the one decision point.
- Why: the seam's contract is "providers answer covering queries"; each module
  re-loading the same predicate creates subtle ordering coupling (which module
  loads — fullscreen vs. minimize — changes which `coveringOccupantOnWs` runs).
  A single covered-query dispatcher (WIN01 removes the duplicate) would let
  both modules call one predicate.
- LoC cost: duplicated load/predicate blocks (~6-10 lines across both modules).
- Concrete simplification: with WIN01 (single occupant scan) + WIN02 (single
  `isCoveringMode` route), both fullscreen and minimize call the shared
  dispatcher; drop their local recompute blocks.
- Est. LoC delta: −6..−10 (overlaps WIN01/WIN02; count once).

## Deferred / Questions
- Working tree's exact uncommitted diff was NOT waxed into line numbers (I did
  not read the full per-file contents due to output-attribution flakiness; all
  line refs above are grep-anchored on live files). Re-verify WIN01/WIN05 line
  drift if files move.
- `dev/audit-v7/` already holds A-whole-codebase.md and config-audit.md; this
  report is a NEW file there (window-simplification-audit-v8.md). If a
  different canonical report name exists, rename only this file.

## Prior-done items NOT re-reported (explicitly)
- FULL-01 fullscreen restructure and Store.click/`coveringOccupantOnWs` single
  scan (v6 §C/Phases).
- MOD-12 sync `Store` alignment, `Store.indexOf` rename, `Store.clear` delete
  (v6).
- PIP-02 `pipeline.FullscreenKind` enum for enter/exit/switch_ (v6 id 22).
- extractFieldPair use-after-return fix + strict `+`/weights grammar (v6 8, §C).
- warnOnce in window.zig (partially done per v6 §C 7 "ledger_overflow").
