# Contract rename & pluggability audit (2026-09-23)

- **Scope**: the rename of `src/core/plugin.zig` → `src/core/contract.zig`
  plus the pluggability decisions that landed with it (bar multi-binder roles,
  unified dispatch in `contract.zig`, blob-ordinal adoption, and the build-rig
  single-pass classification). This audit supersedes the stale historical
  docs (`dev/plugin-audit.md`, `dev/simplification-audit.md`,
  `dev/SIMPLIFICATION_PLAN*.md`) that still reference the pre-rename
  `plugin.zig` name; those pages were written as-of their pinned audit and are
  preserved as snapshots.
- **Method**: full reads of `src/core/contract.zig`, `src/bar/bar.zig`,
  `src/bar/segment.zig`, `src/bar/layout.zig`, `src/bar/variants.zig`,
  `src/window/window.zig`, `src/core/persist.zig`, `src/core/events.zig`,
  `build.zig`, `dev/plugin-template/*`, plus repo-wide `rg` sweeps for the old
  name. Every change below was re-verified running the full gate suite.
- **Gate suite (all green at end of this work)**: `zig fmt --check .`,
  `zig build check` (exit 0; check-layers all layer rules pass),
  `zig build test` (exit 0), `bash dev/scripts/check-modularity.sh`
  (31 passed / 0 failed), `bash dev/scripts/xtest.sh zig build test` (exit 0).

## 1. Rename: `plugin.zig` → `contract.zig`

| Item | Change |
|---|---|
| File | `git mv src/core/plugin.zig src/core/contract.zig`; module name in `build.zig` updated; all `@import("plugin")`/`plugin.` sites re-pointed to `contract` |
| Generated register module | `plugins` → `surfaces` (`build.zig:384` reserved list; `generateModules` output name; injected as `surfaces` into every module; `Surfaces` type still consumed as `@import("surfaces").Surfaces`) |
| Line references in docs | README/IMPROVEMENTS/SIMPLIFICATION_PLAN* `plugin.zig` refs updated; `dev/plugin-template` directory and `check-plugin-template` step name kept (public step names + paths unchanged by design) |
| Docs header | `contract.zig` header rewritten "plugins → surfaces"; `single_binder_hooks` doc now describes the generic dispatch helpers (`providerOf`/`callFirst`/`callFirstBool`/`callFirstTrue`/`callAll`) |

Rationale recorded for posterity: "plugin" named the seam after the removed
`plugins/` sweep; every remaining thing here is a *contract* the modules bind
against, and call sites already read `@import("contract")`. The generated
register module keeps a separate name (`surfaces`) because it is a build artifact.

## 2. Bar multi-binder roles (`center_slot` / `self_ticking`)

The `center_slot` and `self_ticking` capabilities are **multi-binder by
design** — no at-most-one comptime assert is emitted for them (unlike
`Segment.name` uniqueness, §5). The single-binder list (`single_binder_hooks`)
covers only window-module hooks that pair with a specific counterpart.

Landing changes (all in `src/bar/bar.zig`):
- `State.init`: clock width = `max` over the `measureString` result of every
  self-ticking segment (was: single slot).
- `recordSelfTickerScope` State method records a scope per self-ticker; the
  empty-registry guard `if (self_ticking_ids.len == 0) return;` fixes the
  modularity matrix `[0]`-array indexing (segments removed → zero-length
  registry still iterates safely).
- `drawRightSegments` / `drawAllInner` record self-ticker scopes;
  `drawClockOnly` loops the valid `clock.segs[i]` slice.
- `drawAllInner` center branch: `center_count`/`center_idx`/`centerShare`
  equal split of the remaining space; `remaining -= |w` dropped for removed
  binders.
- `updateClock`: `naturalWidth` is fanned out per ticker and the merged max
  width triggers the full redraw.
- `toggleBarSegmentAnchor`: instead of `s.clock.x = null`, invalidates every
  `clock.segs[*].valid` flag (multi-anchor state).
- `segment.zig::findAllByCapability` returns `[]const usize` — all indexes of
  modules carrying a capability, via the comptime array-concat idiom. Note:
  `comptime fn` with a `comptime []const u8` param does **not** parse on
  Zig 0.16 ("expected ',' after field") — the working form uses
  `var result: []const usize = &.{}; result = result ++ [_]usize{idx};`.
- `layout.zig` / `variants.zig` call `contract.activeLayoutKind(...)`;
  `segment.zig` no longer re-imports `pipeline`.

Dispatch in `bar.zig`: `runVoidHook`/`anyBoolHook` now take
`std.meta.FieldEnum(contract.Segment)` and call sites pass the enum literal
(`.onPollWakeup`, `.handleKeypress`, `.invalidate`,
`.invalidateReloadCaches`, `.onBarShown`, `.consumeRedrawRequest`).

