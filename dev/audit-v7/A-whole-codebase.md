# A-whole-codebase audit — interconnected simplifications across the cutter

Scope: full `src/` tree plus the `build.zig` seam/registry plumbing that binds
the layers (`tiling_seam`, `*_seam`, module registries, atom cache, x11 wire,
sync envelope, config). Not a rehash of the per-subsystem audit plans: none of
the items below appear in SIMPLIFICATION_PLAN.md / _v2.._v6 or their execution
statuses as DONE, so they are all new. Each item names `file:line` anchors and
an estimated LoC delta; items marked "(guard)" are comptime checks that add ~0
lines rather than removals.

Format per item: What / Why it matters / Concrete simplification / LoC delta.

---

## WCD-01 — Config "did this change" detectors are a second schema, hand-maintained alongside schema.knobs
Confidence: HIGH    Severity: MEDIUM-HIGH

- What: `config.zig` has one source of truth for knob *shape* (`schema.knobs`,
  applied by `applyAll`) but three parallel, hand-typed *change* detectors:
  `barChanged` (~45 BarConfig fields, config.zig:1826-1870), `tilingChanged`,
  `keysChanged`. The doc block (config.zig:1807-1823) defends the choice
  (schema.knobs carries per-knob conversion tags; a raw diff can't reuse it),
  but the two lists enumerate the same fields by hand on separate screens.
- Why: adding one `[bar]` scalar means editing schema.knobs *and* barChanged;
  forgetting the second silently produces a reload that accepts and applies the
  new value while never rebuilding the bar — stale pixels with no error.
  `barChanged` also compares fields schema.knobs never applies (fonts/icons/
  layout are compared there but not in `applyAll`), so the two tables can drift
  in either direction with no compile error.
- Concrete: extract the *membership check* so the detector is provably a
  superset of the applying table: derive `barChanged`'s comparison list from one
  shared comptime field-name table (same array of `std.meta.FieldEnum(BarConfig)`
  names used by schema.knobs), or add a comptime assert
  `schema applies ⊆ barChanged compares`. No runtime behavior change.
- LoC delta: ~0 (guard) plus removal of the hand-typed drift-prone duplicate
  name spellings once shared.

## WCD-02 — Border "focused vs unfocused" pixel pick is implemented three times
Confidence: HIGH    Severity: MEDIUM

- What: the same two-branch pick ("if focused use focused_px else
  unfocused_px") exists as `pipeline.colorOf` (pipeline.zig:147-150),
  `borders.borderColorOf` (borders.zig:17-19), and the composition
  `borders.resolveBorderColor` (borders.zig:43-56) that layers
  `isBehindCoveringWindow` on top. `sync.zig:132` carries the tell:
  Ctx.color_of is "ported from borders.resolveBorderColor minus its fullscreen
  check". So the resolve logic lives at pipeline.zig:147 *and* borders.zig:43,
  kept manually in lockstep across the core/sync and window layers.
- Why: this is exactly the twin-layer drift the audit is after — it has already
  materialized once (the "ported from" comment records a manual re-copy), and a
  future change to one pick (e.g. a hybrid border for covering windows) will
  land in one layer only. The two layers are the *reason* for two picks, but
  the *pure pick itself* has no reason to be duplicated.
- Concrete: the pure fn is already factored in `borders.borderColorOf` (takes
  `focused: bool`, two colors, no xcb/model deps). Hoist that 3-line pick into a
  layer-free leaf (e.g. `utils`/`constants`-family); `borders.resolveBorderColor`
  keeps its covering scan and delegates; `pipeline.colorOf` stays a 1-line
  delegate updating the pick (does NOT re-implement resolveColor). Cleanup is
  mechanical; the win is killing one documented fork.
- LoC delta: −6 to −8 (−1 fork body + the resolution fork comments shrink by 1).

## WCD-03 — Covering-occupant "who covers this ws" is three differently-scanned queries
Confidence: HIGH    Severity: MEDIUM

- What: `model.coveringOccupantOnWs` (model.zig:246, OR: anchor-or-visibility
  union), `fullscreen.fullscreenOccupantOnWs` (fullscreen.zig:161-175, AND:
  presence must be `.covering`, `covering_ws` anchored, visibleOn), and
  `actions.currentCoveringOccupant` (actions.zig:40-41) which re-routes to the
  module AND scan via contract hook. The fork is deliberate (module scan must
  not be enumerated by core), and the doc comments are thorough — four comment
  sites (model.zig:242, fullscreen.zig:93-159, borders.zig:26-27,
  sync.zig:272-273) spell the difference, and perf tests benchmark both
  (test/latency/perf_test.zig:72-99).
- Why: every reader must hold "OR vs AND" in mind across call sites, and tests
  conflate them (model_test.zig:1298-1323 deliberately asserts both give the
  same answer on parked ghosts — the current equality is an invariant no
  compiler enforces). It is three names for one concept, with the third being a
  pass-through that papers over which semantics the caller wanted.
- Concrete: keep the model OR scan as the single public query; fold the AND
  constraints into `fullscreenOccupantOnWs` as a short wrapper over the same
  `m.store` pass (`presence == .covering` filters a superset result) so the
  distinction reads as "constraint wrapper", not "separate scan". Second order:
  delete `actions.currentCoveringOccupant`'s route in favor of naming the exact
  scan at the two call sites (actions.zig:860, focus.zig:613, workspaces.zig:60
  already name it).
- LoC delta: −10 to −15 plus one deleted duplicate scan definition.

## WCD-04 — Tests bypass the `tiling_seam`; production has no second wiring path
Confidence: HIGH    Severity: MEDIUM

- What: production reaches tiling exclusively through the build-generated
  `@import("tiling_seam")` (grep: input.zig:27, pipeline.zig:27, sync.zig:60,
  actions.zig:65). But the test layer hand-rolls its own gate:
  `test/fixture.zig:34-35` and `test/engine/model_test.zig:19-20` use
  `if (build_options.has_tiling) @import("tiling") else @import("std")`.
- Why: the seam's whole purpose is a single compile-time switch; the test
  fallback imports `std` *under the name `tiling`* (a non-module stand-in) and
  re-evaluates the option by hand. The two wiring paths can diverge (new
  obligation added to the seam in production with no test counterpart), and the
  `@import("std") as tiling` trick makes the seam contract untestable.
- Concrete: expose the production seam (or an equivalent
  `@import("tiling_seam")`) to the test build and delete the hand-rolled
  `else @import("std")` stand-in in both files; optionally add the
  `has_tiling`-style comptime switch to the test artifact the same way
  build.zig does for prod.
- LoC delta: −2 net (both branches collapse to one import) plus the removal of
  a divergent pattern.

## WCD-05 — Ctx carries border width twice: `cfg_bw` duplicates `env.margins.border`
Confidence: HIGH    Severity: LOW-MEDIUM

- What: the pipeline builds tiling env with
  `env.margins.border = core.borderWidth()` (pipeline.zig:135) and then
  separately puts the same value into `Ctx.cfg_bw`; the sync reconcile reads it
  as `ctx.cfg_bw` (sync.zig:527) while tiling modules read
  `ctx.env.margins.border`. Separately `borders.width()` (borders.zig:60-62) is
  a 3-line re-export of the same `core.borderWidth()`.
- Why: two spellings of one value in the same struct — every new tiling
  caller must know which is canonical; the doc comment at sync.zig:527 already
  has to explain the equivalence. Cheap, mechanical, self-contained.
- Concrete: drop `Ctx.cfg_bw`, make `computeDesire`/the one caller read
  `ctx.env.margins.border` (no behavior change); keep `borders.width()` only if
  borders is expected to be the window-layer spelling, otherwise delete it and
  call `core.borderWidth()` at the 2-3 border application sites.
- LoC delta: −6 to −9.

## WCD-06 — window.providerOf/dispatch re-exports + actions' 7 local aliases make one dispatch family three layers deep
Confidence: HIGH    Severity: LOW

- What: canonical generic dispatch lives in `contract.providerOf/callFirst/
  callFirstBool/callAll/callFirstTrue` (contract.zig:278+); `window.zig:34-70`
  re-exports each as a typed typed-forward (5 fns); `actions.zig:27-33` then
  aliases window's versions locally (`const providerOf = window.providerOf;`
  etc., 7 names). Cross-module callers mix all three spellings.
- Why: each layer's naming variant is justified alone (typed field-enum, short
  local), but as a chain it front-loads "which layer owns this?" at every call
  site, and the window.zig forwards exist only for `actions`' and `borders`'
  aliases (window.zig:31-33 doc says exactly that).
