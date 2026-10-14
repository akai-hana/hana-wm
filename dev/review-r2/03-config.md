# config review (round 2)

Re-verify of `src/config/**` against the CURRENT tree, judged fresh (not
inherited from `dev/review/03-config.md`). Since round 1, `config.zig`
was split into 8 files (validate/snapshot/layout_names/diff/discover/
sections/binds + a 429-line orchestrator) and `schema.zig` was rewritten
from a hand-written `applyAll` per-key walk into a **comptime knob table**
(`knobs` array + `Kind` union + compile-time coverage/ordering asserts) —
a materially better shape than round 1 described. Verdict scale:
**★ ideal** · **◐ near-ideal** · **△ restructure** · **▽ redesign**.

**Now** = high-level pseudo-code · **Verdict** · **Ideal** = from-scratch
shape · **Path** = ordered, behavior-preserving steps.

Layer policy (enforced by `dev/scripts/check-layers.sh` Rule 3): `config/`
is xcb-free and owns no X knowledge; single-responsibility files; the pure
config layer sits below bar/tiling/input. Verified honored throughout
(no `xcb` token in any config body; `types` imports only `std/constants/
ids/model/scaling`, all pure).

---

### `config/config.zig` (429) — load orchestration  **★**
**Now:**
```
re-exports: validate / canonicalLayoutName / isLayoutName / layout_name_grammar /
  detectChanges / ConfigChanges / DefaultSource / deinitGoodSource /
  reexecSnapshotPathZ / refreshSnapshot / readFileAlloc / max_file_bytes /
  max_config_files        (the single import surface for callers)
loadConfigFromDir(dir) -> Config            // discoverDirNames -> parseAndBuild(parseDirDoc)
loadConfigDefault(source*, allow_pinned) -> Config
    // HANA_CONFIG_DIR pinned-snapshot branch (re-exec hand-off) ->
    // inline for search_order: SearchAttempt{path,load,is_dir} per tag ->
    //   tryLoadOrWarn(...) -> rememberGoodSource -> .user
    //   else -> loadFallbackConfig -> .fallback
loadConfig(path) -> Config                  // parseAndBuild(parseFileDoc); ConfigEmpty -> fallback
parseAndBuild(alloc, comptime parse, in) -> Config
    // one load-scoped arena hosts the Document; buildConfigFromDoc dupes
    // owned strings off the backing allocator; publishReadFiles republishes
    // the consumed set for the re-exec snapshot
getDefaultConfig(alloc) -> Config           // seed from types.Config field initializers
buildConfigFromDoc(alloc, doc) -> Config
    // had_errors -> ConfigParseFailed; warnMisCasedSections;
    // getDefaultConfig; parseKeybindings; parseTilingStructures;
    // schema.applyAll; warnInertSectionFamilies; parseBar; parseRules;
    // root + every section warnUnconsumed
checkConfig(alloc, collector)               // --check-config: install log.Collector,
    // loadFor(snapshot=false), deinit; restore collector on every exit path
load(alloc) / loadFor(alloc, snapshot: bool)
    // loadConfigDefault(true) -> fatal-error fallback to embedded;
    // validate() failure ALSO falls back (degrades like a parse error);
    // snapshot=true -> refreshSnapshot (last-good freeze)
```
**Verdict:** ★ — pure orchestration; every concern lives in its own module
and `config.zig` only sequences them. The `parseAndBuild(alloc, comptime
parse, in)` generic is the elegant seam: one arena tail serves the
dir/file/fallback pipelines, so the ownership story (arena hosts the
Document; backing allocator owns the Config) is spelled once. The
`search_order`-driven `SearchAttempt` switch makes the search order a
single comptime list a new location cannot drift from. The `loadFor(snapshot)`
split cleanly separates the read-only `--check-config` path from the
state-writing boot path while running the identical load decision.
**Ideal:** unchanged. **Path:** none.

