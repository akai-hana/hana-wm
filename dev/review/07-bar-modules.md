# Bar modules review (`src/bar/modules/**`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

All modules bind the generated registries (`bar_modules`, `slider_subs`, `systatus_subs`, `title_subs`, `prompt_subs`) — membership is file presence, so dropping a file degrades the bar instead of breaking it.

---

## Standalone segments

### `bar/modules/clock.zig` (266 lines)  **★**
**Now:**
```
DisplayMode = { date_time, time, date }
measureStringFor(mode) -> probe string      // stable per mode
effectiveFormatFor(base, mode) -> []u8
cycledMode(mode, forward) -> DisplayMode
stalenessFor(sec, rendered_sec, fmt, rendered_fmt) -> bool
deadlineFromMs(now) -> i32                  // ms to next second boundary
draw(): render per mode; left-click cycles forward, right-click reverse
pollTimeoutMs() -> deadline                 // wakes exactly at boundaries
```
**Verdict:** ★ — single-threaded by construction; wake-at-boundary scheduling (not a 1s timer) means zero spurious repaints; staleness math is pure and unit-tested.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/tags.zig` (276 lines)  **◐**
**Now:**
```
label_widths[] / ws_width / cache_valid     // measured-once width cache
all_view collapse (Mod+5): one cell labeled "花"
getLabel(i): workspace_icons -> workspace_labels -> "?"
invalidate() / ensureCache(...)
draw(): per-workspace cell: label + activity glyph (focused/urgent/occupied)
```
**Verdict:** ◐ — correct cache invalidation and the all-view collapse is a nice touch; the cell geometry and glyph metrics are interleaved with the draw loop (could be a `geom.zig` sibling like title has), but the file is small enough that the split is optional.
**Ideal:** same + optional `tags/geom.zig` for cell layout.
**Path:** none required.

### `bar/modules/layout/layout.zig` (46 lines)  **★**
**Now:** `getIcon()` via `contract.activeLayoutMeta(currentLayout, tilingEnabled, pick=icon, "><>")`; `draw` via `scaffold.drawAndStore`; `module(...)` with `cycleLayoutKind` click.
**Verdict:** ★ — resolves metadata through the contract seam, never names the tiling registry; absent-tiling degrades to `"><>"` with zero code changes.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/layout/variants.zig` (54 lines)  **★**
**Now:** `getIndicator()` — active variant's indicator via the same `activeLayoutMeta` seam; empty indicator = zero-width slot (a successful zero-width draw, not a failure).
**Verdict:** ★ — the `Painted` distinction (zero-width success vs failure) is handled correctly.
**Ideal:** unchanged. **Path:** none.

---

## Prompt (inline command runner)

### `bar/modules/prompt/prompt.zig` (447 lines) — activation lifecycle + key routing  **★ (split DONE)**
**Now:**
```
Mode = { insert, normal }  (+ label/hintWidth; pill policy owned by Mode)
EditorState = { buf, cursor, ... }   // bounded 256-char input
insertSlice / deleteRange / overwriteAt / insertChar
handleCtrl / handleInsertBasic / insertChar      // basic editor
registerHandlers(h)                              // mode handler table
wordAtCursor(buf, cursor) -> WordAtCursor
run history: append + load-order list (~/.local/share/drun/history)
completion: provider seam (run-segment entries -> completions)
Addon = { register, init, deinit }  + addons from prompt_subs registry
draw: prompt overlay on title segment, mode pill, hint text
key routing: Escape/Return/BackSpace/Delete/arrows/Home/End
onActivate/onDeactivate; presentForPrompt/dismissAfterPrompt glue
```
**Verdict:** ★ (split DONE) — the four concerns are now four files: `editor.zig` (buffer + basic key handling, 283 lines), `completion.zig` (provider seam + run history, 481 lines), `render.zig` (overlay draw, mode pill, hint, 498 lines), and this file (activation lifecycle, `Addon` contract, registry, key routing, 447 lines). The vim addon already proved the seam works; the host no longer needs to be big.
**Ideal:**
```
prompt/editor.zig    — EditorState + buffer ops + basic key handlers
prompt/completion.zig— provider seam, run history, completion rendering
prompt/render.zig    — overlay draw, mode pill, hint width
prompt/prompt.zig    — lifecycle, Addon contract, registry, key routing
```
**Path:** DONE — extracted in waves (editor → completion → render), each wave gated on `zig build` + `vim_test`/`completion_test`; full suite, `check-layers.sh` and all 31 `check-modularity.sh` scenarios pass. All names re-exported through `prompt.zig`, so `vim.zig` and the tests import through the package core, unaware of the split.

