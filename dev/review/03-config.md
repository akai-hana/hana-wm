# Config subsystem review (`src/config/**`)

Verdict scale: **★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

---

### `config/config.zig` (429 lines) — load orchestration  **★ (split DONE)**
**Now:**
```
// orchestration only; everything below is re-exported from its module:
readFileAlloc / max_file_bytes / max_config_files        (discover.zig)
loadConfigFromDir(alloc, dir) -> Config                  (thin: discoverDirNames -> parseAndBuild)
loadConfigDefault(alloc, source, allow_pinned_snapshot) -> Config
DefaultSource / GoodSource / deinitGoodSource /
  refreshSnapshot / reexecSnapshotPathZ                  (snapshot.zig)
validate(cfg) -> !void                                   (validate.zig)
canonicalLayoutName / isLayoutName / layout_name_grammar (layout_names.zig)
detectChanges(old, new) -> ConfigChanges                 (diff.zig)
loadConfig(alloc, path) -> Config
load(alloc) -> Config           // entry: XDG paths -> load
checkConfig(alloc, collector)   // --check-config: count diagnostics
```
**Verdict:** ★ — the five concerns are now five files; what remains is pure orchestration (load paths, the parse-and-build pipeline, section-family warnings, `--check-config`).
**Module map (all re-exported through `config.zig`, so importers are untouched):**
```
config/discover.zig    (396) — file discovery, include joining, dir walk, read ceilings
config/snapshot.zig    (342) — last-good snapshot save/load/pin/reexec path
config/sections.zig    (550) — non-scalar structures schema.applyAll doesn't cover:
                               tiling layouts/variants/counts, bar fonts/icons/columns, rules
config/binds.zig       (519) — keybind/action grammar: mod maps, action table, {kill}/{N}
                               placeholders, key globs, parallel/sequence parsing
config/diff.zig        (174) — detectChanges (pure struct compare)
config/layout_names.zig( 65) — canonicalLayoutName / isLayoutName / grammar
config/validate.zig    ( 70) — semantic validation (pure)
config/config.zig      (429) — load()/loadConfig() orchestration only
```
**Path:** DONE — extracted in waves (validate/layout_names/diff, then snapshot, then discover, then binds+sections), each wave gated on `zig build` + `config_test`/`parser_test`/`schema_test`/`tiling_test`; full suite, `check-layers.sh` and all 31 `check-modularity.sh` scenarios pass.

### `config/parser.zig` (1345 lines) — TOML-subset parser  **◐**
**Now:**
```
Value = scalar | string | color-expr | array | table
Section = ordered key/value list + consumed-flags
  init/get/getAs/getAsOrWarn/markConsumed/warnUnconsumed
  lineOfKey, orderedIterator
Document = named Sections; getSection
parseColor / colorFromValue / resolveColorExpr (palette-aware)
isWeightToken/weightFromToken
collectPalette(doc)              // [palette] table -> map
mergeDocumentsInto(...)          // include joining
parse(alloc, content, source_path) -> Document
```
**Verdict:** ◐ — a hand-written TOML subset is the right call (no dep, exact warning control); ordered sections + consumed-flags give the "warn on unknown key" behavior that a generic TOML lib cannot. Nits: `parseColor` (800+ lines into the file) is a self-contained concern that could be `config/color_parse.zig`; the parser and the color grammar are currently interleaved.
**Ideal:**
```
config/parser.zig   — section/table/value grammar only
config/color_parse.zig — hex/rgb/named/color-expr parsing + palette resolution
```
**Path:** (1) move the color grammar (parseColor, colorFromValue, resolveColorExpr, weight tokens) into `config/color_parse.zig` verbatim; (2) keep `collectPalette` in parser (it walks the Document). Tests: `parser_test.zig` covers both halves.

### `config/schema.zig` (978 lines) — comptime schema  **◐**
**Now:**
```
value(cfg, "path.to.key") -> typed value      // comptime path resolution
assignStr(alloc, *?[]u8, val)
applyAll(doc, alloc, cfg) -> !void:
    walk schema; for each key: get from doc, convert, assign;
    unknown keys -> warn (keep-last-good semantics live here)
```
**Verdict:** ◐ — the comptime-path accessor is elegant and type-safe; the file is one giant `applyAll` walk with per-key cases, which is inherently long but flat (each case is independent and greppable). Acceptable as-is; the only structural improvement is grouping cases by section with banners.
**Ideal:** same, with per-section grouping; optionally codegen the walk from a comptime field-spec table (higher effort, no user-visible gain).
**Path:** optional: insert section banners + reorder cases to mirror `types.zig` field order. No behavior change.

### `config/types.zig` (~850 lines) — config data model  **★**
**Now:**
```
Action = union(enum) { keybind actions, mouse binds, ... }
  deinit(alloc); needsTilingFocusScaffold(tag)
SegmentProps { font, colors, weight... }  isDefault()
TilingConfig { layouts, variants, master counts, per-ws overrides }
  masterCountLookup(), workspaceLayoutLookup(), deinit()
BarConfig { layout segments, props per segment, ... }  deinit()
WorkspaceConfig  deinit()
Config { ...everything... }  deinit()
enumFromString(T, str) -> ?T
freeStringMap / freeSegmentMap
```
**Verdict:** ★ — plain data with explicit ownership (every map has a `deinit`); `needsTilingFocusScaffold` is the comptime capability query the focus layer uses.
**Ideal:** unchanged. **Path:** none.

### `config/fallback.zig` (~70 lines)
**Now:** `detectTerminal()` (probe $TERM/$PATH for a terminal); `getFallbackToml()` (embedded default config, used when no user config exists).
**Verdict:** ★ — embedded fallback keeps first-boot zero-touch; terminal detection reuses the shared `$PATH` walker.
**Ideal:** unchanged. **Path:** none.

---

## Config subsystem summary

- 12 files: 3 ★ (types, fallback, config.zig orchestrator post-split), 2 ◐ (parser — color-grammar extraction; schema — cosmetic grouping), 7 extracted modules (discover, snapshot, sections, binds, diff, layout_names, validate) — all behavior-identical, re-exported through `config.zig`.
- Semantics are already ideal for the README contract: file joining, includes, ScalableValue, warn-and-keep-last-good, `--check-config` CI gating.
- The `config.zig` split (2411 -> 429 lines across 8 files) is DONE and fully verified; the remaining nit is the `parser.zig` color-grammar extraction (Phase 5).