### `config/parser.zig` (1345) — TOML-subset reader + color grammar  **◐**
**Now:**
```
Value = integer|boolean|string|array{list,accumulated}|color|scalable
  lastScalar()   // descends ACCUMULATED arrays only (later-declaration-wins)
  asScalar(T)    // comptime dispatch; i64/f32/[]const u8/u32/ScalableValue
  asArray()
Section = { pairs, consumed, keys_in_order, lines_in_order,
            duplicated_keys, scalar_dup_warned, name }
  init/get/getAs/getAsOrWarn/markConsumed/warnUnconsumed/orderedIterator/
  lineOfKey/markDuplicated/warnScalarDuplicate   // unknown-key + dup diagnostics
OrderedIterator; Document = { sections, root, palette, had_errors }
// --- color grammar (value-level) ---
colorFromValue(val) -> ?u32            // literal color / 6|8-digit hex int / string
MixOperand{color, weight?}; parseWeightPrefix / weightFromToken / isWeightToken
splitWeightPrefix / resolveMixOperand{,Value} / pushMixOperand
extractMixOperands(val, palette, out) -> ?usize   // unspaced a+b | spaced [a,"+",b] | bare [a,b,c]
scanWeights / mixColors (round-half-up weighted average) / resolveColorExpr
resolvePaletteDecl / collectPalette(doc)    // bounded fixpoint over palette vars
// --- cross-file merge ---
ensureArray / accumulate / insertOrAccumulate / mergeSectionsInto / mergeDocumentsInto
ParseError = { InvalidSyntax, InvalidSection, InvalidValue, InvalidColor, OutOfMemory }
expectedForm(err) -> "accepted form" text   // per-error user-facing hint
hexPrefixLen / parseColor(value) -> !u32    // TOKEN-level (used by the reader)
Parser = { pos, line, line_start, last_key, had_errors*, source_path, array_depth }
  advanceChar / skipInline(full) / skipWhitespace[AndNewlines] / skipToNewline /
  skipBadLine / peek / consume / column / sourceLabel / warnLine
  parseSection / parseKey / parseString / parseArray(depth<=16) /
  parseBareToken / parseBareTokenValue / parseBareValues / parseValue /
  parseKeyValuePair / parsePairs / advanceAfterPair
parse(alloc, content, source_path) -> Document   // line loop: [header] | pair
```
**Verdict:** ◐ — a hand-written recursive-descent reader is the right call
(no dep; exact warning control; ordered sections + consumed-flags give the
"warn on unknown key" behavior a generic TOML lib cannot). Error recovery
(skip-to-newline + `had_errors` + `expectedForm` mapping each `ParseError`
to its accepted forms) is genuinely excellent user-facing design. The
`accumulated`-array distinction (literal array vs duplicate-key accumulation)
is subtle, load-bearing, and well-documented. The one structural issue: the
**value-level color grammar** (`colorFromValue`…`collectPalette`, ~310 lines,
lines 401-758) is a self-contained sub-language — its own operands, weight
budget, operand cap, channel-averaging math — that is consumed externally by
exactly one caller (`schema.zig`) and shares nothing with line/section/pair
parsing. It is contiguous (not interleaved with the reader machine at 889+),
so the file is well-organized, but it is a separable concern.
**Ideal:**
```
config/parser.zig  — the TOML-subset reader only: Value/Section/Document,
    merging, ParseError, the Parser machine, parse(). Keeps the TOKEN-level
    color grammar (parseColor, hexPrefixLen, parseWeightPrefix,
    weightFromToken, isWeightToken) — the reader's own vocabulary
    (parseBareTokenValue calls parseColor/isWeightToken).
config/color.zig   — the value-level color-expression evaluator:
    colorFromValue, MixOperand, splitWeightPrefix, resolveMixOperand{,Value},
    pushMixOperand, extractMixOperands, scanWeights, mixColors,
    resolveColorExpr, resolvePaletteDecl, collectPalette.
    Imports parser (Value, Document, parseWeightPrefix); parser imports
    nothing from color -> one-directional, NO cycle.
```
This **refines round 1's proposed split**, which moved `parseColor` and the
weight tokens into `color_parse.zig` too — that boundary would create a
`parser -> color_parse -> parser` cycle (the reader's `parseBareTokenValue`
calls `parseColor`/`isWeightToken`, and `colorFromValue` takes `parser.Value`).
Keeping the token-level functions in `parser` and moving only the
value-level resolver is the cycle-free seam.
**Path:** (1) move the value-level color grammar (lines 401-758 minus
`parseColor`/`hexPrefixLen`/the three weight-token helpers) verbatim into
`config/color.zig`; (2) `parser.zig` imports nothing new; `color.zig` imports
`std`, `log`, `parser`; (3) `schema.zig` changes `parser.colorFromValue`/
`parser.resolveColorExpr`/`parser.collectPalette` to `color.*` (its
`parser.isWeightToken` call in `isMixAttempt` stays). Tests:
`parser_test.zig` pins both halves; move the color-mix/collectPalette tests
to a `color_test.zig` (or keep them — they call the moved `pub` fns).

