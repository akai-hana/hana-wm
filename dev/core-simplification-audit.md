# Core simplification audit — hana `src/core/`

RESEARCH ONLY — no source changed. Every finding below was verified against the tree at
`HEAD` (46f85d5) by reading the full file, grepping the whole `src/` tree for consumers,
and diffing against the claimed-DONE items in `dev/SIMPLIFICATION_PLAN_v6.md` and
`dev/audit-v7/A-whole-codebase.md`.

Inviolable constraints honored: sync boundary preserved (no XCB call moves outside
`src/core/sync/` + the `check-layers.sh` allowlist), no changes to `src/test/`, no reports
on window/bar/config/tiling except where they duplicate core logic.

Method:
- Read in full: `core.zig`, `events.zig`, `pipeline.zig`, `persist.zig`, `restart.zig`,
  `scale.zig`, `screen.zig`, `signals.zig`, `spawn.zig`, `contract.zig`,
  `sync/sync.zig`, `sync/sink.zig`, `x11/wire.zig`, `x11/masks.zig`, `x11/xcb.zig`,
  `utils/{constants,utils,idmap,proc,paths,debug,ids,bounded}.zig`.
- Consumer verification via `rg` across `src/` and `dev/`.
- "Claimed fixed but still present" flags are diff-proven (see CORE-02).

Findings are ordered by estimated yield.

---

### [CORE-01] HIGH/VERIFIED: events.zig:89-97, contract.zig:78 — `Surfaces.handlePropertyNotify` optional forward is dead; no surface binds it

- What: `contract.zig:78` declares an optional `handlePropertyNotify` hook on `Surfaces`
  (with a 3-line doc at `:75-77`), and `events.zig:89-97` forwards every PropertyNotify
  through `if (surfaces.handlePropertyNotify) |f| f(e)` before unconditionally calling
  `window.handlePropertyNotify(e)` at `:96`. The dispatch-table entry is `:141`. A tree-wide
  `rg handlePropertyNotify src/` shows **zero** binders: no surface ever sets the field, the
  bar does not, `window/window.zig:1215` handles it by itself.
- Why it matters and LoC cost: `SIMPLIFICATION_PLAN_v6.md` lists this as **EVS-01 — DONE**
  ("drop the optional handlePropertyNotify forward"). The plan claims removal, the code still
  has it: 7 logic lines (events), 1 field line + 3 doc lines (contract) of always-null seam
  that commits the next reader to a branch that never fires.
- Concrete simplification: delete the contract field (`:78`) and its doc; in the events
  forward keep only the cast + `window.handlePropertyNotify(e)`. The doc at `contract.zig:75-77`
  already admits "the bar does not" bind it — the seam has no customer.
- Estimated LoC delta: **−7**

---

### [CORE-02] HIGH/VERIFIED (diff-proven): sync/sync.zig:322-334 — winner-seed if-chain regressed to 4-deep nesting after C-11 claimed it flattened

