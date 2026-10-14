//! Shared X11-backed integration fixture for the window/pipeline layer tests
//! (src/test/window/actions_test.zig, src/test/window/focus_test.zig,
//! src/test/engine/pipeline_test.zig).
//!
//! Each test process connects to the running X server ($DISPLAY). When no
//! server is reachable, or when a live window manager owns the display,
//! `connect()` returns null and the test self-passes as a silent skip (a
//! banner is only printed when stdout is a real terminal), so `zig build
//! test` stays green on headless machines and never draws onto a running
//! session.
//! Everything here goes through the real public boot entry points
//! (atoms.initAtomCache / core.init / window.init / pipeline.init) -- this
//! fixture adds no test-only behavior to src/*.
//!
//! Windows are created as real (unmanaged) top-levels with
//! `xcb_create_window` so the WM's map/focus/configure requests always target
//! live, valid windows (hana is a non-reparenting WM; the fixture windows are
//! just never registered for WM selection).

const std = @import("std");

const core = @import("core");
const xcb = core.xcb;
const build_options = @import("build_options");
const types = @import("types");
const model = @import("model");
const pipeline = @import("pipeline");
const window = @import("window");
const atoms = @import("atoms");
const usable_area = @import("usable_area");
const constants = @import("constants");
const tiling = if (build_options.has_tiling) @import("tiling") else @import("std");
const helpers = @import("helpers");

/// Bounded placement buffer width, mirroring the engine's own cap.
const ledger = @import("ledger");
pub const max_order = constants.max_tiled_windows;

/// Why the fixture refused to connect, so setUp can pick the right banner.
const SkipReason = enum { no_x, live_wm };

/// Set by Fx.connect before it returns null; kept per-process.
var g_skip_reason: SkipReason = .no_x;

/// Best-effort stdout write for skip banners. Goes to stdout rather than
/// stderr on purpose: Zig's build runner prints `failed command: <cmd>` for
/// any test that writes to stderr, even when it passes. When the runner
/// drives this binary, stdout is a `--listen=-` protocol pipe rather than a
/// terminal, and writing banner text into it would corrupt that stream (the
/// harness stalls waiting for its protocol reply), so the write only happens
/// for a manually-run binary attached to a real terminal.
fn printStdout(comptime fmt: []const u8, args: anytype) void {
    const io = std.Options.debug_io;
    if (!(std.Io.File.isTty(std.Io.File.stdout(), io) catch false)) return;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
}

/// Connects the per-process fixture, or returns `error.SkipZigTest` when no X
/// display is reachable -- or when a live window manager owns the display (the
/// fixture's real top-level windows would flicker as garbage on that WM's
/// screen, so it refuses to draw onto a running session). `name` names the test
/// in the SKIP banner.
///
/// (28.4) The skip is a real `error.SkipZigTest` rather than a null the caller
/// turns into `orelse return`. The old shape made a skip a SILENT PASS: the
/// test reported green to the runner and to any CI reading the log, so a run in
/// which the entire integration layer never executed looked identical to a run
/// in which it did. Zig's runner reports `error.SkipZigTest` as a SKIP, so the
/// missing coverage becomes visible in the summary instead of hiding inside a
/// pass.
///
/// HANA_REQUIRE_X still turns a skip into a hard failure, but it is now ONE
/// check rather than a duplicated panic branch per skip reason: the reason
/// decides only the message, and the requirement decides whether to abort.
/// Callers write `try fixture.setUp("name")`.
pub fn setUp(name: []const u8) error{SkipZigTest}!*Fx {
    const fx = Fx.connect(std.testing.allocator) orelse {
        switch (g_skip_reason) {
            .live_wm => printStdout(
                "SKIP: {s}: $DISPLAY is owned by a live window manager. These tests create real windows.\n",
                .{name},
            ),
            .no_x => printStdout(
                "SKIP: {s}: no X display reachable -- set HANA_REQUIRE_X=1 to make this a hard failure.\n",
                .{name},
            ),
        }
        if (std.c.getenv("HANA_REQUIRE_X") != null) {
            std.debug.panic("HANA_REQUIRE_X is set but '{s}' cannot run: {s}", .{
                name,
                @tagName(g_skip_reason),
            });
        }
        return error.SkipZigTest;
    };
    return fx;
}

