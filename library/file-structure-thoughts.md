# Thoughts on `library/file-structure-concerns.md`

Read alongside the actual `src/` tree and file headers. Verdicts below: some
concerns are onto something, several are based on a misreading of the current
boundaries — in those cases the split is deliberate and justified. Longest
items first where they matter most, then per-item.

---

## Item by item

### `src/core/` — no issues
Agreed.

### `src/core/architecture/` — `contract.zig` vs `contract_x11.zig`
The split is justified, not confusing-for-no-reason: `contract.zig` is the
pure composition vocabulary (no XCB types), and `contract_x11.zig` is the
X-aware half adding CB-typed seams (`BarHandlers`, `DrawCtx`, X key-press
events). This keeps the DAG honest: files that must stay XCB-free can import
`contract` without dragging XCB in.

That said, the *name* does invite confusion. Options:

- rename `contract_x11.zig` -> `contract_xcb.zig` (matches the rest of the
  tree, which says `xcb` not `x11` — see `xcb.zig`, `core/x11/` being the
  XCB-facing subtree), or
- merge the two files and re-export, letting the pure/XCB split be
  expressed at the import-site rather than in filenames.

I'd take the rename. Merging both into one file would force every consumer
to import XCB transitively, which defeats the purpose.

`model.zig` — agreed, fine.

### `src/core/display/` — `usable_area.zig`
Slight suspicion is understandable but I think the placement is right. The
module owns the *work-area fact*: claims pushed by surfaces (bar/dock),
`workArea()` computed by core. That's a display-level fact, not a model
concern, and the header documents why "fullscreen means no work area" is
deliberately *not* encoded here. The name `usable_area.zig` is fine;
`work_area.zig` would be equally fine. Keep.

### `src/core/loop/`

**`diag.zig` and `xtrace.zig` are not a `log.zig` concern.** Both are
diagnostics *about live WM state*, not logging primitives:

- `diag.zig` dumps the model/subsystem state on demand (dump-state action).
  It imports `model`, `tracking`, `focus`, `pipeline` — it would be a
  layering violation to put that inside `core/pure/log.zig`, which is the
  xcb-free vocabulary and must stay dependency-free.
- `xtrace.zig` is an opt-in per-window event tracer interleaved with WM
  requests; it's loop-adjacent (X event tracing only makes sense next to
  the event loop). `log.zig` is a sink; `xtrace` is a producer of
  trace lines.

The real question is whether they belong in `loop/` at all. My view: they
read fine there — `diag` is driven from the loop's dump-state action,
`xtrace` is consumed by the loop's dispatch path — but if you want a cleaner
taxonomy, both could live in a small `src/core/diag/` pair. I would not
fold them into `log.zig`.

**`reload.zig` placement: correct.** Config reload is a *transition
orchestrator*: it detects changes, swaps the config pointer atomically, and
tears down/rebuilds subsystems (bar, borders, keybinds). Nearly every one
of those subsystems is not config code. Putting it next to `config.zig`
would mis-imply it's config-layer work. It is a loop concern — the loop
consumes the reload flag. Header says it was split out of `events.zig`.
Agreed with the current placement.

**`grabs.zig`: loop placement is defensible; the alternative is a
lifecycle home.** Grabs are installed once at boot and reinstalled on
config reload / keymap change — a lifecycle concern, not per-event
dispatch. Two defensible homes:

- keep in `loop/` (current): they exist to make keybindings fire, and the
  keybind resolution lives in `input/`.
- move next to `lifecycle.zig`/`persist.zig` in `proc/`: arguably more
  honest, since they're lifecycle (re)installation, and `proc/` already
  holds boot/teardown concerns.

I'd mildly prefer `proc/`, but this is a coin flip, not a defect. Note the
header says *"split out of events.zig"* — so it was a deliberate extraction.

**`events.zig` vs `timers.zig`: keep the split.** `timers.zig` is 39 lines
but it's a *policy* — the min-non-negative reduce over an arbitrary list of
sources — and `events.zig` is the dispatch mechanism. The header explains
why a one-entry inline version would not express the reduce. Merging it into
`events.zig` works mechanically but buries the policy and the test seam
(`timers_test.zig` exercises four sources). Not worth merging.

### `src/core/proc/`

**`persist.zig` naming.** `lifecycle.zig` is already taken, so the rename
you suggest collides. What `persist.zig` actually does: serialize/deserialize
WM model state across re-exec. Better candidates if you want a clearer name:
`handoff.zig`, `session.zig`, or `state_dump.zig`. `persist` undersells it —
it's not durable storage, it's a one-shot hand-off blob. Renaming is a
reasonable cleanup; `lifecycle.zig` is not available.

