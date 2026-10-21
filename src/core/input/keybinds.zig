//! Keybinds: resolution (keysym -> keycode against the live keyboard), the
//! (modifiers, keysym) -> Action dispatch map read on every keypress, and the
//! root-window grabs that make both reachable. Three concerns unified because they
//! share one lifecycle: build the binds, grab them, tear them down.
//!
//! Wire traffic: the keybind and Super+Button grab installations and their flushes.
//! Grabs are installed at startup and re-installed on config reload and
//! keyboard-mapping change (lifecycle, not per-window mutation), which is why this
//! file carries its own allowlist entry in check-layers.sh.
const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const types = @import("types");
const masks = @import("masks");
const log = std.log.scoped(.keybinds);
const keymap = @import("keymap");
const xkb = @import("xkb");

// The (modifiers, keysym) -> Action dispatch map. Owned here, not by Config, to keep
// the pure config layer X-free (see the rationale on KeybindResolver). Rebuilt on
// startup and every config reload; the entries borrow `*const Action` pointers from
// the live config's keybindings.
var keybind_resolver: KeybindResolver = .{};
var resolved_binds: []ResolvedBind = &.{};
// Two derived views of the same config bindings, deliberately not merged into one
// array: `resolved_binds` is the KEYCODE view (config order, derived from the live XKB
// state, read by the grab path and the unresolved-keysym report) and the resolver's
// entries are the DISPATCH view (sorted by packed key, no keycode, read on every
// keypress). Merging them would make keycode resolution and dispatch building share one
// buffer and one failure path; today a failed realloc keeps the previous grabs working
// while a failed dispatch build fails closed to save one allocation. Two lists, one
// source, no fact stored twice.

/// Resolves `keybindings` against the live XKB state and rebuilds the dispatch map.
/// Call once at startup (after `initXkb` and config load) and again on every config
/// reload with the new config's keybindings. No-op without XKB.
pub fn buildKeybinds(keybindings: []types.Keybind) void {
    const state = xkb.getXkbState() orelse return;
    const alloc = core.getState().alloc;
    // The compiled list lives here, not in config: it is derived from the live keyboard
    // and `grabKeybindings` needs it on every regrab (even reloads that did not change
    // the bindings). One path for keyboard and binding changes.
    resolved_binds = alloc.realloc(resolved_binds, keybindings.len) catch |err| {
        // Do NOT clobber resolved_binds on failure: the old allocation is the only copy,
        // and overwriting it would leak it and silently empty the compiled list -> the
        // next keypress grabs nothing until a keymap event.
        log.warn("buildKeybinds: realloc for {} bindings failed ({}); keeping the old set", .{ keybindings.len, err });
        return;
    };
    resolveKeycodes(keybindings, state, resolved_binds);
    reportUnresolved(resolved_binds);
    keybind_resolver.rebuildDispatchMap(keybindings, alloc, core.config_rev.rev());
}

/// The keybindings with keycodes resolved against the live XKB state, for
/// `grabKeybindings`. Empty when XKB is unavailable (no keyboard to resolve against),
/// which is also when nothing can be grabbed.
pub fn resolvedKeybinds() []const ResolvedBind {
    return resolved_binds;
}

/// Releases the dispatch map AND the compiled keybind list. Call before the config
/// whose keybindings the entries point into is freed (shutdown). The `len != 0` guard
/// is not cosmetic: the initial value is a `&.{}` pointing at a static empty slice.
pub fn deinitKeybinds() void {
    const alloc = core.getState().alloc;
    keybind_resolver.deinit(alloc);
    if (resolved_binds.len != 0) {
        alloc.free(resolved_binds);
        resolved_binds = &.{};
    }
}