/// A test-owned transition-layer gate: gives the reset path a mutable model
/// (model.unregister) without touching src/* production code.
var gate: pipeline.Gate = .{};

fn mutModel() *model.Model {
    return pipeline.mut(&gate);
}

/// Server-reported window geometry. X11 sizes include the border, so
/// `width`/`height` are the outer footprint like the engine's placements.
pub const Geometry = struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16,
};

/// Reads the `_NET_SUPPORTING_WM_CHECK` property of `win` as a window id, or
/// null when the property is absent/empty.
fn wmCheckWindow(conn: core.Connection, win: u32) ?u32 {
    const atom = atoms.getAtomCached("_NET_SUPPORTING_WM_CHECK") orelse return null;
    const reply = xcb.xcb_get_property_reply(
        conn,
        xcb.xcb_get_property(conn, 0, win, atom, 0, 0, 1),
        null,
    ) orelse return null;
    defer std.c.free(reply);
    if (reply.*.format != 32 or reply.*.value_len == 0) return null;
    const vals: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
    return vals[0];
}

/// True when a live window manager owns this display. Per the EWMH spec a WM
/// points the root's `_NET_SUPPORTING_WM_CHECK` at a check window that echoes
/// the SAME value back; that self-confirmation is what tells a live WM from a
/// stale property a crashed WM left behind. Under a bare Xvfb (xtest.sh) the
/// property is absent, so tests proceed.
fn liveWmOwningDisplay(conn: core.Connection, root: u32) bool {
    const check_win = (wmCheckWindow(conn, root) orelse return false);
    if (check_win == 0) return false;
    const echo = (wmCheckWindow(conn, check_win) orelse return false);
    return echo == check_win;
}