### `config/schema.zig` (971) — comptime knob table + applyAll  **◐**
**Now:**
```
Placement{section,key}; knob builders: knob/knobGated/masterStack/barBool/
  barScalable/barPlainColor/barColor/barColorOpt
knobs = [_]Knob{ ~55 entries }   // the declarative schema, one line each
Kind = b|int{T,min,max}|scalable|scalable_free|auto_scalable|color|
       color_from{sibling}|color_opt{sibling}|ratio|str|opt_float{min,max}|enum_read
Knob = { places, target, kind, requires, copy_when_absent, needs[] }
// comptime (all @compileError, all verified at build):
//   resolveTarget(k.target) != null        -- every target names a real field
//   dead-field scan                        -- every scalar leaf is a knob or bespoke_fields
//   needs topological order                -- every `needs` is supplied by an EARLIER knob
fieldTypeAt / target_roots / resolveTarget / isScalarLeaf / bespoke_fields
PathType / ptr / value(cfg, path)          // comptime dotted-path accessors
getInRange / getScalableInRange / getRatio / getColorFromValue /
  isMixAttempt / reject / assignStr        // typed readers (warn-and-revert)
applyAll(doc, alloc, cfg)
    // collectPalette; inline for knobs: requires-gate -> first-present
    // placement -> switch(kind) read+convert+assign; then applyBarProperties
applyBarProperties / isBarPropertiesKnobKey
applySegmentEntry + { setStyleFlag, boolFromEqualsToken, firstColorInItems,
  putSegmentEntry, segmentColorMap }   // [bar.properties] composite decode
```
**Verdict:** ◐ — the comptime knob table is the ideal shape for a config
schema: declare knobs as data, interpret generically, and turn "a knob that
parses but assigns nowhere", "a field no code path writes", and "a knob that
reads a sibling declared later" from silent bugs into `@compileError`. This is
a real improvement over round 1's "one giant applyAll walk with per-key
cases". The remaining structural issue: the **[bar.properties] segment-entry
decoder** (`applyBarProperties`…`applySegmentEntry`, ~165 lines) is the one
*bespoke imperative parser* in an otherwise *declarative+generic* file — a
distinct concern (composite per-segment color+style decoding) that only runs
after the knob pass so known keys are distinguishable.
**Ideal:**
```
config/schema.zig        — purely declarative: knobs table, comptime asserts,
    path accessors, typed readers, applyAll (the generic interpreter),
    applyBarProperties (the dispatch loop only).
config/bar_properties.zig — the segment-entry decoder: applySegmentEntry +
    setStyleFlag, boolFromEqualsToken, firstColorInItems, putSegmentEntry,
    segmentColorMap. Imports parser (Value/Section), types, and
    color.getFromValue.
config/color.zig         — gains getColorFromValue (the color decode +
    warn-and-default POLICY) from schema, so bar_properties imports color,
    not schema -> breaks the schema <-> bar_properties cycle.
```
**Path:** (1) extract `color.zig` first (see `parser.zig`); move
`getColorFromValue` into it (it is color policy, used by both the knob pass
and the segment decoder); (2) move `applySegmentEntry` + its five helpers to
`config/bar_properties.zig`; `schema.applyBarProperties` keeps the loop and
calls `bar_properties.applySegmentEntry`; (3) `schema.zig` drops ~165 lines
to ~800 and is then purely declarative+generic. Behavior identical (same
decode order, same warnings).

