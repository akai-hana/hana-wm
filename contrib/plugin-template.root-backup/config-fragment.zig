//! config-fragment.zig — drop-in template for a hana config fragment.
//!
//! COPY ME: a module ships its config BESIDE ITSELF, named after it:
//!
//!     cp contrib/plugin-template/config-fragment.zig \
//!        src/window/modules/mything_config.zig   // next to mything.zig
//!
//! (bar/tiling/... works the same: discovery pairs every `<owner>_config`
//! stem with the module `<owner>` — a fragment whose owner module is ABSENT
//! is a BUILD ERROR, and deleting the owner takes the fragment with it.)
//! File presence alone wires everything: the generated `composed` facade
//! gains a `mything: Config` field, calls your `parse`/`validate` on load
//! and `deinit` on teardown, and `hana --dump-config-schema` prints your
//! knobs' rows. Nothing in the core is edited to add config — the
//! section-knowledge contract below is satisfied by exports from THIS
//! file.
//!
//! This file is INTENTIONALLY inert: it lives in contrib/, so the `src/`
//! discovery walk never sees it, and after a copy the `[template]` sections
//! simply never appear in any shipped config — every place stays unfired
//! and the struct keeps its field-initializer defaults. The gate compiles
//! this file against the REAL modules on every `zig build check` (the
//! check-plugin-template step), so contract drift fails here first.
//!
//! THE FRAGMENT CONTRACT (the generated facade requires all four):
//!   `Config`   — the subtree struct. Field INITIALIZERS are the defaults:
//!                a key-less file must produce exactly `.{}` (knob_test
//!                pins this per fragment).
//!   `parse`    — `fn (std.mem.Allocator, *parser.Document) !Config`.
//!   `validate` — `fn (*const Config) !void`. `error.InvalidConfig` FAILS
//!                the whole load (boot falls back; reload keeps the live
//!                config). Warn-and-continue belongs in `parse` instead
//!                (see tiling_config's master_width ratio policy).
//!   `deinit`   — method on Config; `parse`'s `errdefer` calls it on the
//!                error path, so it must tolerate a partially-filled Config.
//!
//! THE D13 SECTION-KNOWLEDGE CONTRACT (P2-50) — section knowledge lives in
//! THIS file, not in the core. Export the five policy lists (the generated
//! `composed` facade unions every present fragment's lists; each defaults
//! to empty, so a fragment without one still compiles):
//!   `sections`          — the exact section names this fragment owns:
//!                         the mis-case lint's inventory, so a case-variant
//!                         of your header (`[Template]`) gets the warn that
//!                         names it instead of silently dropping the whole
//!                         section. Local consts are fine; reference
//!                         `types.section_*` only for shared vocabulary.
//!   `section_prefixes`  — OPEN name families (one section per rule /
//!                         workspace / layout name): the mis-case lint
//!                         treats the family as a unit.
//!   `inert_families`    — parent-gated families: a child section present
//!                         while its parent is absent leaves those knobs
//!                         inert, which the load warns about.
//!   `accumulate_exempt` — (section, key) pairs where duplicate
//!                         declarations accumulate BY DESIGN (rule/bind
//!                         tables): a scalar read of the accumulated array
//!                         must not warn "later wins". `key` = "" exempts
//!                         every key in the section.
//!   `fallback_sections` — section HEADS that appear in the shipped
//!                         `config/fallback.toml`: the build's fallback
//!                         filter strips a `[head...]` block when this
//!                         fragment's owner module is absent from the
//!                         tree. Empty unless your sections ship in the
//!                         fallback (an unknown head is always kept).
//! Adding a section is an edit to THIS file plus, if you want the shared
//! spelling, a `pub const section_<name>` in `src/config/types.zig`.

const std = @import("std");
const log = std.log.scoped(.template_config);
const parser = @import("parser");
const types = @import("types");
const knob = @import("knob");

// Section names. Upstream these live as `types.section_*` constants (check
// the D13 checklist above); a local const is what a fork may use, and the
// dotted subsection demonstrates the parent-gate pattern.
const section_template = "template";
const section_advanced = section_template ++ ".advanced";
const section_notes = section_template ++ ".notes";

