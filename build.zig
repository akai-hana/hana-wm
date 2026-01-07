// Build config for Zig: compile, link, install and run.

const std = @import("std");

// Helper to register a module with shared defs
fn addModule(b: *std.Build, exe: *std.Build.Step.Compile, defs_module: *std.Build.Module, name: []const u8, path: []const u8) void {
    const module = b.addModule(name, .{
        .root_source_file = b.path(path),
    });
    exe.root_module.addImport(name, module);
    module.addImport("defs", defs_module);
}

pub fn build(b: *std.Build) void {
    // SELECTIONS
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ARTIFACTS
    const exe = b.addExecutable(.{
        .name = "hana",
        .root_source_file = b.path("src/core/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Definitions module (shared by all modules)
    const defs_module = b.addModule("defs", .{
        .root_source_file = b.path("src/core/defs.zig"),
    });
    exe.root_module.addImport("defs", defs_module);

    // Register all modules
    addModule(b, exe, defs_module, "window", "src/modules/window.zig");
    addModule(b, exe, defs_module, "input", "src/modules/input.zig");

    // LINKING
    exe.linkLibC();
    exe.linkSystemLibrary("xcb");

    // INSTALL
    b.installArtifact(exe);

    // RUN
    const run_hana = b.addRunArtifact(exe);
    run_hana.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_hana.addArgs(args);
    }

    const run_step = b.step("run", "Run hana");
    run_step.dependOn(&run_hana.step);
}
