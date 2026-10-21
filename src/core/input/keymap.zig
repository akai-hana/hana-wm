//! X-free keymap utilities: given an `xkb_keymap`, build a flat keycode→keysym table
//! and a reverse index, plus keysym-name parsing -- pure functions of the compiled
//! keymap, no X connection or `xkb_state`. Home to the keymap readiness heuristic and
//! keycode tie-break policy (headless-testable), and the SINGLE `@cImport` owner for
//! libxkbcommon (xkb.zig borrows it, translated once instead of once per importer).
//! Connection-free, so the pure layers and config can parse binding names through it
//! without reaching a live-device input module.

const std = @import("std");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

/// X11 reserves keycodes 0..7; the first real keycode is 8, so the flat keysym table
/// covers 8..255.
pub const x11_min_keycode: u8 = 8;
/// The keycode space 0..255; tables and bitsets over the full range size from it.
pub const x11_max_keycode: usize = 256;

pub const xkb_context = xkb.struct_xkb_context;
const xkb_keymap = xkb.struct_xkb_keymap;

pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;

/// Keycodes in the X11 range, minus the reserved low ones.
pub const reverse_capacity = x11_max_keycode - x11_min_keycode;

/// Upper keycode the readiness heuristic scans. Raising it would let a partially
/// built keymap -- populated high but empty at the low end -- still read as healthy.
const keymap_health_hi: u8 = 128;

/// A keymap with fewer reachable keysyms than this is treated as not ready and the
/// caller retries rather than building a table full of holes. A healthy keymap has
/// 100+; 40 accepts minimal/embedded keymaps while still rejecting the empty keymap
/// a not-yet-ready XKB returns at startup.
const min_keymap_symbols: u32 = 40;

/// Base (level-0) symbol for `kc`, independent of lock state, read straight from the
/// keymap. A lock-sensitive resolve (xkb_state's `get_one_sym`) would apply current
/// locks: a CapsLock held at startup would pin the table to shifted symbols and break
/// lowercase bindings.
fn baseSymbol(km: *xkb_keymap, kc: u8) u32 {
    var syms: [*c]const u32 = undefined;
    const n = xkb.xkb_keymap_key_get_syms_by_level(km, @intCast(kc), 0, 0, &syms);
    if (n > 0) return syms[0];
    return XKB_KEY_NoSymbol;
}

/// A device keymap flattened to the level-0 keysym per keycode, plus whether it passed
/// the health check.
const BuiltTable = struct {
    table: [x11_max_keycode]u32,
    /// At least min_keymap_symbols reachable keysyms in the 8..128 range.
    healthy: bool,
};

/// Builds the flat keycode->keysym table from level-0 symbols, reporting health from
/// the SAME walk (one sweep: counting during the flatten is free). Keycodes below 8
/// are reserved by X11 and yield no real keysym; the `kc < keymap_health_hi` guard
/// keeps the health count to the low-end window while the table runs to
/// x11_max_keycode.
pub fn buildKeysymTable(km: *xkb_keymap) BuiltTable {
    var table: [x11_max_keycode]u32 = [_]u32{XKB_KEY_NoSymbol} ** x11_max_keycode;
    var valid_keys: u32 = 0;
    for (x11_min_keycode..x11_max_keycode) |kc| {
        const sym = baseSymbol(km, @intCast(kc));
        table[kc] = sym;
        if (sym != XKB_KEY_NoSymbol and kc < keymap_health_hi) valid_keys += 1;
    }
    return .{ .table = table, .healthy = valid_keys >= min_keymap_symbols };
}

const ReverseEntry = struct { keysym: u32, keycode: u8 };

