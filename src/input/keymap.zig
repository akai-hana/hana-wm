//! The X-free half of the keymap pipeline: an `xkb_keymap` in, a flat
//! keycode->keysym table and a reverse index out.
//!
//! These are pure functions of a keymap that libxkbcommon has already built.
//! They need no X connection and no `xkb_state`, so they are the only part of
//! the keyboard stack a headless test can reach -- and they are where the two
//! policies that decide whether the WM can use a keyboard at all actually
//! live: the readiness heuristic that rejects a half-built keymap, and the
//! tie-break that decides which of two keys sharing a keysym a binding grabs.
//! Both were previously unreachable from a test, so neither was tested, by
//! construction rather than by choice.
//!
//! This module is also the single `@cImport` owner for libxkbcommon (19.8).
//! `xkbcommon.zig` (which needs the X11 half of the library) and `keysyms.zig`
//! (the pure name vocabulary) both borrow it from here, so the header is
//! translated once instead of once per importer.
//!
//! Layer note: connection-free, so it is importable from the pure layers.

const std = @import("std");

const constants = @import("constants");

pub const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-x11.h");
});

pub const xkb_context = xkb.struct_xkb_context;
pub const xkb_keymap = xkb.struct_xkb_keymap;

pub const XKB_KEY_NoSymbol: u32 = xkb.XKB_KEY_NoSymbol;

/// Keycodes in the X11 range, minus the reserved low ones.
pub const reverse_capacity = constants.x11_max_keycode - constants.x11_min_keycode;

/// Upper keycode the readiness heuristic scans. A keymap that is populated
/// across the whole range but empty in the low end -- a partially built one --
/// still reads as healthy if the bound is raised.
const keymap_health_hi: u8 = 128;

/// A keymap with fewer than this many reachable keysyms is treated as not
/// ready, and its caller retries rather than building a table full of holes.
const min_keymap_symbols: u32 = 40;

/// Base (level-0) symbol for `kc`, independent of lock state; reads the
/// keymap's level-0 entry directly. A lock-sensitive resolve (xkb_state's
/// `get_one_sym`) would apply current locks: a CapsLock held at startup
/// would pin the table to shifted symbols and break lowercase bindings.
fn baseSymbol(km: *xkb_keymap, kc: u8) u32 {
    var syms: [*c]const u32 = undefined;
    const n = xkb.xkb_keymap_key_get_syms_by_level(km, @intCast(kc), 0, 0, &syms);
    if (n > 0) return syms[0];
    return XKB_KEY_NoSymbol;
}

/// Builds the flat keycode->keysym table from level-0 symbols.
/// Keycodes below 8 are reserved by X11 and produce no real keysym.
/// A device keymap flattened to the level-0 keysym per keycode, plus whether
/// it passed the health check.
pub const BuiltTable = struct {
    table: [constants.x11_max_keycode]u32,
    /// True if the keymap has at least min_keymap_symbols reachable keysyms in
    /// the 8..128 range.
    healthy: bool,
};

/// Flatten `km`, reporting health from the SAME walk.
///
/// These used to be two functions, `buildKeysymTable` and
/// `keymapHasEnoughSymbols`, and every caller ran both: the retry ladder asked
/// for health, and the caller of the ladder then asked for the table. Two
/// `xkb_keymap_key_get_syms_by_level` sweeps over the same keymap to produce
/// one table. Counting during the flatten is free, and the two answer questions
/// about disjoint keycode ranges -- health stops at keymap_health_hi, the table
/// runs to x11_max_keycode -- so the `kc < keymap_health_hi` guard below is
/// what preserves the original count exactly.
pub fn buildKeysymTable(km: *xkb_keymap) BuiltTable {
    var table: [constants.x11_max_keycode]u32 = [_]u32{XKB_KEY_NoSymbol} ** constants.x11_max_keycode;
    var valid_keys: u32 = 0;
    for (constants.x11_min_keycode..constants.x11_max_keycode) |kc| {
        const sym = baseSymbol(km, @intCast(kc));
        table[kc] = sym;
        if (sym != XKB_KEY_NoSymbol and kc < keymap_health_hi) valid_keys += 1;
    }
    return .{ .table = table, .healthy = valid_keys >= min_keymap_symbols };
}

/// One (keysym, keycode) pair in the reverse index.
pub const ReverseEntry = struct { keysym: u32, keycode: u8 };

/// The reverse index: the populated level-0 keysyms, sorted by keysym.
///
/// Built from the forward table in one pass and searched by bisection, so
/// `keysymToKeycode` stops being a 248-entry scan per keybinding. A keymap has
/// at most one entry per keycode, so this is a small fixed array, not a hash
/// map: the whole index is 248 * 8 bytes and never needs an allocator.
pub const ReverseIndex = struct {
    /// Sorted by keysym. `len` is the LIVE count; the rest is uninitialized.
    index: [reverse_capacity]ReverseEntry,
    len: usize,

    /// Keycode for `keysym`, or null. Bisection over the sorted index: O(log n)
    /// rather than the 248-entry scan this replaced, which ran once per
    /// keybinding on every resolve.
    ///
    /// This lives here rather than at the call site because the keymap test
    /// used to carry its own copy of the loop, so the tests that were supposed
    /// to pin the ordering rules could not catch a change to the lookup that
    /// used them.
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

/// The table -> reverse-index transform, including its two ordering rules.
///
/// Exposed as a function over a plain table (not folded into buildKeysymTable)
/// precisely so both rules are testable: the forward table is 256 u32s of
/// literals, and the interesting behaviour is what happens when keysyms
/// collide.
pub fn buildReverseIndex(table: [constants.x11_max_keycode]u32) ReverseIndex {
    var out: [reverse_capacity]ReverseEntry = undefined;
    var n: usize = 0;
    for (constants.x11_min_keycode..constants.x11_max_keycode) |kc| {
        const sym = table[kc];
        if (sym == XKB_KEY_NoSymbol) continue;
        // Insertion sort by keysym, ascending, with the LOWEST keycode first
        // on a tie. Stable on keycode order because the scan is in keycode
        // order.
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
    // Compacting adjacent duplicates AFTER the sort is what makes the
    // lowest-keycode tie-break real. Doing it during the scan instead
    // (comparing against the last APPENDED entry) only catches duplicates that
    // happen to be adjacent in KEYCODE order, and keysyms are not ordered by
    // keycode: with kc10=X, kc11=Y, kc12=X the scan-side check compares X
    // against Y, misses the tie, and appends both. After the sort the two X
    // entries sit next to each other, and the bisection in keysymToKeycode can
    // land on either one -- so a binding on a keysym carried by two keys could
    // grab the higher keycode and silently stop responding to the lower one.
    var w: usize = 0;
    for (out[0..n]) |e| {
        if (w > 0 and out[w - 1].keysym == e.keysym) continue;
        out[w] = e;
        w += 1;
    }
    return .{ .index = out, .len = w };
}