**`restart.zig` belongs here, not near `config.zig`.** It is the re-exec
coordinator: argv[0] re-exec via a loop flag. Has nothing to do with config
parsing. `reload.zig` is the config-adjacent one and is correctly
separated. Concern dismissed.

**`signals.zig` self-pipe: this is the standard, correct pattern.** POSIX
forbids most work in a signal handler; the self-pipe trick (handler writes a
byte, loop polls the read end) is the textbook way to defer dispatch to the
event loop. There is no *simpler* implementation achieving the same
guarantees — a global flag set in the handler still re-enters the loop and
misses signals arriving between poll and flag-clear. The header already
notes the handler also keeps an async-signal-safe pending-signal bitmap; the
self-pipe is just the wakeup. No change.

**`spawn.zig`: keep standalone.** It's 430 lines: fork/setsid, subreaper
setup, O_CLOEXEC outcome pipe, PID tracking/reaping. Merging into
`events.zig` (697 lines already) would make the dispatch file unwieldy and
lose the unit-test seam (`spawn_test.zig`). Standalone is right.

### `src/core/pure/`

**`dpi_math.zig` vs `display/dpi.zig`: split is correct.** `dpi_math.zig` is
pure (RESOURCE_MANAGER parsing, geometry→DPI formula, sanity band) and
testable without an X server; `display/dpi.zig` does X I/O plus bar-height
policy. Merging them would force the pure math to import XCB. Keep.

**`idmap.zig`: no meaningful simplification.** Fixed-capacity, allocation-free,
allocation-free tombstone map with Fibonacci hashing and stable entry
pointers is a real data structure; you can't "simplify" a real
open-addressed map without losing one of its properties (stable pointers,
tombstone rehash). If you wanted a simpler one you'd take `std.AutoHashMap`
and pay for allocation. Keep.

**`ids.zig` header: fair criticism.** The header explains the history of the
`WorkspaceId`/`WSId` split at length before saying what the file *is*. The
file *is* "the canonical workspace-id and window-id types, aliased by both
core and model so ids cross the boundary without conversion." Lead with
that; demote the history to a short second paragraph. Not a structure
problem, a docs problem.

**`paths.zig`: your skepticism is half right.** It's 97 lines of mostly
small utilities, and the `common_dirs`/`common_paths` pair is indeed
fiddly. But it is *used* by four call sites (config/discover, config/fallback,
prompt/completion, proc/persist) with the *same* probe-order semantics —
inlining it at each site would duplicate the `$PATH`-dedup logic four times.
That is the definition of a shared utility worth its file. The split
*within* it (`common_dirs` as the source of truth, `common_paths` derived)
is already the right shape. I'd keep it; if anything the header could note
the four consumers so the next reader doesn't infer it's dead code.

**`log.zig` vs `scaling.zig` naming: the inconsistency is real but the
right fix is `scale.zig`.** The module is a set of scaling formulas, not a
single scale operation, so `scaling.zig` reads better than `scale.zig`;
`log.zig` is a single noun for a logging facade. Both are gerund/noun of
the *domain*, which is defensible. If you want symmetry, rename `log.zig`
to `logging.zig` — but that collides conceptually with the 'log' verb used
inside it. Honest answer: this pair is fine as-is; consistency for its own
sake would be bikeshedding. Keep both.

**`time.zig`: concern is factually wrong.** It is used in ~13 non-test
call sites: `window/ws.zig`, `window/window.zig`, `window/wm.zig`,
`window/modules/floating.zig`, `input/input.zig`, `bar/modules/clock.zig`,
`bar/modules/systatus`, slider modules, `core/proc/spawn.zig`,
`core/loop/pipeline.zig`, `core/display/hz.zig`, and latency tests. Merging
into `clock.zig` would make clock.zig the owner of monotonic-time
primitives for the whole WM. `time.zig` must stay. (Worth noting: the name
`clock.zig` in the bar is the *widget*, `time.zig` is the *time source* —
different domains that happen to share a word.)

### `src/core/x11/`

**`cursor.zig`: the subsystem can't be deleted without losing a feature.**
cursor theming via libxcb-cursor is a real feature; no other WM
*necessarily* does it, but that doesn't make it dead weight — it's a small
one-startup-call module and the header explains why it lives in x11 rather
than input. The only simplification available is dropping the config option
and hardcoding the cursor. Keep.

