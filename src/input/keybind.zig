//! Keybinding resolution: keysym -> keycode (via the live XKB state) plus the
//! (modifiers, keysym) -> Action dispatch map consumed on the hot key path.
//!
//! This lives in the input layer, not in `config/types`: config owns the
//! *parsed* bindings (pure data, no X), while turning a keysym into a keycode
//! needs a live `XkbState`. Keeping the resolver here breaks the
//! `types -> xkbcommon -> core -> types` import cycle and leaves the config
//! layer X-free.

const std = @import("std");
const log = @import("log");
const types = @import("types");
const keysyms = @import("keysyms");
const xkbcommon = @import("xkbcommon");

/// Owns the (modifiers, keysym) -> Action dispatch map resolved from a
/// config's keybindings, plus the keycode-resolution step that feeds it.
/// Module-owned by `input` (not embedded in Config) so the config layer stays
/// X-free; `input.deinitKeybinds` tears it down before the Actions its entries
/// point into are freed.
/// Orders the dispatch table by packed key. The key is a u64 built as
/// (modifiers << 32) | keysym, so this is also a plain numeric order on the
/// whole entry.
fn entryLessThan(_: void, a: DispatchEntry, b: DispatchEntry) bool {
    return a.key < b.key;
}

/// One dispatchable binding: the packed dispatch key plus where the action
/// lives in the current config's keybindings slice.
pub const DispatchEntry = struct {
    /// High 32 bits modifiers, low 32 keysym. One u64 compare orders the whole
    /// table, which is why the resolver is a sorted slice and not a hash map.
    key: u64,
    action: *const types.Action,
};

pub const KeybindResolver = struct {
    /// Sorted ascending by `key`, so lookup is a bisection with no hash state,
    /// no tombstones, and no per-rebuild rehashing. A config has tens of
    /// keybindings, so the O(log n) lookup is well under the constant the hash
    /// map's bucket probe actually cost.
    entries: std.ArrayListUnmanaged(DispatchEntry) = .empty,

    inline fn dispatchKey(modifiers: u16, keysym: u32) u64 {
        return (@as(u64, modifiers) << 32) | keysym;
    }

    /// Index of `key` in the sorted table, or null. Hand-rolled because
    /// `std.sort.binarySearch` searches whole elements, and what is ordered
    /// here is the `key` FIELD of each entry, not the entry itself.
    fn find(self: *const KeybindResolver, key: u64) ?usize {
        var lo: usize = 0;
        var hi: usize = self.entries.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = self.entries.items[mid].key;
            if (k == key) return mid;
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Rebuilds the dispatch table from scratch, warning when two bindings
    /// resolve to the same effective mods+keysym (the later one wins).
    pub fn rebuildDispatchMap(
        self: *KeybindResolver,
        keybindings: []types.Keybind,
        allocator: std.mem.Allocator,
    ) void {
        self.entries.clearRetainingCapacity();
        self.entries.ensureTotalCapacity(allocator, keybindings.len) catch |e| {
            log.warnOnErr(e, "keybind dispatch table build");
            return;
        };
        for (keybindings, 0..) |*kb, i| {
            const entry: DispatchEntry = .{
                .key = dispatchKey(kb.modifiers, kb.keysym),
                .action = &kb.action,
            };
            // Deduplicate on insert: a later binding with the same effective
            // key wins, which is what replacing the existing entry does. Done
            // on the (still short) slice rather than after sorting, so the
            // warning is reported once per shadowed binding in config order.
            if (self.find(entry.key)) |idx| {
                log.warn(
                    "Keybinding conflict: binding #{} (mods=0x{x:0>4} " ++
                        "keysym=0x{x}) is shadowed; a later binding with the " ++
                        "same key wins",
                    .{ i + 1, kb.modifiers, kb.keysym },
                );
                self.entries.items[idx] = entry;
                continue;
            }
            self.entries.appendAssumeCapacity(entry);
            std.sort.heap(
                DispatchEntry,
                self.entries.items,
                {},
                entryLessThan,
            );
        }
    }

    /// O(log n) keybinding lookup for use on the hot key-press path.
    /// Returns a pointer into the current config's keybindings slice, or null.
    pub inline fn lookup(self: *const KeybindResolver, mods: u16, keysym: u32) ?*const types.Action {
        const idx = self.find(dispatchKey(mods, keysym)) orelse return null;
        return self.entries.items[idx].action;
    }

    /// Releases the dispatch table. Called before the keybindings whose Actions
    /// this table's entries point into are freed.
    pub fn deinit(self: *KeybindResolver, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.entries = .empty;
    }
};

/// Resolves each binding's keysym to a keycode, reporting (once, via
/// `reportUnresolved`) keysyms with no base keycode -- shifted symbols must be
/// bound via their unshifted key name.
/// One keybinding with its keycode resolved against the live XKB state.
pub const ResolvedBind = struct {
    modifiers: u16,
    keysym: u32,
    /// Null when the keysym has no base keycode on this keyboard.
    keycode: ?u8,
};

/// Resolve every keybinding against `state`, WITHOUT writing the derived
/// keycode back into the config.
///
/// The keycode used to be stored in `types.Keybind.keycode`, which made a
/// derived value look like authored config: it survived a reload that changed
/// the keyboard, it was part of a struct the parser does not produce, and
/// "did this binding resolve" became a question about a nullable field in
/// shared config state rather than about the resolution itself. The resolver
/// now returns what it derived and the grab path consumes that.
pub fn resolveKeycodes(
    keybindings: []const types.Keybind,
    state: *xkbcommon.XkbState,
    out: []ResolvedBind,
) []ResolvedBind {
    var n: usize = 0;
    for (keybindings) |kb| {
        if (n == out.len) break; // caller sized the buffer from the binding count
        out[n] = .{
            .modifiers = kb.modifiers,
            .keysym = kb.keysym,
            .keycode = state.keysymToKeycode(kb.keysym),
        };
        n += 1;
    }
    return out[0..n];
}

/// Log the bindings that resolved to nothing, ONCE per resolve rather than once
/// per binding. A config with a whole keyboard's worth of shifted-symbol
/// bindings used to produce one warning line per binding, which buries the one
/// line that matters.
pub fn reportUnresolved(resolved: []const ResolvedBind) void {
    var count: usize = 0;
    for (resolved) |r| {
        if (r.keycode != null) continue;
        if (count < 8) {
            // 64 bytes covers any XKB keysym name (longest is ~20 chars).
            var name_buf: [64]u8 = undefined;
            const name = keysyms.keysymGetName(r.keysym, &name_buf);
            log.warn(
                "Keybinding mods=0x{x:0>4} keysym={s} (0x{x}) resolves to no base " ++
                    "keycode and will NOT be grabbed, shifted symbols such as \"@\" " ++
                    "must be bound via their unshifted key name (e.g. \"2\")",
                .{ r.modifiers, name, r.keysym },
            );
        }
        count += 1;
    }
    if (count > 8) log.warn("... and {} further unresolvable keybindings", .{count - 8});
}
