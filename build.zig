// File: build.zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zigzap",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link libevtx and libxml2
    exe.linkSystemLibrary("evtx");
    exe.linkSystemLibrary("xml2");
    exe.linkLibC();

    // Add include paths for libxml2
    //exe.addIncludePath(.{ .path = "/usr/include/libxml2" });
    exe.addIncludePath(.{ .src = "/usr/include/libxml2" });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