- What: the reconcile winner-seed in sync.zig is
  `if (winner == null) { if (m.focused) |f| { if (m.store.indexOf(f)) |slot| { ... if (fe.presence == .present and desireIsNonParked(...)) { winner = f; } } } }` —
  4 nested conditionals. `SIMPLIFICATION_PLAN_v6.md` Phase 1 lists **C-11 — DONE** ("flatten
  the 3-deep winner-seed if-chain to guard-clauses / early-return").
- Why it matters: `git show dbc9f1e -- src/core/sync/sync.zig` proves the flatten WAS applied
  (the diff shows the compact `if (winner == null) if (m.focused) |f| if (...) |slot| {`
  form) and was then **re-nested** by the C-12 `on_current` threading commit. The planned,
  approved simplification silently un-landed; LoC cost is 4 levels × 2 indentation lines plus
  the extra `{`/`}` bookkeeping at a hot spot.
- Concrete simplification: reintroduce the guard-clause form with the new `on_current` arg:
  ```zig
  if (winner) |_| {} else if (m.focused) |f| blk: {
      const slot = m.store.indexOf(f) orelse break :blk;
      const fe = m.store.at(slot).val.*;
      if (fe.presence == .present and desireIsNonParked(
          fe, fs_win, placementOfSlot(&placements, &pl_of_slot, slot), false,
          model.visibleEntry(m, fe, m.current),
      )) winner = f;
  };
  ```
- Estimated LoC delta: **−5**

---

### [CORE-03] MEDIUM/VERIFIED: sync/sync.zig:130 + 527 vs pipeline.zig:135 — `Ctx.cfg_bw` mirrors `env.margins.border` (WCD-05, still present)

- What: `pipeline.ctx()` copies `env.margins.border` into `sync.Ctx.cfg_bw`
  (`pipeline.zig:135`); reconcile reads it once per window at `sync.zig:527`.
  `dev/audit-v7/A-whole-codebase.md` flags this as **WCD-05** and it is **not** marked DONE.
- Why it matters: one scalar of truth stored twice — a write to `env.margins.border` that
  forgets to rebuild the Ctx silently desyncs borders. The file's own comments pledge no
  drift (`:527` reads "border width carried into the reconcile env untouched by the window's
  own border pixel work").
- Concrete simplification: drop `cfg_bw` from `Ctx` (and the field line `:130`) and read
  `ctx.color_of`'s sibling — or, if the seam forbids sync reading config, thread `bw: u16`
  via `ReconcileOpts` from the single caller `pipeline.reconcileUnderGrabNow`. Keeps the
  sync–config boundary intact either way.
- Estimated LoC delta: **−3** (plus ends the dual-source drift)

---

### [CORE-04] MEDIUM/VERIFIED: sync/sync.zig:226-236 vs pipeline.zig:180-185 — two grab-bracket idioms (WCD-10, still present)

- What: `sync.reconcileUnderGrab` is a grab→reconcile→ungrab-bracket with an embedded
  retile profiler; `pipeline.withServerGrab` is a grab→closure→ungrab-bracket. Their ONLY
  shared region is the grab/deref bracket (`sync.zig:230-232` ≈ `pipeline.zig:182-183`).
  `pipeline.reconcileUnderGrabNow` (`:188-191`) is the **only** caller of the sync variant;
  the other 4 pipeline entry points use `withServerGrab`.
- Why it matters: two ways to hold the server grab in the same layer invites a third; the
  profiler timing currently rides inside the sync one, so its instrumentation scope is an
  accident of whichever function happened to own the bracket.
- Concrete simplification: delete `sync.reconcileUnderGrab` and have `reconcileUnderGrabNow`
  become `preReconcileDuties(); withServerGrab(...)` with reconcile (and the profiler note)
  in the closure; move the `retile_prof` import to pipeline if its timing belongs to the
  server-grab bracket rather than to sync.
- Estimated LoC delta: **−4** (and one bracket idiom left standing)

---

### [CORE-05] MEDIUM/VERIFIED: pipeline.zig:147-150 duplicates window/borders.zig:17 — border pixel pick duplicated across layers (WCD-02, still present)

- What: `pipeline.colorOf` is `return if (m.focused == win) cfg.border_focused else cfg.border_unfocused;`
  (`pipeline.zig:147-150`); `window/borders.zig:56` computes the identical pick via
  `borderColorOf(focus.getFocused() == win, cfg.border_focused, cfg.border_unfocused)`.
  `dev/audit-v7` lists this as **WCD-02**; not marked DONE.
- Why it matters: the focused/unfocused pixel decision lives in two layers; a palette or
  focus-semantics change must be mirrored. Core owns the config read; the window layer
  re-derives it.
- Concrete simplification: keep one owner (core, since `colorOf` is already the sync-seam
  callback) and have `window/borders.zig` delegate to a single exported picker
  (`core.pixelFor(win, m)`) instead of re-reading `border_focused`/`border_unfocused`.
- Estimated LoC delta: **−4**

---

### [CORE-06] LOW/VERIFIED: spawn.zig:115-123 vs 279-287 — stack-then-heap command `[:0]` resolution duplicated verbatim

- What: both `executeShellCommand` and `execSynchronous` run the identical 8-line block:
  stack `bufPrintZ` when `cmd.len < stack_cmd_capacity`, else heap `dupeZ`, deferring the
  free, returning a `[*:0]const u8`. The only differences are allocator source
  (`core.getState().alloc` vs the `alloc` param) and `catch return` vs
  `catch return error.CommandTooLong`.
- Why it matters: 8 lines duplicated under 2 entry points; any fix to the fallback (e.g.
  shrinking the stack buffer, or surfacing CommandTooLong in both) must be applied twice.
- Concrete simplification: one helper
  `fn resolveCmdZ(alloc: Allocator, cmd: []const u8, buf: []u8) ![:0]const u8`
  returning the borrow (stack slice or heap dupe), both callers adopt it.
- Estimated LoC delta: **−6**

---

### [CORE-07] LOW/VERIFIED: contract.zig:19-35 vs 135-146 — serialize/deserialize seam prose duplicated in the header and on the fields

- What: the file header's `Key seams:` block (`contract.zig:19-35`, 16 lines) and the
  `serializeWindow`/`deserializeWindow` field docs (`contract.zig:135-146`, ~12 lines)
  describe the same design — opaque blob, `*const model.Model` on the read side, registry
  ordinal stamp + magic-byte fallback, at-most-one claimer — in different words.
- Why it matters: two authoritative descriptions of one invariant; they have already drifted
  (the header says the ordinal is tried FIRST + magic fallback; the field doc says adoption
  "fast-paths" on it). A duplicated contract is a contradictory one.
- Concrete simplification: keep the header block (it talks to the whole seam), reduce the
  two field docs to one line each ("see header 'Session persistence seam'").
- Estimated LoC delta: **−10** (docs)

---

### [CORE-08] LOW/VERIFIED: events.zig:185 — redundant `build_options.has_bar and` conjunct on the RandR branch

- What: `dispatch` gates the RandR branch with `if (build_options.has_bar and isRandrEvent(event_type))`,
  but `isRandrEvent` (`events.zig:162-167`) already returns `false` when `!build_options.has_bar`.
- Why it matters: the double gate forces future readers to trust two `has_bar` fences; the
  comment at `:183-184` claims the composer prunes the branch, which the inner gate already
  guarantees. Dead conjunct, dead comment byte.
- Concrete simplification: drop the outer `build_options.has_bar and` and the two comment
  lines that exist only to explain the redundancy.
- Estimated LoC delta: **−2**

---

### [CORE-09] LOW/VERIFIED: spawn.zig:41-42 vs 71-72 — `tag_failed` child tail duplicated in both fork arms

- What: `execAsGrandchild` (`:41-42`) and `forkIntermediate` (`:71-72`) each build
  `[1]u8{tag_failed}`, write it, close `pipe_write`, and `exit(1)` — the exact same 4-line
  failure tail.
- Why it matters: post-fork code is the hardest to change safely (no allocator, no errors);
  a duplicated tail doubles the surface for a variant bug that only shows on a box with a
  broken `execvp`.
- Concrete simplification: one `fn failWithTag(pipe_write: c_int) noreturn` (or fold the
  write+close+exit into `execAsGrandchild`'s single exit path).
- Estimated LoC delta: **−3**

---

### [CORE-10] LOW/VERIFIED: scale.zig:95 — `screen.*.root` redundant explicit deref

- What: `const root = screen.*.root;` where `screen: *const xcb_screen_t`; Zig auto-derefs
  pointer fields, so `screen.root` is identical and is the form used everywhere else.
- Why it matters: cosmetic; `.*` here reads as "careful ownership work" where none exists.
- Concrete simplification: `const root = screen.root;`
- Estimated LoC delta: **0** (noise removal)

---

### [CORE-11] LOW/VERIFIED: signals.zig:244 (doc at :193) — `dispatchSignal(byte)` parameter is a bitmap bit, not a signal byte

- What: `dispatchSignal` receives `@ctz(bit)` of the signal bitmap (`:282`), i.e. a bit
  index; the name "byte" and the comment "SIGCHLD is reaped in dispatchSignal" imply the
  value is the signal number or a byte of state. In practice the byte written by
  `signalHandler` (`:39-43`) is discarded — the pipe is "read purely as a wake token"
  (`:264-266`).
- Why it matters: two readers already wrote comments rationalizing the byte; the naming and
  docs are the only cargo. Low signal.
- Concrete simplification: rename the param `bit: u6`/`index`, or pass the `bool` it actually
  is; reword `:193` to "SIGCHLD is reaped in drainAndDispatch".
- Estimated LoC delta: **0** (doc/name clarity)

---

### [CORE-12] LOW/VERIFIED: pipeline.zig:88-89 — `fn sink() sync.Sink` name collides with `xcb_sink.XcbSink.sink()` and the returned type

- What: pipeline exposes `inline fn sink() sync.Sink { return (&g_sink).sink(); }`; the
  receiver type is `XcbSink` (whose own method is `pub fn sink(self)`). Three things named
  `sink` within 60 lines.
- Why it matters: with `bar.zig` and `window/actions.zig` importing `pipeline.sink`, a
  reader greps `sink()` and gets the seam, the impl method, and the type.
- Concrete simplification: rename the pipeline accessor `syncSink()` (one call-site change at
  `:127` and `:153`).
- Estimated LoC delta: **0**

---

### [CORE-13] INFO/VERIFIED: `src/core/.events.zig.swp` and `src/core/.pipeline.zig.swp` — v6 COREH-24's "no .swp" claim is stale

- What: `SIMPLIFICATION_PLAN_v6.md` §C #24 asserts no `src/core/*.swp` remain; two vim swap
  files exist in `src/core/` (gitignored, dated Sep 20/22).
- Why it matters: doc drift — the plan's evidence list says one thing, the tree has another;
  and stale swap files are the classic source of "my edit vanished" confusion.
- Concrete simplification: delete both files (`src/core/.events.zig.swp`,
  `src/core/.pipeline.zig.swp`).
- Estimated LoC delta: **−2 files**

---

## Verified-as-clean (checked, no report)

- `indexOfById` / `indexOfByIdField` / `indexOfScalar` / `orderedRemove` / `upsertById` /
  `insert` / `swapRemove` / `removeById` / `removeAllById` — all have live consumers
  (model.zig, window.zig, minimize.zig, persist.zig).
- `Store.iterator` / indexed `at`-pass — both idioms consumed (model.zig:247,342;
  sync.zig:298,356).
- `reconcileNow`, `reconcileDragTick`, `releaseClaim`, `surfaceWindow`, `doubledBorder`,
  `clampToU16`, `warnOnErr`, `WorkspaceId.eql`, every `constants.zig` value — used.
- `IdMap.contains` / `count` — test seams only, already annotated in-source (v5 COREP-24
  disposition: annotate, endorsed).
- `event_dispatch_table = 36` guard, `fd_xcb`/`fd_signal`, `max_events_per_batch`,
  `max_queued_drain` — live.
- `window_modules` one-line intros (COREH-23), CR-01/CR-02, RS-01, SCR-01, C-05, C-06 —
  confirmed applied; do NOT re-report.
- `x11/xcb.zig`, `x11/masks.zig`, `utils/paths.zig`, `utils/proc.zig`, `utils/ids.zig`,
  `utils/debug.zig` — leaf/pure, no dead exports found.

## DEFERRED / QUESTIONS

1. **WCD-07 (id aliases)**: `core.zig` re-exports `WindowId`/`WorkspaceId` with 5-line docs
   each for refresh churn. Keeping the aliases (call sites spell `window.WindowId` /
   `persist.WindowId` etc.) is intentional; suggested rework is rename-churn with 0 LoC
   delta on core. Defer — this is `dev/audit-v7` scope, not a core win.
2. **`BoundedList.Store.at` empty-map semantics** (bounded.zig:308): `at` clamps to the last
   slot, so on an empty store it reads `keys[0]`/`vals[0]` of `undefined` storage. All current
   callers gate on `count` first, but the contract is a footgun, not a simplification target.
   Recommend a `debug.assert(seq < count)` hardening, out of scope here.
3. **`BoundedList.removeWhere`**: sole production caller is `dev/plugin-template/provider.zig:98`
   — the sanctioned plugin template. Keep; optionally annotate in-source as "public for the
   plugin template".
4. **CORE-03 follow-through**: if `cfg_bw` must remain in `Ctx` to keep sync config-blind,
   close the drift with a compile-time/textual guard in the sync seam instead. Ask maintainer
   preference.
5. **CORE-04 profiler ownership**: folding `reconcileUnderGrab` moves `retile_prof`'s home;
   confirm `profile_key` gating is applied at the new site before deleting the sync variant.
6. **`dev/cross-cutting-audit.md`** — referenced in the task brief but does not exist in the
   repo (nearest: `dev/simplification-audit.md`, `dev/audit-v7/`). Not a blocker, flagging the
   doc pointer as stale.

Estimated net: **−40..−47 LOC** across `src/core/` + deletions of 2 swap files, with every
item consumer-verified and both plan-claim regressions diff-proven.