/// A connected, boot-wired test environment over a live X server.
///
/// The connection is created ONCE per test process and re-used across tests:
/// pipeline's request sink (pipeline.g_sink) caches the connection for the
/// process lifetime, so a per-test reconnect would strand every reconcile on a
/// dead socket after the first test. Tests instead re-arm via `reset()`, which
/// drops prior windows and re-inits the model/ledger on the same connection.
pub const Fx = struct {
    conn: core.Connection,
    scr: *xcb.xcb_screen_t,
    root: u32,
    alloc: std.mem.Allocator,
    config: types.Config,

    var g_fx: ?*Fx = null;

    /// Connect to $DISPLAY and run the production boot wiring (atoms -> core
    /// -> window -> pipeline). Returns null when no X server is reachable
    /// (SKIP) or boot wiring fails (also SKIP: treat as no-X). The FIRST call
    /// per process performs the boot; later calls re-run the window-module
    /// init cycle and re-arm the model/ledger on the SAME connection (the
    /// request sink caches the connection for the process lifetime, so a
    /// per-test reconnect would strand every reconcile on a dead socket).
    pub fn connect(alloc: std.mem.Allocator) ?*Fx {
        if (g_fx) |fx| {
            window.init(alloc) catch return null;
            fx.reset();
            return fx;
        }
        const conn = xcb.xcb_connect(null, null) orelse return null;
        var connected = false;
        // Any early return below (server error, boot failure) tears the
        // connection down; the FIRST successful boot keeps it for the process
        // lifetime (the request sink caches it).
        errdefer {
            if (!connected) _ = xcb.xcb_disconnect(conn);
        }
        if (xcb.xcb_connection_has_error(conn) != 0) {
            return null;
        }
        const iter = xcb.xcb_setup_roots_iterator(xcb.xcb_get_setup(conn));
        const scr = iter.data orelse {
            return null;
        };

        atoms.initAtomCache(conn) catch {
            return null;
        };

        // Refuse to draw onto a live WM's screen: the fixture's top-levels are
        // real mapped windows, so running against the user's own session (a
        // second copy of hana, or any other WM) would flash them as on-screen
        // garbage. The repo's harness isolates these tests under its own Xvfb
        // (dev/scripts/xtest.sh); skip with a banner when a WM owns the
        // display instead.
        if (liveWmOwningDisplay(conn, scr.*.root)) {
            g_skip_reason = .live_wm;
            return null;
        }

        const fx = std.heap.page_allocator.create(Fx) catch {
            return null;
        };
        fx.* = .{ .conn = conn, .scr = scr, .root = scr.*.root, .alloc = alloc, .config = types.Config{} };

        // The baseline is what main would pass if the config had no [display]
        // dpi override: these tests are about window plumbing, not scaling.
        core.init(conn, scr, scr.*.root, alloc, &fx.config, constants.baseline_dpi);
        window.init(alloc) catch {
            std.heap.page_allocator.destroy(fx);
            return null;
        };
        pipeline.init();
        // Seed the config layout cycle in canonical order with the modules
        // actually compiled in — `cycleLayoutKind` cycles this list (a real
        // boot's parser seeds it from config; `types.Config{}` leaves it
        // empty). page_allocator: process-lifetime config, not leak-tracked.
        if (build_options.has_tiling) {
            inline for (helpers.std_layout_names) |c| {
                if (tiling.layoutByName(c)) |_| {
                    fx.config.tiling.layouts.append(std.heap.page_allocator, c) catch {};
                }
            }
        }
        g_fx = fx;
        connected = true;
        return fx;
    }

    /// Re-arm the environment for the next test: destroy any windows left from
    /// a previous test and re-init the model/ledger. Runs at every connect()
    /// (see above); the connection is kept for the process lifetime.
    pub fn reset(self: *Fx) void {
        const m = mutModel();
        while (m.store.count() > 0) {
            const win = m.store.at(m.store.count() - 1).key;
            _ = xcb.xcb_destroy_window(self.conn, win);
            model.unregister(m, win);
            ledger.forget(win);
        }
        self.flush();
        pipeline.init();
    }

    pub fn deinit(self: *Fx) void {
        // Free the current cycle's window-module state (workspaces, spawn
        // queue, rules map) so the test allocator sees a clean per-test
        // alloc/free ring. The connection and Fx are process-global and stay
        // alive; the next connect() re-runs window.init() on them.
        window.deinit();
        _ = self;
    }

    /// Current workspace work area (screen minus bar claims; none in tests).
    pub fn workArea(self: *const Fx) model.Rect {
        return usable_area.workArea(self.scr);
    }

    /// Creates a real, unmapped, unselected child top-level of the root.
    /// override_redirect protects the test's geometry/focus assertions from a
    /// foreign window manager running on the same $DISPLAY (the repo's own
    /// harness runs these under a dedicated Xvfb; this is defense in depth).
    pub fn createWindow(self: *const Fx) u32 {
        const win = xcb.xcb_generate_id(self.conn);
        const value_mask: u32 = xcb.XCB_CW_OVERRIDE_REDIRECT;
        const value_list = [_]u32{1}; // override_redirect = true
        _ = xcb.xcb_create_window(
            self.conn,
            self.scr.*.root_depth,
            win,
            self.root,
            0,
            0,
            1,
            1,
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            self.scr.*.root_visual,
            value_mask,
            &value_list,
        );
        return win;
    }

    pub fn flush(self: *const Fx) void {
        _ = xcb.xcb_flush(self.conn);
    }

    pub fn geometry(self: *const Fx, win: u32) ?Geometry {
        const reply = xcb.xcb_get_geometry_reply(
            self.conn,
            xcb.xcb_get_geometry(self.conn, win),
            null,
        ) orelse return null;
        defer std.c.free(reply);
        return .{
            .x = reply.*.x,
            .y = reply.*.y,
            .width = reply.*.width,
            .height = reply.*.height,
            .border_width = reply.*.border_width,
        };
    }

    pub fn isViewable(self: *const Fx, win: u32) bool {
        const reply = xcb.xcb_get_window_attributes_reply(
            self.conn,
            xcb.xcb_get_window_attributes(self.conn, win),
            null,
        ) orelse return false;
        defer std.c.free(reply);
        return reply.*.map_state == xcb.XCB_MAP_STATE_VIEWABLE;
    }

    pub fn inputFocus(self: *const Fx) u32 {
        const reply = xcb.xcb_get_input_focus_reply(
            self.conn,
            xcb.xcb_get_input_focus(self.conn),
            null,
        ) orelse return self.root;
        defer std.c.free(reply);
        return reply.*.focus;
    }

    /// Root's `_NET_ACTIVE_WINDOW` advertisement, or null when unset. The
    /// property's type is `XCB_ATOM_WINDOW` (production writes
    /// XCB_ATOM_WINDOW), so the read must filter by XCB_ATOM_ANY, not by the
    /// property's own name atom.
    pub fn rootActiveWindow(self: *const Fx) ?u32 {
        const atom = atoms.getAtomCached("_NET_ACTIVE_WINDOW") orelse return null;
        const reply = xcb.xcb_get_property_reply(
            self.conn,
            xcb.xcb_get_property(self.conn, 0, self.root, atom, 0, 0, 1),
            null,
        ) orelse return null;
        defer std.c.free(reply);
        if (reply.*.format != 32 or reply.*.value_len == 0) return null;
        const vals: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        return vals[0];
    }

    /// WM_PROTOCOLS = [WM_TAKE_FOCUS, WM_DELETE_WINDOW] (input=True +
    /// WM_TAKE_FOCUS -> ICCCM locally_active).
    pub fn setWmTakeFocus(self: *const Fx, win: u32) void {
        const wm_protocols = atoms.getAtomCached("WM_PROTOCOLS") orelse return;
        const take = atoms.getAtomCached("WM_TAKE_FOCUS") orelse return;
        const del = atoms.getAtomCached("WM_DELETE_WINDOW") orelse return;
        const list = [2]u32{ take, del };
        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            wm_protocols,
            xcb.XCB_ATOM_ATOM,
            32,
            list.len,
            &list,
        );
        self.flush();
    }

    /// WM_HINTS input=False -> ICCCM no_input input model.
    pub fn setNoInput(self: *const Fx, win: u32) void {
        const hints = [4]u32{ 1 << 0, 0, 0, 0 }; // flags: input hint present; input=false
        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            win,
            xcb.XCB_ATOM_WM_HINTS,
            xcb.XCB_ATOM_WM_HINTS,
            32,
            hints.len,
            &hints,
        );
        self.flush();
    }

    /// The geometry hana actually SENT for `win`, from the sync ledger --
    /// the sole "last thing sent" owner -- or null if nothing was sent.
    ///
    /// (28.8) This REPLACES an `expectedPlacementOf` that recomputed the
    /// placement by calling `tiling.compute` again with the same order, params
    /// and workarea. That oracle could only ever confirm the engine agreed
    /// with itself: if `tiling.compute` were wrong, the recomputation would be
    /// wrong identically and the assertion would pass. It was the worst case
    /// the item names, and it was load-bearing for the X-gated tile
    /// assertions.
    ///
    /// The ledger is independent of the recomputation in the way that matters:
    /// it is written from inside reconcile's send path, so comparing it against
    /// the X server's answer tests the ROUND TRIP (did the request we issued
    /// actually land?) rather than re-running the decision. Placement
    /// arithmetic itself is covered headlessly by tiling_test; what is left for
    /// this layer, and what it now actually checks, is that the bytes we sent
    /// are the geometry the server has.
    pub fn sentGeometry(self: *const Fx, win: u32) ?model.Rect {
        _ = self;
        return ledger.lastRectFor(win);
    }

    /// Asserts the X server's geometry for `win` equals the geometry hana
    /// recorded sending, with the configured border width (the end-to-end
    /// round-trip check). (28.8)
    pub fn expectTiledGeometry(self: *const Fx, win: u32) !void {
        const sent = self.sentGeometry(win) orelse return error.MissingPlacement;
        const g = self.geometry(win) orelse return error.ClosedWindow;
        try std.testing.expectEqual(sent.width, g.width);
        try std.testing.expectEqual(sent.height, g.height);
        try std.testing.expectEqual(sent.x, @as(i32, g.x));
        try std.testing.expectEqual(sent.y, @as(i32, g.y));
        try std.testing.expectEqual(core.borderWidth(), g.border_width);
    }

    /// Asserts the window sits parked off-screen (X = offscreen slot).
    pub fn expectParked(self: *const Fx, win: u32) !void {
        const g = self.geometry(win) orelse return error.ClosedWindow;
        try std.testing.expectEqual(@as(i32, constants.offscreen_x_position), @as(i32, g.x));
    }
};
