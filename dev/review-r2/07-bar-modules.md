# bar modules review (round 2)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

Re-verified fresh against the CURRENT tree (the prompt module was split since
round 1: `editor`/`completion`/`render` extracted; `prompt.zig` is now the
447-line orchestrator). All modules bind the generated registries
(`bar_modules`, `slider_subs`, `systatus_subs`, `title_subs`, `prompt_subs`) —
membership is file presence, so dropping a file degrades the bar instead of
breaking it. The closed-core/open-module shape (systatus, slider, title, prompt)
is consistent throughout, and the bar-optional rule holds: deleting `src/bar/`
leaves a compiling WM (the `surfaces` composition root no-ops). Time-based,
refresh-rate-aware animation is honored where it matters: the carousel paces on
`hz.detectedHz()` and positions itself as a pure function of the anchor
timestamp, and slider commits are throttled only where the backend is
rate-limited (subprocess spawns); native commits (sysfs write, ioctl, dlopen
call) land un-throttled. Verdicts below are my own fresh reading, not inherited.

---

## Standalone segments

### `bar/modules/tags.zig` (276 lines)
**Now:**
```
label_widths[] / ws_width / cache_valid     // measured-once width cache
all_view collapse (Mod+5): one cell labeled "花"
getLabel(i): workspace_icons -> workspace_labels -> "?"
invalidate() / ensureCache(...)             // per-state styling measured per cell
indicatorPos(cell_w, h, item, loc, pad) -> {x, y}   // corner-fraction anchoring
drawCell(...): bg + centered label + indicator glyph at cached intra-cell offset
drawFrame(): all-view single cell OR per-workspace cells
naturalWidthHook: count*ws_width (narrows to all_view_cell_width in all-view)
resolveWorkspaceClick: offset/cell_w -> idx (all-view -> null no-op)
onClickHook: left=switchTo, right=moveWindowTo(focused)
```
**Verdict:** ◐ — correct cache invalidation, the all-view collapse narrows the
reservation with it, and the per-state styling measurement (the selected tag
may render bold, so its glyph is wider) is a real correctness detail. The cell
geometry and glyph metrics (`indicatorPos` corner-fraction anchoring, the
cached intra-cell offsets) are interleaved with the draw loop; a `tags/geom.zig`
sibling (like `title/geom.zig`) would isolate the pure cell layout, but the
file is small enough that the split is optional, not required.
**Ideal:** same + optional `tags/geom.zig` for cell layout + `indicatorPos`.
**Path:** none required.

### `bar/modules/clock.zig` (266 lines)  **★**
**Now:**
```
DisplayMode = { date_time, time, date }
measureStringFor(mode) -> probe string      // stable per mode
effectiveFormatFor(base, mode) -> []u8
cycledMode(mode, forward) -> DisplayMode
stalenessFor(sec, rendered_sec, fmt, rendered_fmt) -> bool   // byte-compare, not ptr
deadlineFromMs(now) -> i32                  // ms to next second boundary
draw(): record staleness BEFORE the fallible strftime (one retry per boundary,
        never a per-event-batch storm); re-measure slot once per mode
pollTimeoutMs() -> deadline                 // wakes exactly at boundaries
```
**Verdict:** ★ — single-threaded by construction; wake-at-boundary scheduling
(not a 1s timer) means zero spurious repaints; staleness math is pure and
unit-tested. The `rendered_sec = sec` placement ahead of `formatTime` is
load-bearing and documented: a persistent render failure degrades to one retry
per boundary, not a storm. The byte-compare (not pointer-compare) on the
format catches a reload that lands a different format at a recycled address.
**Ideal:** unchanged. **Path:** none.

---

## Systatus core + readouts

