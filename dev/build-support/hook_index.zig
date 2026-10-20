//! Hook-index printer (P2-57): the codegen half of "surface the hook index
//! via codegen, not prose". Imports the REAL engine contracts (wired by
//! build.zig with the same shared/discovered imports every module gets) and
//! walks their fields at comptime, so the table cannot drift from the
//! partition lists the generated registries enforce. The whole table is
//! formatted at COMPILE time into one string; `main` only writes it. Output
//! is one `contract<TAB>hook<TAB>cardinality<TAB>note` row per hook:
//!   cardinality `single` — at-most-one binder, first-match dispatch; the
//!     note names the dispatch site (the window family namespace, or the
//!     bar's providerOf lookup).
//!   cardinality `multi`  — fan-out: several modules may bind, every binder
//!     is adopted (explicit registry loop / uniform bar walk).
//!   cardinality `data`   — not a hook (identity, capability flag, or
//!     family container); listed so the table is a total field index.

const std = @import("std");
const window_contract = @import("window_contract");
const bar_contract = @import("bar_contract");

/// Family field name by index, kept in sync with window_contract's private
/// `families` tuple by the hookFamily index it returns (same source of
/// truth the registry namespaces instantiate).
fn familyName(comptime fi: usize) []const u8 {
    return switch (fi) {
        0 => "hide",
        1 => "covering",
        2 => "workspaces",
        3 => "floating",
        4 => "drag",
        5 => "command",
        6 => "borders",
        else => "unknown",
    };
}

/// `dispatch.isListed` inlined: this tool imports only the two contracts
/// (not contract_dispatch), and the probe is a 5-line scan.
fn listed(comptime list: anytype, comptime name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// A Segment hook field: optional function pointer, or the BarOverlay
/// binding (also optional). Everything else (name, bools, DirtySources) is
/// data.
fn isHookField(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .optional) return false;
    const child = @typeInfo(info.optional.child);
    return child == .pointer or child == .@"struct";
}

/// The whole table, formatted at comptime. Returned as a comptime string so
/// `main` is a single write and no runtime field walk can reintroduce the
/// comptime/runtime control-flow tangle this replaced.
const table: []const u8 = blk: {
    @setEvalBranchQuota(20_000);
    var out: []const u8 = "contract\thook\tcardinality\tnote\n";

    const WM = window_contract.WindowModule;
    for (WM.single_binder_hooks) |hook| {
        const fi = WM.hookFamily(hook).?;
        out = out ++ "WindowModule\t" ++ hook ++ "\tsingle\tregistry." ++ familyName(fi) ++ "\n";
    }
    for (WM.multi_binder_hooks) |hook| {
        out = out ++ "WindowModule\t" ++ hook ++ "\tmulti\tregistry loop\n";
    }
    for (std.meta.fields(WM)) |f| {
        if (listed(WM.single_binder_hooks, f.name)) continue;
        if (listed(&WM.multi_binder_hooks, f.name)) continue;
        out = out ++ "WindowModule\t" ++ f.name ++ "\tdata\t-\n";
    }

    const Seg = bar_contract.Segment;
    for (Seg.single_binder_hooks) |hook| {
        out = out ++ "Segment\t" ++ hook ++ "\tsingle\tproviderOf\n";
    }
    for (std.meta.fields(Seg)) |f| {
        if (listed(&Seg.single_binder_hooks, f.name)) continue;
        const kind: []const u8 = if (isHookField(f.type)) "multi" else "data";
        out = out ++ "Segment\t" ++ f.name ++ "\t" ++ kind ++ "\tbar walk\n";
    }

    break :blk out;
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var out_buf: [4096]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var w = stdout.writer(io, &out_buf);
    w.interface.writeAll(table) catch std.process.exit(1);
    w.flush() catch std.process.exit(1);
    std.process.exit(0);
}