### `config/types.zig` (856) — config data model  **★**
**Now:**
```
ScalableValue{value, is_percentage}; Color = u32; max_color
SegmentProps{underline,bold,italic} + isDefault
section-name + palette-name + prefix constants (single-sourced vocabulary)
Dir / SwapMode / RestoreOrder (= model.RestoreOrder)
Action = union(enum){ exec, close_window, reload_config, reload_hana, ... sequence, parallel, ... }
  deinit(alloc)                    // exhaustive switch, NO else -> new owned variant = compile error
  needsTilingFocusScaffold(tag)    // comptime capability query, NO else -> same
Keybind{modifiers,keysym,action}; MouseBind{modifiers,button,action}
max_config_name; lowerSlice; enumFromString(T,str)
MasterSide / IndicatorLocation / BarScreenPosition / BarSegmentAnchor  (+ string_map)
WorkspaceLayoutOverride / WorkspaceMasterCountOverride; canon_master_layout
TilingConfig + masterCountLookup() + workspaceLayoutLookup() + deinit()
BarConfig + { runBg/runFg/runPromptColor, segmentFg/segmentValueFg/segmentProps,
    workspaceIndicatorColor/workspaceTextFg/workspaceIconProps,   // fallback-chain resolution
    scaledSegmentPadding/scaledSpacing/scaledIndicatorSize/
    scaledWorkspaceWidth/getAlpha16,                            // pure px derivations
    deinit }
freeStrings / freeStringMap / freeBarLayouts / freeSegmentMap / freeOwnedStrings
Rule; WorkspaceConfig; Config + deinit
```
**Verdict:** ★ — the value/semantics mix the prompt asks about is well-managed.
The data types, the `Action` union (ownership via an exhaustive `deinit`,
capability via a comptime `needsTilingFocusScaffold` consumed as a compile-time
gate by `input`), the enums, and the pure resolution queries are all cohesive
as "the config vocabulary" — one import surface for every consumer. The
read-time fallback methods (`segmentFg`, `workspaceTextFg`, `runBg`, …) encode
the config's own fallback chains, so they belong with the data. The five
pixel derivations (`scaled*`, `getAlpha16`) are pure functions of
(config, height) that the bar calls directly (21 sites); `bar/metrics.zig`
resolves the bar's own (font_size, height) at a coarser granularity and does
not duplicate them, so there is no co-tenancy problem. Ownership is
type-driven (`freeOwnedStrings` walks `?[]const u8` fields via
`std.meta.fields` — no list to drift).
**Ideal:** unchanged. **Path:** none.

### `config/sections.zig` (550) — non-scalar section parsers  **◐**
**Now:**
```
checkWorkspaceBound / tryParseWsToken / addRule      // shared ws-bound helpers
BarAnchorInfo / bar_anchors / initDefaultBarLayout
// tiling structures:
parseTilingStructures (layouts array | single layout; clears defaults)
  parseTilingLayoutSubtables (flat *_variant keys; [tiling.layouts.<name>]
    variants; [tiling.layouts.master-stack.counts] per-ws counts)
  parseLayoutsArray -> parseLayoutTrailing (name -> variants word? -> ws list?)
    -> parseWorkspaceListInto
// bar structures:
parseBar (fonts; indicator_focused/unfocused mirror; icons; columns)
  parseWorkspaceIcons (array | string-per-char) -> padWorkspaceIcons
  parseBarLayout ([bar.layout.<anchor>] segments)
// rules:
parseRules -> parseWorkspaceRuleSection (key = class | ws number; two-direction)
  parseNumberedRuleSections ([workspace.rules.N] / [rules.N])
  tryAddClassRule; countLeadingDigits (digit-run disambiguation)
```
**Verdict:** ◐ — three independent parser families (tiling structures, bar
structures, workspace rules) share one file under the "non-scalar structures
the schema walk doesn't cover" charter. They share `checkWorkspaceBound`/
`tryParseWsToken` and are each flat and greppable, but the **rules family**
(~150 lines: the two-direction `[workspace.rules]`, the leading-digit-run
disambiguation that never coerces a class like "12x" into a workspace
number, the numbered sub-sections) is the most intricate and is semantically
distinct (window-class matching) from structure parsing.
**Ideal:**
```
config/sections.zig  — tiling + bar structures (share the BarAnchorInfo table).
config/rules.zig     — the rules family + the ws-bound helpers it primarily
    consumes (checkWorkspaceBound, tryParseWsToken, addRule).
```
**Path:** (1) move `parseRules`, `parseWorkspaceRuleSection`,
`parseNumberedRuleSections`, `tryAddClassRule`, `addRule`,
`checkWorkspaceBound`, `tryParseWsToken`, `countLeadingDigits` to
`config/rules.zig`; (2) tiling structures keep their copy of
`checkWorkspaceBound`/`tryParseWsToken` (or they move to a tiny shared
`ws_bounds.zig` if duplication is unwanted); (3) `config.zig` imports
`rules.parseRules` alongside `sections.*`. Optional — the current file is
cohesive; split only if rules keep growing.

