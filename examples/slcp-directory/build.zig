const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bucketlist = b.dependency("bucketlist", .{ .target = target, .optimize = optimize });
    const slcp = b.dependency("slcp", .{ .target = target, .optimize = optimize });
    const app = b.addModule("directory-app", .{
        .root_source_file = b.path("src/app.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bucketlist", .module = bucketlist.module("bucketlist") },
            .{ .name = "slcp", .module = slcp.module("slcp") },
        },
    });
    const host = b.addExecutable(.{
        .name = "slcp-directory-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/process.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "directory-app", .module = app },
                .{ .name = "bucketlist", .module = bucketlist.module("bucketlist") },
                .{ .name = "bucketlist-store", .module = bucketlist.module("bucketlist-store") },
                .{ .name = "slcp", .module = slcp.module("slcp") },
            },
        }),
    });
    b.installArtifact(host);
    const unit = b.addTest(.{ .name = "directory-slcp-tests", .root_module = app });
    b.step("test", "Test the adapter and three-node loopback restart").dependOn(&b.addRunArtifact(unit).step);
}
