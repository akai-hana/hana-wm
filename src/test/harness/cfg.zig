//! Shared arrange for the config section tests.
//!
//! The ownership rule every one of them used to restate by hand: the parsed
//! `Document` lives in a per-test arena (freed wholesale at test end), while
//! the `Config` and every action payload it owns use `testing.allocator`, so
//! a leak fails the test rather than being swallowed by the arena.
//!
//! Encoded once here instead of the ~45 sites that re-stated it. `begin()` /
//! `deinit()` own the arena+Config pair; `apply` parses a source string with
//! `parser.parse` and hands the document to a section interpreter. Every
//! `config/sections/` entry point (`parseKeybindings`, `parseRules`,
//! `parseBar`, `parseTilingStructures`) and `bar_properties.applyBarProperties`
//! share the `(allocator, *Document, *Config)` shape, so one function-pointer
//! type covers them all. A test that needs a step between parse and apply
//! (the bar-properties palette) reaches for `arena.allocator()` directly and
//! calls the interpreter itself.

const std = @import("std");
const testing = std.testing;
const parser = @import("parser");
const types = @import("types");

/// A section interpreter: parse a document into the Config.
pub const SectionParseFn = *const fn (std.mem.Allocator, *parser.Document, *types.Config) anyerror!void;

pub const Case = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator),
    cfg: types.Config = .{},

    /// Frees the Config against `testing.allocator` (so its owned strings and
    /// payloads are leak-checked) and then the document arena wholesale.
    pub fn deinit(self: *Case) void {
        self.cfg.deinit(testing.allocator);
        self.arena.deinit();
    }

    /// Parses `src` (diagnostics labelled `label`) and applies it with `parse`.
    pub fn apply(self: *Case, label: []const u8, parse: SectionParseFn, src: []const u8) !void {
        var doc = try parser.parse(self.arena.allocator(), src, label);
        try parse(testing.allocator, &doc, &self.cfg);
    }
};

pub fn begin() Case {
    return .{};
}