### `config/binds.zig` (519) — keybind + action grammar  **◐**
**Now:**
```
cached_terminal; resolveAutoTerminal (PATH probe, once per process)
mod_map / mouse_button_map (StaticStringMap)
action_entries + action_map   // comptime: void union tags auto-derived +
    // hand aliases, shadow-checked against tag names
GlobEntry; expandGlobKeys ({a,b,c} / {1-4}; max 256; ws-index tagging)
workspace_action_specs (workspace/move_to_workspace/toggle_tag -> make(ws))
resolveAndParseAction ({kill} substitution first; ws-scoped verb expansion)
actionFromValue (array -> sequence; single -> unwrap)
parallelSepAt (+ is a separator only when whitespace-bounded) / splitParallel
resolveElement (parallel batch) / resolveModPlaceholder
parseKeybindings (Mod/kill placeholders; glob -> mod -> action -> bind string)
parseBindString -> BindResult{keyboard,mouse}; keyNameToKeysym
tryParseWorkspace; action_verb_prefixes; looksLikeActionWord (typo warn)
hasPlaceholderFragment; parseAction (action_map | ws verb | auto_terminal | exec)
```
**Verdict:** ◐ — the comptime `action_map` (auto-derive void tags + hand
aliases + shadow check) is the same elegance as `schema.knobs`: adding an
`Action` variant needs no bind edit, and a shadowing alias is a compile
error. The parallel grammar (`+` separates only when whitespace-bounded, so
`xdotool key ctrl+plus` never splits) and the `{kill}`-before-everything
substitution order are well-reasoned. The one structural issue: three
sub-grammars — the **bind-string** grammar (`parseBindString`,
`keyNameToKeysym`, mod/mouse maps, ~100 lines), the **action-name** grammar
(`action_map`, `parseAction`, workspace verbs, `auto_terminal`, typo
warnings, ~200 lines), and the **glob** expansion (~100 lines) — are
co-located; the action-name half is conceptually separable.
**Ideal:**
```
config/binds.zig   — the [binds] key grammar: parseBindString, keyNameToKeysym,
    mod_map/mouse_button_map, expandGlobKeys, parseKeybindings (orchestrator).
config/actions.zig — the action-name grammar: action_entries/action_map,
    workspace_action_specs, parseAction, tryParseWorkspace,
    action_verb_prefixes/looksLikeActionWord, hasPlaceholderFragment,
    resolveAutoTerminal/cached_terminal.
```
**Path:** (1) move the action-name family to `config/actions.zig`;
(2) `parseKeybindings` calls `actions.actionFromValue`-equivalent (the
`actionFromValue`/`resolveElement` chain bridges the two — it is the one
interleaving point and can stay in `binds.zig` as the orchestrator, calling
`actions.parseAction`); (3) `config.zig` imports both. Optional; the current
file is cohesive and the split has real friction at `parseKeybindings`.

