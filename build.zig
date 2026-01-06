// Build config for Zig: compile, link, install and run.

const std = @import("std");

// Entry point (`zig build`)
pub fn build(b: *std.Build) void {
    // SELECTIONS
    // -Dtarget
    const target = b.standardTargetOptions(.{});
    // -Doptimize
    const optimize = b.standardOptimizeOption(.{});

    // ARTIFACTS
    // Executable
    const exe = b.addExecutable(.{
        .name = "hana",
        .root_source_file = b.path("src/core/main.zig"), 

        .target = target,
        .optimize = optimize,
    });

    // Definitions module
    const defs_module = b.addModule("defs", .{
        .root_source_file = b.path("src/core/defs.zig"),
    });
    exe.root_module.addImport("defs", defs_module);

    // Internal Modules
    // Basic window management
    const basic_module = b.addModule("basic", .{
        .root_source_file = b.path("src/modules/basic.zig"),
    }); 
    exe.root_module.addImport("basic", basic_module);
    // Share defs
    basic_module.addImport("defs", defs_module);

    // Input handling (mouse/keyboard)
    const input_module = b.addModule("input", .{
        .root_source_file = b.path("src/modules/input.zig"),
    });
    exe.root_module.addImport("input", input_module);
    // Share defs
    input_module.addImport("defs", defs_module);

    // LINKING
    // C standard library
    exe.linkLibC();
    // XCB library
    exe.linkSystemLibrary("xcb");

    // INSTALL
    // Executable (`zig build install`)
    b.installArtifact(exe);

    // RUN
    // Create run command for the executable
    const run_hana = b.addRunArtifact(exe);

    // Ensure binary is built and installed before running
    run_hana.step.dependOn(b.getInstallStep());

    // Forward CLI args (`zig build run -- <yada1> <yada2>`)
    if (b.args) |args| {
        run_hana.addArgs(args);
    }

    // Expose Zig build step (`zig build run`)
    const run_step = b.step("run", "Run hana");
    run_step.dependOn(&run_hana.step);
}