## 3. Unified dispatch in `contract.zig`

`window.zig`'s five one-off forwarders and `bar.zig`'s hook loops collapsed
onto one generic family declared once in `contract.zig`:

- `providerOf(T, registry, field)` — first module with a non-null binding
  (takes the element type explicitly so the array element contract is not
  implied; call sites pass `contract.WindowModule` and `window_mods[0..]`).
- `callFirst`, `callFirstBool`, `callFirstTrue`, `callAll` — thin first-match /
  all-match dispatch with the registry typed `[]const contract.X`.
- `window.zig`'s five wrappers are now one-line forwards over
  `window_mods[0..]`; the `binders`/`binder_count` machinery is gone.

Semantics preserved: single-binder hooks still first-match in registry scan
order (alphabetical — deterministic), and the per-owner registries remain
derived from disk so deleting a module just shortens an array.

## 4. Blob-ordinal adoption (persist)

`src/core/persist.zig` wraps every saved window blob with a stamped header so
a restored record's contract can be selected without scanning the whole blob:

- `persist_version` bumped 4 → 5; `pub const ext_format_version: u8 = 1`;
  `pub const ext_header_len: usize = 2` (version byte + ordinal byte).
- `saveSnapshot` writes `[version][ordinal]++body`, freeing the module body
  slice after the copy.
- `window.zig::applyRestoredRecord` fast-paths off `stored[1]` (ordinal), with
  a magic-byte fallback scan for pre-5 files; both paths pass the stripped
  payload to the contract hook.
- The contract seam is header-agnostic: module hooks
  (`serializeWindow`/`deserializeWindow`) see only the payload, so the
  `model_test.zig` minimize round-trip (which calls hooks directly) is
  uncoupled and unchanged.

## 5. Build rig single-pass classification

The registry generator now classifies every discovered source file **once**
(primary read) and reuses the result for both the owner-module walk
reservation and the contract derivation:

- `Module.FileClass = struct { pub_module: bool, contract: ?[]const u8 }`.
- `DiscoveryContext.classified: std.StringHashMap(FileClass)` + `ensureClassified`
  (idempotent; dupes the key) memoize it.
- `classifyFile(b, rel_path)` replaces `deriveOwnerContract`: same three
  recognized spellings (`pub const module: @import("contract").<Contract> = ...`,
  `pub const module = segdraw.module(...)` → Segment,
  `pub const module = tiling.layoutModule(...)` → Layout). An unrecognized
  `pub const module` spelling (bare alias / foreign shim) is a loud
  `error.UnrecognizedModuleSpelling`.
- `deriveOwnerContracts` and `OwnerRegistry.run` now read
  `discovery.classified` (no `deriveOwnerContract` re-read; `declaresBinding`
  remains only for `<package>_subs` sub-binding scans).
- The two registry sanity blocks were merged into ONE contract-derived
  comptime block keyed on the element contract, killing the
  `"window_modules"`/`"bar_modules"` magic-string gates:
  - name-uniqueness assert: gated on `@hasField(T, "name")` where
    `T = @typeInfo(@TypeOf(modules)).array.child` (std-free — generated
    modules import no std).
  - single-binder at-most-one: gated on `@hasDecl(contract,
    "single_binder_hooks")`, iterating `contract.single_binder_hooks` with an
    inner `@hasField(T, hook)` skip so Segment/Layout registries (which don't
    carry those hooks) pass.
- `has_tiling`/`has_bar_orchestrator` now read `registry.owners` / the
  discovery module list (predicate drift from the old
  `generateBarOrchestrator` scraper).

## 6. Naming conventions kept stable (public surface)

- `check-plugin-template`, `dev/plugin-template/`, `PluginTemplateSpec` —
  unchanged (the *window-layout template spec* name, not a code seam).
- Generated register owners `window_modules` / `tiling_modules` / `bar_modules`
  / `surfaces` — unchanged.
- `src/` self-imports all read `@import("contract")` today; `rg` for the old
  `plugin` identifier (outside comments) returns nothing.

## 7. Loose ends recorded (not in scope / deferred)

- vim swap files `src/core/.events.zig.swp`, `src/core/.pipeline.zig.swp`;
  `atlauncher.log` under `src/core/logs/`; stray `(B2)` marker at
  `src/bar/prompt.zig:1223`.
- `dev/plugin-audit.md` and `dev/simplification-audit.md` still cite
  pre-rename `plugin.zig` line numbers (historical snapshots — see Scope).
- `-Doptimize` is not accepted by this build rig (modes hardcoded); the
  default mode is the gate.