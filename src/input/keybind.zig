//! Keybind resolution: keysym → keycode via live XKB state and
//! (modifiers, keysym) → Action dispatch map consumed on the hot key path.
//! Config owns parsed bindings (pure data, no X); keycode resolution requires
//! live XkbState, keeping the resolver in the input layer breaks the
//! types→xkbcommon→core→types cycle and leaves config X-free.

const std = @import("std");
const log = @import("log");
const types = @import("types");
const keysyms = @import("keysyms");
const xkbcommon = @import("xkbcommon");
const masks = @import("masks");

/// Orders the dispatch table by packed key, applied ONCE after the table is
/// built (see rebuildDispatchMap). The key is a u64 built as
/// (modifiers << 32) | keysym, so this is also a plain numeric order on the
/// whole entry.
fn entryLessThan(_: void, a: DispatchEntry, b: DispatchEntry) bool {
    return a.key < b.key;
}

/// Field comparator for the lookup, where what is ordered is each entry's `key`
/// FIELD rather than the entry. `find` was hand-rolled for years on the
/// grounds that binarySearch only searches whole elements; std.sort.binarySearch
/// has taken a per-element Order-returning fn since 0.16, so that reason is
/// gone. entryLessThan is not reusable here: std.sort.heap wants a
/// lessFn(context, a, b) bool, binarySearch wants an Order fn.
fn byKey(key: u64, e: DispatchEntry) std.math.Order {
    return std.math.order(key, e.key);
}

/// One-line report for a binding that can never fire because an earlier one
/// already claims the same (modifiers, trigger). Shared by the keyboard and
/// mouse tables so the two paths cannot drift: the keyboard path reported
/// conflicts and let the later entry win, while the mouse scan silently took
/// the FIRST match, so the same config mistake was a warning on one trigger
/// and silence on the other.
///
/// `trigger_label`/`trigger` are the trigger's own description ("keysym" and a
/// keysym, "button" and a button number); both are printed as hex because
/// keysyms are conventionally hex and button numbers read the same way.
pub fn logShadowConflict(
    comptime table: []const u8,
    index: usize,
    modifiers: u16,
    comptime trigger_label: []const u8,
    trigger: u32,
) void {
    log.warn(
        "{s} conflict: binding #{} (mods=0x{x:0>4} " ++
            trigger_label ++
            "=0x{x}) is shadowed; a later binding with the " ++
            "same trigger wins",
        .{ table, index + 1, modifiers, trigger },
    );
}

/// One dispatchable binding: the packed dispatch key plus where the action
/// lives in the current config's keybindings slice.
const DispatchEntry = struct {
    /// High 32 bits modifiers, low 32 keysym. One u64 compare orders the whole
    /// table, which is why the resolver is a sorted slice and not a hash map.
    key: u64,
    action: *const types.Action,
};