### `config/discover.zig` (396) — bounded file discovery + join  **★**
**Now:**
```
max_file_bytes (1MB); max_config_files (128); max_total_config_bytes (8MB)
ReadSet{paths, bytes}
readFileAlloc(path) -> []u8        // stat-sized or growth-read (procfs/sysfs/pipes
    // report 0); FileTooLarge over the cap; shrinks to exact size on success
parseTomlFile(path) -> ?ParsedToml  // null for empty; bytes = read count (stat-proof)
tryParseTomlFile(path, dst)        // warn-and-skip; sets dst.had_errors on failure
mergeOneFile / parseAndMerge       // THE choke point: both ceilings checked here,
    // fail (not warn) on exceed -- dropping config files is worse than failing
mergeIncludes(dst, src, read, dir) // include = [...]; ONE level deep -> cycle-free
    // by construction; nested include warned-and-skipped
discoverDirNames(dir)             // *.toml, alphabetical, subdirs via include only,
    // excludes embedded fallback.toml
parseDirDoc(a, read, in)
silent_missing / isFatalLoadError / tryLoadOrWarn   // search policy, one list
SearchPaths / searchPaths(alloc)  // XDG + cwd; HOME-unset named, not silent
search_order / SearchLoc / SearchAttempt / LoadFn
```
**Verdict:** ★ — the ceiling machinery is exactly right: per-file, per-count,
and total-bytes caps all enforced at one choke point (`parseAndMerge`), and
exceeding them *fails* the load rather than silently dropping files (the
failure mode the module spends its comments defending against). The
read-with-growth path correctly distrusts a stat that reports 0. Include
joining is one-level-deep, so the graph is cycle-free by construction (no
cycle-detection machinery needed). The search order is a single comptime list.
**Ideal:** unchanged. **Path:** none.

### `config/snapshot.zig` (342) — last-good re-exec snapshot  **★**
**Now:**
```
DefaultSource{user,fallback}
GoodSource{path, is_dir, files[][], stamps?[]FileStamp}   // the consumed set, not the tree
FileStamp{size, mtime}
read_files_arena (page_allocator, fresh per load) / load_read_files
publishReadFiles(items)      // dupes off the load arena into a fresh arena
rememberGoodSource(path, is_dir)   // carry stamps when source+files identical
deinitGoodSource(alloc)            // tests only
snapshotDirPath() -> XDG_RUNTIME_DIR/hana-config | /tmp/hana-config-uid
reexecSnapshotPathZ() -> ?[:0]const u8   // one-shot leaked Z path for setenv
deleteTreeAbsolute / relativeTo(root, path) -> ?rel   // out-of-root includes excluded
snapshotCurrent(io, alloc, snap, files, prev, now) -> bool  // mtime+size AND exact set
refreshSnapshot(alloc)   // staging (.new) -> writeSnapshot -> delete old -> rename
    // (crash-safe swap); no-op fast path when unchanged
writeSnapshot(io, src, snap, staging, files) -> bool
```
**Verdict:** ★ — the crash-safe staging+rename swap (write to `.new`, delete
old, rename) means a half-finished copy never replaces the last-good
snapshot, and the mtime+size + exact-set compare gives a no-op-reload fast
path. Freezing only the *consumed* files (not the whole config dir) is the
right call — the dir holds plenty hana never reads. Process-global state is
inherent to the feature (the set must outlive the load arena) and is
documented. `relativeTo` uses a path-prefix check rather than a
path-component check, but `g.files` are always dir-joined by the loader, so
the false-positive edge (`/a/b` matching `/a/bb/c`) cannot arise.
**Ideal:** unchanged. **Path:** none.

