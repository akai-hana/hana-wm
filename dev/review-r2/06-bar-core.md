# bar core review (round 2)

Fresh re-verification of every file directly under `src/bar/` against the
CURRENT tree; round-1 verdicts (`dev/review/06-bar-core.md`) are input,
not inherited. Since round 1 the four-way orchestrator split LANDED
(`center_row.zig` / `visibility_glue.zig` / `input_events.zig` /
`draw.zig` extracted; `bar.zig` 1683 lines) and `drawing.zig` was
decomposed internally (FontBook / Surface / TextRun carved out of the
monolithic DrawContext, 22.6/22.7). Verdict scale: **★ ideal** ·
**◐ near-ideal** · **△ restructure** · **▽ redesign**.

**Now** = high-level pseudo-code of current behavior · **Verdict** ·
**Ideal** = from-scratch pseudo-code or "unchanged" + delta · **Path** =
ordered, behavior-preserving refactor steps.

Constraints verified against the current tree:

- **Optionality.** The composition root is BUILD-GENERATED: `build.zig`
  emits a `surfaces` module whose body is
  `pub const Surfaces = if (build_options.has_bar) @import("bar").surfaces else .{ ...full no-op hook set... }`
  (build.zig:579). Core, input, pipeline, main consume only
  `@import("surfaces").Surfaces`; deleting `src/bar/` swaps in the no-op
  struct and the WM still compiles. The vtable BINDING lives at
  `bar.zig:1663` (`pub const surfaces = contract_x11.Surfaces{...}`) —
  not in `scaffold.zig` as the review brief had it — and the `Surfaces`
  TYPE lives in the X-aware contract half `contract_x11.zig` (the
  X-free `contract.zig` names no X type). Core never names bar code.
