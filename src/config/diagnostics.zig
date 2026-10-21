//! Diagnostic capture for `--check-config` and its tests.
//!
//! `Diagnostics` collects warn/err lines that the process `logFn` (main.zig)
//! or the test runner's `log()` (dev/test_runner.zig) would otherwise only
//! write to stderr, so a non-interactive check can COUNT them instead of
//! scraping text: `hana --check-config` reports the count and exits non-zero
//! when it is above zero, which is what makes config validation usable in CI.
//!
//! Installed through the module-level `diagnostics` pointer, never passed
//! down the call chain: threading a bag through each of the odd-dozen warn
//! sites is the maintenance burden that made the idea unattractive. When it
//! is null -- the normal case -- `capture` is a no-op.

const std = @import("std");

/// One captured diagnostic. `module` and `message` are owned by the
/// `Diagnostics`.
pub const Diagnostic = struct {
    level: std.log.Level,
    module: []const u8,
    message: []const u8,
};

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn deinit(self: *Diagnostics) void {
        for (self.items.items) |d| {
            self.allocator.free(d.module);
            self.allocator.free(d.message);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Number of warn/err diagnostics captured so far.
    pub fn count(self: *const Diagnostics) usize {
        return self.items.items.len;
    }

    /// Whether any captured message contains `needle`. Lets a test assert a
    /// SPECIFIC rejection happened without matching a whole file's text.
    pub fn contains(self: *const Diagnostics, needle: []const u8) bool {
        for (self.items.items) |d| {
            if (std.mem.indexOf(u8, d.message, needle) != null) return true;
        }
        return false;
    }

    /// Result of `line`: the reconstructed text plus whether bytes were
    /// dropped to make it fit the buffer.
    pub const Line = struct {
        text: []const u8,
        truncated: bool,
    };

    /// The "[module] message" line the stderr path would have written,
    /// clipped to `buf` when it does not fit. `bufPrint` REFUSES to truncate
    /// (error.NoSpaceLeft), so the overflow case is clipped by hand and
    /// reported via `truncated`: one over-long diagnostic must not abort the
    /// check that is printing it, and the exact flag beats the
    /// `len == buf.len` heuristic (false positive on a perfectly-fitting
    /// line, false negative if a clip ever reserved marker room).
    pub fn line(d: Diagnostic, buf: []u8) Line {
        if (std.fmt.bufPrint(buf, "[{s}] {s}", .{ d.module, d.message })) |text| {
            return .{ .text = text, .truncated = false };
        } else |_| {
            // NoSpaceLeft: write the prefix of the same "[module] message"
            // shape, piece by piece, stopping when the buffer is full.
            const pieces = [_][]const u8{ "[", d.module, "] ", d.message };
            var pos: usize = 0;
            for (pieces) |piece| {
                const n = @min(buf.len - pos, piece.len);
                @memcpy(buf[pos..][0..n], piece[0..n]);
                pos += n;
            }
            return .{ .text = buf[0..pos], .truncated = true };
        }
    }
};

/// Non-null while a `Diagnostics` is installed. Both log sinks (the exe
/// `logFn` and the test runner's `log()`) check this BEFORE their
/// print/silence rules, so a check or a test can assert on captured
/// diagnostics without opening the stderr hatch.
pub var diagnostics: ?*Diagnostics = null;

/// The warn/err sink shared by every binary. `scope` is the
/// `std.log.scoped` tag of the logging file; stored beside the message
/// rather than composed into the format string (the format is comptime, the
/// tag is not); `Diagnostics.line` puts it back for printing.
pub fn capture(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const c = diagnostics orelse return;
    // Only the failure levels are collected: a check that failed on
    // `info`/`debug` progress chatter could never pass.
    if (level != .warn and level != .err) return;
    const message = std.fmt.allocPrint(c.allocator, format, args) catch {
        c.items.append(c.allocator, .{
            .level = level,
            .module = c.allocator.dupe(u8, "diagnostics") catch return,
            .message = c.allocator.dupe(u8, "(diagnostic text could not be allocated)") catch return,
        }) catch return;
        return;
    };
    const tag = c.allocator.dupe(u8, @tagName(scope)) catch {
        c.allocator.free(message);
        return;
    };
    c.items.append(c.allocator, .{ .level = level, .module = tag, .message = message }) catch {
        c.allocator.free(message);
    };
}
