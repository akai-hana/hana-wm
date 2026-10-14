# Bar core review (`src/bar/*.zig`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `bar/bar.zig` (1683 lines) — the orchestrator  **★ (four-way split complete: center_row / visibility_glue / input_events / draw extracted)**
**Now:**
```
State = { win, draw ctx, metrics, config, segment bounds[],
          dirty set (registry-sized bools), full-redraw flag,
          visibility level, prompt override, ... }
Registry-resolved roles (comptime): title_id (first center-slot
  binder), self_ticking_ids, center_slot_ids
roleIndexOf/isRole/selfTickerIndex
centerShare / centerRowBudget / mergedClockWidth   // center-row layout math
runVoidHook / anyBoolHook                          // uniform registry loops
probeMetrics / resolveBarMetrics / probeTextHeight
onPollWakeup / pollTimeoutMs                       // timers.Source impl
chromeHandleKeypress / chromeToggleOverlay
dispatchClick(s, id, offset, ...)                  // hit-test -> segment onClick
titleIdBound
frameCtx / performDraw / submitDrawBlockingFull / requestFullRedraw
createBar / init / deinit / reload / applyReload
warnUnknownSegments
minimizedCollect (via collectHiddenSet seam)
applyBarScreenPosition / toggleBarSegmentAnchor / isBarWindow
syncScreenClaim (workarea strut)
redrawInsideGrab / redrawSegmentScoped / redrawSlotScoped / redrawScopedSegment
raiseBar / presentForPrompt / dismissAfterPrompt / setBarState
applyVisibility / updateBarVisibilityForWorkspace / hideBarForFullscreen /
  applyFullscreenVisibility / applyVisibilityDecision
updateIfDirty / barModsConsumeRedrawRequest / foldModuleRedraw
updateClock
handleExpose / handleButtonPress / handleButtonMotion / handleButtonRelease
handleTitleClick / titleClickTrampoline
```
**Verdict:** ★ — the orchestrator is correct in behavior (uniform loops over the registry, zero segment imports, dirty-set coalescing). The four extractable concerns are extracted (center-row math → `center_row.zig`, visibility glue → `visibility_glue.zig`, event intake → `input_events.zig`, draw submission → `draw.zig`); what remains is cohesive: `State` (dirty bookkeeping, frame scan, the paint pass), lifecycle/reload, and the registry loops.
**Ideal:**
```
bar/center_row.zig — center-row budget/share math (pure, unit-tested; named center_row because the `layout` stem is taken by the layout segment module)
bar/draw.zig      — performDraw / redraw*Scoped / blit submission
bar/center_row.zig — center-row math, DONE
bar/visibility_glue.zig — applyVisibility* family, DONE (wire side; policy stays in visibility.zig)
bar/input_events.zig — expose/button/motion/release handlers + click dispatch, DONE (named input_events: the `events` stem is taken by the core event loop)
bar/draw.zig — performDraw / redraw*Scoped / blit submission, DONE (the paint pass itself stays on State in bar.zig)
bar/bar.zig       — State, init/deinit/reload, poll hooks
```
**Path:** (1) ~~extract `layout.zig`~~ **DONE** as `center_row.zig` (136 lines): `centerShare`/`centerRowBudget`/`mergedClockWidth` moved verbatim except the impure inputs are now injected seams — the frame and merged clock width arrive as values, and the string-width probe (`DrawContext.measureTextWidth`) is a function parameter, the metrics.zig pattern; `center_row_test.zig` (114 lines) pins the share remainder rule, the budget clamp/floor, and the merged-clock max+2×padding walk; (2) ~~extract `visibility_glue.zig`~~ **DONE** (166 lines): the apply* family plus its direct dependencies (`syncScreenClaim`, `raiseBar`) moved verbatim; the host state (`State`, `gBar`) and the draw/dirty primitives (`runVoidHook`, `submitDrawBlockingFull`, `requestFullRedraw`) are exposed `pub` from `bar.zig`, and the two files form the bar subsystem's one intentional import cycle — every cross-reference is a runtime access, never comptime, so the lazy module analysis walks no cycle (the hub-and-spoke shape check-layers.sh already documents for core<->window); the Rule 1 wire allowlist gains `src/bar/visibility_glue.zig` next to `bar.zig` (the same bar self-management: map/unmap on visibility change, raise-above-others, screen-claim publish); (3) ~~extract `events.zig`~~ **DONE** as `input_events.zig` (187 lines): `handleExpose`/`handleButtonPress`/`handleButtonMotion`/`handleButtonRelease` plus the click machinery (`titleIdBound`, `dispatchClick`, `handleTitleClick`, `titleClickTrampoline`) moved verbatim; no direct wire mutations (hit-test reads recorded bounds, then delegates to the registry's onClick/onScroll/onDragMotion hooks and the window subsystem's focus/actions), so no allowlist change; the same runtime-only import cycle; `bar.zig` exposes `title_id`/`SegBound`/`segAt`/`performDraw`/`redrawInsideGrab`/`redrawScopedSegment`/`recordedBound`/`SegBound.contains` pub; (4) ~~extract `draw.zig`~~ **DONE** (199 lines): `frameCtx`/`performDraw`/`submitDrawBlockingFull`/`requestFullRedraw`/`foldModuleRedraw`/`redrawInsideGrab`/`redrawSegmentScoped`/`redrawSlotScoped`/`redrawScopedSegment` moved verbatim (`gBar`→`bar.gBar`, `segAt`→`bar.segAt`, `renderBar()`→`bar.renderBar()`, `barModsConsumeRedrawRequest()`→`bar.barModsConsumeRedrawRequest()`); the paint pass (`drawAllInner`/`solveRowPlan`/`paintRowPlan`/`drawSegment`/`drawRowSegment`/`paintGap`/`drawClockOnly`/`scanLiveFrame`/`fillDrawCtx`) stays on `State` in `bar.zig` — the split is orchestration-vs-paint, not a second copy of the paint logic; the third runtime-only import cycle; `bar.zig` additionally exposes `renderBar`/`barModsConsumeRedrawRequest` and the State draw/dirty methods (`markDirty`/`clearSegmentDirty`/`clearRegion`/`pendingFullRedraw`/`hasPendingRepaintWork`/`hasLayoutSegmentDirty`/`fillDrawCtx`/`scanLiveFrame`/`drawSegment`/`drawAllInner`) pub. The registry-driven structure means no other file changes; `visibility_test.zig`/`metrics_test.zig`/`width_state_test.zig`/`center_row_test.zig` gate each step.