/// Owns the (modifiers, keysym) -> Action dispatch map resolved from a
/// config's keybindings.
/// Module-owned by `input` (not embedded in Config) so the config layer stays
/// X-free; `input.deinitKeybinds` tears it down before the Actions its entries
/// point into are freed.
pub const KeybindResolver = struct {
    /// Sorted ascending by `key`, so lookup is a bisection with no hash state,
    /// no tombstones, and no per-rebuild rehashing. A config has tens of
    /// keybindings, so the O(log n) lookup is well under the constant the hash
    /// map's bucket probe actually cost.
    entries: std.ArrayListUnmanaged(DispatchEntry) = .empty,
    /// The `core.config.rev()` these entries were built from. Every entry
    /// holds a `*const types.Action` INTO the live config's keybindings slice,
    /// and `core.replaceOwnedConfig` frees that box at the next reload, so a
    /// map that outlives its config is a use-after-free waiting for the next
    /// matching keystroke. The ordering contract (rebuild before the swap
    /// frees, tear down before shutdown) is real but unenforced; this makes it
    /// mechanical. A mismatch is reported once and the lookup fails closed,
    /// because a keybinding that does nothing is recoverable and a stale
    /// dereference is not.
    config_rev: u32 = 0,
    /// Set after the first stale-generation report so a per-keystroke
    /// mismatch cannot turn into a per-keystroke log line.
    stale_reported: bool = false,

    inline fn dispatchKey(modifiers: u16, keysym: u32) u64 {
        return (@as(u64, modifiers) << 32) | keysym;
    }

    /// Index of `key` in the sorted table, or null.
    fn find(self: *const KeybindResolver, key: u64) ?usize {
        return std.sort.binarySearch(DispatchEntry, self.entries.items, key, byKey);
    }

    /// Rebuilds the dispatch table from scratch, warning when two bindings
    /// resolve to the same effective mods+keysym (the later one wins).
    pub fn rebuildDispatchMap(
        self: *KeybindResolver,
        keybindings: []types.Keybind,
        allocator: std.mem.Allocator,
        config_rev: u32,
    ) void {
        // Recorded even when the build below fails: an empty map is still a
        // map of THIS generation, and claiming otherwise would report a
        // mismatch the caller cannot act on.
        self.config_rev = config_rev;
        self.stale_reported = false;
        self.entries.clearRetainingCapacity();
        self.entries.ensureTotalCapacity(allocator, keybindings.len) catch |e| {
            log.warnOnErr(e, "keybind dispatch table build");
            return;
        };
        // Dedup FIRST, in config order (so each shadowed binding is reported
        // once, where the reader of the config sees it), then sort ONCE. The
        // scan is O(n^2) over a slice that holds tens of bindings, and it
        // replaces the old append-then-re-sort-per-entry, which re-ordered the
        // half-built table on every insert.
        for (keybindings, 0..) |*kb, i| {
            const entry: DispatchEntry = .{
                .key = dispatchKey(kb.modifiers, kb.keysym),
                .action = &kb.action,
            };
            // A later binding with the same effective key wins, which is what
            // replacing the existing entry does.
            var shadowed: ?usize = null;
            for (self.entries.items, 0..) |e, j| {
                if (e.key == entry.key) {
                    shadowed = j;
                    break;
                }
            }
            if (shadowed) |idx| {
                logShadowConflict("Keybinding", i, kb.modifiers, "keysym", kb.keysym);
                self.entries.items[idx] = entry;
                continue;
            }
            self.entries.appendAssumeCapacity(entry);
        }
        std.sort.heap(DispatchEntry, self.entries.items, {}, entryLessThan);
    }

    /// O(log n) keybind lookup for use on the hot key-press path.
    /// Returns a pointer into the current config's keybindings slice, or null.
    /// `mods` is a `BindingMods`, not a raw X modifier state: the table is
    /// keyed by masked masks, so an unmasked value would be a silent
    /// never-match.
    pub inline fn lookup(
        self: *const KeybindResolver,
        mods: masks.BindingMods,
        keysym: u32,
        live_config_rev: u32,
    ) ?*const types.Action {
        if (self.config_rev != live_config_rev) return self.reportStale(live_config_rev);
        const idx = self.find(dispatchKey(masks.toMask(mods), keysym)) orelse return null;
        return self.entries.items[idx].action;
    }

    /// Once-only warning for a map built against a config that has since been
    /// freed. Takes a const self but mutates the report latch, so the latch is
    /// a `*bool` local... which it is not, so this is the single mutable
    /// exception in an otherwise read-only lookup path, and it exists to keep
    /// a broken ordering from logging on every keypress.
    fn reportStale(self: *const KeybindResolver, live_config_rev: u32) ?*const types.Action {
        if (!self.stale_reported) {
            // The latch is written through a const pointer: safe because the
            // resolver is module-owned (`input.keybind_resolver`) and the
            // lookup is single-threaded on the event loop.
            const me: *KeybindResolver = @constCast(self);
            me.stale_reported = true;
            log.warn(
                "Keybind dispatch table is stale (built against config rev {}, " ++
                    "live is {}): keybindings are disabled for this generation. " ++
                    "input.buildKeybinds must run after every config load",
                .{ self.config_rev, live_config_rev },
            );
        }
        return null;
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

/// Resolve every keybinding against `state`, writing each resolved bind into
/// `out`, WITHOUT touching the derived keycode in the config.
///
/// The keycode is deliberately not stored in `types.Keybind.keycode`: a
/// derived value in the config struct would survive a reload that changed the
/// keyboard and would look like authored config. The resolver derives it here
/// and the grab path consumes `out`.
pub fn resolveKeycodes(
    keybindings: []const types.Keybind,
    state: *const xkbcommon.XkbState,
    out: []ResolvedBind,
) void {
    // The caller sizes `out` from the binding count (input.zig reallocs to
    // keybindings.len one line earlier), so the zip is exact: a length
    // mismatch panics loudly rather than silently resolving a short list.
    for (keybindings, out) |kb, *dst| {
        dst.* = .{
            .modifiers = kb.modifiers,
            .keysym = kb.keysym,
            .keycode = state.keysymToKeycode(kb.keysym),
        };
    }
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