**`ledger.zig` into `model.zig`: no — layering.** The ledger is a
write-only diff base keyed per window, XCB-adjacent, and deliberately
*not* part of the authoritative model (the model stays authoritative; the
ledger exists only so reconcile can elide no-op requests). `model.zig` is
xcb-free and DAG-root. Folding ledger in would break that. Its current
placement (x11/, with reconcile as the only writer) is the justified one.

**`constants.zig` (pure/) vs `masks.zig` (x11/): the split is the point.**
`constants.zig` stays XCB-free so the pure layers can import it; `masks.zig`
wraps XCB mask constants and must sit on the xcb side. The header of
`constants.zig` says exactly this. Your "feels kind of wrong" is the same
layering boundary wearing a different hat — these two *cannot* live in the
same subdirectory given the DAG rules. Dismiss.

**`reconcile.zig` + `ledger.zig` + grab split: the indirection is the
design, and the header is the problem.** Reconcile plans the delta, ledger
is the write-only basis it diffs against, requests are the allowlisted raw
primitives, sink is the sanctioned dispatch seam. That is four small files
each with a job, enforced by `dev/scripts/check-layers.sh` Rules 1–2. The
indirection is load-bearing — merging them would collapse the allowlist and
the layer rule.

What's legitimate in your note: the `reconcile.zig` header is a full
screenful of prose before a single line of code. Keep one short orientation
paragraph (what/why/invariants), move the algorithm walk-through and the
sink/grab relationship into section headers further down, and let the file
breathe. Also: you mention `grab.zig` cooperating with ledger+reconcile —
there is no `grab.zig`; the server-grab pair lives in `requests.zig`, and
root grabs live in `loop/grabs.zig`. Worth a grep next time.

**`requests.zig`: the file has a strong motive; the header should say it
louder.** It's the allowlisted home for raw `xcb_*` calls, enforced by the
same layer-check script. The "no strong motive" impression comes from the
header leading with protocol description instead of "this file exists
because every other file is forbidden from calling xcb directly." Reorder
the header. The split itself stays.

---

## What I'd actually change (ranked)

1. **`reconcile.zig` / `requests.zig` / `persist.zig`(via rename) /
   `ids.zig` headers**: lead with purpose, demote history and algorithm
   detail. No structural change; pure docs.
2. **Rename `contract_x11.zig` -> `contract_xcb.zig`** for tree-wide
   consistency (`xcb.zig` everywhere else).
3. **Rename `persist.zig` -> `handoff.zig`** (or `session.zig`); `persist`
   undersells a one-shot re-exec hand-off, and `lifecycle.zig` is taken.
4. **Optional**: `loop/diag.zig` + `loop/xtrace.zig` -> `src/core/diag/`
   if you want loop/ to be dispatch-only. Low value either way.

## What I would *not* change

timers/events split, spawn/events split, signals self-pipe, reload in
loop/, restart in proc/ (not config), dpi_math/dpi split, idmap, paths
inlining (it's used by 4 call sites), time.zig (13+ call sites, not just
clock), ledger/model split, constants/masks split, cursor.zig, contract
pure/x11 split (only rename), usable_area placement.

---

## Questions / follow-ups for you

1. On `cont/​answer`: is `diag.zig` + `xtrace.zig` something you'd ever
   want *outside* the loop (e.g. a `hana --dump-state` CLI path)? If yes,
   I'd argue harder for the `src/core/diag/` move.
2. `persist.zig` rename: `handoff.zig`, `session.zig`, or keep `persist`?
   I lean `handoff`.
3. `contract_x11.zig` rename -> `contract_xcb.zig`: yes/no?
4. The `reconcile.zig` header is the worst offender for length, but it
   contains the four behavioural reads of the ledger. When trimming, do you
   want those four reads moved to `ledger.zig`'s header (they're already
   summarised there) or kept in reconcile?
5. On `paths.zig`: you said "specially the common_dirs/common_paths part."
   If the dedup derivation is the ugly bit, would you prefer
   `std.StaticStringMap` built inline at each of the 4 call sites, or a
   small `pub const probe_order` array built once in paths.zig? I'd keep
   the latter — it's the same code with one owner.
6. `timers.zig`: you floated merging into events.zig. After reading its
   header, do you still want that, or was the "single entry today" fact the
   main trigger? (There is genuinely only one registered source today —
   the bar's deadline.)
7. `grabs.zig`: loop/ vs proc/ — do you have a preference, or should I
   decide? I'd default to keeping it in loop/ and revisiting if proc/
   grows a boot-lifecycle cluster.
