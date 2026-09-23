//! Keybinding resolution: keysym -> keycode (via the live XKB state) plus the
//! (modifiers, keysym) -> Action dispatch map consumed on the hot key path.
//!
//! This lives in the input layer, not in `config/types`: config owns the
//! *parsed* bindings (pure data, no X), while turning a keysym into a keycode
//! needs a live `XkbState`. Keeping the resolver here breaks the
//! `types -> xkbcommon -> core -> types` import cycle and leaves the config
//! layer X-free.

const std = @import("std");
const debug = @import("debug");
const types = @import("types");
const keysyms = @import("keysyms");
const xkbcommon = @import("xkbcommon");

/// Owns the (modifiers, keysym) -> Action dispatch map resolved from a
/// config's keybindings, plus the keycode-resolution step that feeds it.
/// Module-owned by `input` (not embedded in Config) so the config layer stays
/// X-free; `input.deinitKeybinds` tears it down before the Actions its entries
/// point into are freed.
pub const KeybindResolver = struct {
    map: std.AutoHashMapUnmanaged(u64, *const types.Action) = .empty,

    inline fn dispatchKey(modifiers: u16, keysym: u32) u64 {
        return (@as(u64, modifiers) << 32) | keysym;
    }

    /// Rebuilds the dispatch map from scratch, warning when two bindings
    /// resolve to the same effective mods+keysym (the later one wins).
    pub fn rebuildDispatchMap(
        self: *KeybindResolver,
        keybindings: []types.Keybind,
        allocator: std.mem.Allocator,
    ) void {
        self.map.clearRetainingCapacity();
        for (keybindings, 0..) |*kb, i| {
            const key = dispatchKey(kb.modifiers, kb.keysym);
            if (self.map.contains(key))
                debug.warn(
                    "Keybinding conflict: binding #{} (mods=0x{x:0>4} " ++
                        "keysym=0x{x}) is shadowed; a later binding with the " ++
                        "same key wins",
                    .{ i + 1, kb.modifiers, kb.keysym },
                );
            self.map.put(allocator, key, &kb.action) catch |e|
                debug.warnOnErr(e, "keybind map build");
        }
    }

    /// O(1) keybinding lookup for use on the hot key-press path.
    /// Returns a pointer into the current config's keybindings slice, or null.
    pub inline fn lookup(self: *const KeybindResolver, mods: u16, keysym: u32) ?*const types.Action {
        return self.map.get(dispatchKey(mods, keysym));
    }

    /// Releases the dispatch map. Called before the keybindings whose Actions
    /// this map's entries point into are freed.
    pub fn deinit(self: *KeybindResolver, allocator: std.mem.Allocator) void {
        self.map.deinit(allocator);
        self.map = .empty;
    }
};

/// Resolves each binding's keysym to a keycode in place, warning for keysyms
/// with no base keycode (shifted symbols must be bound via their unshifted
/// key name).
pub fn resolveKeycodes(keybindings: []types.Keybind, state: *xkbcommon.XkbState) void {
    for (keybindings) |*kb| {
        kb.keycode = state.keysymToKeycode(kb.keysym);
        if (kb.keycode == null) {
            var name_buf: [64]u8 = undefined;
            const name = keysyms.keysymGetName(kb.keysym, &name_buf);
            debug.warn(
                "Keybinding mods=0x{x:0>4} keysym={s} (0x{x}) resolves to no base " ++
                    "keycode and will NOT be grabbed, shifted symbols such as \"@\" " ++
                    "must be bound via their unshifted key name (e.g. \"2\")",
                .{ kb.modifiers, name, kb.keysym },
            );
        }
    }
}
