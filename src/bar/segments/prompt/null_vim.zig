//! Null-vim stub: minimal editor when prompt/vim.zig is absent.
const std = @import("std");
const core = @import("core");
const xcb = core.xcb;

pub const XK = core.XK;

const xk_back_space = @intFromEnum(XK.BackSpace);
const xk_return = @intFromEnum(XK.Return);
const xk_escape = @intFromEnum(XK.Escape);
const xk_delete = @intFromEnum(XK.Delete);
const xk_left = @intFromEnum(XK.Left);
const xk_right = @intFromEnum(XK.Right);
const xk_home = @intFromEnum(XK.Home);
const xk_end = @intFromEnum(XK.End);

pub const default_max_input: usize = 512;

pub const Action = enum { none, deactivate, spawn };

pub const Mode = enum {
    insert,
    normal,

    pub fn label(self: Mode) []const u8 {
        _ = self;
        return "";
    }
};

pub const VimState = struct {
    allocator: std.mem.Allocator = undefined,
    max_input: usize = 0,
    buf: []u8 = &.{},
    len: usize = 0,
    cursor: usize = 0,
    mode: Mode = .insert,

    pub fn init(allocator: std.mem.Allocator, max_input: usize) !VimState {
        return .{
            .allocator = allocator,
            .max_input = max_input,
            .buf = try allocator.alloc(u8, max_input),
        };
    }

    pub fn reset(vs: *VimState) void {
        const saved_buf = vs.buf;
        const saved_allocator = vs.allocator;
        const saved_max_input = vs.max_input;
        vs.* = .{};
        vs.allocator = saved_allocator;
        vs.max_input = saved_max_input;
        vs.buf = saved_buf;
    }

    pub fn deinit(vs: *VimState) void {
        vs.allocator.free(vs.buf);
        vs.* = .{};
    }
};

pub fn onDeactivate(vs: *VimState) void {
    _ = vs;
}

pub fn insertSlice(vs: *VimState, slice: []const u8) void {
    if (vs.max_input == 0 or vs.len + 1 >= vs.max_input) return;
    const n = @min(slice.len, vs.max_input - 1 - vs.len);
    if (n == 0) return;
    if (vs.cursor < vs.len) {
        std.mem.copyBackwards(u8, vs.buf[vs.cursor + n .. vs.len + n], vs.buf[vs.cursor..vs.len]);
    }
    @memcpy(vs.buf[vs.cursor .. vs.cursor + n], slice[0..n]);
    vs.len += n;
    vs.cursor += n;
}

pub fn handleCtrl(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    _ = vs;
    if (sym == 'c') return .deactivate;
    return .none;
}

pub fn handleInsertBasic(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    if (sym == xk_escape) return .deactivate;
    switch (sym) {
        xk_return => return .spawn,
        xk_back_space => {
            if (vs.cursor > 0) {
                std.mem.copyForwards(u8, vs.buf[vs.cursor - 1 .. vs.len - 1], vs.buf[vs.cursor..vs.len]);
                vs.cursor -= 1;
                vs.len -= 1;
            }
        },
        xk_delete => {
            if (vs.cursor < vs.len) {
                std.mem.copyForwards(u8, vs.buf[vs.cursor .. vs.len - 1], vs.buf[vs.cursor + 1 .. vs.len]);
                vs.len -= 1;
            }
        },
        xk_left => if (vs.cursor > 0) vs.cursor -= 1,
        xk_right => if (vs.cursor < vs.len) vs.cursor += 1,
        xk_home => vs.cursor = 0,
        xk_end => vs.cursor = vs.len,
        else => if (sym >= 0x20 and sym <= 0x7e) {
            const ch: u8 = @truncate(sym);
            insertSlice(vs, &[1]u8{ch});
        },
    }
    return .none;
}

pub const handleInsert = handleInsertBasic;

pub fn handleNormal(vs: *VimState, sym: xcb.xcb_keysym_t) Action {
    _ = vs;
    _ = sym;
    return .none;
}
