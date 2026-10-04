# tiling review (round 2)

Re-verify of `src/tiling/**` against the CURRENT tree (fresh, not
inherited from `dev/review/04-tiling.md`). Since round 1 the
subsystem gained the 14.9 order-guarantee engine (`emitInOrder`: a
module's scratch output is re-emitted in `View.order` position, so a
layout can no longer hand window N's rect to window M), the
`layoutModule` comptime assembler (variant metadata derived from one
`Variant` table instead of four hand-maintained parallel lists), and
the contract-located interchange vocabulary (`View`/`List`/`HintsView`/
`Env` live on `contract.zig`, so the always-compiled reconciler names
them with no edge into the engine). Verdict scale: **★ ideal** ·
**◐ near-ideal** · **△ restructure** · **▽ redesign**.

**Now** = high-level pseudo-code of current behavior · **Verdict** ·
**Ideal** = from-scratch pseudo-code · **Path** = ordered,
behavior-preserving refactor steps.

Constraints verified honored: `tiling/` is xcb-free (check-layers.sh
Rule 3 sweeps `src/tiling` after comment stripping — clean); the pure
model (`core/architecture/model.zig`) is the source of truth; core
never names a layout (dispatch is the build-generated `tiling_modules`
registry consumed through `contract.Layout`); layout math is pure and
unit-tested (`src/test/engine/tiling_test.zig`, 20 tests incl. the
14.9 placement-invariant sweep at every size). Adding a layout = one
file under `tiling/modules/` with `pub const module`
(`dev/plugin-template/layout.zig`).

---

### `tiling/tiling.zig` (503) — dispatch engine + geometry kernel  **★**

**Now:**
```
applyHints(rect, SizeHints) -> Rect        // pure ICCCM 4.1.2.3: inc-snap,
                                           //   max-clamp, aspect clamp (both-or-
                                           //   neither), centre, floor-at-1
LayoutCtx = { v, out, m, min_dim }         // env margins + min_dim copied in
geometry kernel: focusedElse, totalInset, seamGap, shrinkClamped,
                 insetRect, Region, outerArea, bisectRegion, waY, cellStride
emitters: appendPlacement (cap-safe skip), emitView (hints applied),
          emitRect, emitHidden (parked_rect), emitOverflowShare
          // "region too small": focused window inset, park the rest
registry (contract re-export): tiling_mods; comptime assert len <= 255
layoutByName(name) -> ?u8                  // case-insensitive registry scan
layoutKindFallingBack(name, fb) -> u8      // warns on unresolvable name
moduleName / variantCount                  // bounds-checked via contract.moduleOf
cycleKind(cur, dir, names) -> u8           // config-order ring, modulo wrap
compute(kind, v, out):                     // clear; moduleOf; scratch <- f(v);
                                           //   emitInOrder(scratch -> out);
                                           //   assert len==order.len && per-index win
emitInOrder: fast path (already ordered: compare + copy) else
             per-position lookup with `taken` dedup + placeholder
variant machinery (comptime): Variant{name, indicator, fifo},
  variantParse, variantIndicators, variantFifo,
  variantIndex (compileError on miss), layoutModule(name, icon, f, variants, extra)
  // derives variant_count / variant_parse / indicators / fifo_variant FROM the table
```
**Verdict:** ★ — the registry indirection is the whole plugin contract
(one-line dispatch, bounds-checked through `contract.moduleOf`), the
variant machinery is comptime and single-sourced, and the 14.9
`emitInOrder` engine is a genuine safety innovation: the sink consumes
`out` positionally, so a module that emits out of order (master's old
column-major overflow reorder) can no longer silently hand a window
another window's rect. Two nits, neither structural: (1) `LayoutCtx`
is unevenly adopted — master and leaf read `ctx.m`/`ctx.min_dim`
throughout, fibonacci reads `ctx.m` but falls back to
`ctx.v.env.min_dim` in `splitAndAdvance`, and scroll/grid/monocle read
`v.env` directly — so the helper's "one home for the env facts"
contract is realized by 2 of 6 modules; (2) the registry's comptime
assert checks `len <= 255` but not `compute != null`, so a module
binding `Layout` with a null `compute` compiles and silently no-ops in
ReleaseFast (Debug's length assert catches it).
**Ideal:** unchanged + delta:
```
// comptime, in the existing registry assert block:
for (tiling_mods) |m| if (m.compute == null) @compileError(
    "layout module '" ++ m.name ++ "' binds no compute hook");
// (and pick one env-access convention for all six modules — adopting
//  ctx everywhere is the smaller diff: scroll/grid/monocle swap
//  v.env.margins/min_dim for ctx.m/ctx.min_dim, fibonacci's
//  splitAndAdvance reads ctx.min_dim instead of ctx.v.env.min_dim)
```
**Path:** (1) add the `compute != null` comptime assert (one loop in
the existing `comptime` block); (2) adopt `LayoutCtx` uniformly in
scroll/grid/monocle/fibonacci. No behavior change; both are
compile-time only.

### `tiling/modules/master.zig` (337) — master-stack + overflow grid  **★**

**Now:**
```
compute(v, out):
  master_n = clamp(primary_count, 1, n); stack = windows[master_n..]
  master_w = round(screen_w * primary_width) (full width when no stack)
  stack_w  = min(stack_pane_w, minStackWidth)   // widest bounded slave
  tileColumn(windows[0..master_n], master_x, ...)       // water-fill heights
  tileStack(stack, ...):                                 // single column, or
    tileStackExtra: column-major overflow grid, park surplus
fillHeights: pin windows whose max_height <= fair share, redistribute;
             zero-boost = even split (<=1px diff), boost = cumulative-round
minStackWidth: widest max_width slave + seam margins
```
**Verdict:** ★ — pure function of `(view, params, hints)`; the
water-filling height distribution (pin-and-redistribute with three
deliberately-distinct rounding schemes) is the most complex layout math
in the tree and it is factored (`tileColumn`/`fillHeights`/
`tileStack`/`tileStackExtra`) and documented; no state, no X11, no
registry access — consumes only the published `View` contract and the
engine's placement machinery, so it is self-contained and removable.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/scroll.zig` (116) — half-screen slot strip  **★**

**Now:**
```
slotWidth(screen_w) = screen_w / 2
maxOffset(n, slot_w, screen_w) = max(0, n*slot_w - screen_w)
compute(v, out): scroll = clampOffset(viewport_offset, n, screen_w);
  per window i: slot_left = i*slot_w - scroll; edge gap full / seam
  half; park slots entirely off-viewport (x >= screen_w or right <= 0)
clampOffset = max(0, min(offset, maxOffset))     // THE clamp (14.7)
preReconcileHook(params, n, wa_w):               // value-in, value-out
  if n > prev_count: offset = max_off; clamp; prev_count = n
```
**Verdict:** ★ — the slot geometry is single-sourced (`slotWidth` feeds
`maxOffset`, `compute`, and `preReconcileHook`), the clamp is one
function shared by the layout and the grow duty (the two used to spell
it differently — 14.7), and the pre-reconcile hook is pure
value-in/value-out with no mutable pointer into the model. The only
module binding the viewport-addon hooks (`slotWidth`/`maxOffset`/
`preReconcile`), which is the documented "is a scroll layout" test —
no name matching anywhere.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/fibonacci.zig` (114) — clockwise spiral  **★**

**Now:**
```
SpiralDirection = enum(u2){ right, down, left, up }  // +%1 wraps
  step -> {split_x, forward}
compute(v, out): outer = outerArea(workarea, gap); cur = outer;
  per window i: if last or cur too small (w/h < 2*gap + 2*border):
    emitOverflowShare(windows[i..], cur); return
  splitAndAdvance(win, dir, &cur); dir = dir.next()
splitAndAdvance: win_dim = bisectRegion(dim, gap).first; forward places
  at the leading edge, backward keeps origin; emitRect; advance origin
  + shrink remainder along the split axis
```
**Verdict:** ★ — pure; the spiral state is a 2-bit enum with a steps
table (no per-window allocation, no recursion depth risk), the terminal
case delegates to the shared `emitOverflowShare`, and the border
subtraction goes through `shrinkClamped` (14.6) so a degenerate split
floors at `min_dim` instead of emitting a zero-area rect. Self-contained
(imports only `model` + `tiling`).
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/grid.zig` (81) — ceil-sqrt cells  **★**

**Now:**
```
calcGridShape(n): n==3 -> 3x1; else cols = ceil(sqrt(n)), rows = ceil(n/cols)
paneCell(total, count, gap) = (total - (count+1)*gap) / count
compute(v, out): cell_w/h = paneCell(screen, shape, gap);
  relaxed variant: partial last row shares full width;
  per window: col = i % cols, row = i / cols; emitRect at the stride
```
**Verdict:** ★ — pure; the ceil-sqrt shape (with the documented n==3
special case) is deterministic, and the relaxed variant's partial-row
handling spaces by the wider partial cell so relaxed cells cannot
overlap. The variant ordinal is read from the table via `variantIndex`
(compile-checked), not a hand-numbered constant.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/leaf.zig` (67) — BSP bisection  **★**

**Now:**
```
compute(v, out): area = outerArea(workarea, gap); tileRegion(order, area)
tileRegion(windows, r):
  n==1: emitView(insetRect(r, doubledBorder))          // leaf: border only
  if dim < 2*min_dim + gap: emitOverflowShare(windows, r); return
  split = bisectRegion(dim, gap); recurse into the two halves
  (longer axis, ties vertical)
```
**Verdict:** ★ — pure; the recursion is the canonical BSP shape, the
"can't hold two min-dim children" gate is a `min_dim` floor (unlike
fibonacci's gap+border gate — the difference is documented at both
sites), and overflow delegates to the shared `emitOverflowShare`.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/monocle.zig` (43) — full-screen stack  **★**

**Now:**
```
compute(v, out): inset = gaps-variant ? gap : 0;
  top_win = focusedElse(v, order, order[len-1])   // tail fallback:
                                                  // last-focused resurfaces on close
  top_rect = insetRect(inset, waY+inset, w, h, totalInset, min_dim)
  per window in order: top_win -> emitView(top_rect), else emitHidden
```
**Verdict:** ★ — the degenerate layout is correctly one in-order pass
(the previous shape emitted `top_win` first regardless of its position
in `v.order`, which broke the positional sink contract — now impossible
via the engine's `emitInOrder`); the tail fallback is the right
"resurface on close" policy and the variant is table-driven.
**Ideal:** unchanged. **Path:** none.

---

## Tiling subsystem summary

Seven files, all ★. The registry + pure-`compute` contract is the
ideal plugin shape and it hardened further since round 1: the 14.9
`emitInOrder` engine makes the positional sink contract structural (a
layout can no longer reorder or drop a window without tripping a Debug
assert), and `layoutModule` single-sources variant metadata so the four
derived fields cannot drift. No module leaks tiling-internal knowledge —
each consumes only the published `View` contract and the engine's
placement helpers, holds no state, names no other layout, and touches
no registry. The only available deltas are the two compile-time nits on
`tiling.zig` (the `compute != null` registry assert and the `LayoutCtx`
half-adoption); neither is a runtime or behavior issue.

| file | verdict | one-line ideal delta |
| --- | --- | --- |
| `tiling/tiling.zig` | ★ | comptime-assert every registry entry binds `compute`; adopt `LayoutCtx` (or `v.env`) uniformly in all six modules |
| `tiling/modules/master.zig` | ★ | unchanged |
| `tiling/modules/scroll.zig` | ★ | unchanged |
| `tiling/modules/fibonacci.zig` | ★ | unchanged |
| `tiling/modules/grid.zig` | ★ | unchanged |
| `tiling/modules/leaf.zig` | ★ | unchanged |
| `tiling/modules/monocle.zig` | ★ | unchanged |