### `bar/scaffold.zig` (~250 lines) — segment width machinery  **★**
**Now:**
```
widthState(tag): measured/resolved/natural width tracking per segment
  consumeRedrawRequest / store / naturalWidth / resolved / measured
keyedWidthState(tag, Key)            // per-key variant (title windows)
finishDraw(seg, painted) -> bool     // dirty-mark bookkeeping
drawAndStore(...)                    // measure -> draw -> store width
module(name, draw, click, opts)      // the Segment binder helper
```
**Verdict:** ★ — the width-state machine (measured vs resolved vs natural) is the bar's layout contract, isolated and shared by every segment via `module()`.
**Ideal:** unchanged. **Path:** none.

### `bar/segment.zig` (~220 lines) — segment vocabulary  **★**
**Now:**
```
DrawCtx = { dc, config, height, ... }       // per-frame draw context
TitleSnapshot / TitleRenderContext          // title's shared vocabulary
max_visible_windows
hasSource(dirty_sources, source) -> bool
idByName(modules, name) -> ?usize
findAllByCapability(modules, cap) -> []usize
```
**Verdict:** ★ — the vocabulary every segment imports; capability queries (`findAllByCapability`) are how the bar discovers roles without naming modules.
**Ideal:** unchanged. **Path:** none.

### `bar/drawing.zig` (1293 lines) — Cairo/Pango rendering  **◐**
**Now:**
```
clockFormat(config) -> []const u8
findVisualByDepth(screen, depth) -> u32
TextRun { measure, deinit }                // Pango layout run
FontBook { getMetrics, probe }             // font fallback list
SizedFontList { build, deinit }
Surface { fillRect }                        // cairo surface wrapper
valueRange(text, start, len) -> ?ValueRange  // styled-text span parser
DrawContext { initWithVisual, deinit,
  drawText / drawTextSized / drawTextScrolled / drawTextEllipsis /
  drawTextStyled, fillRect, measureText(Width)(Styled),
  baselineY, metrics, queueBlit / blitRegion }   // damage tracking
drawPaddedSegment / drawPaddedSegmentValue      // segment render shell
probeFontMetrics / loadBarFonts
```
**Verdict:** ◐ — cohesive around "rendering", and the damage-tracking blit queue (`queueBlit`/`blitRegion`) is the right design (partial repaints); but three concerns share the file: font management (`FontBook`/`SizedFontList`/`loadBarFonts`/`probeFontMetrics`), the text-drawing family, and the padded-segment shell.
**Ideal:**
```
bar/fonts.zig    — FontBook, SizedFontList, probeFontMetrics, loadBarFonts, findVisualByDepth
bar/text.zig     — TextRun, valueRange, drawText* family, measureText*
bar/surface.zig  — Surface + DrawContext + blit queue
bar/padded.zig   — drawPaddedSegment(Value)  (the segment render shell)
```
**Path:** optional; each extraction is mechanical (no cross-dependency cycles: fonts ← text ← surface ← padded). Do it only in the same pass as the `bar.zig` split, since both touch the draw path.

