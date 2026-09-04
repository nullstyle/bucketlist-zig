const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("bucketlist", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "directory", .root_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bucketlist", .module = dep.module("bucketlist") }},
    }) });
    b.installArtifact(exe);
    b.step("run", "Run the standalone two-table consumer").dependOn(&b.addRunArtifact(exe).step);
}
