# Config subsystem audit — dev/audit-v7

## Scope and method

- **Scope:** `src/config/` — `config.zig` (1923 lines), `parser.zig` (1251), `schema.zig` (792), `types.zig` (761), `fallback.zig` (74). Line numbers are as of commit `46f85d5`.
- **Method:** read-only review; every finding is line-verified against the current source; cross-file / cross-module usage verified with `rg`. No builds or tests were run.
- **Constraint:** the config subsystem is the most test-pinned, user-facing part of hana (TOML parsing, coercion, hot-reload). All proposed changes are semantics-preserving; anything that would alter a warning string, a default, or a parse result is in DEFERRED/QUESTIONS instead of the findings.
- **CFG-v6 status:** the execution status in `dev/SIMPLIFICATION_PLAN_v6.md` was checked against the live source. All config items claimed done are present and applied:
  - CFG-N1 `freeSegmentMap(comptime V)` in `types.zig` — verified.
  - CFG-N2 `Section.reserve` helper (`parser.zig:106-110`) — verified.
  - CFG-N3 `scanWeights` shared by `mixColors`/`resolveColorExpr` (`parser.zig:535`) — verified.
  - CFG-N4 merged `warnScalarDuplicate` (`parser.zig:190`) — verified.
  - CFG-46 bare-hex `colorFromValue` (`parser.zig:328-345`) — verified.
  - CFG-DA / CFG-DB — verified.
  No "claimed fixed, still present" findings.
- **Test pins honored:** `isWeightToken`/`weightFromToken` are public and pinned by `src/test/config/parser_test.zig:234-247`; `readFileAlloc`/`max_file_bytes`/`config.loadConfig`/`schema.knobs`/`schema.value` are pinned by `config_test.zig` and `schema_test.zig`. Nothing below changes their externally visible behavior.
- **Count note:** 12 findings, versus the 15-35 target. The gap is deliberate: the subsystem is clean post-v6, and forcing the target count would push past semantics-preserving territory into speculative rewrites. Two additional candidates are gated on product calls and live in DEFERRED/QUESTIONS — approve them and the count rises to 14.

## Per-file summaries

- **config.zig** — Dense interpreter/loader/reexec/hot-reload engine; the cleanest of the five. Post-v6 it has few structural redundancies left. Its opportunities are doc/comment weight (CFG-04, CFG-08), one genuine redundant conjunct (CFG-07), a single-purpose wrapper worth inlining (CFG-05), and a visibility tightening (CFG-06). No behavioral duplication found.
- **parser.zig** — Test-pinned TOML parser. Tight, but carries the two biggest items in this audit: the weight-token grammar is parsed three times with near-identical logic (CFG-01) and the two whitespace skippers are twin loops (CFG-02). Also has extractable constants (CFG-03) and a repeated cap-check-and-store idiom (CFG-13).
- **schema.zig** — Table-driven comptime knob system over `parser.Document`. The mechanical duplication is the 6× dupe-key + `errdefer` + `put` block in `applySegmentEntry` (CFG-09), plus a probe loop that can use `break` (CFG-10) and a two-arm switch that merges into one arm (CFG-11).
- **types.zig** — Clean. The CFG-N1 `freeSegmentMap` consolidation is applied and correct; no new findings from this read pass.
- **fallback.zig** — Minimal (74 lines), self-contained, no findings.

## Findings (12)

---

### [CFG-01] HIGH / High: parser.zig:366-410 — weight-token grammar parsed three times

- **What:** The `(weight:N%)` marker grammar is redundantly implemented in `isWeightToken` (366-378), `weightFromToken` (384-391), and `splitWeightPrefix` (396-410). All three scan the same `(weight:` prefix, digit run, optional `%`, and closing `)`. The variants differ only in (a) strip-leading-`+` handling and (b) what "malformed" returns.
- **Why it matters and LoC cost:** 37 lines of trust-sensitive scanner written three ways is the single biggest readability/consistency hazard in the parser; today's three behaviors are merely "currently consistent." A user-visible divergence (e.g. one path accepting `(weight:01)`) would only show up at the tests.
- **Concrete simplification:** one core `fn parseWeightPrefix(raw: []const u8) ?struct { weight: u32, rest: []const u8 }` that strips a leading `+`, requires the annotation to close with `)`, and returns the parsed weight plus the trailing operand slice. Then:
  - `isWeightToken(raw) bool` → `(parseWeightPrefix(raw) orelse return false).rest.len == 0` (leading `+` is consumed by the core; today's `+(weight:N%)` tokens end with `)` so `rest.len == 0` is exactly today's `i == s.len - 1`).
  - `weightFromToken(raw) ?u32` → `if (parseWeightPrefix(raw)) |p| if (p.rest.len == 0) return p.weight; return null;`.
  - `splitWeightPrefix(part)` → `parseWeightPrefix(part) orelse .{ .weight = null, .operand = part }`. This is safe because parts reaching `splitWeightPrefix` come from `std.mem.splitScalar(u8, s, '+')` (`parser.zig:449`) and never carry a leading `+`.
  Keep `isWeightToken`/`weightFromToken` `pub` — they are pinned by `parser_test.zig:234-247`.