### `bar/modules/prompt/vim.zig` (482 lines)  **◐**
**Now:**
```
Prefix = { count, op, op_count, arg }   // vim prefix state machine
Arg = { none, find_char, g_prefix }
handleCtrl / handleInsert / handleNormal  // mode handlers
onDeactivate / init / deinit / register   // Addon binding
motions: word/line/char finds; operators: d/c/y; registers: yank buf
```
**Verdict:** ◐ — a faithful modal engine bound as an addon (membership via `prompt_subs`); cohesive as one file because the prefix machine, motions, and operators are one state machine. The `register()` hook swaps handlers in, leaving the basic editor when absent.
**Ideal:** unchanged. **Path:** none.

---

## Slider core + controls

### `bar/modules/slider/slider.zig` (715 lines)  **◐**
**Now:**
```
Sub = { name, label, read, pct, preview, commit, apply, ... }
subs = slider_subs registry (file presence + self-declared role)
segmentFor(i) -> Segment            // each control is its OWN segment
Throttle                            // commit scheduler (subprocess commits only)
interaction shell: click hit-test, press-hold drag, wheel +/-2%,
  right-press secondary action
poll loop: per-control cadence + owed-sweep
per-segment lifecycle: arm-on-first-draw, dirty redraw, painted width
```
**Verdict:** ◐ — the closed-core/open-module split is exactly right, and the documented decision *not* to merge with systatus.zig (interaction + throttle + cadences vs read-only fixed cadence) is correct — a shared scaffold would be a parameterized contract surface around a thin body.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/slider/volume.zig` (528 lines)  **◐**
**Now:**
```
Backend ladder (most-native first):
  1. native_pulse (dlopen libpulse.so.0)
  2. native_alsa  (controlC* ioctls)     [only when no PulseAudio runtime]
  3. pactl subprocess
  4. amixer subprocess
LATCHED after first successful read; negative-cached on total failure
  (recheck via probeDue + slow deadline so a late daemon is picked up)
g_pct / g_muted / g_has_value; commit clamps 0-100 (single guard)
```
**Verdict:** ◐ — the ladder + latching + negative cache is the right perf story (a dead daemon costs one probe, not a popen per event); the file is long because it owns the ladder policy over four backends, which is its job.
**Ideal:** unchanged (backends already in their own files). **Path:** none.

### `bar/modules/slider/brightness.zig` (428 lines)  **★**
**Now:**
```
Backend: sysfs (/sys/class/backlight/<dev>/brightness + max_brightness)
  first; brightnessctl subprocess on first denied write (EACCES/EROFS)
  or missing sysfs; latches permanently
