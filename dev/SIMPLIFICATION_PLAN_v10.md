# hana — Simplification Campaign v10

A line-by-line, function-by-function, subsystem-by-subsystem simplification sweep of the
entire `src/` tree, produced by a 17-agent parallel audit organized as one team per
subsystem (4×bar, 2×config, 3×core, 3×window, 2×tiling, 2×input/model/main, 1×whole-tree
interconnect).

- **Date**: 2026-09-24
- **Baseline gates**: `zig build check` (all layer rules pass) and `zig build test`
  (282/282 pass) verified green before any change.
- **Scope**: production code under `src/` (test dir analyzed only for hygiene/fixture
  duplication facing production; no test coverage removed).
- **Compass**: every item must either (a) remove lines while preserving behavior, or
  (b) improve readability at neutral-to-slightly-positive LoC. Risk/effort are never a
  reason to bail — only "the resulting code is not clearly better" is.
- **Standing constraints** (inherited from ARCHITECTURE.md / dev/scripts/check-layers.sh):
  sync boundary sacred (raw XCB wire sends stay behind `src/core/sync/` + allowlist),
  pure layers (model/tiling/config) xcb-free, core never imports an optional module by
  name (deletion-modularity), no god-file splits for size alone, no public TOML/config
  surface changes, no test removal/weakening, no `TODO`/`FIXME` markers.
- **Notation**: Conf. H = body + call sites verified; M = inventory verified, not every
  line; L = inferred. LoC = `+N`/`-N`/`0` estimated net effect on production lines.
  `[~]` = higher-risk / judgment item, see §"Deferred & questions".

---

## 0. Executive summary

### 0.1 Headline counts (by subsystem)

| Subsystem | Files| Agent team | Findings | Est. LoC effect (top items) |
|---|---|---|---|---|
| `bar/` | 25 | 4 agents | 56 | −110..−140 + readability |
| `config/` | 5 | 2 agents | 23 | −80..−90 |
| `core/` | 23 | 3 agents | 47 | −55..−70 + comment precision |
| `window/` | 11 | 3 agents | 42 | −55..−65 |
| `tiling/` | 7 | 2 agents | 21 | −15..−20 + readability |
| `input/` + `model/` + `main.zig` | 6 | 2 agents | 22 | −40..−50 + prose cuts |
| whole-tree seams | — | 1 agent | 13 | −30..−35 + test hygiene |

Round total: **~−390..−470 LoC** of provable/mechanical removals across ~224 distinct
findings, a large assortment of comment/precision fixes, and ~20 items deferred to the
owner (risk-judgment / behavior-adjacent).

### 0.2 The ten highest-value single items

| # | Item | Where | LoC | Conf |
|---|---|---|---|---|
| 1 | Title width/segmented-titles memo machinery is pure caching (output-identical removal) | `bar/modules/title/title.zig:49-138,348-373` | −110 | H/perf-deferred |
| 2 | `slider.Level` redundant middle layer between `Sub` and hooks | `bar/modules/slider/slider.zig:134-163` | −30 | M |
| 3 | `RightCluster` struct → locals in `drawAllInner` | `bar/bar.zig:356-395,988-989,1067` | −25..−30 | H |
| 4 | `parseLayoutVariant` dead re-normalization (delete + inline) | `config/config.zig:1401-1422` | −18..−21 | H |
| 5 | `IndicatorLocation.string_map` comptime generator → literal table | `config/types.zig:353-376` | −18..−20 | H |
| 6 | Knob-key two-pass comptime build → inline scan | `config/schema.zig:192-220` | −15 | H |
| 7 | `focus.applyClear` dead vestige | `window/focus.zig:468-480` | −14 | H |
| 8 | Prompt 5× hand-rolled buffer shifts → one `deleteRange` | `bar/modules/prompt/prompt.zig` + `vim.zig` | −18..−20 | H |
| 9 | `layoutKindOf` = `layoutKindFallingBack(name, 0)` (10-line alias) | `tiling/tiling.zig:264-272` | −10 | H |
| 10 | `types.Geometry` scalers duplicate `utils.scaling` | `config/types.zig:675-696` | −8..−10 | H |

### 0.3 Verification protocol (per subsystem patch)

1. `zig fmt` on every touched file.
2. `zig build check` (layer rules must keep passing).
3. `zig build test` (282+ tests) — full suite.
4. Re-`rg` any removed symbol to prove zero callers.

---

## 1. `src/bar/` — the bar subsystem

### 1.1 bar-core (`bar.zig`, `segment.zig`, `segdraw.zig`, `drawing.zig`, `metrics.zig`, `refresh.zig`, `visibility.zig`, `win.zig`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| B-01 | OVER-ENG | `bar.zig:356-395,988-989,1067` | `RightCluster` buys ~2 cached Pango measures/frame | Replace struct + `measure`/`take`/16-cap with locals `right_widths: [max_right_segments]u16`, `right_count`, `right_ridx`, `right_total_raw: u32`; fold measure loop once before layout loop; keep `drawRightSegments`'s `?[]const u16` and null branch | −25..−30 | H [~] |
| B-02 | DUPL | `drawing.zig:783-825` | `drawPaddedSegmentValue` no-split fallback duplicates `paintedSegment` | On `value == null`/non-subslice → `return dc.paintedSegment(x, height, text, padding, config.bg, config.segmentFg(name), null, props)` | −9..−12 | H |
| B-03 | READ | `bar.zig:718-726` | `hasLayoutSegmentDirty` nested inline struct hides a trivial scan | Direct `for (lay.segments)` loop; drop the `pred` struct | −5..−6 | H |
| B-04 | DEAD | `bar.zig:1181-1185,1210` | `BarSetup.dc` never read | Drop field + return assignment (keep local for `State.init`) | −3 | H |
| B-05 | COMM | `bar.zig:77-84` | Garbled/contradictory doc on `hasRegisteredSegments` | Single 3-line doc | −5..−6 | H |
| B-06 | COMM | `bar.zig:411-417` | "All live bar state" doc sits above `Visibility`, not `State` | Move block above `const State` | 0 | H |
| B-07 | DUPL | `bar.zig:1006-1025` | Center-row budget derivation buried in the switch | Extract `centerRowBudget(...)` | 0 | H |
| B-08 | API | `segment.zig:299,313` | Inline `@import("contract")` in fn signatures while `contract` imported | `[]const contract.Segment` | 0 | H |
| B-09 | API | `segment.zig:182-204,235-242,271-273` | `gather`/`gatherAndSortWindowInfos` take `windows` + `win_count` separately | Single slice; fold `@min` clamp into `gather` | −3..−6 | M |
| B-10 | API/READ | `drawing.zig:208-252` | `FontState` named struct vs `getMetrics` anonymous tuple | Make cached type the tuple | −2..−3 | H |
| B-11 | CONSOL | `bar.zig:158-165` + `scale.zig:22` | `max_bar_height`/`default_bar_height` apart from `bar_min_height_px` | Move to scale.zig, one clamp helper | 0 | H |
| B-12 | DUPL | `bar.zig:232-234,1112,1684-1687` | 3× "fold module redraw → markDirty" | One `foldModuleRedraw(s)` | ≈0 | H |
| B-13 | READ | `bar.zig:271-278` | `dispatchClick(s,tid,0,false,true)` bare flags | Named local `is_right_click` | +1 | H |
| B-14 | COMM | `drawing.zig:220-223,883,918-963` | `loadBarFonts` "fallback support" log lies; `convertFontName` keeps first family only | Pass pre-joined (`,`) names through; correct the log [behavior note] | −0 | M |
| B-15 | READ | `bar.zig:167-177` | `probeMetrics` re-boxes `probeFontMetrics` output | Return the pair directly | −2..−3 | H |
| B-16 | READ | `bar.zig:1859-1862` | `titleClickTrampoline`/`title_id` resolution duplicated twice | `titleIdBound(s)` helper | −4 | H |
| B-17 | CONSOL | `segdraw.zig` vs `clock.zig:66-69,162-173` | `widthState` vs clock's own last-width tracker | optional key-field merge [~] | 0..−10 | M |

