//! Simple debug logging check

const std = @import("std");
const builtin = @import("builtin");

pub inline fn isDebug() bool {
    return builtin.mode == .Debug;
}
