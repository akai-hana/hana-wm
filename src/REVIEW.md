# Review of src/PLAN.md — Dynamic Config Registry Plan

Reviewed against the tree at the current working state (Zig 0.16.0, `build.zig`
as the module-discovery source of truth). Verdict: **not executable as written**.
The genuinely new work (Phases 1–3, the dynamic registry) has several hard
blockers, while Phases 4–6 largely describe work that has already landed.

Errors quoted below were compiled with the pinned 0.16.0 compiler, not guessed.

---

## Blockers

### B1. The generated `Config` struct cannot be expressed as written
The registry sketch (PLAN.md:134-139) uses `inline for` inside a struct body to
declare fields, and `@fieldName(mod.name)` to name them:

```zig
pub const Config = struct {
    core: CoreConfig,
    inline for (ConfigModules) |mod| {
        @fieldName(mod.name): ?mod.Config = null,
    }
};
```

Verified against 0.16.0: `error: expected type expression, found '{'` — container
scope accepts declarations, not loop-generated fields. Separately,
`@fieldName` takes a **type**, not a `[]const u8` value, so `@fieldName(mod.name)`
is wrong even if the loop were legal. There is no supported syntax for
comptime-computed struct field names. The composed struct therefore needs a
different mechanism (e.g. an explicit manifest of field names, or a comptime
tuple of `(name, type)` pairs consumed via `@Type`/`std.meta.Tuple`), and the
plan must state it.

Same problem in `defaults()` (PLAN.md:153-160): a struct literal containing
`inline for` fails with `error: expected field initializer`.

### B2. The `Module` interface does not compile
```zig
parse: fn (alloc: Allocator, node: toml.Node) !Config,
```
Verified: `error: function type cannot have an inferred error set` — `!Config`
in a function-*type* position is an inferred error set, which is illegal for
stored function pointers. It must be a named error set or `anyerror`.

### B3. `toml.Node` / `doc.get()` do not exist
hana does not parse TOML and has no `toml` module (checked `src/` and Zig's
`lib/std` — 0.16 ships no `std.toml` either). The config reader is a
hand-written dialect: `src/config/parse/parser.zig` + `document.zig`, whose
model is `Document` / `Section` / `Value` (`parser.zig:35-37`), and it
**rejects** dotted keys, inline tables and floats by design. Every occurrence of
`toml.Node` and `doc.get(mod.name)` (PLAN.md:86, 145, 208) must be restated in
terms of the real document model.

### B4. Discovery by `src/*/config.zig` collides with the global stem namespace
AGENTS.md rule 4 and `build.zig`'s `registerModule` (build.zig:2130-2157)
enforce one `.zig` basename per tree: a second file with the same stem aborts the
configure step with `error.ModuleNameCollision` (a "Rename the file" hard error).

- `src/config/config.zig` already exists, so the stem `config` is **taken today**.
- The plan's discovery pattern (PLAN.md:113) would register `src/config/config.zig`
  as its own "module config".
- The Phase 1 destinations `src/window/modules/{workspaces,fullscreen,floating,minimize}/config.zig`
  are four *more* files with stem `config` — the build dies at discovery before
  any config code is written.

Either the discovery pattern, the file naming, or rule 4 itself must change; the
plan currently does all three inconsistently (see M1).

### B5. The discovery snippet is wrong for Zig 0.16 and for this build
PLAN.md:104-121 fails on multiple independent counts (verified against
`0.16.0/lib/std`):

| Line | Problem |
|------|---------|
| `std.ArrayList(T).init(b.allocator)` | `std.ArrayList` is unmanaged in 0.16; `.init` lives only on the deprecated `array_list.Managed` |
| `std.fs.Dir.openDir("src", .{})` | `openDir` is an instance method and takes an `Io` first (see `build.zig:2061`) |
| `std.fs.pathExists(path)` | does not exist in 0.16 std (`cwd().access` is the primitive) |
| `"src/" ++ entry.name ++ ...` | `++` needs comptime-known operands; `entry.name` is runtime — use `std.fmt.allocPrint`/`std.fs.path.join` |
| cwd-relative `"src"` | the build script reads via `b.build_root.handle`, not the process cwd |

The existing `Module.DiscoveryContext.discoverAll` (build.zig:2057) already does
this walk correctly; a second, weaker walk is what the plan proposes.