Device: auto-discovery (lexicographically smallest, positive max) or
  brightness_device pin ("led:" prefix -> /sys/class/leds/*)
g_read_only: displays but no-ops when unwritable; zero-width when no device
sysfs helpers take explicit `base` root -> tests use a fabricated tree
```
**Verdict:** ★ — sysfs-first is the correct native path (one file write per commit, no throttle); the testable-by-root-argument design is exemplary.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/slider/native_alsa.zig` (372 lines)  **★**
**Now:**
```
scan controlC0..31; enumerate elements (SNDRV_CTL_IOCTL_ELEM_LIST);
  attach first MIXER INTEGER "Master Playback Volume" (fallback "Master"),
  plus BOOLEAN "Master Playback Switch"
setVolumePct / readVolumePct / readMuted    // single ioctl per op
isShimCard(name) -> bool                    // skip PipeWire softvol cards
rawFromPct / pctFromRaw                     // linear [min..max] <-> 0-100
```
**Verdict:** ★ — dependency-free kernel ABI with runtime-verified struct sizes; the activation gate (no PulseAudio runtime) is documented and correct (writing the card control under PipeWire would move the wrong element).
**Ideal:** unchanged. **Path:** none.

### `bar/modules/slider/native_pulse.zig` (480 lines)  **★**
**Now:**
```
std.DynLib dlopen("libpulse.so.0"); symbols resolved at runtime
pa_sink_info read as raw bytes with offset guards (server_version2
  hole: default_sink_name at offset 40 or 48, first plausible wins)
attach once, cached; ops under mainloop lock with bounded wait
  (a dead daemon cannot hang the WM loop)
readSink / setVolumePct / setMuted
```
**Verdict:** ★ — zero link-time dependency, runtime ABI guards on every field, bounded waits; the version-dependent offset handling is exactly the right level of paranoia for dlopen'd structs.
**Ideal:** unchanged. **Path:** none.

---

## Systatus core + readouts

### `bar/modules/systatus/systatus.zig` (334 lines)  **★**
**Now:**
```
Sub = { name, label, read: *const fn () ?Sample }
Sample = { text }   // display text owned by the readout (25.3)
percentSample(buf, pct) -> Sample
readFileChecked(path, buf) -> ?{ bytes, truncated }   // truncation-aware
render(label, sample, buf) -> Rendered
segmentFor(i) -> Segment     // each readout is its OWN bar segment
per-segment lifecycle: arm-on-first-draw, 2s poll, dirty redraw
```
**Verdict:** ★ — truncation-aware reads (the /proc/stat buffer cliff is fixed by design, not per-module); `Sample` carrying display text lets a readout report anything (temp, bytes, "up") without abandoning the registry.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/systatus/cpu.zig` (132 lines)  **★**
**Now:**
```
parseCpuLine(s) -> ?{ total, idle }   // pure; leading "cpu " line only,
                                        // all fields (10+ kernel counters)
read(): delta of total/idle jiffies vs previous sample;
  first read primes with one real measurement (boot_priming_ns)
```
**Verdict:** ★ — the pure parser (field-count-agnostic, newline-bounded) is the fix for the "silently blank on big machines" bug; priming makes the first frame render like every other segment.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/systatus/ram.zig` (49 lines)  **★**
**Now:** `parseRamField` (pure); `usedPct(total, avail)` (pure, clamped); `read()` via truncation-checked `/proc/meminfo`.
**Verdict:** ★ — 49 lines, pure where possible, honest null on unreadable.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/systatus/batt.zig` (46 lines)  **★**
**Now:** `parseCapacity` (pure, range-checked); `read()` probes `BAT0..7`, first valid wins, null when none (zero-width slot on battery-less machines).
**Verdict:** ★ — absence is a renderable state, not an error.
**Ideal:** unchanged. **Path:** none.

---

## Title segment + addons

### `bar/modules/title/title.zig` (404 lines)  **★**
**Now:**
```
Scroll = { off: f32, cycle: f32, active: bool }   // ONE value per frame
Scroller = { offsetFor, pivot, pollDeadlineMs }   // the addon seam
draw(): split view over visible windows (geom.zig layout),
  prompt overlay, scroll decoration via the bound Scroller addon
needsRepaint forwards exactly the `active` bit (marquee repaints
  moving pixels whose data has not changed)
```
**Verdict:** ★ — the seam shape (`Scroll` as one value, declared in the contract, not the extensor) is the correct addon design: three formerly-separate queries that had to agree are now one call that cannot disagree.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/title/carousel.zig` (229 lines)  **★**
**Now:**
```
anchor-based motion: pos(t) = f(anchor, speed, now)   // PURE function
  of the anchor timestamp, not an accumulator over call history
offsetFor(win, title, text_w, avail_w, enabled, speed, now) -> Scroll
pivot()            // restart scroll on focus/title change (identity:
                     // window id + title hash)
pollDeadlineMs(now, hz) -> ms      // next wrap boundary
```
**Verdict:** ★ — exemplary: the design comment documents why an accumulator was wrong (double-draw = double speed, late draw = jump, lost dt = permanent speed change) and the anchor design eliminates all three. Position is a pure function of time.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/title/geom.zig` (148 lines)  **★**
**Now:**
```
WindowInfo = { window, x, y, title, minimized }
sortWindows(): non-minimized first, on-screen before off-screen,
  then left-to-right, top-to-bottom
segmentBounds(...) / inverse hit-test ...   // THE load-bearing pair,
                                             // kept together on purpose
```
**Verdict:** ★ — the draw and the click hit-test share one geometry kernel so a click can never select a neighbour; the file's own header documents why the pairing must not be split.
**Ideal:** unchanged. **Path:** none.

---

## Bar modules summary

- 18 files: 15 ★ (prompt.zig — four-way split DONE: editor/completion/render/orchestrator), 3 ◐ (tags — optional geom split; vim — cohesive as-is; slider core — documented why not merged).
- The closed-core/open-module pattern (systatus, slider, title, prompt) is consistent and correct throughout: file presence = registry membership = drop-in addon.
- Reference-quality designs to preserve as templates: carousel (pure time-anchored motion), systatus (truncation-aware reads), native_pulse (dlopen ABI guards), metrics/visibility (injected impure inputs).
