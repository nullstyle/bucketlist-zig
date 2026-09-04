const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("bucketlist", .{ .target = target, .optimize = optimize });
    const example = b.addExecutable(.{
        .name = "persistent-directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = dependency.module("bucketlist") },
                .{ .name = "bucketlist-checkpoints", .module = dependency.module("bucketlist-checkpoints") },
            },
        }),
    });
    b.installArtifact(example);
    const run = b.addRunArtifact(example);
    run.addPassthruArgs();
    b.step("run", "Save, restore, continue, and collect checkpoints in the supplied empty directory").dependOn(&run.step);
}