### `bar/meter.zig` (~60 lines)
**Now:** `pctFromSlot(slot_x, slot_w, offset) -> u8`; `offsetFromPct(slot_x, slot_w, pct) -> u16` — slider geometry math.
**Verdict:** ★ — pure, symmetric pair, unit-tested (`meter_test.zig`).
**Ideal:** unchanged. **Path:** none.

### `bar/metrics.zig` (117 lines)  **★**
**Now:**
```
Inputs = { font_size: ScalableValue, height: ?ScalableValue, screen_height }
Probe  = *const fn (trial_pt) -> ?u32     // injected font measurement
Metrics = { font_size, height }
resolve(in, probe) -> Metrics:
    configured height -> scaled into policy range (FINAL)
    % font size -> refined against that height
    no height -> fonts decide (ascent+descent), policy default fallback
```
**Verdict:** ★ — exemplary: derived values as an immutable struct, the only impure input (font probe) injected, so the policy is unit-testable without Pango. This is the pattern the rest of the bar should follow.
**Ideal:** unchanged. **Path:** none.

### `bar/visibility.zig` (89 lines)  **★**
**Now:**
```
barForcedHiddenByFullscreen(model, ws) -> bool   // comptime-folded w/o fullscreen
shouldBeVisible(global, forced_hidden) -> bool
desiredVisibility(model, ws, global) -> { should_be_visible, reason }
keepPromptOverride(model, ws, global) -> bool
```
**Verdict:** ★ — exemplary partition: pure policy (model is a *parameter*), zero X11, zero pipeline import; the orchestrator owns the wire side and the mapped-state comparison.
**Ideal:** unchanged. **Path:** none.

### `bar/win.zig` (~190 lines)
**Now:**
```
initAtoms()
calcBarYPos(position, screen_h, height) -> i16
setWindowProperties(win, height)     // _NET_WM_STRUT_PARTIAL, TYPE_DOCK, ...
createBarWindow(height, y, want_transparency) -> BarWindowSetup
createDrawContext(setup, height, font_size) -> *DrawContext
freeColormap / destroyBarWindow
```
**Verdict:** ★ — X window lifecycle isolated; strut properties batched so setup is one round trip.
**Ideal:** unchanged. **Path:** none.

---

## Bar core summary

- 8 files: 7 ★ (scaffold, segment, meter, metrics, visibility, win, bar), 1 ◐ (drawing — optional four-way split).
- `metrics.zig` + `visibility.zig` are the reference pattern for the codebase: derived values as structs, impure inputs injected, policy/wire split.