### 1.2 prompt + slider (`prompt.go`, `prompt/vim.zig`, `slider/*`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| P-01 | DUPL | `prompt.zig:125-152,105-121,184-191,163-165`, `vim.zig:270-278` | Five hand-rolled delete-shifts | one `deleteRange(es, from, to)`; `backspace`/`clearToStart`/`deleteWordBack`/Delete-arm delegate; `vim.deleteRange` → 5-line delegate | −18..−20 | H |
| P-02 | OVER-ENG | `slider.zig:134-163` | `Level` redundant middle layer | Delete `Level`; subs bind hooks directly | −25..−30 | M [~] |
| P-03 | DUPL | `vim.zig:298-307` | `pasteBefore`/`pasteAfter` = one fn + one line | `paste(vs, after: bool)`; hoist `p`/`P` branch | −4..−5 | H |
| P-04 | DUPL | `volume.zig:71-143` | Four-arm read-ladder repeats resolve-state quintuple | `setResolved(backend, pct, muted)` | −6..−8 | M |
| P-05 | CONSOL | `brightness.zig:114-124` + `native_alsa.zig:137-151` | pct↔range linear maps twice | single `slider.rawFromPct`/`pctFromRaw` (nearest-round, unchanged behavior) | −6..−8 | M [~] |
| P-06 | OVER-ENG | `prompt.zig:1131-1133,577-584,1366-1369` | single-caller `promptWidth`/`draw` wrappers | inline into `measureCached`/`drawHook` | −6 | H |
| P-07 | API | `prompt.zig:502` | magic `& 0x7F` | `& masks.synthetic_event_mask` | 0 | H |
| P-08 | API | `slider.zig:460-486,561-570` | `onClickFor` carries dead `*anyopaque`/`trampoline` params | stop forwarding | −3..−4 | H |
| P-09 | DEAD | `native_pulse.zig:57` | `sink_info_volume_values` zero callers | delete | −1 | H |
| P-10 | READ | `slider.zig:422` | `catch {}` swallows `drawText` error | `try` (or one-line deliberate-suppression comment) | 0 | H |
| P-11 | READ | `prompt.zig:82-96` | `insertSlice` first guard subsumed | saturating `@min` form | −1..−2 | H |
| P-12 | COMM | `prompt.zig:1066-1070` | `drawBlockCursor` doc references removed visual-selection | reword | 0 | H |
| P-13 | OVER-ENG | `prompt.zig:259` | `num_modes = @typeInfo(Mode)…` for a fixed 2 | NOTE only — "can't drift" is defensible | −1 | L |
| P-14 | DUPL | `prompt.zig:805-826,931-946` | `{home}/{suffix}` path built twice | `homePath(suffix, buf)` | −3 | M |
| P-15 | READ | `vim.zig:384-426` | `wordScanFwd/Bwd` near-twins | leave as-is (fold would grow); optionally one comment | 0 | L |
| P-16 | DEAD | `slider.zig:78`,`prompt.zig` pub | sweep — all live | none | 0 | H |

### 1.3 systatus + clock + tags + title (`systatus/*`, `clock.zig`, `tags.zig`, `title/*`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| ST-01 | OVER-ENG | `title.zig:49-138,348-373` | two cross-frame memos are pure caching (output-identical removal) | Delete `TitleWidthMemo`/`SegmentedTitlesMemo` + rebuild + `invalidateReloadCaches`; call `dc.measureTextWidth` directly | −110 | H [~ perf] |
| ST-02 | DEAD | `systatus.zig:152-159` | `naturalWidthFor` orphaned by inlined hook (uncommitted working-tree edit) | Delete fn + doc; move load-bearing fact onto `g_slot_width` decl | −6 | H |
| ST-03 | READ | `title.zig:158-173,414-418` | `emptyWorkspace` `?u16` dance | inline (always `ctx.start_x + ctx.width`) | −5 | H |
| ST-04 | DUPL | `batt.zig:17-21` | intermediate `name` buffer | one `bufPrint` straight to path | −4 | H |
| ST-05 | DUPL | `title.zig:239-269` | duplicated ellipsis tail in `drawMarqueeCell` | early-return scrolled branch; one shared tail | −3 | H |
| ST-06 | COMM | `systatus.zig:30-49` | 18-line open-module essay duplicates module doc | cut L32-44; keep the "how to add" line | −8 | M |
| ST-07 | CONSOL | `systatus.zig:84,106` | two unlinked `128` render buffers | `const render_buf_len` | 0 | H |
| ST-08 | CONSOL | `title.zig:272-276` + `segment.zig:275-281` | equal-split math in two files | `segmod.segmentBounds`/`segmentIndexOfX` | +4 | H |
| ST-09 | API | `segment.zig:235-242`/`title.zig:345` | `gather` caller-side `win_count` clamp | clamp internally | −3 | M |
| ST-10 | DEAD | `tags.zig:28-33` | unreachable `"?"` fallback (call sites structurally ≤ len) | drop arm | −1 | H |
| ST-11 | READ | `tags.zig:41-74` | `cache_valid` ignores key; `ws_current`/`ws_all_active` fake keys | store `cache_ws`/`cache_all` and guard on them | +4 | M [~ behavior] |
| ST-12 | API | `title.zig:321-323` | `offsetFor(...false,0,now)` side-effect call | named `retireScroll` (or additive `deactivate` contract field) | 0 | M |
| ST-13 | OVER-ENG | `clock.zig:205-215` | onClickHook ignores 5/6 params | doc-only (uniform segment seam) | 0 | H |
| ST-14 | READ | `carousel.zig:122-127` | period math vs clock's — rejected merge | none (documented as considered) | 0 | H |