/// The reverse index: the populated level-0 keysyms, sorted by keysym. Built from the
/// forward table in one pass and searched by bisection, so `keysymToKeycode` stops
/// being a 248-entry scan per keybinding. A keymap has at most one entry per keycode,
/// so this is a small fixed array rather than a hash map: 248 * 8 bytes, never needs
/// an allocator.
pub const ReverseIndex = struct {
    /// Sorted by keysym. `len` is the LIVE count; the rest is uninitialized.
    index: [reverse_capacity]ReverseEntry,
    len: usize,

    /// Keycode for `keysym`, or null -- bisection over the sorted index, so every
    /// resolve is O(log n) rather than a 248-entry scan. Lives here so the tests
    /// pinning the ordering rules also catch lookup changes.
    pub fn find(self: *const ReverseIndex, keysym: u32) ?u8 {
        var lo: usize = 0;
        var hi: usize = self.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const e = self.index[mid];
            if (e.keysym == keysym) return e.keycode;
            if (e.keysym < keysym) lo = mid + 1 else hi = mid;
        }
        return null;
    }
};

/// The table -> reverse-index transform, including its two ordering rules. Exposed as
/// a function over a plain table so both are testable: the forward table is 256 u32s
/// of literals, and the interesting behaviour is what happens when keysyms collide.
pub fn buildReverseIndex(table: [x11_max_keycode]u32) ReverseIndex {
    var out: [reverse_capacity]ReverseEntry = undefined;
    var n: usize = 0;
    for (x11_min_keycode..x11_max_keycode) |kc| {
        const sym = table[kc];
        if (sym == XKB_KEY_NoSymbol) continue;
        // Insertion sort by keysym ascending, LOWEST keycode first on a tie --
        // stable on keycode order because the scan is in keycode order.
        var j = n;
        while (j > 0) {
            const prev = out[j - 1];
            if (prev.keysym < sym or (prev.keysym == sym and prev.keycode <= kc)) break;
            out[j] = prev;
            j -= 1;
        }
        out[j] = .{ .keysym = sym, .keycode = @intCast(kc) };
        n += 1;
    }
    // Compacting adjacent duplicates AFTER the sort is what makes the lowest-keycode
    // tie-break real. Compacting during the scan (comparing against the last
    // APPENDED entry) only catches duplicates adjacent in KEYCODE order, and keysyms
    // are not ordered by keycode: with kc10=X, kc11=Y, kc12=X the scan compares X
    // against Y, misses the tie and appends both -- then bisection can land on
    // either, so a binding on a keysym carried by two keys could grab the higher
    // keycode and silently stop responding to the lower one.
    var w: usize = 0;
    for (out[0..n]) |e| {
        if (w > 0 and out[w - 1].keysym == e.keysym) continue;
        out[w] = e;
        w += 1;
    }
    return .{ .index = out, .len = w };
}

/// Keysym for `name` under case-insensitive lookup (so `"super_l"` and `"Super_L"`
/// agree), or `XKB_KEY_NoSymbol` when unknown; `name` may carry trailing NUL bytes
/// and parsing stops at the first. Pure libxkbcommon table lookups -- no X
/// connection, `xkb_state`, or XKB setup -- which is possible only because this file
/// owns the single @cImport of that header, and the module is connection-free so
/// config can import it without pulling in live-device-state modules.
pub fn keysymFromName(name: []const u8) u32 {
    // xkb_keysym_from_name wants a NUL-terminated C string; a name without an embedded
    // NUL would hand it an unterminated buffer and read out of bounds. Copy into our
    // own NUL-terminated buffer regardless.
    var buf: [256]u8 = undefined;
    const z = std.mem.sliceTo(name, 0);
    const n = @min(z.len, buf.len - 1);
    @memcpy(buf[0..n], z[0..n]);
    buf[n] = 0;
    return xkb.xkb_keysym_from_name(&buf, xkb.XKB_KEYSYM_CASE_INSENSITIVE);
}

/// XKB name for `keysym` (e.g. XKB_KEY_at -> "at") into `buf`, returning the
/// slice holding it. Used for diagnostic messages.
pub fn keysymGetName(keysym: u32, buf: []u8) []const u8 {
    const n = xkb.xkb_keysym_get_name(keysym, buf.ptr, buf.len);
    const len: usize = if (n < 0) 0 else @min(@as(usize, @intCast(n)), buf.len);
    return buf[0..len];
}
