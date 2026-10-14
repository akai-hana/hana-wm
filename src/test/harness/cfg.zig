//! Shared arrange for the config section tests.
//!
//! The ownership rule every one of them follows: the parsed
//! `Document` lives in a per-test arena (freed wholesale at test end), while
//! the fragment `Config` and every action payload it owns use
//! `testing.allocator`, so a leak fails the test rather than being swallowed
//! by the arena.
//!
//! Encoded here once for every section test. `begin(T)`
//! / `deinit()` own the arena+Config pair; `apply` parses a source string
//! with `parser.parse` and hands the document to a section interpreter.
//! Every fragment entry point that shares the `(allocator, *Document, *T)`
//! shape (`parseKeybindings` on CoreConfig, `parseTilingStructures` on
//! tiling_config.Config, `parseBar`/`applyBarProperties` on
//! bar_config.Config, `parseRules` on workspaces_config.Config) is covered
//! by the one function-pointer type below, instantiated per T.

const std = @import("std");
const testing = std.testing;
const parser = @import("parser");

pub fn Case(comptime CfgT: type) type {
    return struct {
        arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(testing.allocator),
        cfg: CfgT = .{},

        /// A section interpreter: parse a document into this Case's Config.
        pub const SectionParseFn = *const fn (std.mem.Allocator, *parser.Document, *CfgT) anyerror!void;

        /// Frees the Config against `testing.allocator` (so its owned strings
        /// and payloads are leak-checked) and then the document arena
        /// wholesale.
        pub fn deinit(self: *@This()) void {
            self.cfg.deinit(testing.allocator);
            self.arena.deinit();
        }

        /// Parses `src` (diagnostics labelled `label`) and applies it with
        /// `parse`.
        pub fn apply(self: *@This(), label: []const u8, parse: SectionParseFn, src: []const u8) !void {
            var doc = try parser.parse(self.arena.allocator(), src, label);
            try parse(testing.allocator, &doc, &self.cfg);
        }
    };
}

pub fn begin(comptime CfgT: type) Case(CfgT) {
    return .{};
}