### 1.4 layout + variants (`modules/layout/*`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| LV-01 | DUPL/COMM | `layout.zig:29`,`variants.zig:27` | `tiling_mods.len == 0` guard subsumed by `activeLayoutKind` | delete gates; single `orelse`; trim header | −3..−4 | H |
| LV-02 | CONSOL | `layout.zig:17,35,40`,`variants.zig:16,43,49` | registry name spelled 4× | `const name` in each file | 0 | M |
| LV-03 | COMM | `layout.zig:19-27` | "><>" fallback narrated 3× in 9 lines | one doc on `fallback_icon`; shrink `getIcon` doc | −4 | H |
| LV-04 | DUPL | `layout.zig:34-38`,`variants.zig:39-47` | draw body byte-twin (+ variants' null-content guard) | segdraw `content:` mode (or shared 3-line width-store helper) | −5 | M [~] |
| LV-05 | OVER-ENG | `segdraw.zig:29-32` | `store()` arms `redraw_pending` for instantiations that can't consume it | `widthState(comptime tag, comptime track_collapse)` | 0 | H |
| LV-06 | READ | `variants.zig:31-33` | variant_idx reaches into model directly | single borrow `const p = &pipeline.model().ws[pipeline.model().current.index].params` | 0 | M |
| LV-07 | CONSOL | `tiling/{master,monocle,grid}.zig` + `tiling.zig:341-347` | `variant_count == indicators.len` hand-synced | comptime assert in `layoutModule` | +2 | M |
| LV-08 | COMM | `variants.zig:39-47` vs `layout.zig:34-38` | draw-doc asymmetry (0-width story) | one-line doc on layout's draw | +1 | H |
| LV-09 | API | `variants.zig:20,26-35` | empty-string sentinel meaning 3 states | doc the deliberate three-way meaning | +1 | H |

---

## 2. `src/config/`

### 2.1 parser + schema

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| C-01 | CONSOL | `schema.zig:192-220` | knob-key two-pass comptime build | inline `isBarPropertiesKnobKey` scan | −15 | H |
| C-02 | DUPL | `parser.zig:392-407` | `isWeightToken` = `weightFromToken != null` | one-line body | −4 | H |
| C-03 | OVER-ENG | `parser.zig:212-222` | `getAs` re-lists `asScalar`'s tag switch | comptime-branch single dispatch | −4 | H |
| C-04 | OVER-ENG | `parser.zig:1190-1201,1160-1185` | `advanceAfterPair` bool is constant | return void; reword `parsePairs` doc | −3 | H |
| C-05 | OVER-ENG | `parser.zig:604` | per-weight `w > 100` dead after `sum > 100` | delete arm | −2 | H |
| C-06 | DUPL | `schema.zig:720,731,781` | 3× `if (is_value) &a else &b` map pick | `segmentColorMap(cfg, is_value)` helper | −3 | H |
| C-07 | DUPL | `schema.zig:752,774` | identical "Invalid style" warn twice | hoist/`recognized` flag | −2 | H |
| C-08 | OVER-ENG | `parser.zig:555-558` | `mixColors` n==0/1 arms unreachable | drop (or keep as defensive backstop convention) | −2 | H |
| C-09 | CONSOL | `parser.zig:426-430` | `resolveMixOperandValue` reparses what `colorFromValue` parsed | one-line form | −1 | H |
| C-10 | OVER-ENG | `schema.zig:509-516` | labeled `break :probe` manual guard | inline `if (doc.getSection(...)) | sec | { …; break; }` | −3 | H |
| C-11 | API | `schema.zig:520,526` | self-assigning `orelse p.*` | `if (…) | v | p.* = v;` | 0 | H |
| C-12 | COMM | `schema.zig:323-324` | `reject` "shared by getInRange and getScalableInRange" is false | reword | 0 | H |
| C-13 | CONSOL | `parser.zig:563,603` | magic `100` weight | `const weight_total` | 0 | H |
| C-14 | API | `parser.zig:230-241` | `getAsOrWarn` double hash lookup | fetch once, branch | −1 | H |
| C-15 | READ | `parser.zig:706` | `const inc = incoming` pointless | direct deref | −1 | H |
| C-16 | OVER-ENG | `parser.zig:31-39,334-351,471-492`, `schema.zig:398-399` | `lastScalar` conflates literal arrays with accumulation (observable: hex-last array element wins; palette-name duplicates average) | product decision + regression test [~ HIGH] | 0 | H→M |

### 2.2 config host + types + fallback

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| CF-01 | OVER-ENG | `config.zig:1401-1422` | `parseLayoutVariant` re-normalizes already-lowered name; `orelse` unreachable | inline at `parseLayoutTrailing` | −18..−21 | H |
| CF-02 | DUPL | `types.zig:675-696` vs `utils.zig:162-191` | `scaleValue`/`scaleToU16` duplicate `utils.scaling` | delegate; fold `scaledIndicatorSize`/`scaledWorkspaceWidth` into one `scaledUnit` | −8..−10 | H |
| CF-03 | OVER-ENG | `types.zig:353-376` | `IndicatorLocation.string_map` comptime diagonal generator | 20-entry literal `StaticStringMap` | −18..−20 | H |
| CF-04 | API | `config.zig:390-395` | `dupe` if/else-with-empty-arm | `catch return` | −2 | H |
| CF-05 | DUPL | `config.zig:188-233` | `mergeOneFile`/`mergeIncludes` repeat join+parse-fail-silent+merge+log tail | hoist `tryParseMerged` (LoC-neutral; cohesion) | ≈0 | M |
| CF-06 | API | `config.zig:1701` | redundant `@as(usize, @intCast(ws_num))` | plain binding | −1 | H |
| CF-07 | DUPL | `fallback.zig:38` vs `:26` | `"xterm"` spelled twice | one const | 0 | H |

---

## 3. `src/core/`

### 3.1 core-meta (`core.zig`, `pipeline.zig`, `events.zig`, `screen.zig`, `signals.zig`, `spawn.zig`, `restart.zig`, `persist.zig`, `scale.zig`, `contract.zig`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| K-01 | DUPL | `pipeline.zig:203-242` | grab-pair fold: `reconcileGrabFocus` + `reconcileUnderGrabNowWithFocusDuty` | one `reconcileGrabFocus(o,t,order,duty)`; 7 call sites + focus carry `null`/duty | −3 net | H [~] |
| K-02 | COMM | `spawn.zig:73-83` | comment duplicated inside own `if` | delete inner copy | −4 | H |
| K-03 | DUPL | `spawn.zig:49,312` | identical `/bin/sh -c` execp construction | `execShell(cmd_z)` | −3 | H |
| K-04 | DUPL/DEAD | `persist.zig:327,28` | redundant `has_tiling` guard (pipeline guards first) | delegate; drop `build_options` import | −3 | H/M |
| K-05 | READ | `events.zig:563-574` | bare scope block conveys nothing | delete braces | −2 | H |
| K-06 | DUPL | `persist.zig:252-261` | `createFileAbsolute` twice with identical args | `createExclusive(io, tmp)` | −2..−3 | H/M |
| K-07 | DUPL | `events.zig:203,468` | raw type-byte read twice | `inline fn eventType(e: anytype) u8` | −2 | H |
| K-08 | COMM | `contract.zig:344-347` | `DirtySources` doc jams Segment prelude | add `///` separator | +1 | H |
| K-09 | COMM | `IMPROVEMENTS.md:212` | stale "sparse zig-zag" claim | correct the doc (code all-64 is deliberate) | 0 | H |
| K-10 | READ | `scale.zig:155-168` | sibling scalers take different shapes | doc the asymmetry (no signature churn) | +2 | H |
| K-11 | API | `events.zig:296-302,658` | double-log of reload failure | single report | −1..−2 | M |
| K-12 | COMM | `spawn.zig:176-177` | "survive-the-cutout" gravestone | delete or one-liner | −2 | M |
| K-13 | CONSOL | `spawn/restart/events` @cImport trio | overlaps libc headers | optional shared `utils/libc.zig` | 0 | M [~] |
| K-14 | — | `core.zig:86-100` | `factAccessors` generator — **KEEP** (shorter than 4 pairs, 1-site wrap policy) | verdict only | 0 | H |
| K-15 | — | `persist.zig:111-277` | streaming JSON — **DEFER** (streaming doesn't remove dominant allocs; cold path) | verdict only | 0 | H |
| K-16 | — | `events.zig:425-506` | two drain loops — **KEEP** (already unified; pinned budgets) | verdict only | 0 | H |
| K-17 | — | `pipeline.zig:180` vs `sync.zig:226` | double grab+reconcile — **KEEP** (RETILE_PROF home; re-route would add lines) | verdict only | 0 | H |

### 3.2 sync + x11 (`sync/sync.zig`, `sync/sink.zig`, `x11/wire.zig`, `x11/xcb.zig`, `x11/masks.zig`, `utils/idmap.zig`, `utils/bounded.zig`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| S-01 | DUPL | `bounded.zig:57-67,141-147,152-158` | 3× identical field-match closure | `fieldEq(comptime FieldEnum(T))` factory | −6 | H |
| S-02 | DUPL | `sync.zig:129-130,521` + 4 ctors | `Ctx.cfg_bw` duplicates `env.margins.border` | delete field; read `env.margins.border`; fix test fixtures | −6 | H [~] |
| S-03 | DUPL | `sync.zig:214-236` + `pipeline.zig:188-191` | second grab-bracket idiom (`sync.reconcileUnderGrab`) | fold into pipeline's `withServerGrab`, move `retile_prof` | −8 net | M [~] |
| S-04 | OVER-ENG | `sync.zig:466-472,387,563-564` | `Desire.is_winner` pass-global smuggled into per-window struct | drop field; `const is_winner = winner.* == win;` | −2 | H |
| S-05 | OVER-ENG | `sync.zig:158-163` | `pub const State` zero external users | `const State` | 0 | H |
| S-06 | API | `wire.zig:163-176` (+8) | `getAtomCached` error!u32 never distinguished | `?u32`; `orelse` at 8 sites | −1 | H |
| S-07 | OVER-ENG | `sink.zig:136-141` | dead `if (count == atoms.len) break` | delete | −2 | M |
| S-08 | READ | `sync.zig:394-398` | `const last = ledger` alias | use `ledger.*` | −1 | H |
| S-09 | COMM | `sync.zig:2-3` | header overstates seam/primitive split | add inline-shims clause | 0 | H |
| S-10 | COMM | `sync.zig:141-143` | "three contract reads" vs "four" | fix count | 0 | H |
| S-11 | COMM | `sync.zig:474-480` | "four parked arms" (used by two) | reword | 0 | H |
| S-12 | COMM | `sync.zig:180-188` | stale ".found_existing" history in `sentGetOrPut` doc | drop clause | −1 | H |
| S-13 | CONSOL | `prompt.zig:502` | `0x7F` literal (see P-07) | masks const | 0 | H |
| S-14 | COMM | `sync.zig:7-9` | "ACTIONS" attribution moved to pipeline preReconcile | reword | 0 | M |

### 3.3 utils (`utils.zig`, `constants.zig`, `debug.zig`, `ids.zig`, `paths.zig`, `proc.zig`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| U-01 | DUPL | `utils.zig:31-49` | `clockTs` single-consumer two-module dance | fold into `clockNs` | −5 | H |
| U-02 | API | `paths.zig:26-46` | `?[]const u8` env param null branch never fires | `[]const u8` | −4 | H |
| U-03 | CONSOL | `core.zig:30-42`,`model.zig:11-17` vs `ids.zig` | ids rationale prose tripled | one-line cross-ref in both | −9 | M |
| U-04 | API | `ids.zig:24` | `fromIndex(u8)` forces ~14 `@intCast` | `anytype` [~ explicit tradeoff] | −14 | M |
| U-05 | DUPL | `paths.zig` vs `fallback.zig:55-64`,`prompt.zig:702-708` | dir+name+X_OK probe copied | `exeInDir` in paths.zig | −3 | H [~] |
| U-06 | DUPL | `actions.zig:528` | `stepVariantDir` re-implements `utils.wrapIndex` | delegate | 0 | H |
| U-07 | STALE | `dev/scripts/check-layers.sh:172` | pat2 still greps removed `utils.ungrabServer` | drop | 0 | H |
| U-08 | READ | `utils.zig:3-4` | header overclaims "every public decl" | reword | −4 | H |
| U-09 | READ | `utils.zig:102-103` | mixed import styles | bind `idmap` first | 0 | H |
| U-10 | CONSOL | `utils.zig:102-103` + model/window/spawn/contract/minimize | `BoundedList`/`IdMap` two spellings | either all-direct or all-hub [~] | net 0 | M |
| U-11 | READ | `utils.zig:21-116` | wire re-export block is naming sugar (guard not facade) | doc it or leave | 0 | M |
| U-12 | CONSOL | `constants.zig:81-87` | `max_workspace_command_1based` = 256 literal | derive `= max_workspace_number_1based + 1` | 0 | H |
| U-13 | COMM | `utils.zig:30` | "inlined from former time.zig" archaeology | reword | 0 | H |
| U-14 | DUPL | `master.zig:202-204` | `rowPitch` hand-rolls `2 *| m.border` | `m.gap +| utils.doubledBorder(m)` | 0 | H |
| U-15 | READ | `utils.zig:47-63` | `monotonicMs`/`realtimeMs` identical 2-line bodies | shared `ms(comptime clock)` | 0 | H |
| U-16 | CONSOL | `utils.zig:101-103` | `Store` missing from facade; model imports both | re-export `Store`; drop model's `bounded` import | 0 | H |

---

## 4. `src/window/`

### 4.1 hub + actions + icccm

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| W-01 | DUPL | `window.zig:1019-1026` | cache-miss geometry fallback re-implements `getGeometry` | `return getGeometry(conn, win)` | −4 | H |
| W-02 | DUPL | `actions.zig:131-137,1008-1013` | minimize/unmanage near-twin withdraw tails | `retileWithFallback(m, fs_current, was_focused)` | −4 | M |
| W-03 | DUPL | `window.zig:946` | hand-rolled `onWindowGone` fan-out | `dispatchAll(.onWindowGone, .{win})` | −1 | H |
| W-04 | DUPL/API | `actions.zig:396-401` | `detachTiledToFloating` leaves stale `tiled_order` entry, contradicts own comment | use `model.removeValue(...)`; fix comment | −2 | H/M [~] |
| W-05 | API | `actions.zig:371-377` | `pinToggle` double registry scan | one-capture idiom | 0 | H |
| W-06 | API | `actions.zig:339,351-357` | `tagToggle` guards a hook it never calls | guard on the two hooks actually dispatched | 0 | M |
| W-07 | COMM | `window.zig:99,539,659` | stale `resolveTargetWorkspace` reference; dangling doc | rename ref; re-splice | 0 | H |
| W-08 | OVER-ENG | `actions.zig:830/862/881/896 + 266/304` | three timing styles; switchTo pays clock samples unprofiled | gate on `profile_key` | 0 | M |
| W-09 | READ | `icccm.zig:335-342` | nested 4-way matrix | flatten two binomials | 0 | H |
| W-10 | API | `actions.zig:40,860` | `coveringOccupantOnWs` two meanings | one-line discriminator at callers | 0 | M |
| W-11 | COMM | `icccm.zig:69-74` | stale `populateFocusCacheFromCookies` doc | describe shared drain | 0 | H |
| W-12 | DUPL | `window.zig:1056-1085` | twin border-width bookkeeping | shared `resolveBorderWidth` tail | −3 | M |
| W-13 | DUPL | `actions.zig:592-593,633-635` | viewport clamp+stamp tail | `commitViewport(p, offset, count)` | −2 | M |
| W-14 | OVER-ENG | `window.zig:1394-1399` | `warnOnce` 6-line latch for 2 sites | two bools | 0 | L |
| W-15 | API | `icccm.zig:58-61` | `reset(active: bool)` bare-boolean | `setCacheArmed(active)` or split | 0 | L |
| W-16 | OVER-ENG | `icccm.zig:115,231-232,306,332` + `window.zig:1233-1234` | `"WM_PROTOCOLS"`/`"WM_HINTS"` ×6 | `atom_names` table | 0 | L |
| W-17 | COMM | `window.zig:1334-1341,1358-1360,1370-1373` | `skip_tiled` rationale ×3 | keep one | 0 | L |
| W-18 | API | `actions.zig:29-32` | alias layer over window dispatch fns | keep (documented) | 0 | L |

### 4.2 focus + tracking + wincache + borders

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| F-01 | DEAD | `focus.zig:468-480` | `applyClear` zero callers | delete + doc trim | −14 | H |
| F-02 | MIRROR | `tracking.zig:96-131`+`workspaces.zig:20-31` | `state.workspace_count` mirror + write-only `state.initialized` | latch in `tracking.init` from config; drop `setWorkspaceCount`; drop workspaces init/deinit bindings | −10 | M [~] |
| F-03 | DUPL | `focus.zig:369-384` | setIntent built twice (only `old` differs) | merge | −7 | H |
| F-04 | API | `wincache.zig:131-151`+`borders.zig:79-91` | `sendBorderColorIfChanged` bool-contract fallback duplicated | fold fallback inside | −5 | H |
| F-05 | DUPL | `focus.zig:632-634` | `cycleIndex` re-implements wrapIndex | delegate | −4 | H |
| F-06 | OVER-ENG | `focus.zig:252-256,444-446` | `CommitFlags.take_focus_known: ?bool` vestigial null | make bool; drop stale prose | −4 | H |
| F-07 | READ | `focus.zig:81-106,399-415` | duplicated focused-cast + no-op `@as(u32,…)` | `getFocused()` reuse | −4 | H |
| F-08 | DUPL | `borders.zig:58-62` | `borders.width()` passthrough twin of `core.borderWidth()` | delete; 3 callers → `core.borderWidth()`; test edits | −4 | M |
| F-09 | READ | `tracking.zig:126`,`actions.zig:957`, etc. | no-op `@intCast` on u8/u32 ids | drop | 0 | H |
| F-10 | READ | `wincache.zig:28` | `WindowData.border` field name ambiguous | `border_color` | 0 | M |
| F-11 | COMM | `tracking.zig:1-2`,`focus.zig:402-412` | facade claim overstatement + safe `.?` | reword; bind locals | 0 | M/L |
| F-12 | COMM | `tracking.zig` header | pending note: `coveringOccupantOnWs` O(N) scan on sweep unresolved (optimization, not simplification) | record only | 0 | — |

### 4.3 modules (`floating`, `fullscreen`, `minimize`, `workspaces`)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| FM-01 | OVER-ENG | `floating.zig:85,113-151` | `ResizeDirection` 8-way enum consumed one call later | merge into `nearestResizeCorner` | −12..−14 | H [~] |
| FM-02 | API/DUPL | `floating.zig:160-162`,`minimize.zig:135-138,175-178` | hand-rolled covering checks vs `window.isCoveringMode` | use facade | −8 | H |
| FM-03 | DESIGN | `fullscreen.zig:32,37,46-51,230-263` | two mutually-exclusive pending-bar globals | one `g_pending_bar: ?struct{win,hide}` | −10..−12 | H [~] |
| FM-04 | OVER-ENG | `fullscreen.zig:161-175` | nested `if (e.covering_ws) | cws | {…} else continue` | `orelse continue` | −4 | H |
| FM-05 | API/DUPL | `floating.zig:398-400`,`fullscreen.zig:81-83` | peek-and-call for `isWindowHidden` | `window.callHookBool` | −5 | H |
| FM-06 | DEAD | `floating.zig:93-96,297-298` | `snapEdge` ≡ dim-0 `snapAxis` | delete; call `snapAxis` | −4 | H |
| FM-07 | OVER-ENG | `fullscreen.zig:219-222` | casts run every ConfigureNotify | fold into FM-03 (early orelse return) | 0 | H |
| FM-08 | OVER-ENG | `minimize.zig:301-306` | `hideWindow` widening wrapper | bind `minimize` directly if coercion compiles | −3 | M [~] |
| FM-09 | READ | `workspaces.zig:44-46` | `h == null or !h.?.eql(ws)` optional churn | `if (h) | hw | !hw.eql(ws) else true` | −1..−2 | M |
| FM-10 | OVER-ENG | `workspaces.zig:59-71` | if/else-if three-hook consult | explicit restructure | −3 | M [~] |
| FM-11 | CONSIST | `floating.zig:74,174,251` | `borders.width()*2` vs `core.borderWidth()` | one spelling (fold into F-08) | 0 | H |
| FM-12 | COMM | `fullscreen.zig:91-99` | 9-line covering-switch comment now self-evident | compress to ~4 | −5 | M |

---

## 5. `src/tiling/`

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| T-01 | DUPL | `tiling.zig:233-236` + leaf/fib | `emitOverflowShare` re-derives focusedElse head-fallback | drop `top` param; fold "fallback is head" into one doc | −2 | H |
| T-02 | OVER-ENG | `tiling.zig:56-61` | `clampAspectDim` max cap provably redundant with caller `@min` | signature `(other, ratio, inc)` | −3 | H |
| T-03 | CONSOL | `tiling.zig:264-272` + pipeline/actions | `layoutKindOf` = alias of `layoutKindFallingBack` | delete; 2 call sites | −10 | H |
| T-04 | API | `tiling.zig:276,282,322` + actions/pipeline/persist | hand-rolled `kind >= tiling_mods.len` at 8 sites | optional `moduleOf(kind)` seam | −1..−5 | H [~] |
| T-05 | COMM | `tiling.zig:341-347` | `layoutModule` has no doc | 3-4 line doc | +4 | H |
| T-06 | OVER-ENG | `tiling.zig:182-184` | `paneCell` single-owner export | move into grid.zig private | 0 | H |
| T-07 | COMM | `tiling.zig:313-319,323` | "defensive only" understates n=0 contract (grid div-by-zero) | reword | 0 | H |
| T-08 | OVER-ENG | `tiling.zig:292-301` | `cycleKind` guard unreachable under config cap | document, don't delete | −1 | M |
| T-09 | CONSOL | `tiling.zig:240` vs `contract.zig:48-49` | twin registry imports | import via contract's guarded re-export | 0 | H |
| TM-01 | READ | `master.zig:126-187` | `fillHeights` conflates pin pass + two distributions | extract `pinCapped` (+10 net) [~ no golden test on pin path] | +10 | M |
| TM-02 | OVER-ENG | `master.zig:146` | `if (zero_boost)` branch is a constant (weight = 1.0 anyway) | drop | −1 | H |
| TM-03 | OVER-ENG | `master.zig:147-150,178-179` | unreachable `else 0` arms (rem_weight ≥ rem_count) | direct compute + note | −2 | H |
| TM-04 | API | `master.zig:239-242` | u32 widening noise; `space_per_window` re-expresses `rowPitch` | u16 saturating + `rowPitch` reuse | −3 | M |
| TM-05 | COMM | `fibonacci.zig:41-42`,`leaf.zig:44-45` | stale "recursive path/spiral" | drop "recursive" | −2 | H |
| TM-06 | DEAD | `monocle.zig:4` | unused `utils` import | delete | −1 | H |
| TM-07 | READ | `scroll.zig:50` | double `@intCast` | saturating u16 add | −1 | H |
| TM-08 | COMM | `scroll.zig:9-12,43-45` | grow-duty explained 3× | shrink inline note | −2 | H |
| TM-09 | READ | `fibonacci.zig:56` | repeated geometry gate + `border2` single-use | `const min_region` | 0 | H |
| TM-10 | READ | `fibonacci.zig:97-103` | mirror-symmetric advance block re-tests `split_x` ×3 | nest by axis | 0 | H |
| TM-11 | OVER-ENG | `leaf.zig:47` | `@as(@TypeOf(dim),…)` type-dance | saturating idiom | 0 | H |
| TM-12 | DUPL | `grid.zig:49-50`,`master.zig:296,305` | cell+qap stride idiom ×4 | `cellStride(cell, gap, i)` helper | −2 | M |

---

## 6. `src/input/`, `src/model/`, `src/main.zig`

### 6.1 input (+ xkbcommon + keybind + keysyms)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| IN-01 | OVER-ENG/DEAD | `events.zig:337-343`, `input.zig:62-66,74-75` | reload-time XKB null-guard unreachable (no reload re-init) | delete guard; doc only boot/shutdown null window | −10 | H [~] |
| IN-02 | API | `xkbcommon.zig:45,117,149,211,232,263` | `*anyopaque` connection threading forces 5 ptrcasts | `core.Connection` | −6 | H |
| IN-03 | COMM | `input.zig:24-37,61-75`,`keysyms.zig:1-12`,`xkbcommon.zig:24-36,110-116` | ~45 lines history/why prose | condense to one-line pointers | −40..−60 | H/M |
| IN-04 | CONSOL | `input.zig:184-185` + `prompt.zig:521` | modifier-keysym band test duplicated inverted | `masks.isModifierKeysym(k)` | 0 | H |
| IN-05 | DUPL | `xkbcommon.zig:131-137,149-160` | init/rebuild duplicate acquire+build-table | `tableForDevice` | −5 | H |
| IN-06 | OVER-ENG | `keysyms.zig:33` | never-firing `buf.len == 0` guard | delete | −1 | H |
| IN-07 | READ | `input.zig:159` vs `77/97` | two access styles for module global | uniform `getXkbState()` | 0 | H |
| IN-08 | DUPL | `xkbcommon.zig:211-227,232-239,263-278` | three retry loops with same skeleton | optional comptime `withRetries` [~ judgment] | −8..−12 | H [~] |
| IN-09 | READ | `input.zig:330-331,364,366` | `dirSign` float dance | `dirSignFloat` | +3/−2 | H |
| IN-10 | COMM | `xkbcommon.zig:175-181` | keysymToKeycode doc digression | trim to 2 load-bearing facts | −5 | H |
| IN-11 | CONSOL | `keybind.zig:74`,`xkbcommon.zig:245,248` | local thresholds vs count constants | reference constants / why-comment | 0 | M |
| IN-12 | COMM | `input.zig:43-47` vs `keybind.zig:16-20` | resolver-ownership rationale twice | collapse to pointer | −4 | H |

### 6.2 model + main

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| M-01 | DUPL | `model.zig:332-337` | floating tier re-binary-searches entry it holds | `if (row.key == excluded or !visibleEntry(m, row.val.*, ws)) continue;` | −1 | H |
| M-02 | COMM | `model.zig:272-277,1-5` | "ONLY transition logic" banner false | enumerate actual set; trim | −5 | H |
| M-03 | DUPL | `model.zig:341-361` | stepTiled→reorderTiled double resolve | `moveTiled(list, win, from, to)` | −2..−3 | H |
| M-04 | READ | `main.zig:121-148` | HANA_RESTORE adoption block mid-boot-list | extract `adoptRestoredSession` | −1..−2 | H |
| M-05 | DUPL | `model.zig:99-101,156-158,176-178` | `home_ws` semantics ×3 | keep findHome authority; trim others | −3..−4 | H |
| M-06 | COMM | `model.zig:116-119,127-129` | doc bloat on one-line re-exports | condense | −3 | H |
| M-07 | READ | `main.zig:154-158` | type name `X` opaque | `XSession` | 0 | H |
| M-08 | READ | `model.zig:395-400` | one-line packed clamp | wrap | 0 | H |
| M-09 | COMM | `model.zig:134-139,20-21` | bit/lowestBit bound prose | cross-ref u64 width | 0 | M |
| M-10 | API | `model.zig:198` | `visibleEntry` by-value Entry on hot paths | `*const Entry` [~] | 0 | H |

---

## 7. Whole-tree seams (interconnect agent)

| # | Cat | File:Line | Title | Change | LoC | Conf |
|---|---|---|---|---|---|---|
| X-01 | REGISTRY | `events.zig:97,105`, `window.zig:946`, `pipeline.zig:312-314` | 4 manual registry fan-outs bypass `dispatchAll`/`callAll` | route through them; drop events' `window_mods` import | −6 | H |
| X-02 | TEST | `helpers.zig:65-78`,`sync_test.zig:40-47`,`tracking_test.zig:49-55` | 3 spellings of sync.Ctx fixture; magic 1920×1080 | `makeCtx(sink, color_of, screen)` + std_wa | −8 | H |
| X-03 | TEST | `helpers.zig:36-39` vs `tracking_test.zig:37-44` | `setUpModel` name collision (by-value vs pipeline-global) | rename local | 0 | H |
| X-04 | IMPORTS | `model.zig:7-8` + `utils.zig:101-103` | `Store` missing from facade → double import | re-export in utils; drop model's bounded import | 0 | H |
| X-05 | DUPL | `tiling.zig:129` vs `floating.zig:98-100` | `satI16`/`clampI16` twins | unify in utils | −3 | H |
| X-06 | DUPL | `types.zig:676-684` vs `utils.zig:162-191` | scale dup (see CF-02) | — | — | — |
| X-07 | REGISTRY | `title.zig:41-43` | overlay for-loop re-implements `providerOf` | use it | 0 | H |
| X-08 | REGISTRY | `bar.zig:779,1337` | `.collectHiddenSet` scan ×2, raw spelling | file-scope bound `window.providerOf(.collectHiddenSet)` | −2 | H |
| X-09 | DUPL | `actions.zig:528` | stepVariantDir mod-wrap (see U-06) | — | — | — |
| X-10 | API | `icccm.zig:58-61` + `window.zig:278,296` | `reset(bool)` = init/disarm | rename (see W-15) | 0 | M |
| X-11 | TEST | `model_test.zig:53-61` | double-armed module stores (testReset already arms) | drop init/deinitModules | −8 | M |
| X-12 | CONST | `prompt.zig:821` + `persist.zig:253,256` | `0o600` spelled twice | `paths.restricted_file_mode` | 0 | M |
| X-13 | BARREL | `segment.zig:299,314`; `persist.zig:92`; test mid-fn imports | minor hygiene | −4 total | H |

---

## 8. Deferred & questions (owner judgment required)

These were surfaced by the audit but deliberately parked: implementing them would change
observable behavior, cut a documented perf capability, or needs a product decision. Risk
is *not* the reason for deferral — semantic policy is.

| # | Item | Why deferred | Question to owner |
|---|---|---|---|
| Q-01 | **C-16** `parser.lastScalar` conflates literal arrays with accumulation. Observable today: `border_focused = [#aa0000, #008800]` yields solid `#008800` (last element), never the documented 50/50 bare-list mix; duplicate palette-*name* declarations average instead of later-wins. | Two documented features share one shape; which wins is a design decision with test pins on both sides. | Should `colorFromValue`/`asScalar` stop treating literal arrays as scalars and let `resolveColorExpr` own literal arrays (mix), keeping later-wins only for genuinely duplicated keys? If yes, I need to add regression tests and re-verify the "later declaration wins" pins. |
| Q-02 | **ST-01** title.zig memo removal (−110 LoC). Output-identical, but `SegmentedTitlesMemo` exists so a scrolling split-view doesn't re-gather + re-measure every frame. | Cuts a *deliberate* perf capability on the scroll path (Pango shapes/caches absorb most cost per the audit, but the gather is O(k log k) per frame). | Remove the memos (cleaner, −110) or keep them and treat as documented perf code? |
| Q-03 | **B-01** `RightCluster` (−25..−30). Keeps a per-frame Pango re-measure for right segments; falls back to re-measure for >16 anyway. | Behavior-identical but touches the hottest geometry path in the bar; the audit rated it MED risk. | Implement, or keep the cache and only add a verdict comment? |
| Q-04 | **P-02 / P-05** slider `Level` removal + pct↔range consolidation. | The `Level` struct is the only place the "commit-then-reread" apply discipline is documented centrally; the pct↔range formulas are pinned by two test suites and previously owner-deferred pending a rounding ruling. | OK to delete `Level` (subs bind hooks directly) and centralize the linear pct↔range map in slider.zig (nearest-round, unchanged)? |
| Q-05 | **U-04** `ids.fromIndex(anytype)` (−14 casts). | The `u8` param is *documented as intentional* ("prevents confusing indices"); widening to `anytype` trades Debug compile-error for ReleaseFast silent truncation. | Widen to `anytype` for the cast hygiene, or keep the strict u8? |
| Q-06 | **F-02** tracking `workspace_count` mirror → config-direct latch; drop modules' init/deinit bindings. | Touches module-registry wiring (deletion of bindings) and the teardown `0` latch; the audit rated MED. | Implement (behavior preserved via init-time latch) or keep the mirror with a corrected header? |
| Q-07 | **W-04** `detachTiledToFloating` leaves a stale `tiled_order` membership contradicting its own comment. | This is arguably a latent bug fix (unify on `removeValue`), not pure simplification. | Apply the membership fix (drift-correct + comment), or is the stale-list resolution load-bearing for `findHome`? |
| Q-08 | **B-14** multi-family Pango font "fallback support" is first-family-only. | Fixing it is a *behavior change* (log + feature honesty). | Ship the behavior note (pass pre-joined names through to Pango), or just correct the log/comment? |
| Q-09 | **IN-08** three XKB retry loops → comptime `withRetries`. | `anytype` closure plumbing may read worse than the ~10 lines it removes; audit split judgment. | Worth the generic, or leave the three loops with the shared skeleton documented once? |
| Q-10 | **K-01 / S-03** pipeline grab-pair fold + `reconcileUnderGrab` fold. | Ordering semantics are the load-bearing part of the focus/latency path; each fold touches 7-8 call sites incl. test fixtures and moves the RETILE_PROF home. | Apply both folds (with `focus_latency_test`/`tiling_latency_test` re-runs), or only the high-confidence `reconcileGrabFocus` fold? |
| Q-11 | **B-17 / LV-04 / T-04 / T-01 / FM-01 / FM-03** medium-risk structural items (widthState key, segdraw content mode, moduleOf seam, fillHeights pinCapped). | Each trades several lines/API surface in a module with no golden test on the touched path. | Apply the mechanically pure ones; leave the ones whose route lacks test coverage (fillHeights pin path) as owner-decision? |

---

## 9. Implementation log

Filled in as items land. Each subsystem patch must pass: `zig fmt`, `zig build check`,
`zig build test`, and a re-`rg` of every removed symbol.

| Date | Patch | Items | Checks | LoC net |
|---|---|---|---|---|
| 2026-09-24 | baseline | — | check ✓ / 282 tests ✓ | 0 |
| 2026-09-24 | config | C-01..C-13, C-15, CF-01..CF-07 (C-14 skipped: restructure duplicates the dispatch switch, net-negative; C-16 deferred Q-01) | check ✓ / tests ✓ | −~75 |
| 2026-09-24 | core | U-01..U-03, U-05..U-07, U-11..U-13, U-16 (U-04 deferred Q-05; U-15 skipped: net-zero helper, no clear win); K-02..K-12 (K-01 deferred Q-10); S-01, S-02, S-04..S-14 (S-03 deferred Q-10); X-05, X-12; model.zig Store via utils facade, bounded import dropped (X-04) | check ✓ / tests ✓ | verified |
| 2026-09-24 | window | W-01..W-03, W-05..W-15 (W-04 deferred Q-07; W-16 skipped: named atom lookups clearer than a table; W-18 KEEP: documented alias layer); X-09, X-10; F-01, F-03..F-12 (F-02 deferred Q-06; F-04 folded fallback into `sendBorderColorIfChanged`; F-07/F-11/F-12 tracking header rewrites); FM-02, FM-04, FM-05, FM-06, FM-08..FM-10, FM-12 (FM-01/FM-03 deferred Q-11; FM-07 folded into FM-03; FM-11 folded into F-08) | check ✓ / tests ✓ | verified |
| 2026-09-24 | tiling | T-02 (clampAspectDim max-cap drop), T-03 (layoutKindOf deleted; callers → layoutKindFallingBack), T-05..T-09 (layoutModule doc, paneCell→grid, compute n=0 doc, cycleKind guard doc, registry via contract), TM-02 (zero_boost weight branch constant), TM-03 (dead `else 0` arms), TM-04 (space_per_window u16 + rowPitch), TM-05..TM-12 (recursive→spiral prose, monocle utils import, scroll casts/comment, min_region, axis-nest, leaf type-dance, cellStride) (T-01/T-04/TM-01 deferred Q-11) | check ✓ / tests ✓ | verified |
| 2026-09-24 | input | IN-01 (reload XKB guard deleted; boot/shutdown-only docs), IN-02 (`*anyopaque` → `core.Connection`; FFI boundary keeps 4 `@ptrCast` — xkbcommon-x11's own cimport opaque), IN-03 (history prose condensed in input/keysyms/xkbcommon), IN-04 (`masks.isModifierKeysym`; prompt too), IN-06 (never-firing buf guard), IN-07 (uniform `getXkbState`), IN-08 deferred Q-09, IN-09 (`dirSignFloat`), IN-10 (keysymToKeycode doc trim), IN-11 (name_buf why-comment; xkbcommon thresholds already named consts), IN-12 (resolver-ownership → pointer to keybind) | check ✓ / tests ✓ | verified |
| 2026-09-24 | model/main | M-01 (floating tier uses held row), M-02 (transition banner → enumerated set), M-03 (`moveTiled` — no double resolve), M-04 (`adoptRestoredSession`), M-05 (home_ws docs → findHome pointer), M-06 (re-export doc bloat), M-07 (`X` → `XSession`), M-08 (adjustPrimaryWidth wrap), M-09 (lowestBit cross-ref), M-10 (`visibleEntry` → `*const Entry`; sync at()). | check ✓ / tests ✓ | verified |
| 2026-09-24 | seams | X-01 (events.zig fan-outs → window.dispatchAll, dropped window_mods import; pipeline armPendingBarShow → contract.callAll; window.zig:946/window_mods import; setEwmhFullscreenState kept manual — two arg tuples per module) | check ✓ / tests ✓ | verified |
| 2026-09-24 | test hygiene | X-02 (makeCtx(sink, color_of, screen) + std_wa; sync/tracking fixtures → makeCtx), X-03 (tracking_test setUpModel → pipelineModel), X-11 (initModules/deinitModules dropped; setUpModel already arms via testReset) | check ✓ / tests ✓ | verified |
| 2026-09-24 | bar | B-02 (drawPaddedSegmentValue no-split fallback → paintedSegment), B-03 (hasLayoutSegmentDirty direct loop), B-04 (BarSetup.dc dropped), B-05 (segAt doc fixed), B-06 ("live state" doc → State), B-07 (centerRowBudget extracted), B-08 (→ contract.Segment), B-09 (gather slice + folded clamp), B-10 (cached_metrics tuple), B-11 (bar-height consts + clampBarHeight → scale.zig), B-12 (foldModuleRedraw ×3), B-13 (named is_right_click), B-15 (probeMetrics → FontMetrics directly), B-16 (titleIdBound); B-01 deferred, B-14 deferred [behavior note: font fallback keeps first family] | check ✓ / tests ✓ | verified |
| 2026-09-24 | bar | ST-02 (naturalWidthFor deleted; fact onto g_slot_width), ST-03 (emptyWorkspace inlined), ST-04 (batt direct bufPrint), ST-05 (marquee shared ellipsis tail), ST-06 (systatus essay cut), ST-07 (render_buf_len), ST-08 (segmentBounds/segmentIndexOfX → segmod), ST-09 (gather clamp, with B-09); ST-01 deferred Q-11 | check ✓ / tests ✓ | verified |
| 2026-09-24 | bar seams | X-07 (title overlay → providerOf), X-08 (collect_hidden_set file-scope), X-12 (0o600 → paths.restricted_file_mode), X-13 (segment.zig:299/313 via B-08; persist.zig:92 stale — no inline import; test mid-fn imports: none remain) | check ✓ / tests ✓ | verified |
| 2026-09-24 | Q-deferred | P-02 + P-05 (slider `Level` deleted; subs bind hooks directly; single shared nearest-round `slider.rawFromPct`/`pctFromRaw`; brightness pctFromRaw route → nearest per owner ruling, matching its dormant 75 pin) | check ✓ / 282 tests ✓ | verified |
| 2026-09-24 | Q-deferred | ST-01 (title.zig memo removal: `SegmentedTitlesMemo`/memo gathers/`needs_gather` delete, gather is per-frame again; scroll path notes kept) | check ✓ / tests ✓ | verified |
| 2026-09-24 | Q-deferred | B-01 (`RightCluster` inlined at both call sites; right-segment measure path unified) | check ✓ / tests ✓ | verified |
| 2026-09-24 | Q-deferred | B-14 (multi-family font "fallback support" honesty: pre-joined family list passed through to Pango; behavior + docs reconciled) | check ✓ / tests ✓ | verified |
| 2026-09-24 | Q-deferred | C-16 (`Value.array` gains `accumulated: bool`; literal single-declaration arrays keep it false so `colorFromValue`/`asScalar` never descend them and `resolveColorExpr` owns them as bare-operand mixes, while accumulated duplicate-key arrays stay later-wins: `lastScalar` only descends accumulated, `extractMixOperands` skips accumulated; regression tests: `[0xaa0000, 0x008800]` → 0x554400 mix, dup palette names → later-wins 0x008800; parser_test pins accumulated=false; `[#..]` colors note: bracket `#` spelling is a pre-existing parse limitation, `0x` spelling is the documented mix vehicle) | check ✓ / 284 tests ✓ | verified |
| 2026-09-24 | Q-deferred | W-04 (`detachTiledToFloating` now really drops `tiled_order` membership via `model.removeValue` before `home_ws = null`, matching its comment; call sites pass `m`; toggleFloating round-trip re-enters via `repairStrandedHome` → `home_ws`/tiled_count pin updated; X-gated actions_test verified under xtest.sh/Xvfb, not skipped) | check ✓ / 284 tests ✓ | verified |
| 2026-09-24 | Q-deferred | U-04 (`fromIndex(anytype)` with the checked cast centralized inside — callers pass native int types, ~10 `@intCast` wrappers dropped at call sites; `@intCast` on the runtime value is the same checked/ReleaseFast-behavior as before; inline shelf tests were never wired to a test root, so moved into the first real `ids_test.zig` module + `test_gates` row) | check ✓ / layers ✓ / 286 tests ✓ | verified |
| 2026-09-24 | Q-deferred | F-02 (tracking workspace count latched from config at `tracking.init` via a new `core.isReady()` guard so headless test harnesses keep the default rather than panicking; `setWorkspaceCount` deleted; the write-only `state.initialized` deleted; workspaces module init/deinit + lifecycle bindings dropped) | check ✓ / layers ✓ / 286 tests ✓ | verified |