- **Estimated LoC delta:** −13 (37 → ~23).

---

### [CFG-02] MED / High: parser.zig:856-875 — `skipWhitespace` and `skipWhitespaceAndNewlines` are twin loops

- **What:** Two `inline fn` skippers with identical structure; the only differences are the `'\n'` and `'#'` arms in the second.
- **Why it matters and LoC cost:** 17 lines of near-duplicate parser-front logic; a future whitespace addition (e.g. `\f`) must be made in both places.
- **Concrete simplification:** one `inline fn skipInline(self: *Parser, comptime newlines: bool) void` with the family split `comptime`, then `skipWhitespace` = `skipInline(false)`, `skipWhitespaceAndNewlines` = `skipInline(true)` — both kept as `inline fn` wrappers so call sites compile identically.
- **Estimated LoC delta:** −4.

---

### [CFG-03] LOW / High: parser.zig:298 / parser.zig:108 — magic reserve capacities

- **What:** `Document.init` reserves `8` section slots (`sections.ensureTotalCapacity(8)`, parser.zig:298) and `Section.reserve` hardcodes `4` (parser.zig:108). Both are load-bearing performance hints with no named rationale.
- **Why it matters and LoC cost:** zero LoC impact; purely load-bearing-ness — the numbers are undocumented and could be silently "modernized" by someone not knowing they are intentional hints.
- **Concrete simplification:** extract `const section_reserve_capacity = 8;` and `const reserve_initial_capacity = 4;` with the one-line rationale (typical config declares ≤8 sections; ≤4 keys per section) next to the existing constants in parser.zig, and reference them.
- **Estimated LoC delta:** 0.

---

### [CFG-04] LOW / High: config.zig:120-134 — `readFileAlloc` doc comment is four times the body

- **What:** The 15-line doc block above `readFileAlloc` restates, at length, the stat-vs-growth-path design that the body and the inline comment at 142-144 already convey.
- **Why it matters and LoC cost:** 15 lines of prose for a 40-line function; the stat-timing/race explanation is already given tersely inside the body.
- **Concrete simplification:** shrink to ~4 lines: signature contract (`error.FileTooLarge` above `max_file_bytes`, returned slice may alias a larger allocation, ownership released by the arena) and one pointer to the body comments for the growth-path rationale.
- **Estimated LoC delta:** 0 (→ ~4 lines).

---

### [CFG-05] LOW / High: config.zig:44-46 — `parseWsToken` is a one-expression wrapper with two callers

- **What:** `parseWsToken` wraps `std.fmt.parseInt(usize, tok, 10) catch null`; callers at config.zig:53 and config.zig:1687 both immediately `orelse` their way forward.
- **Why it matters and LoC cost:** 3-line indirection for a standard-library call; the name now mostly signals intent that the callers' context already names.
- **Concrete simplification:** inline the expression at both call sites and delete the function.
- **Estimated LoC delta:** −3.

---

### [CFG-06] LOW / High: config.zig:418 — `snapshotDirPath` is `pub` with zero external consumers

- **What:** `rg` over `src/` shows the only callers are the two internal ones in the same file (config.zig:430 `reexecSnapshotPathZ`, config.zig:455 `refreshSnapshot`). No test references it either.
- **Why it matters and LoC cost:** zero LoC; it shrinks the module's pub surface, which is otherwise strictly the documented API (`load`, `loadConfigDefault`, `validate`, `detectChanges`, `refreshSnapshot`, `reexecSnapshotPathZ`, `canonicalLayoutName`, `DefaultSource`, `ConfigChanges`, `types.*`).
- **Concrete simplification:** change `pub fn` to `fn`.
- **Estimated LoC delta:** 0.

---

### [CFG-07] MED / High: config.zig:152 — redundant `stat != null and known_size > 0`

- **What:** `const initial: usize = if (stat != null and known_size > 0) known_size else read_growth_initial_bytes;` — when `stat` is `null`, `known_size` is already `0` (set at lines 146-150), so the `stat != null` conjunct proves nothing.
- **Why it matters and LoC cost:** a misleading redundant conjunct that suggests a case that cannot occur; mild but real reasoning cost on a load path.
- **Concrete simplification:** `if (known_size > 0) known_size else read_growth_initial_bytes` (or `known_size orelse read_growth_initial_bytes`-style via the existing `if`).
- **Estimated LoC delta:** −1.

---

