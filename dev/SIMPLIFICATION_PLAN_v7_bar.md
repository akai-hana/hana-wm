# SIMPLIFICATION_PLAN_v7 — bar core subsystem (`src/bar/`)

Research-only audit. No code was changed; every finding below was verified
against the current tree (`46f85d5`). Scope:

- In scope: `src/bar/bar.zig`, `drawing.zig`, `segment.zig`, `segdraw.zig`,
  `refresh.zig`, `win.zig`, `visibility.zig`, `metrics.zig`.
- Out of scope: `src/bar/modules/*` (sibling analysis), `src/test/*`.
- Invariant: preserve the `contract.Segment` surface + bar's public seam
  exactly; these findings are behavior-preserving.

## Findings

### bar.zig

### [BAR01] LOW/HIGH: bar.zig:230-233 — `onPollWakeup` calls `consumeRedrawRequest` redundantly
What: `onPollWakeup` does `if (barModsConsumeRedrawRequest()) { s.markDirty(); s.consumeRedrawRequest(); }`. `performDraw` already
consumes the redraw request (bar.zig:1111) immediately after its own
`barModsConsumeRedrawRequest()` gate, so the redraw request is double-consumed.

Why: The extra consume at :232 is dead against the next `performDraw` call in
the same batch; consume-before-draw is also the wrong order — the request
must outlive any early-return gate in `performDraw` until the redraw really
runs.

Concrete: delete `s.consumeRedrawRequest();` in `onPollWakeup`. The single
consume in `performDraw` (:1111) is the authoritative one. -2 lines.

### [BAR02] HIGH/MED: bar.zig:1716-1725 — `updateClock` hand-rolls the `callFirstTrue` fan-out
What: A manual `for (bar_mods) |m| { if (m.secondsElapsed) |h| { if (h(fmt)) { break; } } }` reimplements exactly what
`anyBoolHook(.secondsElapsed, .{fmt})` already does via
`contract.callFirstTrue` (contract.zig:324-334: iterate bound hooks, return
true on first true).

Why: Duplicated dispatch idiom; the codebase's own `anyBoolHook` helper
(bar.zig:143-144) was built for this.

Concrete: replace the loop with `if (!anyBoolHook(.secondsElapsed, .{fmt})) return;` — identical ordering/short-circuit semantics. -8 lines.

### [BAR03] MED/HIGH: bar.zig:83-107 — triplicated comptime empty-registry guard
What: `segAt`, `segDirty`, `setSegDirty` each carry the same
`if (comptime bar_mods.len == 0) { unreachable; } else { ... }` stanza
with identical doc-comments.

Why: Three copies of one invariant (`bar_mods` non-empty at comptime).

Concrete: one `inline fn hasRegisteredSegments() bool { return comptime bar_mods.len != 0; }`
plus `if (comptime !hasRegisteredSegments()) unreachable;` at the top of the
three helpers. -6..-9 lines (comptime-if guarantees the removed bodies are
still elided for the empty registry).

### [BAR04] HIGH/HIGH: bar.zig:674 — `markAllSegmentsDirty` is a single-caller wrapper
What: `markAllSegmentsDirty` (workspace-drops-all case) has exactly one
caller, `fn markDirty` (bar.zig:613); the doc comment already documents the
caller/reason coupling.

Why: One-use indirection; the wrapper-name adds nothing over the caller's
already-commented loop.

Concrete: inline the `for (bar_mods) |m| self.markSegmentDirty(m.name)` loop
into `markDirty`. -4 lines.

### [BAR05] MED/HIGH: bar.zig:702-725 — `hasPendingRepaintWork` / `hasLayoutSegmentDirty` duplicate the two-level scan
What: Both helpers run the same `config.layout.items` → `lay.segments.items`
iteration (repaintable-vs-dirty predicate only). `hasLayoutSegmentDirty` also
handles the `segId`-null case that `hasPendingRepaintWork` bakes into its
predicate.

Why: Two copies of the layout-scan skeleton; a third variant appears in
`drawAllInner` (line ~974).

Concrete: `inline fn anyLayoutSegment(self: *const State, comptime pred: anytype) bool { ... }`
with `hasPendingRepaintWork = anyLayoutSegment(self, State.isSegmentRepaintable)`
and a small private dirty-pred. -5..-6 lines.

### [BAR06] MED/HIGH: bar.zig:113-127 — `isRole` and `selfTickerIndex` duplicate the registry-id search
What: Two inline-for scans of comptime `ids` differing only in whether they
yield the index (`?usize`) or a bool.

Why: Same mechanism; `isRole` is literally `selfTickerIndex != null`.

