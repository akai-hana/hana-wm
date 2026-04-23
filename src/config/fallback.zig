//! Fallback configuration
//! Auto-detects a suitable terminal and font when no user config is provided.

const std   = @import("std");
const debug = @import("debug");

// Checked in preference order.
const TERMINALS = [_][]const u8{
    "ghostty", "alacritty", "kitty", "wezterm", "foot",
    "st", "urxvt", "rxvt", "xterm",
    "konsole", "gnome-terminal", "xfce4-terminal",
    "mate-terminal", "lxterminal", "terminator",
};

// Checked in preference order. "monospace" is always the final fallback.
const FONTS = [_][]const u8{
    "FiraCode Nerd Font",
    "FiraCode",
    "JetBrains Mono Nerd Font",
    "JetBrains Mono",
    "Terminus",
    "monospace",
};

// Direct libc bindings — avoids depending on the nightly std.process.Child API,
// which requires an Io handle incompatible with synchronous config loading.
// link_libc = true in build.zig makes these resolve at link time.
const FILE = opaque {};
extern fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*FILE;
extern fn pclose(stream: *FILE) c_int;
extern fn fread(ptr: [*]u8, size: usize, nmemb: usize, stream: *FILE) usize;
extern fn feof(stream: *FILE) c_int;

/// Returns the first available terminal from TERMINALS, or "xterm".
/// Pure PATH scan — does not allocate; returns a static string slice.
pub fn detectTerminal() []const u8 {
    for (TERMINALS) |cmd| {
        if (isCommandAvailable(cmd)) {
            debug.info("Detected terminal: {s}", .{cmd});
            return cmd;
        }
    }
    debug.warn("No preferred terminal found, using 'xterm'", .{});
    return "xterm";
}

/// Runs fc-list and returns the first FONTS entry present on the system.
/// Falls back to "monospace" when fc-list is unavailable or produces no match.
pub fn detectFont(allocator: std.mem.Allocator) ![]const u8 {
    const pipe = popen("fc-list --format=%{family}\\n", "r") orelse {
        debug.warn("fc-list unavailable, using 'monospace'", .{});
        return "monospace";
    };
    defer _ = pclose(pipe);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);

    var buf: [4096]u8 = undefined;
    while (feof(pipe) == 0) {
        const n = fread(&buf, 1, buf.len, pipe);
        if (n == 0) break;
        try output.appendSlice(allocator, buf[0..n]);
        if (output.items.len > 256 * 1024) break; // guard against pathological fc-list output
    }

    // fc-list may emit comma-separated aliases per line, e.g. "FiraCode,FiraCode Nerd Font".
    // Iterate FONTS first so preference order is respected regardless of fc-list output order.
    for (FONTS) |font| {
        var lines = std.mem.splitScalar(u8, output.items, '\n');
        while (lines.next()) |line| {
            var families = std.mem.splitScalar(u8, line, ',');
            while (families.next()) |family| {
                if (std.mem.eql(u8, std.mem.trim(u8, family, " \t\r"), font)) {
                    debug.info("Detected font: {s}", .{font});
                    return font;
                }
            }
        }
    }

    debug.warn("No preferred font found via fc-list, using 'monospace'", .{});
    return "monospace";
}

/// Checks whether command exists in a common bin directory or $PATH.
fn isCommandAvailable(command: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const common_paths = [_][]const u8{ "/usr/bin", "/usr/local/bin", "/bin" };
    inline for (common_paths) |path| {
        if (checkPath(&buf, path, command)) return true;
    }

    const path_env = std.mem.span(std.c.getenv("PATH") orelse return false);
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const already_checked = inline for (common_paths) |c| {
            if (std.mem.eql(u8, dir, c)) break true;
        } else false;
        if (!already_checked and checkPath(&buf, dir, command)) return true;
    }

    return false;
}

// std.Io.Dir.openFileAbsolute takes []const u8 directly — no null terminator needed.
// std.options.debug_io is appropriate: this is a blocking existence check that
// runs at startup before any event loop or Io context is available.
inline fn checkPath(buf: []u8, dir: []const u8, command: []const u8) bool {
    const full_path = std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, command }) catch return false;
    const io = std.Options.debug_io;
    const file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch return false;
    file.close(io);
    return true;
}

/// Returns the fallback TOML configuration embedded in the binary,
/// or error.FallbackMissing if config/fallback.toml was absent at build time.
pub inline fn getFallbackToml() error{FallbackMissing}![]const u8 {
    const opts = @import("build_options");
    if (!@hasDecl(opts, "fallback_toml")) return error.FallbackMissing;
    return @field(opts, "fallback_toml");
}
