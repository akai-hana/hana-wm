//! Rule 3 xcb sweep (P2-49): the tool half of check-layers.sh's Rule 3.
//! Reads each file path given after `--`, strips comments via the shared
//! build-time scanner (dev/build-support/source_scan.zig: comment-aware,
//! string-aware, newline-preserving), and prints `path:line:content` for
//! every line whose comment-stripped text still contains the substring
//! `xcb` -- the exact output shape the script's violation loop consumes,
//! replacing the inline awk stripper so configure-time checks and the
//! layer guard share one comment stripper and cannot drift apart. Fails
//! loudly (non-zero) on any unreadable file instead of sweeping nothing.

const std = @import("std");
const source_scan = @import("source_scan.zig");

const xcb_token = "xcb";
/// Generous cap: the swept files are source, not data; a larger file than
/// this is itself worth failing on rather than silently under-scanning.
const max_file_bytes = 16 << 20;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var w = stdout.writer(io, &out_buf);

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // argv[0]: the tool itself

    var exit_code: u8 = 0;
    while (it.next()) |rel_path| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, rel_path, alloc, .limited(max_file_bytes)) catch |err| {
            std.debug.print("rule3: cannot read {s}: {}\n", .{ rel_path, err });
            exit_code = 1;
            continue;
        };
        defer alloc.free(src);

        var stripped: std.ArrayList(u8) = .empty;
        defer stripped.deinit(alloc);
        source_scan.stripCommentsInto(&stripped, alloc, src) catch |err| {
            std.debug.print("rule3: cannot strip {s}: {}\n", .{ rel_path, err });
            exit_code = 1;
            continue;
        };

        var line_no: usize = 1;
        var rest = stripped.items[0..];
        while (rest.len > 0) : (line_no += 1) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = rest[0..nl];
            rest = if (nl == rest.len) rest[nl..] else rest[nl + 1 ..];
            if (std.mem.indexOf(u8, line, xcb_token) != null) {
                w.interface.print("{s}:{d}:{s}\n", .{ rel_path, line_no, line }) catch {
                    std.debug.print("rule3: cannot write result\n", .{});
                    w.flush() catch {};
                    std.process.exit(1);
                };
            }
        }
    }
    // std.process.exit skips defers, so the buffered stdout must be
    // flushed explicitly before it (P1-44's runDumpConfigSchema pins the
    // same shape).
    w.flush() catch std.process.exit(1);
    std.process.exit(exit_code);
}
