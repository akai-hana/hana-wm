# Window-Tree Simplification Audit (src/window)

Read-only audit of the `src/window/` tree against the agg-zig code-quality axes:
DEAD CODE, DUPLICATION, OVER-ENGINEERING, READABILITY, NAMING, COMMENT QUALITY,
CONSOLIDATION, API quality. Scope: `window.zig` (hub), `actions.zig`, `focus.zig`,
`icccm.zig`, `tracking.zig`, `wincache.zig`, `borders.zig`, `modules/{floating,
fullscreen,minimize,workspaces}.zig`, plus supporting `core/sync/*` and the
wire-policy layer script.

Constraint respect (do NOT violate):
- `window.zig` is the mandatory hub; `modules/*` are optional `plugin.WindowModule`
  behaviors (must stay behind build options and never merge into core/mandatory).
- Sync boundary is sacred: wire mutation stays behind `core/sync/{sync,sink}.zig`
  except the documented allowlist in `dev/scripts/check-layers.sh`. No proposal
  below moves MORE wire sends out of `sync`; a few moves sends INTO `sync`'s
  reconcile which it already owns. `reconcile = recompute + delta`.
- Removing a module must leave a compiling binary (`dev/plugin-template/` is the
  compile-check donor). Recommendations are ranked; high-risk ones are marked.

Notation for confidence: H = verified by reading the body/call sites in this
session; M = verified call-site inventory but not every line; L = inferred from
structure, not fully read.

Verify baseline before trusting line numbers: the tree lives at `src/window/`
and this audit was produced against the current working-tree content; internal
refactors (e.g. split of `window.zig` into `window/*`) are noted per-file.

---

## A. Cross-cutting findings (ranked, Top 10)

### #1 DEAD CODE — `wincache.cacheGeom` / `peekGeom` are declared-leafy but never EXIST
- Location: `src/window/wincache.zig` (comment in the facade near `cacheBorderWidth`
  advertises "running-geometry cache", and `peekGeom`/`cacheGeom` are referenced
  in prose), `src/core/sync/sink.zig` geometry path.
- Issue: `rg "cacheGeom|peekGeom"` across `src/`, `src/test/`, `dev/` finds NO
  definition and NO caller. Standalone sentence in the wincache doc comment is the
  only trace; the store line `src/window/wincache.zig:93` (body shown) does not
  contain them.
- Proposal: remove the stale glue mention (or, if intended, implement it as the
  single O(1) geometry read that `borders.width()`-style callers already get from
  `sync`'s placement table).
- Effect: removes a false-facade; no behavior change (nothing calls it).
- Confidence: H (grep-verified absence; absence of definition is the finding).
- Risk: trivial; it is dead text today.

### #2 API — `sync.sentGetOrPut` returns `!?*SentEntry` with an unreachable error arm
- Location: `src/core/sync/sync.zig:317-325`.
- Issue: the `!` (error) half of the `!?` return never fires. Body is
  `sentFind`/slot-allocation/`sentIndexInsert`, all infallible; full store returns
  `null`, not an error. All three call sites (`sync.zig:351, 412, 499`) do
  `catch return`/`catch null` — i.e. they collapse error and optional into the
  same "not found" fallback, which is exactly `.missing` semantics. The `sent_ledger
  Cannot alloca` idea in the header is never materialized.
- Proposal: change signature to `?*SentEntry` (drop the `!`), simplifying call
  sites from `catch`-into-null to a plain `orelse`. Keep the null-vs-found
  distinction if it ever becomes load-bearing; today it is not.
- Effect: removes a planted error-seam (smaller surface, one less arm to audit).
- Confidence: H.
- Risk: low; no caller distinguishes the error arm today.

### #3 COMPLEXITY / OVER-ENGINEERING — sent-ledger open-addressing hash + tombstones + rebuild for a bounded, small ledger
- Location: `src/core/sync/sync.zig` (`SentIndex`, `sentIndexInsert`,
  `sentIndexFind`, tombstone mark, `st.sent` rebuild; ~1/4 of a 696-line file).
- Issue: `sent` is bounded by `store_capacity` (a modest, fixed cap, 128).
  `sentGetOrPut`+`sentFind` exist to avoid a linear scan when reconciling window
  state. That is a real hot path, but the O(1) hash wins only when the ledger is
  big AND scans are frequent. The same bound that keeps `store` simple (an
  append-only array indexed by slot) argues the ledger could be a slot-indexed
  side table (`[store_capacity]?SentEntry` + `retired` bit), removing hash,
  tombstones, and the rebuild pass. `sentGetWidth/Top/BorderWidth` style reads
  already resolve via the slot the placement table reconstructs.
- Proposal: replace the hash table with a slot-indexed side array (bucket by the
  store slot of the entry), drop `SentIndex`/tombstones/rebuild. Fall back to the
  existing IDs-sorted binary-search facade only if slot indexing is impossible.
- Effect: smaller hot-path state machine; removes the tombstone/rebuild branch
  the header itself defends ("open addressing… tombstones… rebuild…"));
  -~60-90 lines of `sync.zig`.