- Concrete: pick one home. Cheapest: keep window.zig's typed forwards as the
  window-layer facade and delete actions' 7 aliases (borders already imports
  window.* directly); or delete the window.zig forwards and move the
  typed field-enum call sites to contract.* directly. Two edits per module,
  no runtime change.
- LoC delta: −7 (alias block) or −5 forwards once callers name contract
  directly.

## WCD-07 — Window/workspace ids are the same type spelled two ways
Confidence: HIGH    Severity: LOW-MEDIUM

- What: `ids.zig` defines `WindowId = u32`, `WorkspaceId = struct{...}`; both
  `core.zig:33,42` and `model.zig:12,17` re-export them under different names —
  `core.WindowId/WorkspaceId` vs `model.WindowId/WSId`. All four are the same
  underlying types, and callers mix spellings inside a single file (borders.zig
  passes raw `u32`, sync uses `model.WindowId`, screen uses `core.WindowId`,
  contract fn sigs use `model.*`). Interop is free; the names are noise.
- Why: two facade names for one type is the cheapest readability tax in the
  tree, and it is the kind of thing that turns "same type" into "must check
  which alias" at boundaries that matter (contract signatures are `model.*`,
  wire calls use `core.*`).
- Concrete: retain exactly one visible pair (`model.WindowId`, `model.WSId` —
  they dominate contract/sync signatures) and trim the core.zig aliases to a
  single doc line "re-exported as model.WindowId"; or rename nothing and add a
  doc pointer at both sites. Mechanical, ~40-60 touch points, zero behavior.