pub const Config = struct {
    enabled: bool = true,
    sample_count: u16 = 5,
    // Optional `.str` knob: the ENGINE dupes the value off the document
    // (applyInto's assignStr), this deinit frees the copy.
    label: ?[]const u8 = null,
    // The fallback-chain pair: `banner` falls back to `accent`.
    accent: types.Color = 0x61AFEF,
    banner: types.Color = 0x61AFEF,
    // Bespoke scalar: NOT a knob (parsed by hand in parseDetail below) —
    // claimed in validateTable's `bespoke` list or the table would flag it
    // as a dead (never-written) field.
    detail_level: u8 = 3,
    // Non-scalar: lists/maps are outside the knob engine entirely (only
    // SCALAR leaves need claiming), parsed by hand — see parseNotes.
    notes: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.label) |s| allocator.free(s);
        for (self.notes.items) |n| allocator.free(n);
        self.notes.deinit(allocator);
    }
};

pub const knobs = [_]knob.Knob{
    // knob() — one accepted spelling. A place whose section never exists
    // never fires, so a config without [template] loads pure defaults.
    knob.knob(&.{knob.place(section_template, "enabled")}, "enabled", .b),
    knob.knob(
        &.{knob.place(section_template, "sample_count")},
        "sample_count",
        .{ .int = .{ .T = u16, .min = 1, .max = 100 } },
    ),

    // Alias spellings, FIRST-PRESENT-WINS (dedicated-section spelling
    // outranks the flat one; section presence, not key presence, picks —
    // the tiling master-stack shape), gated on the parent: a bare
    // [template.advanced] without [template] must stay inert rather than
    // half-apply. `requires` is what skips the whole knob without the
    // parent — it matters whenever a place's section differs from the gate.
    knob.knobGated(
        &.{
            knob.place(section_advanced, "label"),
            knob.place(section_template, "label"),
        },
        "label",
        .str,
        section_template,
    ),

    // The fallback chain: `accent` parses first, `banner` reads the
    // sibling's FRESH value when its own key (or section) is absent —
    // `copy_when_absent` assigns the fallback unconditionally, so both
    // defaults being equal keeps the template inert. `.needs` states the
    // dependency as data: validateTable fails the build if `accent` is
    // ever moved BELOW this entry (the knob would still parse — it would
    // just read the default and be visually wrong).
    knob.knob(&.{knob.place(section_template, "accent")}, "accent", .color),
    .{
        .places = &.{knob.place(section_template, "banner")},
        .target = "banner",
        .kind = .{ .color_from = "accent" },
        .copy_when_absent = true,
        .needs = &.{"accent"},
    },
    // Module-owned knobs: use `knob.readerOf(...)` / `readerOfGated(...)` —
    // or set `.reader = "mything"` like `barBool` does — when the field's
    // only reader is an OPTIONAL module, and list every (target, stem) pair
    // in knob_reader_modules below. validateOwnership (comptime) fails the
    // build if the tables drift, and the build's knob-reader scan excuses a
    // target whose reader module has been deleted instead of calling it
    // dead. Empty `.reader` (every entry above) means "a reader must exist
    // in the tree" — right for a fragment read by its own always-present
    // owner module.
};

/// Config fields that are legitimately NOT knobs: each entry is a contract,
/// not an exemption — the reason is why the table must not claim it.
const bespoke_fields = [_][]const u8{
    "detail_level",
};

/// Ownership pairs for module-owned knobs (see the reader note above).
/// Empty while every entry above is fragment-read; add `.{ "field", "stem" }`
/// when you set a `.reader`.
pub const knob_reader_modules = [_][2][]const u8{};

comptime {
    // Both checks run when this file is imported (container-level comptime
    // blocks are evaluated on import), so a copy that drifts fails at build
    // time: validateTable proves every scalar field is written by a knob or
    // claimed bespoke (and the `needs` ordering); validateOwnership pins the
    // reader/pair tables to each other.
    knob.validateTable(Config, &knobs, &bespoke_fields);
    knob.validateOwnership(&knobs, &knob_reader_modules, "template");
}