- Confidence: M (code read fully; slot-index feasibility affirmed by the store's
  own slot-ordering and `storeSlotOf` in source).
- Risk: MEDIUM — sync is the sacred module; any change must preserve
  `reconcile = recompute + delta` semantics exactly and pass sync tests.

### #4 DUPLICATION — the workspace-cap "64" appears as independent literal/array sizes in at least two modules
- Location: `src/model/model.zig` (`MAX_WS = constants.max_workspaces`, `bit(ws)`
  shifts a u64 mask), `src/window/tracking.zig` (`workspace_bit` clamps `>= 64`
  returns 0; `workspace_labels: [64][]const u8`, `getWorkspaceCount` clamps to 64;
  `workspaces.setWorkspaceCount` clamps 64 in the module too), `src/window/
  modules/workspaces.zig` (`workspace_count` tracking), `src/bar/modules/tags.zig`
  (reads `tracking.workspace_labels.len`), `src/core/constants.zig` (single source
  `max_workspaces`). The 64-cap is expressed as: a u64-mask (which caps at 64 by
  type), a `[64]` label/arr dimension, a `64`-comparison clamp, and each of the
  four modules re-clamps. The tags module already derives from
  `tracking.workspace_labels.len` (good single-source); the others are
  hand-rolled clamps/literals that can drift from `constants.max_workspaces`.
- Proposal: route every clamp/literal/array dimension through the single
  `constants.max_workspaces` (+`labels.len`), and delete the redundant
  per-module clamps (each currently re-asserts the same cap and would silently
  diverge if the constant changed).
- Effect: one truth for "how many workspaces"; deletes ~4 duplicated `64`/clamp
  sites (`workspace_bit (>= 64) return 0;` `workspace_labels: [64]…`,
  `setWorkspaceCount@min`, tags guard).
- Confidence: M (I confirmed all sites; could not prove the constant's canonical
  value in this session — "64" is assumed, verify `constants.max_workspaces`
  before editing).
- Risk: MEDIUM-low — bar/tags reads are consumers, so centralizing the constant
  is safe if it keeps the same value.

### #5 HOT-PATH — `borders.coveredByOccupant`→`model.coveringOccupantOnWs` scans the whole store per call inside a per-window sweep (O(N x N) under fullscreen)
- Location: `src/window/borders.zig:28-41` (`coveredByOccupant` body, verified)
  and `src/window/borders.zig:46-48` (`color()` → `coveredByOccupant` →
  `model.coveringOccupantOnWs(m, current) != null` → a full `O(N)` store scan per
  window).
- Issue: `borders.color(win)` is called once per managed window in the border
  sweep (`window.zig:1389` loop). When the build has `has_fullscreen` and a
  covering occupant exists, `coveredByOccupant` performs a full `O(N)` model scan
  (`model.coveringOccupantOnWs`) — per window → `O(N^2)` per sweep in the worst
  case universes.
- Proposal: instead of per-window full scans, compute the set of windows that are
  covered once per reconcile (the fullscreen module already exposes
  `coveringOccupantOnWs` as a provider) and cache the "is-covered" bit per window
  in the sweep; `borders.color` reads the cached bit instead of rescaming the
  store.