### `config/diff.zig` (174) — reload change detection  **◐**
**Now:**
```
eqlBarLayouts(a[], b[]) -> bool          // logical: position + segments.items
eqlStringMap(V, a, b) -> bool            // count + per-key meta.eql (no bookkeeping)
ConfigChanges{bar, tiling, keys}
BarCmp = direct | meta | string_map(V) | layouts
cmpFor(comptime t) -> BarCmp             // type -> strategy; @compileError fallthrough
barFieldEql(name, old, new)              // comptime cmpFor(@TypeOf(field))
barChanged(old, new)                     // inline for over ALL BarConfig fields
    // -> TOTAL BY CONSTRUCTION (a new field is auto-compared)
tilingChanged(old, new)                  // HAND-WRITTEN field list: TilingConfig +
    // workspaces.* + fullscreen_enabled + drag_enabled + snap_distance
keysChanged(old, new)                    // (modifiers, keysym/button) pairs only;
    // Action deliberately excluded (a changed command needs no regrab)
detectChanges(old, new) -> ConfigChanges
```
**Verdict:** ◐ — `barChanged` is ideal: `cmpFor` derives each field's compare
strategy from its type (with a `@compileError` fallthrough for an unrecognized
type), and the `inline for` over `std.meta.fields` makes coverage total by
construction — the exact fix for the silent-drift hazard the module documents.
But `tilingChanged` is a **hand-written field list with the same drift
hazard**, and the source says so: "barChanged **at least** binds its list to
a comptime coverage check" — the "at least" is the admission that
`tilingChanged` does not. A new tiling-relevant field compiles, parses, and
reloads while silently failing to trigger a tiling rebuild. Secondary:
`cmpFor`'s `.struct -> .meta` fallthrough compares `ArrayList([]const u8)`
(`fonts`, `workspace_icons`) via `std.meta.eql` on the whole list, which is
capacity-sensitive — violating the module's own "never capacity/bookkeeping"
invariant (only `ArrayList(BarLayout)` is special-cased to compare `.items`).
Latent today (same content -> same append sequence -> same capacity) but a
contract violation.
**Ideal:**
```
cmpFor gains a StringHashMapUnmanaged([]const u8) case (tiling.variants) and a
generic list case (ArrayList(T) -> compare .items, upholding the no-bookkeeping
invariant). tilingChanged derives the TilingConfig half via the SAME
inline-for/cmpFor machinery as barChanged (total by construction), keeping the
cross-struct gates (workspaces.enabled/count/rules, fullscreen_enabled,
drag_enabled, snap_distance) as a short explicit tail. keysChanged unchanged
(pair-based is correct for its purpose).
```
**Path:** (1) extend `cmpFor` with the `[]const u8` string-map case and a
generic `ArrayList(T)` list strategy (compare `.items`); (2) rewrite the
`TilingConfig` portion of `tilingChanged` as `inline for
(std.meta.fields(TilingConfig))` using `cmpFor`, leaving the cross-struct
gates explicit; (3) behavior identical for all current fields (same
comparisons, same strategies); a new field now fails to compile only if its
type has no `cmpFor` strategy (the existing `@compileError`).

### `config/validate.zig` (70) — semantic validation (pure)  **★**
**Now:**
```
invalid(fmt, args) -> error{InvalidConfig}     // log.err "keeping old"
validate(cfg*) -> !void
    // master_width: percentage -> [min,max] ratio bound; px -> >= 0 only
    //   (the screen width for a ratio isn't available here; runtime clamps)
    //   -> warnOnly
warnOnly(cfg*)   // workspaces.count==0, master_count==0, font_size<=0/0%
    // all log.warn, NEVER fail (a config that boots with a loud warning is
    // recoverable; one that refuses to boot over a cosmetic value is not)
```
**Verdict:** ★ — pure by construction (no IO, no allocation, no document
access), trivially testable, and the fail/warn line is drawn deliberately
and documented. The comment explaining why bar-segment and layout names are
NOT validated here (their registries live above config; importing them
would invert the layer and break the no-bar/no-tiling modularity builds,
so the checks sit with their owners) is exactly the layering argument
`check-layers.sh` exists to enforce.
**Ideal:** unchanged. **Path:** none.

### `config/layout_names.zig` (65) — layout-name grammar + aliases  **★**
**Now:**
```
canonicalLayoutName(name) -> []const u8   // master-stack/master_stack (any case)
    // -> canon "master"; else name unchanged (aliases input, never allocates)
layout_name_grammar (StaticStringMap)     // known spellings, for disambiguation ONLY
    // (unknown names pass through so third-party addon layouts keep working)
max_layout_name (= types.max_config_name)
normalizeLayoutName(buf, name) -> ?[]const u8   // lowercases; null when overlong
isLayoutName(name) -> bool                // grammar test (lowercase + map)
```
**Verdict:** ★ — canonicalization at the config boundary so downstream
resolution (`engine.layoutByName`, exact-on-canonical) needs no alias
handling; the known-spelling set is grammar, not an authoritative registry,
so third-party layouts still resolve. The cross-layer test seam (the tiling
test asserts this list and the registry agree in both directions, since
neither side can import the other) is the right way to catch drift without
inverting the dependency.
**Ideal:** unchanged. **Path:** none.