- **Wire policy.** Rule-1 allowlist (check-layers.sh:42) holds exactly
  `bar.zig|visibility_glue.zig|drawing.zig|win.zig`: bar self-management
  (map/unmap/configure/raise/flush), and `drawing.zig`'s `Surface`
  (create_pixmap/create_gc/change_gc/poly_fill_rectangle/copy_area — the
  off-screen drawable's writes). No other bar file sends wire traffic.
- **Loop.** Single-threaded; the draw path's ONE allocation is the
  deliberate per-run Pango layout (22.7), named under `drawing.zig`.

---

### `bar/bar.zig` (1683) — the orchestrator

**Now:**
```
registry: bar_mods (generated); comptime role sets (self_ticking_ids,
  center_slot_ids); title_id = FIRST center-slot binder
segId/segAt/segDirty/setSegDirty/roleIndexOf/isRole/selfTickerIndex
runVoidHook / anyBoolHook                          // uniform registry loops
probeMetrics/probeTextHeight/resolveBarMetrics     // live state -> metrics.resolve (pure)
onPollWakeup / pollTimeoutMs                       // timers.Source impl; hidden bar: no deadline
chromeHandleKeypress / chromeToggleOverlay         // keypress cast = the one X-event producer;
                                                   // overlay toggle = synthetic right-click on title
gBar { state, prompt_forced_visible }
WindowCtx{conn,win_id,colormap} / RenderCtx{dc,width,height,alloc}
state model — cross-frame: vis{shown,preferred}, dirty{flag, segments[bar_mods.len],
  span_x/span_w}, Facts{last-seen focus/window/layout/fullscreen revs},
  clock{width, segs[]}, title_data{minimized map, minimized_api};
  per-frame derived: frame, clicks, ticker scopes, title-snapshot bufs
RowSlot/RightCluster/RowPlan                       // solve vocabulary (20.1)
State: init/deinit; dirty bookkeeping (markDirty, clearSegmentDirty,
  extendDirtySpan, clearRegion, markDirtySource, isSegmentRepaintable,
  isFullDirty, pendingFullRedraw); layout probes (anyLayoutSegment,
  hasPendingRepaintWork, hasLayoutSegmentDirty); hit-test records
  (recordClickBound, recordedBound); measureSegmentWidth;
  recordSelfTickerScope; fillDrawCtx/scanLiveFrame/titleGeom;
  the paint pass (drawSegment, drawRowSegment, paintGap, drawAllInner,
  solveRowPlan, paintRowPlan, drawClockOnly, adoptFreshClockWidth)
createBar; init/deinit; warnUnknownSegments; reload/applyReload
minimizedCollect (collectHiddenSet seam adapter)
applyBarScreenPosition / toggleBarSegmentAnchor / isBarWindow
presentForPrompt / dismissAfterPrompt / setBarState
updateIfDirty (fullscreen-rev reaction; focus/window/layout rev diff
  -> dirty granularity; capped fold+redraw loop, max 4)
barModsConsumeRedrawRequest; updateClock (mode-cycle reflow path)
pub const surfaces = contract_x11.Surfaces{...}    // composition-root binding
```
**Verdict:** ★ — every remaining duty is the orchestrator's own. The
state model is minimal-stored/max-derived: only `vis`, `dirty`, `Facts`
revs and `clock.width` cross a frame; `frame`, `clicks`, the title
snapshot and the ticker scopes are re-derived per frame, with `last_ctx`
the single guarded derived cache (the marquee fast path in `draw.zig`).
The paint pass correctly STAYS on State: its invariant — clear the
segment's region, draw, record the click bound and ticker scope at the
position actually painted, extend the dirty span by the painted width,
clear the dirty bit — is one atomic unit per segment; a `paint.zig`
would fracture it across a module boundary for no gain. No segment is
named anywhere; wire traffic is exactly the allowlisted bar
self-management. At 1683 lines the file sits at the ceiling of one
orchestrator, but nothing in it is misplaced. Two trivial wobble points:
the `segId`/`hasRegisteredSegments` pair is duplicated verbatim in
`center_row.zig`, and `solveRowPlan` carries a dead `is_full_redraw`
parameter (`_ = is_full_redraw` at :1066, a 20.1 leftover).
**Ideal:** unchanged + two deltas: (1) hoist the `segId`/
`hasRegisteredSegments` pair into `segment.zig` as
`segmod.segIdOf(&bar_mods, name)` / `segmod.hasSegments(&bar_mods)` (the
`findAllByCapability` pattern already parameterizes the registry, so the
helpers are one generalization away); (2) drop `solveRowPlan`'s dead
parameter.
**Path:** (1) add the two helpers to `segment.zig`; (2) replace the
`bar.zig` and `center_row.zig` copies; (3) delete `solveRowPlan`'s
`is_full_redraw` parameter, its `_ =` line, and the argument at the
`drawAllInner` call site.

### `bar/drawing.zig` (1293) — Cairo/Pango rendering

**Now:**
```
clockFormat(config)                        // 3-line config accessor
C-ABI block (~185 lines): cairo/pango/glib pub extern fn decls,
  opaque types, ABI enums, the PangoAttribute layout (22.1)
firstVisualOfDepth/findVisualByDepth       // X visual selection (shared: win.zig + Surface.init)
TextRun{layout, attrs, sized_font; measure, deinit}   // one-shot Pango run (22.7)
FontBook{pango_layout, current_font_desc, cached_metrics,
  sized_desc/sized_px cache, layout_font;
  loadFonts/loadFont, invalidateSized, sizedDesc, getMetrics,
  measureTextWidth, beginRun, initBook, probe}  // the font-lifecycle owner (22.6)
Surface{conn,window,pixmap,w,h,cairo_surface,ctx,gc,copy_gc,
  is_argb,alpha_u8,last_color,last_gc_color,xcb_filled_this_frame;
  init/deinit, setColor, fillRect, blitImpl}    // X drawable owner + paint-order rule
                                                 // (22.5: XCB fills ordered before cairo
                                                 //  glyphs, enforced by the one-shot quiesce)
unit conversions (setCairoColor, pangoToF64, pxToPango, ...)
ValueRange/valueRange/foregroundAttr/buildStyleAttrs   // styled-span vocabulary (22.1/25.3)
DrawContext{fonts: FontBook, surface: Surface;
  initWithVisual/deinit, paintRun, drawTextSized, drawText,
  drawTextScrolled, drawTextEllipsis, drawTextImpl, drawTextStyled,
  baselineY, paintedSegment; facade forwarders (fillRect,
  measureTextWidth(Styled), metrics); queueBlit/blitRegion}
drawPaddedSegment / drawPaddedSegmentValue   // config-aware segment shell (one Pango pass)
FontMetrics/probeFontMetrics; SizedFontList{build,deinit}; loadBarFonts
createPangoLayout; resolveVisualType; convertFontName (Xft -> Pango)
```
**Verdict:** ◐ — the internal decomposition is principled: FontBook owns
the font lifecycle, Surface owns the X drawable and the subtle
paint-order rule (22.5, now structural — the one-shot quiesce instead of
six modules' call order), TextRun makes a text run an immutable value
(the 22.7 fix), and DrawContext is a clean facade composing the two.
Three things keep it off ideal: (a) the ~185-line hand-written extern
block crowds the head of the file — it is ABI vocabulary, not rendering,
and the tree has the leaf-bindings precedent (`core/x11/xcb.zig`);
(b) `SizedFontList.build` reads `core.getState().config.bar.fonts` — the
one hidden global read in an otherwise value-oriented API (both callers
already hold the list's source); (c) the per-run Pango layout is the draw
path's one deliberate allocation (one layout + attr list per drawn text
run per frame) — a correctness-first trade that eliminated the
shared-mutable-layout bug class, named here as a known cost against the
"allocate nothing hot" constraint, not a tangle. Round-1's four-way file
split is NO LONGER the right shape: the `drawText` family are
`DrawContext` methods, so a `text.zig` would have to reshape the facade
into free functions, and `DrawContext = FontBook + Surface` is a
composition, not a layer — the facade file is the natural home.
**Ideal:**
```
bar/c.zig       — the cairo/pango/glib externs + opaque types + ABI enums
                   (~185 lines; the ABI vocabulary, a leaf like core/x11/xcb.zig)
bar/drawing.zig — FontBook/TextRun/SizedFontList (fonts), Surface (X drawable
                   + paint-order rule), ValueRange/attrs, the DrawContext facade
                   + drawText family, drawPaddedSegment(Value), probe/loadBarFonts,
                   convertFontName — with SizedFontList.build(fonts, font_size)
                   taking the list as a parameter (no global read)
findVisualByDepth/firstVisualOfDepth/resolveVisualType stay: shared X-visual
                   vocabulary used by BOTH window creation (win.zig) and
                   surface creation (Surface.init)
```
**Path:** (1) move the C-ABI block to `bar/c.zig` (`drawing.zig`
re-imports it; zero API change); (2) thread the font list into
`SizedFontList.build` from its two callers (`probeMetrics`,
`loadBarFonts`) and drop the `core.getState()` read; (3) optional: move
`clockFormat` beside the clock segment (3 lines of config vocabulary) —
skip if the churn is not worth it.

### `bar/scaffold.zig` (276) — segment width machinery + binder

**Now:**
```
widthState(tag): per-module comptime state {cached width, redraw_pending}
  consumeRedrawRequest / store (diff -> request) / naturalWidth /
  resolved (never reserve 0 for an unpainted segment) / measured
keyedWidthState(tag, Key): {cached, cached_key}; matches/store/
  naturalWidth(key, fallback)/invalidate        // the clock's mode reservation
finishDraw(seg, painted) -> bool                // post-draw policy as a PURE fn (21.7)
drawAndStore(name, ...) -> Painted.span         // padded draw; empty text = 0-width success
SlotMode {measured_relayout, measured_no_relayout, fixed, self_measured}
Opts{...}; drawHook/clickHook/passthroughWidth adapters
module(name, draw, action, opts) -> contract.Segment   // the binder
```
**Verdict:** ★ — the width-state machine (measured vs resolved vs
natural, with the never-reserve-0-for-unpainted rule) is the bar's
layout contract, isolated and shared by every icon-ish segment through
`module()`; `SlotMode` enumerates the real width lifecycles instead of
two overlapping bools (21.8), and `finishDraw` as a pure function makes
the post-draw width-report policy testable without a live DrawContext or
X connection.
**Ideal:** unchanged. **Path:** none.

### `bar/segment.zig` (229) — shared segment vocabulary

**Now:**
```
BarHandlers{presentForPrompt, dismissAfterPrompt, isBarWindow}  // one-way services
Frame = contract.Frame alias; MinimizedApi{collect}  // type-free collect seam
castDraw; DrawCtx{dc,config,height,conn,allocator,width,name,
  minimized_api,frame, title snapshot slots;
  titleRenderContext, titleSnapshot}
title_min_width; max_visible_windows; offscreen_rect
TitleRenderContext; TitleSnapshot
DirtySourcesSource/hasSource; idByName;
findAllByCapability(modules, comptime field) -> []usize
```
**Verdict:** ★ — the vocabulary every segment and the orchestrator
import; capability queries (`findAllByCapability`, comptime over the
generated registry) are how the bar discovers roles without naming
modules, and the comptime-returned slice lets empty-set guards
dead-code-eliminate. The title snapshot/render types live here because
the bar (filler) and the title segment (consumer) both need them and
neither may import the other — the one correct home; the title's
geometry itself correctly stays in `modules/title/geom.zig` (21.6).
**Ideal:** unchanged + delta: receives the hoisted `segIdOf`/
`hasSegments` registry helpers (the `bar.zig` delta), generalizing
`idByName`.
**Path:** (1) receive the helpers; (2) no other change.

### `bar/win.zig` (201) — X window lifecycle

**Now:**
```
BarAtoms{strut_partial, window_type(+dock), wm_state, state_above,
  state_sticky, allowed_actions, action_close/above/stick}
initAtoms()                                    // resolved once, module-owned cache
calcBarYPos(position, screen_h, height) -> i16 // PURE, all inputs as values (20.4)
BarWindowSetup{win_id, visual_id, has_argb, colormap}
setAtomProperty; setWindowProperties(win, height)
  // strut + type=dock + state(above,sticky) + actions, batched
freeColormap; destroyBarWindow(conn, win, cmap)  // one teardown, both halves
createBarWindow(height, y_pos, want_transparency)
  // visual/depth/colormap/CW selection from the ONE transparency value
createDrawContext(setup, height, font_size)    // DrawContext + loadBarFonts
```
**Verdict:** ★ — X window lifecycle isolated; the EWMH/dock property
batch means setup is one round trip; every decision input (transparency,
position, font size) is a parameter rather than a global read
(20.4/21.5), so the window's visual/depth/colormap all derive from one
caller-supplied value. Wire traffic is the allowlisted bar
self-management.
**Ideal:** unchanged. **Path:** none.

### `bar/draw.zig` (199) — draw submission

**Now:**
```
frameCtx(s) -> DrawCtx skeleton (dc/config/height/conn/alloc, empty frame)
performDraw():
    hidden -> return; fold queued module redraw request;
    no whole-bar work AND no pendingRepaint -> return;
    FAST PATH (marquee-only: !dirty && ctx_valid && no layout-segment
      dirty bit): reuse the cached last_ctx snapshot, paint, blit the
      span, return                      // skips scan+fill per marquee tick
    scanLiveFrame; fillDrawCtx; drawAllInner;
    cache minimized_api + last_ctx (ctx_valid = true);
    queueBlit(span)                     // no flush: caller's batch owns it
    clear the whole-bar flag
submitDrawBlockingFull; requestFullRedraw; foldModuleRedraw
redrawInsideGrab                          // grab-safe: queueBlit, no flush
redrawSegmentScoped / redrawSlotScoped
  // clear the reserved slot, draw, blit max(bound_w, drawn_w)
  // (digit-width drift can overrun the reservation)
redrawScopedSegment                     // drag/scroll target dispatch
```
**Verdict:** ★ — the seam is named and honored: this file decides WHEN
to paint and WHAT to blit; the paint pass stays on `State`. The marquee
fast path is the subsystem's one subtle optimization and its guard is
exact (a needsRepaint-only wake cannot have stale frame facts, because
any fact change sets a dirty bit via markDirty/markDirtySource); the
scoped-repaint skeleton (clear-slot → draw → blit the union of reserved
and painted width) is the drag/scroll performance contract. The
runtime-only import cycle with `bar.zig` is documented and honest.
**Ideal:** unchanged. **Path:** none.

### `bar/input_events.zig` (187) — input intake

**Now:**
```
titleIdBound(s) -> ?SegBound         // first center-slot binder's recorded bound
dispatchClick(s, id, offset, is_left, is_right)   // -> onClick hook (ClickCtx)
handleExpose                          // count==0 on the bar window; during a drag
                                      // defers via dirty.flag (the batch repaints),
                                      // else performs the draw directly
handleButtonPress                    // hit-test RECORDED bounds (first match):
  left -> arm drag_segment + click; right -> click;
  4/5 -> onScroll(dir, redrawScopedSegment) under a scroll_segment pin
handleButtonMotion                   // drag_segment's onDragMotion(offset, redrawScopedSegment)
handleButtonRelease                  // drag_segment's onDragEnd(redrawInsideGrab)
handleTitleClick(offset)             // title_geom.hitTest -> focus / minimize / restore
titleClickTrampoline                 // *anyopaque adapter
```
**Verdict:** ★ — thin intake: the hit-test reads the bounds the last
layout pass recorded (never re-derives geometry), then delegates to the
registry's uniform hooks; no wire mutation, so correctly absent from the
allowlist. The drag/scroll segment pins are orchestrator state written
here and consumed by `draw.zig`'s scoped repaints — the cross-file
coupling is explicit, one-directional, and documented. One nit: the
expose handler's direct `s.dirty.flag` write (:65) is the only
extracted-file poke at an orchestrator field that has no method; it is
deliberate (during a drag the expose defers to the batch rather than
fighting the drag's region-scoped repaints), but a named
`deferRedraw()` on State would say so better.
**Ideal:** unchanged. **Path:** none.

### `bar/visibility_glue.zig` (166) — visibility wire glue

**Now:**
```
syncScreenClaim()                    // publish height@edge (or 0 when hidden) to usable_area
raiseBar()                           // stack-mode-above configure
applyVisibility(s, should, do_reconcile):
    vis.shown = should
    syncScreenClaim()                // BEFORE grabScoped (its ctx snapshots workArea)
    grab = do_reconcile ? grabScoped() : null
    map / unmap                      // map BEFORE draw (blit to unmapped is discarded)
    if shown: runVoidHook(.onBarShown);
       do_reconcile ? submitDrawBlockingFull()   // inside the grab: one flush
                                                : requestFullRedraw()  // caller's batch repaints
    if grab: reconcileNow(); if shown: raiseBar()  // raise LAST, same flush
updateBarVisibilityForWorkspace(ws) -> applyVisibilityDecision(ws, false)
hideBarForFullscreen()               // applyVisibility(s, false, false); idempotent
applyFullscreenVisibility()          // applyVisibilityDecision(current_ws, true)
applyVisibilityDecision(ws, do_reconcile):
    desiredVisibility(model, ws, preferred) vs vis.shown -> apply + log reason
```
**Verdict:** ★ — the policy/wire partition is exact: `visibility.zig`
decides, this file owns ordering, and every ordering constraint that was
once a comment-shaped hope (claim-before-grab-snapshot, map-before-draw,
raise-last-inside-the-flush) is now structural inside one function with
the rationale inline. The two flavors (workspace-switch: no reconcile,
the caller owns it; fullscreen-fact reaction: reconcile inside the grab)
are one boolean apart, and the decision comparator
(`decision.should_be_visible == s.vis.shown`) correctly lives here, not
in the pure policy.
**Ideal:** unchanged. **Path:** none.

### `bar/center_row.zig` (136) — center-row math

**Now:**
```
center_slot_ids / self_ticking_ids          // comptime capability sets
segId / hasRegisteredSegments / isCenterSlot // registry helpers (duplicated from bar.zig)
centerShare(remaining, count, idx)          // even split, remainder to the leftmost
naturalWidthOf(name, frame, clock_width)
centerRowBudget(lay, avail, spacing, frame, clock_width)
  -> {remaining, center_count}              // reserves the row's own non-center segments first
mergedClockWidth(ctx, config, height, measure)
  // max over self-tickers of measure(measureString()) + 2*padding
```
**Verdict:** ★ — pure over injected seams (the `metrics.zig` pattern):
the frame and the clock width arrive as values, the string-width probe is
a function parameter, so the share/budget/merged-clock derivations are
unit-tested without Pango or a live bar (`center_row_test.zig` pins the
remainder rule, the budget clamp/floor, the merged-clock walk). The only
impure input is the comptime registry read, which is the generated table
itself.
**Ideal:** unchanged + delta: drop the duplicated `segId`/
`hasRegisteredSegments` pair for the shared `segmod` helpers.
**Path:** (1) receive the shared helpers (the `bar.zig` delta);
(2) delete the local copies.

### `bar/metrics.zig` (117) — derived bar metrics

**Now:**
```
Inputs{font_size, height?, screen_height}   // plain value, no getState()
Probe = *const fn (trial_pt) -> ?u32        // the only impure input, injected
Metrics{font_size, height}                  // an immutable value
resolve(in, probe) -> Metrics:
    configured height -> scaled into policy range, FINAL (fonts cannot change it)
    % font size -> refined against that height (percentageOf: px-per-pt ratio
      from a fixed 100pt trial, clamped before the u16 cast)
    no height -> fonts decide (ascent+descent at the DPI-scaled base),
      policy default when the probe fails
default_fallback_font (monospace@10, agreeing with the probe's default size)
```
**Verdict:** ★ — exemplary and re-verified: derived values as an
immutable struct, the single impure input injected, no global, no
save/restore across reloads (a failed reload cannot leave a wrong font
size because the size was never process state). This is the pattern
`center_row.zig` and `visibility.zig` follow.
**Ideal:** unchanged. **Path:** none.

### `bar/visibility.zig` (89) — visibility policy

**Now:**
```
barForcedHiddenByFullscreen(m, ws) -> bool   // comptime-folded w/o the fullscreen module
shouldBeVisible(global, forced_hidden) -> bool
desiredVisibility(m, ws, global) -> {should_be_visible, reason}
  // reason: user_and_workspace | user_hidden | fullscreen_claims_screen
keepPromptOverride(m, ws, global) -> bool    // dismissAfterPrompt's recomputation
```
**Verdict:** ★ — exemplary partition, re-verified: pure policy over a
model PARAMETER (zero pipeline import, so a decision can never be
computed against a model the caller is not about to act on), zero X11,
and `is_visible` deliberately NOT a parameter — the policy states the
target and why, the orchestrator owns the mapped-state comparison.
**Ideal:** unchanged. **Path:** none.

### `bar/meter.zig` (60) — linear meter mapping

**Now:**
```
pctFromSlot(slot_x, slot_w, offset) -> u8    // saturating both ends; denominator clamped to 1
offsetFromPct(slot_x, slot_w, pct) -> u16    // nearest-rounding; u32->u16 narrowing clamped
```
**Verdict:** ★ — pure, symmetric pair with both edge rules named
(zero-width slot, past-edge offset) and unit-tested (`meter_test.zig`);
the dead-clamp removal in `offsetFromPct` is exactly the kind of
reasoned simplification this tree rewards.
**Ideal:** unchanged. **Path:** none.

---

## Bar core summary (round 2)

| file | verdict | one-line ideal delta |
|---|---|---|
| `bar.zig` (1683) | ★ | hoist the `segId`/`hasRegisteredSegments` pair (duplicated in `center_row.zig`) into `segment.zig`; drop `solveRowPlan`'s dead parameter |
| `drawing.zig` (1293) | ◐ | extract the ~185-line C-ABI block to a leaf `bar/c.zig` (the `core/x11/xcb.zig` precedent); `SizedFontList.build` takes the font list as a parameter (drops its `core.getState()` read) |
| `scaffold.zig` (276) | ★ | none |
| `segment.zig` (229) | ★ | none (receives the registry-helper hoist) |
| `win.zig` (201) | ★ | none |
| `draw.zig` (199) | ★ | none |
| `input_events.zig` (187) | ★ | none |
| `visibility_glue.zig` (166) | ★ | none |
| `center_row.zig` (136) | ★ | receive the shared registry helpers (drop the local copies) |
| `metrics.zig` (117) | ★ | none |
| `visibility.zig` (89) | ★ | none |
| `meter.zig` (60) | ★ | none |

- 12 files: **11 ★, 1 ◐, 0 △, 0 ▽**. Round 1's one ◐ (`drawing.zig`,
  "optional four-way split") is re-judged against the current tree: the
  decomposition LANDED INTERNAL (FontBook/Surface/TextRun/DrawContext
  facade, 22.6/22.7), which is the right shape; a further file split is
  no longer mechanical because the `drawText` family are `DrawContext`
  methods, so the remaining deltas are the bindings extraction and the
  one global read.
- The round-1 four-way orchestrator split is verified correct: each
  extracted file holds exactly one concern (submission / intake / wire /
  pure math), each import cycle is runtime-only, and the paint pass
  correctly stayed on `State` because its per-segment
  paint+bookkeeping invariant is atomic.
- `metrics.zig` / `visibility.zig` / `center_row.zig` remain the
  reference pattern for the codebase: derived values as structs, impure
  inputs injected, policy/wire split.

**Top findings:**
1. `drawing.zig` (◐) — the only file off ideal: ~185 lines of
   hand-written cairo/pango/glib externs inline (the tree already has
   the leaf-bindings precedent in `core/x11/xcb.zig`), plus
   `SizedFontList.build`'s hidden `core.getState()` read breaking an
   otherwise value-oriented API.
2. `bar.zig` (★) — the orchestrator is cohesive post-split; its only
   wobble is the ~20-line registry-helper duplication with
   `center_row.zig`, which the `segmod` parameterization pattern already
   solves (plus a dead `solveRowPlan` parameter, a 20.1 leftover).
3. The state model is minimal-stored/max-derived — only `vis`, `dirty`,
   `Facts` revs and `clock.width` cross a frame; `last_ctx` is the
   single guarded derived cache and its fast-path guard (`!dirty &&
   ctx_valid && !hasLayoutSegmentDirty`) is exact.
4. `drawing.zig`'s per-run Pango layouts (22.7) are the draw path's one
   deliberate allocation (one layout + attr list per text run per frame)
   — a correctness-first trade that eliminated the shared-mutable-layout
   bug class; named as a known cost against the "allocate nothing hot"
   constraint, not a tangle.
5. Cross-cutting (the only one): the registry-helper hoist touches
   `bar.zig` + `center_row.zig` + `segment.zig` — three files, one
   pattern, no behavior change.
