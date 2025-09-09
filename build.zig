const std = @import("std");
const builtin = @import("builtin");


pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Exposing as a dependency for other projects
    const pkg = b.addModule("sloop", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize
    });

    const main = b.addModule("main", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const app = "sloop";
    const exe = b.addExecutable(.{.name = app, .root_module = main});

    switch (target.query.os_tag orelse builtin.os.tag) {
        .macos => {},
        .windows, .linux => exe.linkLibC(),
        else => @panic("Codebase is not tailored for this platform!")
    }

    // Self importing package
    exe.root_module.addImport("sloop", pkg);

    // Adding package dependency
    const quill = b.dependency("quill", .{});
    pkg.addImport("quill", quill.module("quill"));
    exe.root_module.addImport("quill", quill.module("quill"));

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
