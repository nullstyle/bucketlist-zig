const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bucketlist = b.dependency("bucketlist", .{ .target = target, .optimize = optimize });
    const slcp = b.dependency("slcp", .{ .target = target, .optimize = optimize });
    const chain = b.addModule("disk-command-chain", .{
        .root_source_file = b.path("src/chain.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bucketlist", .module = bucketlist.module("bucketlist") },
            .{ .name = "slcp", .module = slcp.module("slcp") },
        },
    });
    const bridge = b.addModule("disk-consensus-bridge", .{
        .root_source_file = b.path("src/bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "disk-command-chain", .module = chain },
            .{ .name = "bucketlist-disk", .module = bucketlist.module("bucketlist-disk") },
            .{ .name = "slcp", .module = slcp.module("slcp") },
        },
    });
    const executable = b.addExecutable(.{
        .name = "slcp-disk-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "disk-command-chain", .module = chain },
                .{ .name = "disk-consensus-bridge", .module = bridge },
                .{ .name = "slcp", .module = slcp.module("slcp") },
            },
        }),
    });
    b.installArtifact(executable);
    const tests = b.addTest(.{ .name = "slcp-disk-adapter-tests", .root_module = bridge });
    const chain_tests = b.addTest(.{ .name = "slcp-disk-chain-tests", .root_module = chain });
    const test_step = b.step("test", "Test the bounded command chain and disk delivery adapter");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(chain_tests).step);
}