/// The section names this fragment owns (D13/P2-50, see the contract at the
/// top of the file): the composed facade unions every present fragment's
/// list into the mis-case lint's inventory. Local consts are fine — the
/// names need not live in types.zig unless other modules share them.
pub const sections = &[_][]const u8{
    section_template,
    section_advanced,
    section_notes,
};

/// The template's sections never ship in config/fallback.toml, so nothing
/// is fallback-gated (a tree without this module strips no `[template]`
/// blocks — there are none). Non-empty ONLY for section heads that actually
/// appear in the shipped fallback, else the head is kept unconditionally.
pub const fallback_sections = &[_][]const u8{};

/// Parent-gated family (D13): [template.advanced]/[template.notes] are
/// read only when bare [template] is present; the load warns when a child
/// shows up without its parent, which would leave those knobs inert.
pub const inert_families = &[_]types.InertFamily{.{
    .parent = section_template,
    .child_prefix = section_template ++ ".",
}};

/// No section here accumulates duplicate declarations by design: a
/// duplicated template key is a user mistake and SHOULD warn "later wins".
/// Rule/bind tables list their (section, key) pairs instead (`key` = ""
/// exempts every key in the section).
pub const accumulate_exempt = &[_]types.SectionKey{};

/// The fragment parse entry: engine scalars first (knobs may depend on
/// each other — table order), then the bespoke families. `errdefer` tears
/// down whatever was filled (OOM safety); the facade calls `deinit` only on
/// the success path.
pub fn parse(allocator: std.mem.Allocator, doc: *parser.Document) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);
    try knob.applyAll(Config, doc, allocator, &cfg, &knobs);
    parseDetail(doc, &cfg);
    try parseNotes(allocator, doc, &cfg);
    return cfg;
}

/// No domain invariant beyond what the knobs' ranges already enforce;
/// present so the facade can call `validate` uniformly on every fragment.
/// A load-FAILING rule belongs here (`return error.InvalidConfig`), a
/// warn-and-keep rule belongs in parse — never in the knobs' readers.
pub fn validate(_: *const Config) !void {}

/// Bespoke scalar from the subsection: `getAsOrWarn` diagnoses a
/// wrong-typed value; the RANGE is your job (the engine's int bounds only
/// apply to declared knobs), warn-and-keep matching the engine's style.
fn parseDetail(doc: *parser.Document, cfg: *Config) void {
    const s = doc.getSection(section_advanced) orelse return;
    if (s.getAsOrWarn(i64, "detail_level")) |v| {
        if (v >= 0 and v <= 9) {
            cfg.detail_level = @intCast(v);
        } else {
            log.warn("[{s}] detail_level = {d} outside 0..9; keeping {d}", .{ section_advanced, v, cfg.detail_level });
        }
    }
}

/// A non-scalar family: every entry KEPT must be DUPED — the document (and
/// its arena) dies at the end of the load, so a borrowed slice would dangle
/// by the time the owner module reads it. Scalar `.str` knobs are duped by
/// the engine; this rule covers everything YOU stash by hand. The iterator
/// marks each key consumed as it hands it over, so `lintDocument` stays
/// quiet about this section.
fn parseNotes(allocator: std.mem.Allocator, doc: *parser.Document, cfg: *Config) !void {
    const s = doc.getSection(section_notes) orelse return;
    var iter = s.orderedIterator();
    while (iter.next()) |entry| {
        if (entry.value.asScalar([]const u8)) |text| {
            try cfg.notes.append(allocator, try allocator.dupe(u8, text));
        } else {
            log.warn("[{s}] '{s}' is not a string; skipping", .{ section_notes, entry.key });
        }
    }
}

/// The check-plugin-template gate binds this (spec `.decl`): resolving the
/// tuple forces the four contract pieces — Config, parse, validate,
/// Config.deinit — through analysis against the REAL modules on every
/// `zig build check`, and (being in this file) pulls the container-level
/// validateTable/validateOwnership blocks with it. Function bodies follow
/// the gate's documented residual gap: a helper renamed inside a body is
/// flagged once the tree's own modules use the new name (same as every
/// other template here).
pub const binding = .{ Config, parse, validate, Config.deinit };