- LoC delta: ~0 (rename churn only).

## WCD-08 — Three per-module atom mini-caches duplicate the one shared AtomCache
Confidence: HIGH    Severity: LOW-MEDIUM

- What: `wire.zig` owns the single `AtomCache` + `getAtomCached`/`getAtomOrZero`
  (each get is one struct-field read after first init). Yet `wincache.zig`
  keeps its own file-global pair `net_wm_name`/`utf8_string` behind
  `ensureAtoms()` + `atoms_resolved` (wincache.zig:160-176, 233-237) and
  `icccm.zig` caches `FocusAtoms` via its own `focusAtoms()` (icccm.zig:205-234)
  — each re-resolving atoms at first fire and stashing results in module state.
- Why: the shared cache already exists and is initialized in boot order before
  these modules run; the local caches store nothing the shared cache does not,
  so they are duplicated state + duplicated first-fire logic per module, and
  each new property resolution copies the pattern again.
- Concrete: delete wincache's globals and call
  `wire.getAtomCached(conn, "_NET_WM_NAME") orelse null` at the two read sites;
  delete icccm's `FocusAtoms` struct and cache and inline `getAtomCached` calls
  in the two property functions that needed them. Keeps the `catch null`
  semantics identical.
- LoC delta: −14 to −20.

## WCD-09 — Property-reply validation is hand-rolled in three places with three shapes
Confidence: MEDIUM    Severity: LOW-MEDIUM

- What: "did this reply come back as the expected format/type" is checked in
  talls: `wincache.takePropertyReply` (wincache.zig:259-274, its comment
  literally says "Mirrors wire's property validation"), icccm's
  `extractWMHintsInput` + `u32Values` (format-32 path), and the poll-first
  `collectPropertyReply` in wire. The 8-bit encoded-name and 32-bit u32 paths
  each re-implement the format/type gating inline.
- Why: same guard, three spellings, and the string one explicitly records that
  it mirrors another (fork that already needed a doc to stay honest).
- Concrete: one `takePropertyReply(conn, cookie, want_format, want_type) ?reply`
  in wire; re-enter it from wincache (format 8, `self.atom_type`) and from the
  icccm u32 path (format 32, any-type accepted), deleting the inline checks.
- LoC delta: −8 to −12.

## WCD-10 — Server-grab brackets take three shapes: reconcileUnderGrab, withServerGrab, and bar's local ungrabAndFlush
Confidence: HIGH    Severity: LOW

- What: the "grab server, run body, ungrabAndFlush" atomicity idiom is
  implemented as `sync.reconcileUnderGrab` (sync.zig:230-236, used directly by
  pipeline.reconcileUnderGrabNow pipeline.zig:188-191), as
  `pipeline.withServerGrab` (pipeline.zig:182-185, 4 grab variants), and as
  bar.zig's own `inline fn ungrabAndFlush()` (bar.zig:1168-1170) hand-placed
  beside `utils.grabServer` in toggleBarSegmentAnchor/applyVisibility —
  even though `bar.zig` already imports `utils` and calls
  `utils.ungrabAndFlush` would do the identical thing with the state's conn.
- Why: three spellings of one bracket means "did this path grab/flush
  symmetrically?" must be checked per call site; bar's local shim adds a name
  no other layer uses.
- Concrete: fold `reconcileUnderGrab` into `pipeline.withServerGrab` (same body
  template; reconcile is just the grab-with-body run) and replace bar.zig's
  local shim with `utils.ungrabAndFlush(core.getState().conn)` at the two sites
  (or a single bar helper taking conn once). Keep the wire vs Sink duplicate of
  the raw `grabServer`/`ungrabAndFlush` — that pair is the sanctioned seam.