Concrete: one `fn roleIndexOf(name: []const u8, comptime ids: []const usize) ?usize`;
`isRole` becomes `return roleIndexOf(name, ids) != null;`. -4..-5 lines.

### [BAR07] LOW/HIGH: bar.zig:864-871 — `drawSegment` duplicates the missing-segment warn/return block
What: `segId(name) orelse warn-return` and `segAt(id).draw == null`
warn-return are two identical `debug.warnOnErr(error.DrewInvalidSegment,
"bar drawSegment"); return x;` blocks.

Why: Message/error string shared; only the guard condition differs.

Concrete: hoist the warn+return into a small `fn drewNothing() u16`
(or reuse a single resolve step). -3 lines. (Optional: distinct error codes
for the two conditions is the other way — avoid, it widens the surface.)

### [BAR08] LOW/HIGH: bar.zig:1672-1679 — `updateIfDirty` reads the same three core fact revs twice
What: `core.focus.rev()`, `core.window.rev()`, `core.layout.rev()` are each
called in the differ-check and again in the assignment tail, interleaved with
`markDirtySource`/`markDirty`/`requestFullRedraw` calls.

Why: Three redundant `rev()` calls per batch; reading once makes the
snapshot-vs-update pairing explicit.

Concrete: hoist the three reads into consts, use them for both check and
assignment. ~0 net LoC, removes 3 fn calls, read-only cleanup.

### [BAR09] MED/HIGH: bar.zig:952 — `drawRightSegments` re-extends a span already covered by `clearRegion`
What: `self.clearRegion(cur_x, seg_w)` (:948) already widens
`dirty_span` (region-scoped repaint); the following
`self.extendDirtySpan(cur_x, seg_w)` (:952, drawn branch) repeats the same
argument pair on the same span.

Why: Same class as the earlier site fixed in v6/BAR-N5 (left side, old :902):
re-extending an identical range on `dirty_span` is a no-op (non-decreasing
already achieved by `clearRegion`).

Concrete: delete the `extendDirtySpan` call (mirror how the left/layout-side
does it). -1 line.

### [BAR10] MED/MED: bar.zig:761 — `recordSelfTickerScope` dead zero-ticker guard
What: `if (self_ticking_ids.len == 0) return;` then `if (selfTickerIndex(name)) |i|`.
Both callers (bar.zig:943, 1041) gate on `isRole(s, self_ticking_ids)`
first, and `selfTickerIndex` over a comptime-empty list returns null anyway.

Why: Provably unreachable in the empty-registry build; the `segs[i]` indexing
is runtime-bounds-checked so no compiler protection is being bought.

Concrete: drop the guard (keep `isRole`/index gating at the two call
sites). -2..-3 lines.

### [BAR11] LOW/HIGH: bar.zig:1333 — `minimizedApiFromRegistry` is a one-use wrapper
What: 5-line registry probe with a single caller (fillDrawCtx, :780).

Why: One-use indirection of a 3-line loop.

Concrete: inline into `fillDrawCtx`. -4..-5 lines. (Borderline — the name
documents the seam; acceptable to leave.)

### [BAR12] LOW/MED: bar.zig:462-466 — `Clock.segs` block-initialized from a comptime `blk`
What: `${blk}: { ... }` loop zero-inits `[self_ticking_ids.len]SelfTickerScope`
when the type has no default.

Why: Initializer boilerplate; replaceable by `@splat(.{})` only if the
installed Zig (0.16.0) accepts structure-valued @splat — verify before
applying.

Concrete: if valid, `var segs: [self_ticking_ids.len]SelfTickerScope = @splat(.{});` -4 lines. (See Q1.)

### drawing.zig

### [BAR13] HIGH/HIGH: drawing.zig:775-790 — duplicated 8-line doc comment on `drawPaddedSegmentValue`
What: The exact same 8-line doc block appears twice back-to-back above
`drawPaddedSegmentValue` (a copy artifact).

Why: Pure comment bloat; the plan's ideology explicitly targets
copy/paste artifacts.

Concrete: delete the duplicate block. -8 lines.

### [BAR14] MED/MED: drawing.zig:763/791-833 — `drawPaddedSegmentValue` and `paintedSegment` re-implement fill+baseline+draw
What: `paintedSegment` already does width-`@max` with `min_w`,
`applyStyleProps`/`restoreStyleProps`, `fillRect`, `baselineY`, and the
fallback `paintText` tail — the exact preamble `drawPaddedSegmentValue`
re-implements before its value-partition loop. Only the value-split middle
differs.

Why: Largest single duplication in `drawing.zig`; the two wrappers share an
invariant (value-or-text rendering of a padded segment).