### `config/fallback.zig` (62) — embedded default + terminal probe  **★**
**Now:**
```
terminals[] (preference order) / fallback_terminal ("xterm")
detectTerminal() -> []const u8   // first on $PATH; else fallback_terminal
isCommandAvailable(cmd)          // $PATH dir walk via paths.dirIterator/exeInDir
getFallbackToml() -> ?[]const u8  // embedded fallback_toml.content; null when
    // empty (the only "missing" signal; the injected module always exists)
```
**Verdict:** ★ — the embedded fallback keeps first-boot zero-touch, and
`getFallbackToml` returning null-on-empty (rather than a missing-module
error) lets `config.zig` degrade to code defaults with a warning instead of
a boot-fatal error. Terminal detection reuses the shared `$PATH` walker.
**Ideal:** unchanged. **Path:** none.

---

## Config subsystem summary (round 2)

12 files: **7 ★** (config, types, discover, snapshot, validate,
layout_names, fallback), **5 ◐** (parser, schema, sections, binds, diff),
**0 △, 0 ▽**. No redesign is warranted anywhere — the round-1 split landed
well and `schema.zig`'s comptime table is a strict improvement over round
1's shape. The five ◐ are all *optional, friction-light extractions or one
hardening gap*, not shape failures.

Two cross-cutting seams:
- **`config/color.zig`** is the dependency for both the `parser.zig` and
  `schema.zig` ideals: the value-level color grammar moves out of `parser`,
  and `getColorFromValue` moves out of `schema` into it, which is what lets
  `schema`'s `bar_properties.zig` extraction break its cycle. Extracting
  `color.zig` first unblocks both.
- **`diff.zig`'s `cmpFor`** extension (string-map + generic-list cases) is
  shared machinery that also upholds the no-bookkeeping invariant for
  `BarConfig.fonts`/`workspace_icons`, not just the `tilingChanged`
  derivation.

| file | verdict | one-line ideal delta |
| --- | --- | --- |
| `config/config.zig` | ★ | unchanged — pure orchestration; the `parseAndBuild` comptime generic is the ownership seam |
| `config/parser.zig` | ◐ | extract the value-level color grammar (~310 lines) into `config/color.zig` (token-level `parseColor`/weight markers stay in `parser` — a cycle-free seam that refines round 1's cycle-creating split) |
| `config/schema.zig` | ◐ | extract the `[bar.properties]` segment decoder (~165 lines) into `config/bar_properties.zig`, moving `getColorFromValue` into `color.zig` to break the cycle — leaving `schema` purely declarative+generic |
| `config/types.zig` | ★ | unchanged — value/semantics mix is well-managed; resolution queries and pure derivations belong with the data |
| `config/sections.zig` | ◐ | optionally extract the workspace-rules family (~150 lines, digit-run disambiguation) into `config/rules.zig` |
| `config/binds.zig` | ◐ | optionally extract the action-name grammar (~200 lines, comptime `action_map`) into `config/actions.zig` |
| `config/discover.zig` | ★ | unchanged — bounded read/merge at one choke point; ceilings fail rather than silently drop files |
| `config/snapshot.zig` | ★ | unchanged — crash-safe staging+rename swap and mtime+set no-op fast path |
| `config/diff.zig` | ◐ | derive `tilingChanged`'s TilingConfig half via the `cmpFor`/`inline-for` machinery `barChanged` already has (the source documents only `barChanged` is total-by-construction); extend `cmpFor` for the variants map + generic `ArrayList` `.items` compare |
| `config/validate.zig` | ★ | unchanged — pure, fail/warn line drawn and documented |
| `config/layout_names.zig` | ★ | unchanged — boundary canonicalization + cross-layer test seam |
| `config/fallback.zig` | ★ | unchanged — embedded fallback, null-on-empty, shared `$PATH` walker |