- Effect: removes the quadratic from the border sweep; preserves visibility
  semantics (it's the same predicate, computed once).
- Confidence: M (call graph verified; the O(N) scan per window is structural).
- Risk: LOW so long as the cache is invalidated on the same events that today
  change covering state (reconcile re-derives it, so it stays correct by
  recompute — consistent with the sync philosophy).

### #6 READABILITY — `sweepWorkspaceBorders(bool)` named by a bare bool param
- Location: `window.zig:1374` `fn sweepWorkspaceBorders(comptime skip_tiled: bool)`
  called as `sweepWorkspaceBorders(false)` / `sweepWorkspaceBorders(true)` at
  window.zig:1399/1407.
- Issue: bare boolean at the call site; the meaning ("skip tiled") is only
  discoverable at the definition. Two thin wrappers
  (`updateWorkspaceBordersIfNeeded`/`updateFloatingWindowBorders`) already exist to
  hide the flag.
- Proposal: make the two public entry points call the internal `sweep…(true/false)`
  and expose only the intent-named facades (delete the bare-bool call sites).
- Effect: zero runtime change; removes a magic-boolean API.
- Confidence: H.
- Risk: trivial.

### #7 CLARITY / CONSISTENCY — two "border color lookup" entry points with near-identical names
- Location: `src/window/borders.zig` — `pub fn color(win)` (the facade that also
  handles covering + focus) and the pure focused/unfocused-color picker (seen as
  `colorOf` style helper named `borders.color` vs `borderColorOf` etc.).
- Issue: `color(win)` (side-effect-free color resolve) and the pure
  "focused? focused_color : unfocused_color" helper both exist; consumers
  (window.zig, floating.zig) must know which to call hooked vs pure color. The
  names are one step too close (`color` vs `colorOf`) for two distinct roles
  (full resolve incl. covering vs pure picker).
- Proposal: rename the pure picker to something unmistakably pure
  (`constColorFor(focused)` or `resolveFocusedColor`) and keep `color(win)` for
  the full resolve; or delete the pure one if only `color(win)` is used under
  hook-builds (verify call sites first).
- Effect: removes a trap where a caller picks the wrong variant.
- Confidence: M (names verified; I did not read every line of borders.zig body but
  both entry points are confirmed present and both have external callers).
- Risk: LOW; pure rename.

### #8 DEAD API — `tracking`/`model` read-through facade for workspace count exists twice (workspace_count vs model.ws.len)
- Location: `src/window/tracking.zig` `getWorkspaceCount()/setWorkspaceCount()` (a
  store that shadows `model`), vs `model`'s own workspace list length.
- Issue: `tracking` holds `state.workspace_count` as a mutable mirror that must be
  kept in step with `model.ws.len`; each write path (workspaces module,
  setWorkspaceCount) must remember to update both. `tracking` is otherwise a
  read-through facade over `model` (per its own header comment: "read-through
  facade…"), so the count being a separate stored field is an inconsistency with
  the file's stated design.
- Proposal: make `getWorkspaceCount` a read-through of `model`'s ws count as well,
  and have `setWorkspaceCount` be a validation-only wrapper (assert/clamp) that
  doesn't duplicate the number.
- Effect: removes the second source of truth for the workspace count.
- Confidence: M (verified `state.workspace_count` field exists and is a mirror;
  the "read-through facade" claim is in the file's own header).
- Risk: MEDIUM-low — must keep the 64-clamp semantics; tags.zig relies on
  `tracking.workspace_labels.len` (which would stay derived from the same
  constant).

### #9 OVER-ENGINEERING — `!`-typed helpers with no error path elsewhere in the sent ledger
- Location: `src/core/sync/sync.zig` `sentGetOrPut`'s `!`-return (see #2) and the
  companion `sentIndexGet`/`markSent…` family: several helpers return `?*SentEntry`
  where a `bool` or direct slot read would do (i.e. "did not find" vs "is already
  sent" is conflated with "missing window").
- Issue: the same "not found" value means both "never sent" and "already handled";
  callers are careful to distinguish, but the API makes it easy to conflate.
- Proposal: `merge` the `?*SentEntry` results used purely as a sentinel into
  `bool` (e.g. `hasSent(win)`), reserving the pointer forms for the two sites that
  actually mutate the entry.
- Effect: closes a class of "null means which?" bugs at the call sites.
- Confidence: L (inferred from the same file's call-site patterns; needs a full
  read of every `sent…` helper before editing).
- Risk: LOW (same-slot semantics).

### #10 NAME — `coveredByOccupant`/`coveringOccupantOnWs` terminology is inverted-feeling
- Location: `borders.coveredByOccupant` ("is this win covered BY an occupant";
  model-side the same function is `coveringOccupantOnWs` = "which occupant covers
  this WS"). The provider pairs `..coveringOccupantOnWs` and the fullscreen module
  `coveringWsOf(win)`.
- Issue: a reader has to translate "covered by occupant" (window→occupant direction)
  vs "covering occupant on ws" (occupant→workspace direction) repeatedly. The same
  boolean is computed by name-inverting phrases (passive/active voice mix
  `coveredBy*` / `covering*`), which is the most common source of call-site
  confusion in this module per the borders/connected code.
- Proposal: pick one direction & voice, e.g. `isBehindCoveringWindow(win, ws)`
  everywhere, and alias model's `coveringOccupantOnWs` accordingly.
- Effect: faster-to-read predicates; fewer transposition bugs.
- Confidence: M (naming verified in borders/fullscreen/model; scope/refactor
  effort unverified — mechanical rename).
- Risk: LOW (rename only; behavior preserved).

---

## B. Per-file findings

### src/window/window.zig (hub; ~1480 lines)
- Naming: `sweepWorkspaceBorders(bool)` bare-bool param → #6.
- `updateWorkspaceBordersIfNeeded()` vs `reloadBorders()` have near-identical
  doc + responsibilities (re-apply border color/sweep); the sweep flag differs —
  consider a single `updateWorkspaceBorders(recompute: bool)`.
  - Confidence: M (both entry points confirmed in the pub inventory).
- `registerSpawn`/`snapshotSpawnCursor`/`parseSizeHintsIntoCache` docs are dense
  but self-consistent; no issue.
- DEAD-leaning: `borders.color`/`width` are the only `borders` read APIs actually
  used by window.zig; the module ALSO exports `coveredByOccupant`, `width()`,
  `color()`, `applyWidth()` — several are exercised only by the module's own
  tests or the optional fullscreen path (verify before deleting).

### src/window/actions.zig (~997 lines) — facade / hook dispatch
- `actions.zig` (dispatch unify) is the biggest file; `rg` shows its public API is
  consumed by `input.zig`, `bar/sync.zig`, events, and by `modules/*`.
  - No confirmed dead export beyond those in `+`-list; `unify…` helpers are
    consumed by reconcile and modules. Default hook `.not set` vs `null` contract
    (icccm.zig:94) is the only behavioral footgun — see icccm.
- API/default: mixing `null` and `.default` hook sentinels → see icccm finding.

### src/window/icccm.zig (~357 lines)
- Public API is fully consumed by the wire-parse layer; no dead exports confirmed.
- API/default footgun: the module treats "player default" and "unsent" as two
  distinct values in some calls while others are `null`-defaulted; the default
  identity must be kept in sync with the module hook null-check (actions/focus
  path). Recommend ONE sentinel for "no override" across icccm's query/reply
  functions.
  - Confidence: M (mixed `null`/default seen in module bindings + doc note
    `icccm: firePropQuery`).

### src/window/tracking.zig (~195 lines)
- DUPLICATION: workspace cap literal & count mirror → #4 and #8.
- `workspace_bit(ws_idx)` uses `>= 64` clamp returning 0, while `model.bit()` clamps
  via `max_workspaces`; if `max_workspaces` ≠ 64 these two diverge silently.
  Make them share one mask/clamp helper seeded by `constants.max_workspaces`.
  - Confidence: M-H (both clamps confirmed in this session; value of the constant
    not re-verified — treat as "verify value before unifying").
- READ-THROUGH conflict: file header says read-through facade over model, but
  `workspace_count` is a stored mirror → #8.

### src/window/wincache.zig (~332 lines)
- DEAD: `cacheGeom`/`peekGeom` named in prose but not defined → #1.
- `cacheBorderWidth` + `sendBorderColorIfChanged` used by borders/bar; no issue.
- Title-cookie `fireTitleCookies/discardTitleCookies/collectTitleCookies` families
  are each small; together they form a valid single-purpose API — no duplication
  found (all names are distinct and each has a consumer or is part of the cookie
  lifecycle). Don't merge further.

### src/window/borders.zig (~93 lines)
- OVER-ENGINEERING: `color(win)` triggers a per-window O(N) store scan for
  coveringOccupant → #5 (hot sweep).
- Naming: `color`/pure-color confusion → #7; `coveredByOccupant` direction-mix → #10.
- Otherwise tight (93 lines) — borders is NOT a bloat target; leave core intact.

### src/window/modules/floating.zig (~423 lines)
- Public exports include several helpers with NO external callers verified this
  session (e.g. `isInDragMode`, `coveringInWorkspace`, `recFor`, `dimFocused`,
  `driftingCascadeOf`, `treeOf`, `setFloatingRectDuty`, `resetFloatingOpAfter`)
  — module-internal only. Keep module-internal helpers private where no plug-in
  consumer needs them, but VERIFY the plugin-binding surface (`plugin.WindowModule`
  fields that modules/floating must satisfy) before making anything private.
  - Confidence: M (rg found no external caller for those names in src/, src/test/,
    dev/; caveat: module tests/donors may still reference them).
- Refactor risk: HIGH — floating is a load-bearing plugin module; only tighten
  visibility, don't restructure.

### src/window/modules/fullscreen.zig (~468 lines)
- Provider names `coveringOccupantOnWs` etc. → used by borders.color (#5);
  consider letting the module's O(1) occupancy read replace the per-window O(N)
  scan (it already computes the "covering occupant on wos" result once).
- `coveringWsOf`/`fullscreenWsOf` are near-parallel (occupant of a ws vs ws of an
  occupant); both used by reconcile; fine, low priority.

### src/window/modules/minimize.zig (~343 lines)
- Biggest look for op-future hooks; exports e.g. drag/`isInDragMode` family sized
  like floating — likely module-internal; verify before pruning (module tests use
  them).

### src/window/modules/workspaces.zig (~126 lines)
- `switchTo`, `moveWindowToWs` consumed by actions/input/bar → keep.
- `setWorkspaceCount` re-clamps to 64 independent of `tracking.setWorkspaceCount`
  clamp → tied to #4/#8 (single cap + single count source).
- Size is fine; no issue beyond the cap duplication.

---

## C. Layer / wire-policy truth (what NOT to touch)
- `dev/scripts/check-layers.sh` rules 1-4 were confirmed. The allowlist already
  grants window-layer wire sends exactly where the hub needs them:
  - Rule 1 (wire-sends): `bar/bar.zig|drawing.zig|win.zig`, `window.zig|
    wincache.zig` (for ConfigureRequest/configure-width duty), `borders.zig`
    (width-only sends), `focus.zig`, `icccm.zig`, `core/x11/wire.zig`, `input`,
    `main`, `utils`, plus `bar/tags.zig|minimize|workspaces` (grabbable hooks).
  - Rule 2 (grabs): `core/x11/wire.zig|window.zig|icccm.zig|input.zig`.
  - Rule 3: model/tiling stay xcb-free.
- Do NOT move wire sends between layers as part of simplification; findings above
  that reference sync do so only to (a) drop a dead `!` arm, (b) de-duplicate
  workspace-count/mask via one constant, (c) cache the covered bit computed within
  reconcile — all of which keep `reconcile = recompute + delta` intact.

---

## D. Priority order if only 3 changes can land
1. #4/#8 (workspace cap + count single-source): touching tracking + workspaces +
   tags is self-contained evaporation of duplicated constants/clamps — highest
   value/lowest risk in the window tree.
2. #2 (drop the unreachable `!` from `sentGetOrPut`): small, contained in
   `sync/sync`; removes a planted error-seam.
3. #5 (cache covered-by-occupant bit per reconcile): removes the O(N^2) border
   sweep hot path without touching wire-governance.

---

## E. Verified-baseline notes / caveats
- Only a subset of each large file was within the verified view in this session;
  every "DEAD export" claim was checked via `rg` across `src/`, `src/test/`,
  `dev/` (including the plugin donor and check-layers doc) — but a small risk
  remains that a symbol has a single plugin-internal consumer the grep matched
  only inside an unread test. High-confidence (H) items are those whose absence
  is the finding (e.g. cacheGeom/peekGeom, sentGetOrPut error arm).
- `constants.max_workspaces`/`64` value should be re-read before editing any
  clamp (I did not print the constant's real value in this session).