### `bar/modules/systatus/systatus.zig` (334 lines)  **★**
**Now:**
```
Sub = { name, label, read: *const fn () ?Sample }
Sample = { text }                            // display text owned by the readout
percentSample(buf, pct) -> Sample
readFileChecked(path, buf) -> ?{ bytes, truncated }   // truncation-aware
render(label, sample, buf) -> Rendered       // PURE: "<label> <value>" + value span
refresh(idx) -> changed                     // miss-tolerance sticky last-good, then absent
pollDeadlineMsFor(i): armed? absent? -> 2s : 30s re-probe
onPollWakeupFor(i): sweep + read at cadence
drawFor(i): arm-on-first-draw, zero-width when empty, drawPaddedSegmentValue
segmentFor(i) -> Segment                    // comptime, own hooks into subs[i]
```
**Verdict:** ★ — truncation-aware reads (the `/proc/stat` buffer cliff is fixed
by design), `Sample` carrying display text lets a readout report anything
(temp, bytes, "up") without abandoning the registry, and the pure `render` is
directly testable. The miss-tolerance + slow-reprobe policy is the right cost
story (a transient procfs hiccup keeps the last-good reading; a genuinely
absent readout backs off to 30 s but stays recoverable). One doc defect: the
comment at :104-108 is an orphaned fragment describing the removed
non-truncation-aware `readFile`, misattached above `miss_tolerance`, making
that const's doc a chimera (half `readFile`, half miss-policy).
**Ideal:** unchanged. **Path:** delete the orphaned doc fragment at :104-108 so
`miss_tolerance`'s doc reads as one policy (the "Consecutive failed reads…"
half) with no stale `readFile` preamble.

### `bar/modules/systatus/cpu.zig` (132 lines)  **★**
**Now:**
```
parseCpuLine(s) -> ?{ total, idle }   // pure; leading "cpu " line only,
                                             // newline-bounded, field-count-agnostic (16 slots)
utilBetween(prev, cur) -> ?u8         // delta; null on zero/rewound total
bootAverage(cur) -> ?u8               // since-boot reading for the first sample
aggregateLineComplete(bytes, truncated) -> bool  // truncated-but-line-1-whole is fine
read(): delta vs previous, else bootAverage (primes the first frame)
```
**Verdict:** ★ — the pure parser (field-count-agnostic, newline-bounded) is the
fix for the "silently blank on big machines" bug; priming makes the first
frame render like every other segment. The `aggregateLineComplete` rule (a
short read is fine iff line 1 is whole) is the correct, testable distinction.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/systatus/ram.zig` (49 lines)  **★**
**Now:** `parseRamField` (pure, line-split); `usedPct(total, avail)` (pure,
clamped); `read()` via truncation-checked `/proc/meminfo` (truncated => null,
the I/O problem not "no RAM").
**Verdict:** ★ — 49 lines, pure where possible, honest null on unreadable.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/systatus/batt.zig` (46 lines)  **★**
**Now:** `parseCapacity` (pure, range-checked); `read()` probes `BAT0..7`,
first valid wins, null when none (zero-width slot on battery-less machines).
**Verdict:** ★ — absence is a renderable state, not an error.
**Ideal:** unchanged. **Path:** none.

---

## Title segment + addons

### `bar/modules/title/title.zig` (404 lines)  **★**
**Now:**
```
Scroll = { off: f32, cycle: f32, active: bool }   // ONE value per frame, declared HERE
Scroller = { offsetFor, pivot, pollDeadlineMs }   // the addon seam
subs = title_subs.addons; comptime assert len <= 1
overlay = providerOf(Segment, bar_modules, .overlay)   // the prompt, name-free
drawInner: 0 windows -> fill; 1 -> single; else -> split view (geom.zig)
drawFittedTitle: scroll seam (both outcomes) -> ellipsis -> plain
drawHook: overlay active -> delegate (latch overlay_was_active);
          overlay just closed -> pivot() (resume without teleporting)
pollTimeoutMsHook: overlay active -> -1 (no hidden marquee wakeups)
needsRepaintHook: overlay active -> overlay.needsRepaint; else scroll_active
```
**Verdict:** ★ — the seam shape (`Scroll` as one value, declared in the contract,
not the extensor) is the correct addon design: three formerly-separate queries
that had to agree are now one call that cannot disagree. The
overlay-delegation interlock (latch `overlay_was_active`, pivot on close,
suppress hidden marquee wakeups) is complete and the reasons live at `pivot`.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/title/carousel.zig` (229 lines)  **★**
**Now:**
```
anchor-based motion: off(t) = mod((now - anchor_ms) * speed / 1000, cycle)
                     // PURE function of the anchor timestamp, not an accumulator