### B6. Deleting a module breaks unconditional `config.<module>.*` reads
The zero-trace goal ("Delete `src/tiling/` → `zig build check` passes") cannot
hold with the plan as written. With the composed struct field only present when
the module exists, every unconditional consumer stops compiling. Current
examples (none gated by `has_tiling`/`has_workspaces`):

- `src/core/loop/pipeline.zig:74,120,123,124,171` — `config.tiling.*`
- `src/core/core.zig:139` (`borderWidth()`, unconditional), `src/core/process/session.zig:427`
- `src/window/protocol/borders.zig:53`, `src/window/sync/reconcile_tails.zig:122`,
  `src/window/modules/floating.zig:281` — `config.tiling.min_window_dim` etc.
- `src/window/state/query.zig:110`, `src/window/admission.zig:153,332` — `config.workspaces.*`

(~22 references outside `src/config/`, `src/tiling/`, `src/bar/`, tests.) The
plan has no step for auditing/gating config-field access; Phase 4 only covers the
four boolean flags. `has_bar` gating exists for bar reads, but nothing equivalent
exists for tiling/workspaces in core/window. Without this step, checklist items
287-289 are unreachable.

---

## Major design gaps

### M1. Module-config placement contradicts itself (and the layer guards)
Two mutually exclusive destinations are specified:

- Target tree (PLAN.md:35-41): `src/config/modules/{tiling,workspaces,bar,...}.zig`
- Phase 1 table (PLAN.md:171-176): `src/tiling/tiling_config.zig`,
  `src/bar/bar_config.zig`, `src/window/modules/*/config.zig`

They have opposite failure modes:

- **Under `src/config/modules/`**: deleting `src/tiling/` leaves
  `config/modules/tiling.zig` → the zero-trace goal fails immediately, and
  discovery would have to be told to look there (it doesn't).
- **Under the subsystem dirs**: layer guards reject it. `pureLayerAllows`
  (build.zig:2341-2366) lets a `config`-layer file import only `src/config/*`,
  `keymap`, `model`, `domain` and the shelf; a `tiling`-layer file only
  `src/tiling/*`, `tiling_contract`, `model`, `domain`, shelf. A fragment's
  `parse` needs `config/parse/schema.zig` helpers (`place`/`knob`/`Kind`) →
  tiling→config edge → build failure; the composed parser importing
  `tiling_config` → config→tiling edge → build failure. The plan adds exactly
  one carve-out (Phase 2 step 4, for the registry file) and does not mention
  `check-layers.sh`, which enforces the same policy with grep rules.

The plan must pick a placement and spell out the guard changes for it.

### M2. `schema.zig` is an engine, not a list of knobs
Phase 3 reduces 974 lines to a "thin dispatcher". What the dispatcher actually
has to keep, and where each part goes, is unspecified:

- **Knob table + reflection** (`applyAll`, defaults, validation, schema.zig:878)
- **Coverage pass over unknown keys** (`coverage_subtrees`, schema.zig:334-340 —
  itself a hard-coded per-module list that must also become generated)
- **Section aliasing/gating**: flat `[tiling]` vs
  `[tiling.layouts.master-stack]` spellings (schema.zig:53-55, 113-130),
  `knobGated` section-presence gates, cross-module keys
  (`workspaces.count` accepted in both `[workspaces]` and
  `[bar.modules.workspaces]`, schema.zig:110-111)
- **`[bar.properties]` decoder** and the `sections/` files
  (`bar_sections.zig`, `tiling_sections.zig`) plus `parse/bar_properties.zig`
  and `vocab/layout_names.zig` — all feature-specific code inside config that
  the migration table never moves, so "zero trace" fails even after Phase 1

The plan says only "Remove hard-coded knobs" (Phase 3 step 2). It needs a
per-mechanism destination table.

### M3. No `deinit` in the module interface
Every real config fragment owns allocations: `TilingConfig.deinit`
(types.zig:265), `WorkspaceConfig.deinit` (types.zig:659), `BarConfig`'s
`freeOwnedStrings` reflection (types.zig:401-409), and `Config.deinit`'s manual
per-subconfig list (types.zig:687-701) — the exact "manual cleanup" the plan's
problem table complains about. The proposed `Module` exports
`parse`/`defaults`/`validate` only; the composed struct therefore cannot be
freed, and `defaults()` handing out owned `std.StringHashMap`s has no lifetime
story. `deinit` (and a decision on who calls `validate` — the drafted dispatcher
never does) must be part of the interface.

### M4. `?Config = null` vs `defaults()` is unresolved
`parseConfig` assigns a module field only when the section is present and never
merges `mod.defaults()`; `defaults()` fills every field. The plan needs one
coherent answer: are absent sections `null` (then every consumer needs null
handling — see B6) or defaulted (then `?` is pointless)? Also in that snippet:
missing `try` on `mod.parse(...)`, and `allocator` vs the `alloc` parameter name.
`var cfg = Config{}` additionally requires every field (incl. `core`) to have a
default initializer, which the sketch doesn't give `core`.

### M5. Core config is not handled by the dispatcher at all
The drafted `parseConfig` only walks `ConfigModules`. Nothing parses the core
fields the current pipeline fills: keybindings/mouse bindings
(`sections/binds.zig`), `snap_distance`, `dpi`, palette/scheme keys. Phase 3
must say where core parsing lives relative to the module loop.

### M6. "Generated" vs `git mv` / `zig fmt --check .`
- Cross-cutting requires `git mv` for every rename, but Execution Order step 5
  "Rename `types.zig` → `composed.zig` (generated)" is contradictory: a
  generated file is not a tracked rename.
- The generated file's location is never stated. In `src/`, it must survive
  `zig fmt --check .` (CI runs it on a clean checkout where the file may not
  exist yet), be classified as the `config` layer by the `src/config/` prefix
  rule (build.zig:2310), and be excluded from the stem walk or it collides too.
  In the cache, it must be wired as a module instead of imported by path. None
  of this is planned.

### M7. Blast radius on imports of `types` beyond config
Moving `BarConfig`/`TilingConfig`/`WorkspaceConfig`/`Config` out of
`config/types.zig` touches: `dev/plugin-template/control.zig:30,100`
(`types.BarConfig` — gated by `zig build check-plugin-template`, part of
`zig build check`) and ~13 test files under `src/test/**` that
`@import("types")`. Phase 1 marks itself "No Behavior Change" and the checklist
mentions plugin-template only under Phase 5 (contracts), not for the config
move. Add an explicit lockstep list for Phase 1.

### M8. Zero-trace ignores the user-facing config surface
`config/fallback.toml` (embedded at build time, build.zig:81) ships `[tiling]`,
`[workspaces]`, `[bar]` sections, and `config/README.md` documents them. A
tiling-less build still parses/validates the fallback file (coverage pass on
unknown sections is a designed error path). Plan never mentions fallback.toml,
its embedding, or the README.

### M9. Hot reload / snapshot path not revisited
`config/reload.zig`, `persist/snapshot.zig` and `config/model_config.zig`
(`applyConfigReload`) all work against `types.Config` today. Replacing the type
with a generated one changes their seams; the plan lists `model_seeding.zig`
(see S4) but no step for snapshot/reload compatibility.

---

## Stale or factually wrong content

### S1. Phase 5 (contract split) is already done
`src/core/architecture/{tiling_contract,contract_dispatch,domain}.zig`,
`src/window/window_contract.zig` and `src/bar/bar_contract.zig` all exist, and
AGENTS.md rule 6 already documents the post-split world. The phase (and the
"Update plugin templates, tests, AGENTS.md" step) should be dropped, not
executed.

### S2. Phase 6 (operation migration) is already done
Every operation in the "destination" table is already at its destination:
`setFocus`/`clearFocus`/`fallbackFocusCandidate`/`collectCyclePool`/
`focusedBorderColor` → `src/window/protocol/focus.zig:1010-1096`;
`reorderTiled`/`stepTiled`/`swapPrimary`/`swapFocusedWithPrevious`/
`adjustPrimaryWidth` → `src/tiling/tiling.zig:539-592`;
`register`/`unregister` → `src/window/state/window_state_ops.zig:14`;
`applyConfigReload` → `src/config/model_config.zig:106`;
`capPrimaryCount` → `src/core/architecture/domain.zig:314`.
`src/core/model.zig` (264 lines) contains exactly the "pure queries stay" list.
No work remains.

### S3. Phase 4 and the second "Phase 6" flag tables are stale (and duplicated)
`config.tiling.enabled`, `fullscreen_enabled`, `drag_enabled`,
`workspaces.enabled` do not exist anywhere in `src/` (checked `types.zig`,
`schema.zig`, call sites). `core.tilingEnabled()` already returns
`build_options.has_tiling` (src/core/core.zig:131-133). The tables are
duplicated verbatim (PLAN.md:224-233 vs 259-269), so the plan lists the same
nonexistent work twice. Meanwhile the flags that *do* exist —
`BarConfig.enabled` (types.zig:407, `barBool("enabled")` schema.zig:137) and
`carousel_enabled` (types.zig:475, schema.zig:139) — are not mentioned at all.

### S4. Phase 1 migration sources don't exist
- `config/types.zig:FullscreenConfig` — no such type; `[fullscreen]` is only an
  accepted-empty section name (`section_fullscreen`, types.zig:80; config.zig:276).
- `config/types.zig:DragConfig` — no such type; drag is the root field
  `snap_distance` with one knob (schema.zig:105).
- `WorkspacesConfig` — actual name is `WorkspaceConfig` (types.zig:655).
- `Minimize "(new)"` — invents config for a module that has no knobs.
- The interface example's `variants: std.StringHashMap` field is not in
  `TilingConfig` either.

### S5. "Current State Problems" table is partly wrong
- "`tiling: ?TilingConfig`" — it is `tiling: TilingConfig = .{}` (types.zig:670),
  non-optional with defaults.
- "Runtime flags duplicate comptime `has_*`" — those flags are gone (S3).

### S6. Notes reference a pre-rename tree
- "`config/` gains `model_seeding.zig`" — already renamed to
  `model_config.zig` (staged `git mv` in the working tree).
- "`core/architecture/` loses `seed.zig` and `contract.zig`" — both already gone.
- "Docs with `wm_state`: `AGENTS.md:65,77`" — `wm_state` appears nowhere in
  AGENTS.md; the model rename already happened.
- The Target-Architecture tree lists `core.zig`, `composed.zig`, `modules/`
  (none exist) and omits the existing `config.zig`, `action.zig`,
  `model_config.zig`, `types.zig`; `reload.zig` is listed twice (lines 26-27).

---

## Editorial / structural problems

- **Phase numbering**: three different sections are numbered "Phase 6"
  (Operation Migration, Flag Removal, Cleanup). Phase 3 has two items numbered "2."
- **Execution Order table** (PLAN.md:317-330): step 8 missing; step 10 appears
  twice; steps 7 and 9 execute work that is already done (S1, S2); step 6 "Remove
  runtime feature flags (9)" — the "(9)" is unexplained and no nine flags exist.
- **The "Notes" block is duplicated verbatim** (PLAN.md:305-313 vs 334-342).
- **Verification checklist** lists `zig build check-plugin-template` twice
  (lines 286 and 290).
- **Flag-removal table duplicated** inside Phases 4 and 6 (S3).
- **Phase 5 title** "Contract Split (Contract Split)".
- **Interface vs registry naming**: the interface says each module exports a
  `Module` struct holding `parse`/`defaults`/`validate`, but the registry
  references bare `tiling.parse` / `tiling.defaults` (PLAN.md:128-130).
  Pick one export shape.
- **`zig build check-modularity -j 4`**: the build step exists, so the flag is
  fine, but AGENTS.md documents the script form
  (`dev/scripts/check-modularity.sh -j 4`); keep one spelling.

---

## What a revised plan needs before execution

1. A composable-struct mechanism that actually compiles on 0.16 (B1) — this is
   the core of the design and should be prototyped first, in a scratch file.
2. A naming scheme for module config files that survives the global stem
   namespace (B4), applied consistently in discovery, the tree, and the
   migration table.
3. One placement decision for fragments + the exact `build.zig`
   (`pureLayerAllows`/`assertPureLayerImports`) and `check-layers.sh` changes it
   requires (M1).
4. A call-site gating audit for `config.<module>.*` reads, or a decision that
   composed fields are always present with defaults (B6, M4).
5. A mechanism map for `schema.zig`'s engine parts: coverage pass, aliasing,
   gating, `sections/`, `bar_properties`, `vocab` (M2).
6. Delete Phases 4–6 as written; re-scope flag work to `bar.enabled` /
   `carousel_enabled` if runtime flags are still in scope (S1–S3).