### [CFG-08] LOW / High: config.zig:1807-1823 — 17-line rationale header ahead of `barChanged`/`tilingChanged`

- **What:** The shared `barChanged`/`tilingChanged` header comment (1807-1823) is an essay that references past consolidation work ("were already consolidated", "without a reflection layer").
- **Why it matters and LoC cost:** the comparable comparators are self-evident from the one-line comments at 1824-1825; half the header is archaeology.
- **Concrete simplification:** compress to ~6 lines: the detectors are by design hand-maintained field lists (cannot derive bar/tiling content from `schema.knobs`), keep the `keysChanged` bespoke note, drop the historical-consolidation paragraph.
- **Estimated LoC delta:** 0 (→ ~6 lines).

---

### [CFG-09] HIGH / High: schema.zig:699-702, 709-712, 722-725, 774-777, 780-783, 788-791 — the dupe-key + `errdefer` + `put` block appears six times

- **What:** `applySegmentEntry` repeats, 6×, the exact 4-line ownership dance:
  ```zig
  const k = try allocator.dupe(u8, seg_key);
  errdefer allocator.free(k);
  try map.put(allocator, k, value);
  ```
  across `segment_props` (`std.StringHashMapUnmanaged(SegmentProps)`) and `segment_fg`/`segment_value_fg` (`std.StringHashMapUnmanaged(u32)`).
- **Why it matters and LoC cost:** 24 lines of the error-not-possible-to-forget pattern; a future seventh site that skips the `errdefer` leaks. This is the file's mechanical duplication.
- **Concrete simplification:** `fn putSegmentEntry(comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), seg_key: []const u8, value: V) !void` containing exactly the 3 statements above. Each of the six sites becomes one call (`try putSegmentEntry(u32, allocator, map, seg_key, k)` / `... try putSegmentEntry(SegmentProps, allocator, &cfg.bar.segment_props, seg_key, props)`), with the site-local `map` selection as-is.
- **Estimated LoC delta:** −8 (24 → 6 calls + 8-line helper).

---

### [CFG-10] MED / High: schema.zig:513-518 — place-probe loop guards against itself

- **What:** The probe `inline for (k.places) |pl| { if (hit == null) { ... } }` tests `hit == null` inside the loop even though the loop body is exactly how `hit` gets set — the guard is only there to emulate a `break`.
- **Why it matters and LoC cost:** an extra nesting level and a redundant check per iteration for a FIRST-wins scan (documented at 509-511).
- **Concrete simplification:** `inline for (k.places) |pl| { if (doc.getSection(pl.section)) |sec| { hit = .{ .sec = sec, .key = pl.key }; break; } }` — `break` is supported on `inline for`.
- **Estimated LoC delta:** −2.

---

### [CFG-11] MED / High: schema.zig:350-352 — `getInRange` bool / `[]const u8` arms are identical in shape

- **What:** The first two arms of the `switch (T)`:
  ```zig
  bool => section.getAsOrWarn(bool, key) orelse return default,
  []const u8 => section.getAsOrWarn([]const u8, key) orelse return default,
  ```
  differ only in the spelled-out type.
- **Why it matters and LoC cost:** a doubled arm that reads as intentional asymmetry.
- **Concrete simplification:** `bool, []const u8 => section.getAsOrWarn(T, key) orelse return default,` (comptime `T` is known at the call site; `getAsOrWarn(T, ...)` is already instantiated for the whole function).
- **Estimated LoC delta:** −1.

---

### [CFG-13] LOW / High: parser.zig:452-455, 477-479, 514-520 — `extractMixOperands` repeats the cap-check + store + increment triple

- **What:** All three operand-producing branches of `extractMixOperands` repeat:
  ```zig
  if (count == max_mix_operands) return null;
  out[count] = .{ .color = color, .weight = <per-branch> };
  count += 1;
  ```
  differing only in the weight expression.
- **Why it matters and LoC cost:** three near-twin "push an operand or fail the mix" sequences; the max-8 bound is a parser invariant repeated 3×.
- **Concrete simplification:** `fn pushMixOperand(out: []MixOperand, count: *usize, color: u32, weight: ?u32) bool` (returns false when `count.* == out.len`, else stores and increments). Each branch becomes `if (!pushMixOperand(out, &count, color, w)) return null;`.
- **Estimated LoC delta:** −1 (9 → 3 calls + 5-line helper).

---

## DEFERRED / QUESTIONS — act on these to unlock further findings