offsetFor(win, title, text_w, avail_w, enabled, speed, now) -> Scroll
  // hysteresis: a scrolling cell stays scrolling until avail grows by slack_px,
  // so neighbour-width jitter cannot restart the marquee mid-cycle
pivot()             // rebase the clock at the next frame (show / reload)
pollDeadlineMs(now, hz) -> ms   // next display-period boundary
```
**Verdict:** ★ — exemplary: the design comment documents why an accumulator was
wrong (double-draw = double speed, late draw = jump, lost dt = permanent speed
change) and the anchor design eliminates all three. Position is a pure function
of time. The exit-hysteresis (`scroll_exit_slack_px`) is the right call — a
knife-edge `text_w > avail_w` re-run every frame would teleport the marquee on a
clock-digit change.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/title/geom.zig` (148 lines)  **★**
**Now:**
```
WindowInfo = { window, x, y, title, minimized }
sortWindows(): non-minimized first, on-screen before off-screen,
  then left-to-right, top-to-bottom, tie-break by window id (focus NOT a key)
GatherScratch.gather(snapshot, wins) -> ?[]WindowInfo   // sort in place
segmentBounds(total, i, count) -> {x, w}                // equal tiling, exact sum
segmentIndexOfX(total, offset, count) -> usize          // THE inverse, kept together
hitTest(snapshot, width, offset) -> ?{ window, minimized }
```
**Verdict:** ★ — the draw and the click hit-test share one geometry kernel so a
click can never select a neighbour; the file's own header documents why the
pairing must not be split. The sort-order rationale (focus excluded as a key so
the bar doesn't jump on focus change) is stated and correct.
**Ideal:** unchanged. **Path:** none.

---

## Layout indicators

### `bar/modules/layout/layout.zig` (46 lines)  **★**
**Now:** `getIcon()` via `contract.activeLayoutMeta(currentLayout,
tilingEnabled, pick=icon, "><>")`; `draw` via `scaffold.drawAndStore`;
`module(...)` with `cycleLayoutKind` click.
**Verdict:** ★ — resolves metadata through the contract seam, never names the
tiling registry; absent-tiling degrades to `"><>"` with zero code changes.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/layout/variants.zig` (54 lines)  **★**
**Now:** `getIndicator()` — active variant's indicator via the same
`activeLayoutMeta` seam; the variant-index lookup lives inside the `pick` (the
only place that has a variant dimension). Empty indicator = zero-width slot (a
successful zero-width draw, not a failure).
**Verdict:** ★ — the `Painted` distinction (zero-width success vs failure) is
handled correctly, and the variant-index ownership inside the `pick` keeps the
layout sibling free of a dimension it doesn't have.
**Ideal:** unchanged. **Path:** none.

---

## Slider core + controls

### `bar/modules/slider/slider.zig` (715 lines)  **★**
**Now:**
```
Sub = { name, read_interval_ms, level?, writable, read, write, commit_cost,
        commit_window_ms?, label, secondary?, probeNaturalWidth }
subs = slider_subs registry (file presence + self-declared role)
Write = { preview, commit, apply }            // ONE hook, named mode (was 3 hooks)
CommitCost = { immediate, rate_limited }      // per-BACKEND runtime fact, not a const
Throttle { write, interval_ms, last_ms, pending }  // commit scheduler
  apply(cost, pct) / reset() / flushOwed(pct) / finish(pct) / land(pct)
rawFromPct / pctFromRaw                        // shared linear map, nearest-rounding
spawnCapture/runOut/runOk                      // allocation-free /bin/sh racers
renderLineValue(fmt, pct, state, buf) -> Label // {pct}/{state} substitution + value span
interaction: click hit-test (bound = reservedWidth, not painted width),
  press-hold drag (exclusive per segment), wheel +/-2% (boundary no-op),
  right-press secondary action
poll loop: per-control cadence + owed-sweep (earliest wins)
per-segment lifecycle: arm-on-first-draw, dirty redraw, painted width via scaffold.widthState
segmentFor(i) -> Segment                       // comptime, own hooks into subs[i]
```
**Verdict:** ★ — the closed-core/open-module split is exactly right, and the
named `Write`/`CommitCost` enums are the principled core of the design: the
clamp and the throttle decision each live in exactly one place, and the
latency class is a per-backend runtime fact (a static field would either
throttle a sysfs write or lag a native drag). The drag-state machine (press ->
`apply`+`reset`; motion -> `preview`+throttled; end -> `finish`+read+exit) is
principled and coalesces onto the newest value. The documented decision *not*
to merge with systatus.zig (interaction + throttle + per-control cadences vs
read-only fixed cadence) is correct — a shared scaffold would be a
parameterized contract surface around a thin body.
**Ideal:** unchanged. **Path:** none required (latent only: `spawnCapture`
`fread`s `sink.len` bytes before `pclose`, so a child producing more than the
OS pipe buffer would block on a full pipe and hang `pclose`; every current
command is far under that, so it never bites — but the "drain so pclose never
blocks" comment overstates the guarantee for a future verbose command).

### `bar/modules/slider/volume.zig` (528 lines)  **◐**
**Now:**
```
Backend = { unknown, pulse, alsa }            // family; the RUNG is latched separately
Rung = { native_pulse, pactl, amixer, native_alsa, none }
g_native_pulse / g_native_alsa                // attached handles (probed lazily, never given up)
g_ladder_failed_at_ms: ?i64                   // negative cache
g_pulse_recheck_at_ms / g_pulse_reachable     // daemon-reachability recheck
probeDecision(now, failed_at, recheck_at, last_reachable, reachable) -> { walk }  // PURE
latchedRung(backend) -> Rung                  // backend -> rung, checkable without a daemon
runLadder(): native_pulse -> pactl -> amixer -> native_alsa  (family order, not speed)
readLatched(): one read per rung (pactl needs two commands)
commitCost(): native rungs .immediate, subprocess rungs .rate_limited
commitPct(v): switch (latchedRung) -> setVolumePct / pactl / amixer
write(w, v): preview -> optimistic; commit -> commitPct; apply -> commitPct + optimistic
toggleMute(): switch (g_backend) -> pactl/amixer toggle, then readVolume   // SUBPROCESS ONLY
```
**Verdict:** ◐ — the ladder + latching + negative cache + reachability recheck
is the right perf story (a dead daemon costs one probe, not a popen per event),
and `probeDecision`/`latchedRung` are pure and checkable without a daemon. Two
real defects keep it off ★: (1) the header comment is stale — it asserts the
native backends "were removed" and "Both are subprocesses on purpose", directly
contradicting `runLadder` (native rungs 1 and 4), `latchedRung`, `commitCost`,
and the `native_pulse`/`native_alsa` imports; (2) the mute toggle is
subprocess-only — `toggleMute` dispatches on `g_backend` (family) and spawns
`pactl`/`amixer`, so on a machine where the native backend won *because* the
CLI is absent (the split-packaging case `native_pulse`'s own doc names),
right-click mute silently no-ops. The root cause is that the rung is latched
for read/commit but NOT for mute: three separate switches (`readLatched` /
`commitPct` / `toggleMute`) over the rung set, with mute's over the family.
**Ideal:**
```
// latch ONE backend vtable (read / write / mute) selected once by the ladder,
// so the dispatch happens at latch time, not three times:
const Vtable = struct {
  read: *const fn () ?bool,  write: *const fn (u8) void,  mute: *const fn () void, ...
};
// native_pulse.Backend and native_alsa.Master each implement all three
// (pulse: wrap the already-resolved set_sink_mute symbol; alsa: one ELEM_WRITE
// to switch_numid); the pactl/amixer rungs implement them via subprocess.
toggleMute() = latched.mute();   // dispatches through the RUNG, so the native path is used when attached
```
**Path:** (1) add `setMuted` to `native_pulse.Backend` (wrap the already-resolved
`set_sink_mute`: build a set-sink-mute op, bounded wait, like `setVolumePct`);
(2) add `setMuted` to `native_alsa.Master` (one `ELEM_WRITE` ioctl to
`switch_numid` with the boolean value); (3) collapse `readLatched` / `commitPct` /
`toggleMute`'s three switches into the latched vtable — or at minimum route
`toggleMute` through `latchedRung`; (4) rewrite the stale header to describe the
four-rung ladder accurately.

### `bar/modules/slider/brightness.zig` (428 lines)  **★**
**Now:**
```
Backend = { unknown, sysfs, brightnessctl }; Class = { backlight, leds }
findDevice(base, pin, out): pin ("led:" prefix -> leds class) else
  lexicographically-smallest /class/backlight/* with positive max
readU32File / readMaxOf / readRawValue (brightness, fallback actual_brightness)
pctFromRaw / rawFromPct via the shared slider map
WriteResult = { ok, denied, transient }; classify(err): ACCES/PERM -> denied, else transient
writeU32File: O_WRONLY|O_TRUNC raw POSIX write
readBrightness(): re-discover while unresolved; sysfs first, brightnessctl fallback
commitPct(v): sysfs write; on failure brightnessctlApply; latch read_only ONLY on
  a denial the fallback could not work around (transient EIO does NOT latch)
write(w, v): preview -> g_pct; commit -> commitPct; apply -> commitPct + re-read
sysfs helpers take an explicit `base` root -> tests use a fabricated tree
```
**Verdict:** ★ — sysfs-first is the correct native path (one file write per
commit, no throttle); the `denied` vs `transient` classification is the right
latch policy (a driver rebind's EIO must not turn the module permanently
read-only); the testable-by-root-argument design is exemplary.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/slider/native_pulse.zig` (480 lines)  **★**
**Now:**
```
pulseReachable(): access("$XDG_RUNTIME_DIR|/run/user/<uid>/pulse/native", F_OK)
std.DynLib dlopen("libpulse.so.0"); ~20 symbols resolved at runtime (openLib)
pa_sink_info / pa_server_info read as raw bytes with offset guards
  (server_version2 hole: default_sink_name at offset 40 or 48, first plausible wins)
plausibleSinkName(name) -> bool          // printable-ASCII gate on the read pointer
volumePct / buildCvolume via the shared slider.pctFromRaw/rawFromPct (round-trip exact)
runOp(issue, done, timeout): lock, issue, unlock, bounded waitDone (dead daemon can't hang)
attach(): pulseReachable -> openLib -> mainloop -> context -> connect -> start ->
  waitReady(2s) -> resolve default sink (server_info, then by-name, then list)
Backend { setVolumePct, readSink }       // ops under the mainloop lock, bounded
```
**Verdict:** ★ — zero link-time dependency, runtime ABI guards on every field,
bounded waits so a dead daemon cannot hang the WM loop; the version-dependent
offset handling is exactly the right level of paranoia for dlopen'd structs.
The shared pct map makes a write-then-read round trip exact (the old local
formula disagreed by up to 1%). One doc/impl mismatch: the header's "Every
commit (`setVolumePct`, `setMuted`)" already promises a `setMuted` the
`Backend` struct does not deliver — the symbol is resolved into `Lib`
(`:365`) but never wrapped. That is the volume mute gap manifesting here, not
a flaw in the ABI plumbing.
**Ideal:** unchanged. **Path:** none — except to close the volume mute gap,
expose `setMuted` here (wrap the already-resolved `set_sink_mute` symbol);
that is a volume.zig-driven addition, and it makes this file's own header
true.

### `bar/modules/slider/native_alsa.zig` (372 lines)  **★**
**Now:**
```
extern struct UAPI layouts (ElemId/ElemList/ElemInfo/ElemValue, CardInfo)
ior/iowr ioctl encoding; devctl sign-extends the request like C
isShimCard(name): skip pipewire/pulse/pulseaudio softvol cards (writing one would
  move a userspace element that does nothing to the hardware)
openMaster(): scan controlC0..31 -> skip shim -> ELEM_LIST enumerate ->
  first MIXER INTEGER "Master Playback Volume" (fallback "Master"),
  plus BOOLEAN "Master Playback Switch"; verify INTEGER + WRITE + !INACTIVE
Master { setVolumePct, readVolumePct, readMuted }   // one ioctl per op
rawFromPct / pctFromRaw via the shared slider map
```
**Verdict:** ★ — dependency-free kernel ABI with runtime-verified struct sizes;
the shim-card gate is the correct activation protection (the documented "no
PulseAudio runtime" rule is enforced by skipping the PulseAudio/PipeWire cards
that would otherwise be written). The ALSA floor is reachable on a box with no
alsa-utils at all. `readMuted` reads `switch_numid` but there is no `setMuted`
to write it — the volume mute gap's ALSA half.
**Ideal:** unchanged. **Path:** none — except to close the volume mute gap, add
`setMuted` (one `ELEM_WRITE` to `switch_numid`); that is a volume.zig-driven
addition, not a flaw in this file.

---

## Prompt (inline command runner) — four-way split

### `bar/modules/prompt/prompt.zig` (447 lines)  **★**
**Now:**
```
Addon = { register, init, deinit }  + addons from prompt_subs registry
re-exports editor's whole contract (XK, Action, Mode, EditorState, Handlers,
  insertChar/insertSlice/deleteRange/overwriteAt, handleCtrl, registerHandlers)
  + completion's WordAtCursor/wordAtCursor/CompletionSource, so vim.zig and the
  tests import through the package core, unaware of the split
PromptState = { is_active, vim_state: EditorState, handlers, key_syms, redraw_pending }
XCB key-symbol externs (the one segment that needs xcb_key_symbols_*)
handlePromptKeypress: inactive -> false; close_window -> by cursor position;
  Super-held + bound WM action -> let WM dispatch; else handleKeyPress
handleKeyPress: guard PRESS (release trap); resolve keysym; drop modifier keysyms;
  Ctrl -> handlers.handle_ctrl; Tab -> acceptGhost; insert-basic vs modal dispatch
finishKeyPress: handleAction + completion.updateGhost + render.showCaret/markLayoutDirty
activate/deactivate: keyboard grab/ungrab + presentForPrompt/dismissAfterPrompt glue
draw: overlay body (clearBlinkRepaint first) -> render.drawActive
module: Segment + BarOverlay (is_active/toggle/draw/needsRepaint)
```
**Verdict:** ★ — the orchestrator owns exactly the lifecycle, the X grab, and
the key routing; the buffer, completion, and render concerns are extracted and
reach the host only through this file's re-exports. The dependency graph is
clean and acyclic (`prompt → {editor, completion, render}`,
`render → {editor, completion}`, `completion → editor`, `vim → prompt`) — the
split does not leak: no extensor imports a sibling's internals, only the
package core. The press-release guard and the modifier-keysym drop are each
load-bearing and documented.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/prompt/editor.zig` (283 lines)  **★**
**Now:**
```
default_max_input = 256
Action = { none, deactivate, spawn }
Mode = { insert, normal }  + label()/hintWidth() via the handlers.mode_label seam
  (the pill's "no hint => no pill" policy lives with the mode, not the host)
EditorState = { allocator, max_input, buf, len, cursor, mode }
insertSlice / deleteRange (mode-aware clamp: normal cursor may sit on the last char) /
  overwriteAt (in-place, extent-preserving) / isPrintableAscii
handleCtrl (readline set + Ctrl-C) / handleInsertBasic / insertChar
addon_active / Handlers (defaults: basic insert, no-op normal, handleCtrl, "" label)
registerHandlers(h) -> handlers = h; addon_active = true
measureCached(cache, dc, text) -> u16
```
**Verdict:** ★ — the base layer is clean and the `Handlers` seam is the right
extensibility point: the defaults are a working basic editor, and registering a
modal engine is a value swap that also flips `addon_active` (so a compiled-in
extensor is never bypassed because a config key is unset). `deleteRange` owning
the mode-aware clamp is the one home for a rule that had five divergent copies.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/prompt/completion.zig` (481 lines)  **★**
**Now:**
```
CompState = { comp_names[1024][65:0], comp_count, ghost, hist_entries[128],
              hist_count, hist_head, is_hist_loaded, is_completions_loaded }
loadCompletions(): $PATH scan once (DT_REG/LNK/UNKNOWN + X_OK probe), pdq sort
wordAtCursor(buf, cursor) -> { token, start }   // PURE; last-space split
completeToken(token, source) -> ?suffix         // history | executables
completeFromHistory: ring newest-first, match the token-under-cursor of each entry,
  tail up to the next space (so "git ch" completes from "git checkout")
completeFromExecutables: compLowerBound binary search, first longer match
updateGhost(vim_state): insert-mode + cursor-at-end only; history -> executables priority
histPrepend (skip consecutive dups) / histAppendToFile (mkdir -p, mode 0600)
histParseLine: fish "- cmd:", zsh ": <ts>:<elapsed>;", bash "#" skip, bare
histLoadFile: bounded tail window (256 KiB), back-to-front, O(1) dedup via hash set
loadHistory(): run -> bash -> zsh -> fish (load order => fish highest priority)
spawnCommand(cmd): histPrepend + append + double-fork setsid /bin/sh -c (detached)
```
**Verdict:** ★ — the completion provider seam is cohesive and pure where it can
be (`wordAtCursor` takes the buffer and cursor, so the split is testable). The
history loader's bounded tail-window + back-to-front + O(1) dedup is the right
shape for an overgrown history file, and the multi-shell format parsing is
centralized. The ghost priority (history outranks executables) is stated in one
place.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/prompt/render.zig` (498 lines)  **★**
**Now:**
```
RenderState = { cached_prompt_w, cached_mode_w[], is_blink_visible,
  cached_caret_top/h, blink_repaint, cached_pre_w/caret_w/scroll_x/height,
  layout_dirty }      // blink ticks reuse the layout cache: ~20 Pango passes avoided
measureBound(dc, text, t, ge|gt) -> usize   // binary search to a char boundary
drawScrollSpan(post, dc, px, ...): pre = hard-clip both edges + advance pen;
  post = ellipsize to the right edge, never advance
drawBlockCursor(dc, px, style, buf, lo, hi, text_w)   // shared by selection + normal caret
refreshLayoutCache: recompute caret widths + scroll_x only when layout_dirty or height
drawPill: right-pinned mode pill via mode.hintWidth(); returns scroll_end_x
  (no pill => full region; a pill that can't fit is dropped, text keeps the room)
drawInsertMode: thin blinking caret (consumes no char) + dim ghost at end
drawNormalMode: full-character block cursor
drawActive: [pad | scrollable: PROMPT | pre | CURSOR | post | MODE_LABEL | pad]
```
**Verdict:** ★ — the renderer is cohesive and the layout cache is a real,
documented perf design (a caret-blink frame is allocation- and
measurement-free). The `drawScrollSpan` comptime-`post` split shares the span
logic while keeping the two clipping policies distinct, and the pill-width
policy correctly degrades (drop the pill, keep the text room) rather than
blanking the prompt.
**Ideal:** unchanged. **Path:** none.

### `bar/modules/prompt/vim.zig` (482 lines)  **★**
**Now:**
```
Prefix = { count, op, op_count, arg: { none, find_char, g_prefix } }  // the state machine
handleCtrl / handleInsert / handleNormal        // mode handlers (registered via register())
resolveMotionKey: pending find-char / g-prefix -> digits -> ";" repeat -> simple motions
resolvePendingFindChar / resolvePendingGPrefix / resolveSimpleMotion
applyOperator(op, mr): range from (cursor, pos, inclusive, override); d/c delete+yank
  (c enters insert), y yank+home cursor
execNormalKey: x/X/D/C/s, p/P paste, ~ case, S clear+yank+insert, i/I/a/A insert modes
motions: w/W/b/B/e/E, 0/^/$, h/l, f/F/t/T + ;/, repeat, g-prefix (ge/gE/gg/g0/g$)
wordScanFwd/Bwd (comptime end), charClass (big vs word), motionFind
yank_buf (addon-allocated), last_find_kind/ch
register() -> prompt.registerHandlers({ insert, normal, ctrl, on_deactivate, mode_label })
addon = prompt.Addon { register, init, deinit }   // membership via prompt_subs
```
**Verdict:** ★ — a faithful modal engine bound as an addon (membership via
`prompt_subs`); cohesive as one file because the prefix machine, the motions,
and the operators are one state machine that shares `Prefix` throughout —
splitting it would thread `Prefix` through every leaf for no net clarity, and
a pure extraction of the word-scan helpers is not an improvement by itself. The
`register()` hook swaps handlers in, leaving the basic editor when absent. The
saturating `effectiveCount` (chained counts can exceed u32 max) is the right
call, and the modal semantics are faithful (inclusive `f`/`F` vs exclusive
`t`/`T`, big-vs-word classes, counts, `;`/`,` repeat, backward word scans).
**Ideal:** unchanged. **Path:** none.

---

## Bar modules summary

- 21 files: 19 ★, 2 ◐ (tags — optional geom split; volume — stale header +
  subprocess-only mute toggle), 0 △, 0 ▽. Round 2 upgrades `vim.zig` to ★:
  both prior rounds rated it ◐ on "cohesion" grounds, but cohesion is the
  *correct* shape for a shared-`Prefix` state machine, not a roughness, and no
  defect survives fresh reading.
- The closed-core/open-module pattern (systatus, slider, title, prompt) is
  consistent and correct throughout: file presence = registry membership =
  drop-in addon. The prompt four-way split (editor/completion/render/
  orchestrator) is clean — acyclic, re-exported through the package core,
  invisible to `vim.zig` and the tests; no extensor imports a sibling's
  internals.
- Reference-quality designs to preserve as templates: carousel (pure
  time-anchored motion + exit hysteresis), systatus (truncation-aware reads +
  pure render), native_pulse (dlopen ABI guards + shared round-trip-exact pct
  map), native_alsa (shim-card gate), brightness (denied-vs-transient latch),
  editor (Handlers seam with working defaults), slider (named `Write`/`CommitCost`
  enums + per-backend latency-class query).

### Summary table

| file | verdict | ideal delta |
| --- | --- | --- |
| `bar/modules/tags.zig` | ◐ | optional `tags/geom.zig` for cell layout + `indicatorPos` |
| `bar/modules/clock.zig` | ★ | unchanged |
| `bar/modules/systatus/systatus.zig` | ★ | unchanged (delete orphaned stale doc fragment at :104-108) |
| `bar/modules/systatus/cpu.zig` | ★ | unchanged |
| `bar/modules/systatus/ram.zig` | ★ | unchanged |
| `bar/modules/systatus/batt.zig` | ★ | unchanged |
| `bar/modules/title/title.zig` | ★ | unchanged |
| `bar/modules/title/carousel.zig` | ★ | unchanged |
| `bar/modules/title/geom.zig` | ★ | unchanged |
| `bar/modules/layout/layout.zig` | ★ | unchanged |
| `bar/modules/layout/variants.zig` | ★ | unchanged |
| `bar/modules/slider/slider.zig` | ★ | unchanged (latent: `spawnCapture` drain bound is the pipe buffer, not `sink.len`) |
| `bar/modules/slider/volume.zig` | ◐ | expose `setMuted` on both native backends; collapse the three rung switches into one latched vtable; route `toggleMute` through `latchedRung`; refresh stale header |
| `bar/modules/slider/brightness.zig` | ★ | unchanged |
| `bar/modules/slider/native_pulse.zig` | ★ | unchanged (add `setMuted` to close the volume mute gap; makes its own header true) |
| `bar/modules/slider/native_alsa.zig` | ★ | unchanged (add `setMuted` to close the volume mute gap) |
| `bar/modules/prompt/prompt.zig` | ★ | unchanged |
| `bar/modules/prompt/editor.zig` | ★ | unchanged |
| `bar/modules/prompt/completion.zig` | ★ | unchanged |
| `bar/modules/prompt/render.zig` | ★ | unchanged |
| `bar/modules/prompt/vim.zig` | ★ | unchanged (cohesive as-is) |