Concrete: extend `paintedSegment` with `value: ?[]const u8` (+ value_fg) so
the value-partition loop lives inside it; keep both pub wrappers as thin
adapters. Net -10..-16 lines after the doc-dup fix. (See Q2 for the
end-to-end confirmation ask.)

### visibility.zig

### [BAR15] LOW/HIGH: visibility.zig:62-64 — `keepPromptOverride` restates the `desiredVisibility` tail
What: `keepPromptOverride` re-runs
`shouldBeVisible(is_globally_visible, barForcedHiddenByFullscreen(ws))`,
the first three lines of `desiredVisibility` (also folded by
`updateBarVisibilityForWorkspace`/`applyFullscreenVisibility` paths).

Why: The natural visibility chain is spelled out in two places.

Concrete: extract `fn naturalVisibility(ws: u8, is_globally_visible: bool) bool
{ return shouldBeVisible(is_globally_visible, barForcedHiddenByFullscreen(ws)); }`
used by both `desiredVisibility` and `keepPromptOverride`. -2..-3 lines.

## Verification notes (audit v6 / audit-v7 claims re-checked against source)

- BAR-N10 (v6, claimed DONE) is NOT applied: `segdraw.Opts.clickable` still
  exists (segdraw.zig:57, forwarded at :116) and is load-bearing —
  `src/bar/modules/systatus/systatus.zig:209` sets `.clickable = false`.
  Treat the v6 plan's status claim as stale; the field must stay.
- WCD-10 (audit-v7) still open on the bar side: local
  `ungrabAndFlush()` shim at bar.zig:1168 with 4 call sites (:1321, :1380,
  :1393, :1602) sits outside the core `sink` seam; the ordering-reason
  comments at :1419/:1585 document why the local grabs bracket geometry +
  EWMH. Verified present; folded/wiring changes belong in a follow-up, not
  here.
- WCD-06 (providerOf chain) — bar.zig uses `contract.callFirst/...`
  directly; no local duplicate seam. No bar-side finding.
- v6's "only one `dirty.flag = false`" ruling verified: the single write is
  bar.zig:1159 (inside `performDraw`) and is load-bearing.

## DEFERRED / QUESTIONS

- Q1 — `@splat(.{})` validity for struct arrays in Zig 0.16.0 (guardian for
  BAR12).
- Q2 — BAR14 merge touches the two padded-segment draw paths end-to-end
  (title/carousel unaffected, but geometry must be byte-identical); needs
  one markup-level confirmation before applying.
- Q3 — `DesiredVisibility` + `naturalVisibility` refactor (BAR15) is
  optional churn; fine either way.
- Q4 — `refresh.detected_rate_hz` (refresh.zig:45) is an
  `std.atomic.Value(f64)`: assessed and dismissed — the module documents a
  lock-free publish for render pacing; keep the atomic.
- Q5 — `metrics.zig` (44-line singleton): previously examined and kept; not
  re-filed.
- Q6 — BARCR-18 bare-bool `applyVisibility(..., do_reconcile)` /
  `applyVisibilityDecision(ws, false)`: still open, unchanged, deferred.
- Q7 — Observation (not a simplification): `State.init` measures the clock's
  initial slot with unstyled `measureTextWidth` while `updateClock`'s merged
  width derives from the styled `reserved_width`. First-tick re-layout can
  result from the small divergence. Not actionable for this plan.

## Digest

Total estimated reduction across the 15 findings: ~65-75 lines in the eight
in-scope files, all behavior-preserving. Top-10 by expected yield:

| Id  | File | ~LoC | Title |
|-----|------|------|-------|
| BAR02 | bar.zig | -8 | updateClock → anyBoolHook |
| BAR14 | drawing.zig | -10..-16 | drawPaddedSegmentValue/paintedSegment unify |
| BAR03 | bar.zig | -6..-9 | empty-registry guard dedupe |
| BAR13 | drawing.zig | -8 | duplicated doc block |
| BAR04 | bar.zig | -4 | markAllSegmentsDirty inline |
| BAR05 | bar.zig | -5..-6 | anyLayoutSegment helper |
| BAR11 | bar.zig | -4..-5 | minimizedApiFromRegistry inline |
| BAR06 | bar.zig | -4..-5 | roleIndexOf |
| BAR12 | bar.zig | -4 | Clock.segs @splat (Q1) |
| BAR01 | bar.zig | -2 | poll-wakeup double consume |

by file: bar.zig 11 findings (~-46..-54), drawing.zig 2 (~-18..-24),
visibility.zig 1 (~-2..-3). Nothing to report for segment.zig, segdraw.zig,
win.zig, refresh.zig, metrics.zig.