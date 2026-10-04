# Tiling subsystem review (`src/tiling/**`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `tiling/tiling.zig` (500 lines) — layout dispatch + geometry kernel  **★**
**Now:**
```
View = { screen rect, focused, windows: []WindowId, params }
List = { slots: []Rect }                     // computed geometry
applyHints(rect, SizeHints) -> Rect          // pure: honor min/max/inc hints
focusedElse(view, fallback) -> ?WindowId
layoutByName(name) -> ?u8                    // registry lookup
layoutKindFallingBack(name, fallback) -> u8
moduleName(kind) -> []const u8               // registry metadata
variantCount(kind) -> u8
cycleKind(cur, dir, names) -> u8             // wrap-around registry cycle
compute(kind, view, out) -> List             // dispatch to module.compute
variantParse(variants) -> fn(str) -> ?u8     // comptime-generated parser
variantIndex(variants, vname) -> u8
layoutModule(kind) -> ?*const Layout         // registry access
```
**Verdict:** ★ — the registry indirection is the whole plugin contract: `compute` is a one-line dispatch, `variantParse` is comptime-generated per module, and `applyHints` is pure (size-hint respect is testable without X).
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/master.zig`
**Now:**
```
compute(view, out):
  n_master = params.master_count
  master area = left (or per params) fraction primary_width
  stack area = remainder, split among stack windows
  emit Rect per window (master first, then stack)
```
**Verdict:** ★ — pure function of `(view, params)`; no state, no X11; the master/stack split is the canonical layout shape.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/monocle.zig`
**Now:**
```
compute(view, out):
  every window gets the full view rect (minus gaps/borders)
  (stacking order decides visibility; off-screen parks handled by reconciler)
```
**Verdict:** ★ — the degenerate layout is correctly a full-rect emission; the "background windows are off-screen" behavior lives in the reconciler's park path, not here.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/grid.zig`
**Now:**
```
compute(view, out):
  cols = ceil(sqrt(n)); rows = ceil(n / cols)
  cell = view / (cols, rows); emit per-window cell rects
```
**Verdict:** ★ — pure; the ceil-sqrt grid is the standard heuristic and is deterministic.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/fibonacci.zig`
**Now:**
```
compute(view, out):
  split view recursively along the golden ratio,
  alternating axis per depth; emit one leaf rect per window
```
**Verdict:** ★ — pure; axis alternation keeps aspect ratios sane at depth.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/scroll.zig`
**Now:**
```
slotWidth(screen_w) -> i32          // one full-screen slot
maxOffset(n, slot_w, screen_w) -> i32
compute(view, out):
  windows laid out left-to-right in full-screen slots;
  viewport offset (params.scroll_offset) shifts the visible window
```
**Verdict:** ★ — the offset math (`maxOffset` clamps to the last full window) is pure and shared with the viewport-step action.
**Ideal:** unchanged. **Path:** none.

### `tiling/modules/leaf.zig`
**Now:** `compute(view, out)` — the single-window layout: focused window gets the full view.
**Verdict:** ★ — the identity layout; needed as registry index 0's fallback and as the degenerate case.
**Ideal:** unchanged. **Path:** none.

---

## Tiling subsystem summary

- 7 files, all ★ — the registry + pure `compute` contract is already the ideal shape: layouts are pure functions of `(view, params)`, metadata (name/icon/indicators/variant list) is declarative, and dispatch is one line.
- No refactor required. Adding a layout = one file with `pub const module: Layout` (see `dev/plugin-template/layout.zig`).