/// Rebuilds the keymap/keysym table after the server changes the keyboard mapping
/// (setxkbmap/xmodmap). `keyboard` is the event's `request` field narrowed to
/// MappingKeyboard; false for the modifier-map and pointer remaps. Keybind resolution is
/// keysym-indexed, so the rebuild keeps existing bindings working -- but the per-binding
/// keycodes the grabs were taken with go stale; re-resolve them from the rebuilt table.
/// Returns true when the keycodes changed under it (caller must re-grab).
pub fn handleMappingNotify(keyboard: bool) bool {
    if (!xkb.rebuildKeymap(keyboard)) return false;
    const cs = core.getState();

    // `buildKeybinds` is the single producer of the list, so a mapping change cannot
    // leave the grab path reading a list resolved against the old keyboard. The regrab
    // is the CALLER's step (core/loop events.zig), right after this.
    buildKeybinds(cs.config.core.keybindings.items);
    return true;
}

/// O(log n) dispatch lookup for the hot key-press path (keys.zig): packs the
/// (modifiers, keysym) pair the same way `rebuildDispatchMap` sorted it and validates
/// the result against the live config revision. Returns a pointer into the current
/// config's keybindings slice, or null.
pub fn lookupAction(
    mods: masks.BindingMods,
    keysym: u32,
    live_config_rev: u32,
) ?*const types.Action {
    return keybind_resolver.lookup(mods, keysym, live_config_rev);
}

/// Orders the dispatch table by packed key, applied ONCE after the table is built
/// (see rebuildDispatchMap). The key is a u64 built as (modifiers << 32) | keysym, so
/// this is also a plain numeric order on the entry.
fn entryLessThan(_: void, a: DispatchEntry, b: DispatchEntry) bool {
    return a.key < b.key;
}

/// Field comparator for the lookup: binarySearch orders each entry's `key` FIELD, and
/// entryLessThan is not reusable because heap wants a lessFn(context, a, b) bool.
fn byKey(key: u64, e: DispatchEntry) std.math.Order {
    return std.math.order(key, e.key);
}

/// One-line report for a binding that can never fire because an earlier one already
/// claims the same (modifiers, trigger). Shared by the keyboard and mouse tables so the
/// two paths cannot drift. `trigger_label`/`trigger` are the trigger's own description;
/// both print as hex.
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

/// One dispatchable binding: the packed dispatch key plus where the action lives in
/// the current config's keybindings slice.
const DispatchEntry = struct {
    /// High 32 bits modifiers, low 32 keysym. One u64 compare orders the whole table,
    /// which is why the resolver is a sorted slice, not a hash map.
    key: u64,
    action: *const types.Action,
};