- **`tryParseWsToken` (config.zig:52) vs `checkWorkspaceBound` (config.zig:26) overlap.** Both perform the identical three-part bounds check (`< 1`, `> 255`, `> max`). They cannot be merged as-is because `tryParseWsToken` embeds per-section `fmt`/`args` in its warning while `checkWorkspaceBound` takes a context string — merging would change warning text. Question: is unifying the three warning shapes acceptable? (Product decision.) If yes, ~−8 LoC in a follow-up.
- **`loadConfigDefault` env/`REE-EXEC` block (config.zig:503-532) vs the dir/file attempt loops.** The env block silently checks, the dir/file loops warn — coalescing into one attempts-table would change silent-vs-warn behavior. Worth revisiting only if silent-fallback semantics are intentionally asymmetric.
- **`isMixAttempt` (schema.zig:375-384) vs `extractMixOperands`' marker scan (parser.zig:464-482).** Both scan for a `+`/weight marker, but `isMixAttempt` accepts an embedded `'+'` anywhere in a scalar while `extractMixOperands`' unspaced branch requires an exact `+` split. A shared predicate would change detect semantics (`"a+b"`). Not safe to merge today.
- **`resolveElement`'s no-`sep` early return (config.zig:~1039-1050).** Merging the `has_sep` pre-scan into `splitParallel` would change trimming behavior for single padded commands (a lone `cmd ` with trailing space). Kept out of the audit for that reason.
- **`parseAndBuild` + `DirInput`/`FileInput`/`FallbackInput`.** The generic is instantiated exactly once per input type and each `parse` fn has a single caller; this looks like mild over-generalization. Question: would three straight-line functions be clearer? Net LoC ≈ 0, so this is a style call, not a savings.
- **`typeLabel`/`valueTypeLabel` (parser.zig:244-263) single-use by `getAsOrWarn`.** Inlining is net-zero LoC and both labels keep the warning readable; left alone.
- **Dropped candidates (examined, rejected):** extracting a release-tail helper for `freeStrings`/`freeStringMap`/`freeBarLayouts` comes out net +1 LoC (worse); `collectPalette` double-scan inversion is equivalent but not simpler; `segmentFgMap` extraction replaces 3 same-length lines with a helper call (net 0).

## Top-10 by expected yield

| # | ID | File | Est. Δ |
|---|----|------|--------|
| 1 | CFG-01 | parser.zig:366-410 | −13 |
| 2 | CFG-09 | schema.zig:699-791 (6 sites) | −8 |
| 3 | CFG-02 | parser.zig:856-875 | −4 |
| 4 | CFG-05 | config.zig:44-46 | −3 |
| 5 | CFG-10 | schema.zig:513-518 | −2 |
| 6 | CFG-04 | config.zig:120-134 | 0 (docs, 15→4) |
| 7 | CFG-08 | config.zig:1807-1823 | 0 (docs, 17→6) |
| 8 | CFG-07 | config.zig:152 | −1 |
| 9 | CFG-11 | schema.zig:350-352 | −1 |
| 10 | CFG-13 | parser.zig:452-520 | −1 |

(CFG-03 and CFG-06 are the two 0-LoC structural tightenings below the top-10 bar.)

## Digest

### parser.zig (main parser; test-pinned — all changes preserve behavior)
- **CFG-01:** three `(weight:N%)` scanners → one core + 3 wrappers. −13. Highest-value and highest-risk item; the isWeightToken/weightFromToken wrapper semantics are pinned by parser_test.
- **CFG-02:** merge `skipWhitespace`/`skipWhitespaceAndNewlines` into one comptime-flagged skipper. −4.
- **CFG-03:** name the `8`/`4` reserve capacities. 0.
- **CFG-13:** one `pushMixOperand` helper for the cap-check-and-store triple. −1.
- Subtotal: −18 across 4 findings.

### schema.zig (table-driven comptime knobs)
- **CFG-09:** 6× dupe-key + errdefer + put → `putSegmentEntry(comptime V, …)`. −8.
- **CFG-10:** first-wins place probe uses `break` instead of re-checking `hit`. −2.
- **CFG-11:** merge the `bool, []const u8` arms of `getInRange`. −1.
- Subtotal: −11 across 3 findings.

### config.zig (loader / reexec / hot-reload)
- **CFG-05:** inline `parseWsToken` (one-expression wrapper, 2 callers). −3.
- **CFG-07:** drop the provably-redundant `stat != null` conjunct. −1.
- **CFG-04 / CFG-08:** compress two doc blocks (30 → ~10 comment lines); 0 LoC but the biggest readability win per line.
- **CFG-06:** de-pub `snapshotDirPath` (no external/test consumers). 0.
- Subtotal: −4 across 5 findings.

### types.zig and fallback.zig
- No findings; both are clean post-v6 / minimal.

**Totals:** 12 findings; cumulative estimated LoC −33 (plus two comment slims). All are semantics-preserving; the two deferred product decisions (`tryParseWsToken`/`checkWorkspaceBound` unification, silent-vs-warn coalescing in `loadConfigDefault`) could add ~−8 more if approved.