- LoC delta: −6 to −10.

## WCD-11 — Workspace-number parsing is a trio with a duplicated bound check
Confidence: HIGH    Severity: LOW

- What: `config.zig` implements `parseWsToken`, `tryParseWorkspace`, and
  `tryParseWsToken` (config.zig:26-65), where the last literally re-does
  `parseWsToken` + `checkWorkspaceBound` inline (the range predicate at
  :57-60 duplicates :27-31) and emits its own warn text. Workspace-rule section
  parsers then call `checkWorkspaceBound` *again* after `parseWsToken` on
  adjacent lines.
- Why: three parse entry-points with overlapping shapes; the bound predicate
  exists in two places so a future bound change (e.g. bounded by a monitor
  count) must be applied twice.
- Concrete: define `tryParseWsToken = parseWsToken → checkWorkspaceBound → null`,
  delete the inline re-predicate; merge tryParseWorkspace's distinct unsigned
  parsing into one utility when plausible (its behavior differences are only
  the prefix-sensitive base).
- LoC delta: −5 to −8.

## WCD-12 — Layout canonical names are hand-listed in two config tables plus types, against a build-generated registry
Confidence: HIGH    Severity: LOW

- What: `tiling_modules` (build-generated from the tiling dir) is the owner of
  "which layouts exist", but `flat_variant_keys` (config.zig:1289-1293)
  hardcodes `"master"/"monocle"/"grid"`, `layout_name_grammar` (config.zig:1392
  -1396) hardcodes all eight canonical names for parse validation, and
  `types.canon_master_layout` hardcodes the master spelling — three
  hand-maintained lists where a typo silently kills a config line.
- Why: adding a layout touches two config tables + types + the tiling dir, and
  a mismatch surfaces as a parse warning rather than an error.
- Concrete: (guard) comptime assert in config that
  `flat_variant_keys` ⊆ `layout_name_grammar` and both ⊆ registry names, or
  derive the literal tables from the registry comptime list passed into config
  via the seam. No runtime behavior change.
- LoC delta: ~0 (guard) / −10 if the tables go generated.

## WCD-13 — build.zig-generated registry files each inline their own comptime invariant block
Confidence: HIGH    Severity: LOW

- What: the generated per-registry modules (build.zig ~1034-1082) carry
  copied comptime checks — duplicate canonical-name guards and the
  `single_binder_hooks` audit — repeated for each registry bulk (bar, window,
  tiling). They can't `@import("std")` by design (leaves the generated module
  std-free), so each copy is ~48 lines of near-identical comptime code.
- Why: the invariant logic is duplicated N-way; when the audit rules tighten,
  each registry file must be regenerated-and-reviewed, and a copy can drift
  silently because the checks live in generated (compiled) files, not in one
  place.
- Concrete: emit a single shared table of invariant specs from build.zig into a
  leaf generated module (std-free, just comptime structs) which all registries
  import; the 48-line checks become one shared comptime loop over specs.
- LoC delta: −90 to −130 across the three registries' generated bodies (the
  generated count is fixed by dirs, so real savings are in build.zig + bytes).

---

## DEFERRED / QUESTIONS (owner to confirm before filing)

- `pipeline.Gate` is re-declared privately per owner module (tracking.zig:19,
  focus.zig:18, window.zig:29, actions.zig:23); invariants deliberately do not
  cross-module — keep as-is, or promote to one shared Gate? (Q for tiling owner.)
- `sync.Sink.VTable` (12 forwarding stubs, sync.zig:85-120) is the sanctioned
  test seam — no action proposed.
- `helpers.zig` / `sync`'s writes (sink.zig VTable shims) duplicate the wire
  grab/flush primitives; considered sanctioned (test hook layer) and excluded
  from WCD-10.
- `bar.zig`'s manual ungrab+flush in toggleBarSegmentAnchor exists to keep a
  paused bar from flushing mid-frame; folding it into WCD-10 keeps that
  ordering comment — confirm the ordering constraint survives the fold.
- Chain of DONE-status hygiene: `serializeWindow`/`deserializeWindow`
  (contract.zig:147-148, window.zig:752/757, persist.zig:182) are the plugin
  *seam*, not the removed ledger serialization (COREP-21) — confirmed still
  present and intended, not a regression.
- No "claimed-fixed-but-still-present" instances found: `applied_border_width`,
  `SentEntry.id`, slot-removal paths, and duplicate per-pass warns are all
  absent from grep; the surviving identifiers above are sanctioned seams, not
  zombies.