/// Owns the (modifiers, keysym) -> Action dispatch map resolved from a config's
/// keybindings. Module-owned (not embedded in Config) so the config layer stays X-free.
pub const KeybindResolver = struct {
    /// Sorted ascending by `key`, so lookup is a bisection with no hash state, no
    /// tombstones, no per-rebuild rehashing. A config has tens of keybindings, so the
    /// O(log n) lookup is well under a hash map's bucket-probe constant.
    entries: std.ArrayListUnmanaged(DispatchEntry) = .empty,
    /// The `core.config.rev()` these entries were built from. Every entry holds a
    /// `*const types.Action` INTO the live config's keybindings slice, and
    /// `core.replaceOwnedConfig` frees that box at the next reload, so a map that outlives
    /// its config is a use-after-free. A mismatch is reported once and the lookup fails
    /// closed: a keybinding that does nothing is recoverable, a stale dereference is not.
    config_rev: u32 = 0,
    /// Set after the first stale-generation report so a per-keystroke mismatch cannot
    /// turn into a per-keystroke log line.
    stale_reported: bool = false,

    inline fn dispatchKey(modifiers: u16, keysym: u32) u64 {
        return (@as(u64, modifiers) << 32) | keysym;
    }

    /// Index of `key` in the sorted table, or null.
    fn find(self: *const KeybindResolver, key: u64) ?usize {
        return std.sort.binarySearch(DispatchEntry, self.entries.items, key, byKey);
    }

    /// Rebuilds the dispatch table from scratch, warning when two bindings resolve to
    /// the same effective mods+keysym (the later one wins).
    pub fn rebuildDispatchMap(
        self: *KeybindResolver,
        keybindings: []types.Keybind,
        allocator: std.mem.Allocator,
        config_rev: u32,
    ) void {
        // Recorded even when the build below fails: an empty map is still a map of THIS
        // generation, and claiming otherwise would report a mismatch the caller cannot
        // act on.
        self.config_rev = config_rev;
        self.stale_reported = false;
        self.entries.clearRetainingCapacity();
        self.entries.ensureTotalCapacity(allocator, keybindings.len) catch |e| {
            log.warn("Best-effort op failed (keybind dispatch table build): {}", .{e});
            return;
        };
        // Dedup FIRST, in config order (so each shadowed binding is reported once, where
        // the reader of the config sees it), then sort ONCE. O(n^2) over a slice of tens
        // of bindings.
        for (keybindings, 0..) |*kb, i| {
            const entry: DispatchEntry = .{
                .key = dispatchKey(kb.modifiers, kb.keysym),
                .action = &kb.action,
            };
            // A later binding with the same effective key wins: replacing the existing
            // entry does exactly that.
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

    /// O(log n) keybind lookup for the hot key-press path. Returns a pointer into the
    /// current config's keybindings slice, or null. `mods` is a `BindingMods`, not a
    /// raw X modifier state: the table is keyed by masked masks, so an unmasked value
    /// would be a silent never-match.
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

    /// Once-only warning for a map built against a config that has since been freed. The
    /// single mutable exception in an otherwise read-only lookup path, existing so a
    /// broken ordering cannot log on every keypress.
    fn reportStale(self: *const KeybindResolver, live_config_rev: u32) ?*const types.Action {
        if (!self.stale_reported) {
            // Safe through a const pointer: the resolver is module-owned and the lookup
            // is single-threaded on the event loop.
            const me: *KeybindResolver = @constCast(self);
            me.stale_reported = true;
            log.warn(
                "Keybind dispatch table is stale (built against config rev {}, " ++
                    "live is {}): keybindings are disabled for this generation. " ++
                    "keybinds.buildKeybinds must run after every config load",
                .{ self.config_rev, live_config_rev },
            );
        }
        return null;
    }

    /// Releases the dispatch table. Called before the keybindings whose Actions this
    /// table's entries point into are freed.
    pub fn deinit(self: *KeybindResolver, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
        self.entries = .empty;
    }
};

/// One keybinding with its keycode resolved against the live XKB state. Shifted
/// symbols must be bound via their unshifted key name (reported once, via
/// `reportUnresolved`).
pub const ResolvedBind = struct {
    modifiers: u16,
    keysym: u32,
    /// Null when the keysym has no base keycode on this keyboard.
    keycode: ?u8,
};

/// Resolve every keybinding against `state`, writing each resolved bind into `out`,
/// WITHOUT touching the derived keycode in the config. The keycode is deliberately not
/// stored in `types.Keybind.keycode`: a derived value would survive a reload that
/// changed the keyboard and would look like authored config.
pub fn resolveKeycodes(
    keybindings: []const types.Keybind,
    state: *const xkb.XkbState,
    out: []ResolvedBind,
) void {
    // The caller sizes `out` from the binding count, so the zip is exact: a length
    // mismatch panics loudly rather than silently resolving a short list.
    for (keybindings, out) |kb, *dst| {
        dst.* = .{
            .modifiers = kb.modifiers,
            .keysym = kb.keysym,
            .keycode = state.keysymToKeycode(kb.keysym),
        };
    }
}

/// Log the bindings that resolved to nothing, ONCE per resolve rather than once per
/// binding -- a whole keyboard's worth of shifted-symbol bindings would otherwise bury
/// the one line that matters.
pub fn reportUnresolved(resolved: []const ResolvedBind) void {
    var count: usize = 0;
    for (resolved) |r| {
        if (r.keycode != null) continue;
        if (count < 8) {
            // 64 bytes covers any XKB keysym name (longest ~20 chars).
            var name_buf: [64]u8 = undefined;
            const name = keymap.keysymGetName(r.keysym, &name_buf);
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

/// Upper bound for the XCB cookie scratch buffer in grabKeybindings (max distinct
/// keybindings x lock_modifiers.len combinations). Unmeasured but DERIVED: 8
/// lock-modifier combos x 128 keybindings = 1024. Raise if you ever exceed 128
/// keybindings.
const max_keybind_cookies = 1024;

const CookieEntry = struct { cookie: xcb.xcb_void_cookie_t, keycode: u8 };

/// Failures detail-logged individually before the "N further ..." tail.
const cap_detail: usize = 4;

/// One grab-failure log policy for both grab paths: name the first `cap_detail`
/// failures, then summarize the rest in one line.
const FailureReporter = struct {
    failed: usize = 0,

    /// Count a failure; true = the caller should log this one.
    fn detail(self: *FailureReporter) bool {
        self.failed += 1;
        return self.failed <= cap_detail;
    }

    /// The "N further ..." tail, only when anything was capped.
    fn tail(self: *const FailureReporter, comptime what: []const u8) void {
        if (self.failed > cap_detail)
            log.warn("{} further {s} failed", .{ self.failed - cap_detail, what });
    }
};

fn fillGrabCookies(cookies: []CookieEntry, resolved: []const ResolvedBind) usize {
    var n: usize = 0;
    const cs = core.getState();
    // The caller's compiled list, not cs.config.keybindings: keycodes are derived from
    // the live keyboard and deliberately not stored in config.
    for (resolved) |kb| {
        const keycode = kb.keycode orelse continue;

        // Check once per keybinding that the full lock-modifier set fits: avoids a
        // per-lock branch and prevents partial grabs when the buffer is nearly full.
        if (n + masks.lock_modifiers.len > cookies.len) {
            log.warn(
                "Too many keybindings. Increase max_keybind_cookies (currently {})",
                .{max_keybind_cookies},
            );
            break;
        }

        for (masks.lock_modifiers) |lock| {
            cookies[n] = .{
                .cookie = xcb.xcb_grab_key_checked(
                    cs.conn,
                    0,
                    cs.root,
                    @intCast(kb.modifiers | lock),
                    keycode,
                    xcb.XCB_GRAB_MODE_ASYNC,
                    xcb.XCB_GRAB_MODE_ASYNC,
                ),
                .keycode = keycode,
            };
            n += 1;
        }
    }
    return n;
}

fn checkGrabCookies(cookies: []const CookieEntry) void {
    const conn = core.getState().conn;
    var reporter: FailureReporter = .{};
    for (cookies) |entry| {
        if (xcb.xcb_request_check(conn, entry.cookie)) |err| {
            std.c.free(err);
            if (reporter.detail()) log.warn("Failed to grab keycode: {}", .{entry.keycode});
        }
    }
    reporter.tail("keybind grab");
}

/// The root-window mouse grab, as data. `mouse.zig` builds this from the very tables
/// `grabMouseButtons` iterates, so the grab and the reachability rule cannot drift
/// apart; the rule below stays pure and unit-testable without X.
pub const MouseGrabSpec = struct {
    /// Button numbers the grab covers.
    buttons: []const u8,
    /// The non-lock modifier the grab is taken with (Super).
    modifiers: u16,
    /// Lock bits, taken in every combination by the grab and masked off by
    /// `normalizeModifiers` before dispatch, so they can neither make a bind reachable
    /// nor unreachable.
    lock_bits: u16,
};

/// The buttons the root mouse grab covers, in grab order: the table
/// `grabMouseButtons` fires, the spec `mouse.zig`'s report builds, and the reachability
/// rule below judges -- one home so all three cannot drift.
pub const mouse_grab_buttons = [_]u8{
    masks.mouse_button_left,
    masks.mouse_button_middle,
    masks.mouse_button_right,
    masks.mouse_button_scroll_up,
    masks.mouse_button_scroll_down,
};

/// Why `mb` can never be delivered by `grab`, or null when it can. The two unreachable
/// shapes: a button the grab does not cover, and a modifier the grab does not take. The
/// worst failure mode a config surface has -- the bind loads, the config looks valid,
/// the key does nothing -- so it is reported rather than left to discovery.
pub fn undeliverableMouseBindReason(mb: types.MouseBind, grab: MouseGrabSpec) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, grab.buttons, mb.button) == null) {
        return "the root grab covers Button1-5 only";
    }
    if (mb.modifiers & ~grab.lock_bits & ~grab.modifiers != 0)
        return "the root grab is taken with Super+Button only, with no other modifier";
    if (mb.modifiers & grab.modifiers == 0)
        return "the root grab is taken with Super held";
    return null;
}

/// The label that names a mouse grab in a failure message.
const MouseGrabLabel = struct { button: u8, lock: u16 };

/// One fired mouse-grab request with its failure label, kept in one value so a label
/// cannot desynchronize from its cookie (the key path pairs cookie with keycode the
/// same way, in `CookieEntry`).
const MouseGrab = struct {
    cookie: xcb.xcb_void_cookie_t,
    label: MouseGrabLabel,
};

/// Grabs Super+Button{1,2,3,4,5} (including the scroll buttons) on the root window
/// for every lock-modifier combination, checking each one.
///
/// Lives beside `grabKeybindings` and uses its discipline: each grab is verified, so a
/// failure (another client already holds Super+Button1) is reported with the button and
/// modifier that did not take.
pub fn grabMouseButtons() void {
    const cs = core.getState();
    var grabs: [mouse_grab_buttons.len * masks.lock_modifiers.len]MouseGrab = undefined;
    var n: usize = 0;
    for (mouse_grab_buttons) |button| {
        for (masks.lock_modifiers) |lock| {
            grabs[n] = .{
                .cookie = xcb.xcb_grab_button(
                    cs.conn,
                    0,
                    cs.root,
                    xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                        xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                        xcb.XCB_EVENT_MASK_POINTER_MOTION,
                    xcb.XCB_GRAB_MODE_SYNC,
                    xcb.XCB_GRAB_MODE_SYNC,
                    cs.root,
                    xcb.XCB_NONE,
                    button,
                    @intCast(masks.mod_super | lock),
                ),
                .label = .{ .button = button, .lock = lock },
            };
            n += 1;
        }
    }
    // Fire every cookie before reading any reply -- same round-trip discipline as the
    // key grabs.
    var reporter: FailureReporter = .{};
    for (grabs[0..n]) |grab| {
        if (xcb.xcb_request_check(cs.conn, grab.cookie)) |err| {
            std.c.free(err);
            if (reporter.detail()) log.warn(
                "Failed to grab Super+Button{d}{s} on the root window; " ++
                    "another client is holding it, so that mouse binding will not fire",
                .{ grab.label.button, if (grab.label.lock == 0) "" else " (with a lock modifier held)" },
            );
        }
    }
    reporter.tail("mouse grab");
    _ = xcb.xcb_flush(cs.conn);
}

/// Ungrabs all keys, then re-grabs every configured keybinding across all lock
/// modifier combinations. Fires all grab cookies before reading any reply to reduce
/// round-trips. `resolved` is the caller's snapshot from `resolvedKeybinds()`; taking
/// it as an argument is what keeps this file free of the input import.
pub fn grabKeybindings(resolved: []const ResolvedBind) void {
    const cs = core.getState();
    _ = xcb.xcb_ungrab_key(cs.conn, xcb.XCB_GRAB_ANY, cs.root, xcb.XCB_MOD_MASK_ANY);

    var cookies: [max_keybind_cookies]CookieEntry = undefined;
    const n = fillGrabCookies(&cookies, resolved);

    checkGrabCookies(cookies[0..n]);

    _ = xcb.xcb_flush(cs.conn);
}
