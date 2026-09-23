# hana — Simplification Task List v8 (bar-modules audit)

Date: 2026-09-23. Method: research-only audit of every module under
`src/bar/modules/`. Every finding below was verified against the live tree
(full-file reads + `rg` call-site inventory) before listing. No code was
changed. Prior module-campaign items (BARMOD-T01..T05 from
`SIMPLIFICATION_PLAN_v6.md`) were re-verified as applied in the current source
and are **not** re-reported; BARMOD-T06 (optional) was left open and is re-listed
in §C.

Baseline reference: clean tree at `64755cf`; `src/bar/modules/` LOC per file in
the table below.

Inviolable constraints honored: the core never names a module (deletion
modularity) — nothing here touches `src/bar` core, `src/test/`, the
`plugin-template` segment contract, or merges the native_alsa/native_pulse
backends.

## A. Findings by module

### prompt/prompt.zig (1388 ln / 919 code) — 7 findings

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| P-01 | prompt.zig:505 | magic `& 0x7F` hardcoded while `masks.synthetic_event_mask` (u8 = 0x7f, masks.zig:52) exists and `masks` is already imported (used at :524) | use the named constant | 0 | H |
| P-02 | prompt.zig:357-362 | `copyToZ` 6-line C-string copy helper has exactly one call site (loadCompletions:681) | inline at the call site | −5 | MH |
| P-03 | prompt.zig:1032-1042 vs 1084-1099 | the visibility-clip (`px+w <= tl or px >= se` guard, `draw_x = @max(px, tl)`, clipped width) is spelled nearly identically in `drawScrollSpan` and `drawBlockCursor` | shared `inline clipSpan(tl, se, px, w) → { draw_x, visible_w }`; call sites keep their distinct ellipsis/suffix/block bodies | −3..−5 | MH |
| P-04 | prompt.zig:603-608 | `resetPromptEditing` has a single caller (activate:614) | inline its 4 assignment lines into `activate` | −4 | MH |
| P-05 | prompt.zig:819-821 + 944-948 | drun history path literal `.local/share/drun/history` spelled twice (histAppendToFile path build vs `history_suffixes` array) | hoist `const drun_history_suffix` and reuse (format arg differs only in the `{s}/` prefix) | −1 | H |
| P-06 | vim.zig:359-362 | `resolveCount` one-line `if n==0 →1` wrapper, single call site (effectiveCount:368) | inline | −2 | H |
| P-07 | vim.zig:183-229 | `wordScanFwd`/`wordScanBwd` mirrored state machines sharing a comptime `end` branch | [DEFERRED] see §C #5 | — | — |

### slider/{slider,volume,brightness,native_alsa}.zig — 3 findings + 1 deferred

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| S-01 | slider.zig:94-130 | Throttle's write tail (`write(pct); last_ms = nowMs(); pending = false`) copied in `apply` (:95-98), `flushOwed` (:115-118), `finish` (:125-128); `reset` (:107-110) repeats the last two | private `inline fn land(self, pct, write)` called by the three guards | −2..−3 | H |
| S-02 | brightness.zig:114-124 + native_alsa.zig:137-151 | `pctFromRaw`/`rawFromPct` implement the same linear 0-100↔[min..max] map twice; acts of `max==0`/`max<=min` and clamp are duplicated (rounding differs: sysfs brute-truncates the read, alsa rounds-nearest both directions for amixer parity) | one shared slider-core `pctFromRange`/`rangeFromPct` with a comptime `nearest_rounding: bool`, used by both controls (does NOT merge the backends) | −5..−7 | M |
| S-03 | volume.zig:160-185 + 220-241 | per-`.pulse`/`.alsa` branches in `commitPct`/`toggleMute` duplicate the native-else-spawn shape (differing native fn per arm) | [DEFERRED] see §C #2 | — | — |

### systatus/{systatus,cpu,mem,batt}.zig — 2 findings

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| SY-01 | cpu.zig:18-23, mem.zig:23-28, batt.zig:23-27 | the `std.Options.debug_io` + `openFileAbsolute` + `readPositionalAll` stanza is repeated across the three readouts (all already import `systatus`) | add `systatus.readSmallFile(path, buf) ?usize`; callers keep their parse | −5..−8 | H |
| SY-02 | cpu.zig:39-53 | baseline and delta branches duplicate the state write (`cpu_prev_total/idle = …` twice, :41-42 and :49-50) and both end in `@intCast(@min(busy,100))` | write the baseline state once, then compute `d_total = total -| prev`; when `d_total==0` report the boot-cumulative busy (the current baseline arm), else the delta — single exit tail | −3..−4 | M |

### clock.zig — 1 finding

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| CL-01 | clock.zig:101-103 | `stale()` single caller (secondElapsed:112-114) | inline the two-term comparison | −3 | H |

### tags.zig — 2 findings

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| TG-01 | tags.zig:41-43 | `getCachedWorkspaceWidth()` trivial getter, two callers (187, 192) | `ws_width` directly at both sites | −2..−3 | H |
| TG-02 | tags.zig:93-116 | corner anchoring hides `[x, y]` semantics behind a `[2]f32` + named-index constants `corner_x_axis`/`corner_y_axis` | switch directly to a 2-field struct (`.{ .x, .y }`) or to `(ax, ay)` pairs; drops the index indirection | −2..−4 | M |

### title/title.zig — 1 finding

| ID | Location | Issue | Fix | Est. LOC | Conf. |
|----|----------|-------|------|----------|-------|
| T-01 | title.zig:250-252 vs 268 | `drawMarqueeCell` spells the identical `drawTextEllipsis(geom.text_x, baseline_y, txt, geom.avail_w, fg)` twice (not-scrolling arm and the `scroller == null` fallthrough) | hoist a single ellipsis tail after the scroll branch | −2..−3 | M |

---

## B. Estimated total LoC delta (numbered findings)

P-01 0, P-02 −5, P-03 −4, P-04 −4, P-05 −1, P-06 −2, S-01 −3, S-02 −6,
SY-01 −7, SY-02 −4, CL-01 −3, TG-01 −3, TG-02 −3, T-01 −3.
**Total ≈ −48 (range −40..−56).** All findings are mechanical/behavior-preserving;
each carries its own test surface already exercised (slider commit_test pins the
Throttle contract; systatus readouts self-skip when files are absent).

## C. Deferred items & questions

1. **systatus/slider arm scaffold twins** — `pollDeadlineMsFor`/`onPollWakeupFor`/
   `consumeRedrawRequestFor` (systatus.zig vs slider.zig) are byte-identical but
   for `nowMs()` vs `utils.realtimeMs()` and the `read_interval` const. The
   systatus.zig:12-20 header documents this as a deliberate non-merge (per-index
   arrays + separate poll cadences). Recommend: keep, but add one cross-reference
   line in each header so future readers see the twin is intentional.
2. **volume backend-arm duplication (S-03)** — the native-else-spawn shape in
   `commitPct`/`toggleMute` differs in which native method+spawn string each arm
   uses; unifying needs a per-arm callback and starts to look like a vtable.
   Deferred — low value, and it brushes the "do not merge backends" seam.
3. **S-02 rounding policy** — alsa's nearest-rounding must be preserved (tests
   mirror `amixer`); brightness's truncating read looks like an inconsistency but
   *fixing* it is a behavior change. Owner ruling wanted: shared helper with both
   modes (finding) or leave as-is.
4. **BARMOD-T06 re-open** — prompt.zig:77 named `onDeactivate` no-op default vs
   anonymous siblings: still present and optional (0 LoC). Worth doing next round
   with the anonymous style.
5. **vim wordScanFwd/Bwd** — mirrored scans share a comptime `end` flag; merging
   onto one direction-parameterized scan risks subtle off-by-one. Left as-is.
6. **prompt histLoadFile / histPrepend** — the Wyhash seen-set + capped ring
   window (256 KiB) + dedupe feed into one another; behavior-critical and tested
   indirectly. Not touched.
7. **Q: title.zig:322 phantom `_ = s.offsetFor(...)`** — "retire" is achieved by
   calling the scroll offset function for its side effect with `scroll=false`.
   Works, but a dedicated `retireScroll(window)` (or a comment) would make the
   intent legible. Owner preference?
8. **Q: name twins** — slider's `nowMs()` (pub) is used by the test suite
   (commit_test.zig:21,43,76) and is a one-line alias of `utils.realtimeMs()`.
   Keep pub for tests, or add a `pub const nowMs = utils.realtimeMs` alias?

## D. Re-verified as applied (NOT re-reported)

BARMOD-T01 (commitMotion drops unused `vs`), T02 (runPromptCommand inlined),
T03 (slider bufPrint `catch return x + slot`), T04 (num_modes doc cites
prompt.Mode), T05 (variants.zig hoists `pipeline.model()`).

## E. Out-of-scope / no-action notes (recorded, not findings)

- `clock.zig:213` → `render` third-ish draw helper pending `texts` reuse — fine.
- `batt.zig:13` `battery_probe_slots` const — good (v1 C15-style, now named).
- `slider.zig:65` `scroll_step` — live (494-496), not dead.
- `carousel.zig` `resetForTesting` test seam — labeled, kept.
- `layout.{zig,variants.zig}` gate twin (`tiling_mods.len==0` + `activeLayoutKind
  orelse` + fallback) — ideology keeps the two deletable modules separate; header
  cross-reference addition suggested instead of a merge.