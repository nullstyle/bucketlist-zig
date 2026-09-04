const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("build.zig.zon");

comptime {
    const required = std.SemanticVersion.parse(manifest.minimum_zig_version) catch unreachable;
    if (builtin.zig_version.order(required) == .lt)
        @compileError("bucketlist-zig needs the compiler floor in build.zig.zon; run mise install");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vectors = b.createModule(.{ .root_source_file = b.path("vectors/reference.zig"), .target = target, .optimize = optimize });
    const lib = b.addModule("bucketlist", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "reference_vectors", .module = vectors }},
    });
    const store = b.addModule("bucketlist-store", .{
        .root_source_file = b.path("src/store.zig"),
        .target = target,
        .optimize = optimize,
    });
    const checkpoints = b.addModule("bucketlist-checkpoints", .{
        .root_source_file = b.path("src/checkpoints.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "bucketlist-store", .module = store }},
    });
    const tests = b.addTest(.{ .root_module = lib });
    const test_step = b.step("test", "Run codec, schema, database, bucket, and native store tests");
    const check = b.step("check", "Compile all native tests and example without executing them");
    check.dependOn(&tests.step);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    const store_tests = b.addTest(.{ .root_module = store });
    check.dependOn(&store_tests.step);
    test_step.dependOn(&b.addRunArtifact(store_tests).step);
    const persistence = b.addTest(.{
        .filters = &.{"persistence:"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/persistence_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bucketlist-store", .module = store }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(persistence).step);
    check.dependOn(&persistence.step);
    const checkpoint_tests = b.addTest(.{
        .filters = &.{"checkpoints:"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/checkpoints_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-store", .module = store },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(checkpoint_tests).step);
    check.dependOn(&checkpoint_tests.step);

    const example = b.addExecutable(.{
        .name = "directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/directory/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bucketlist", .module = lib }},
        }),
    });
    b.installArtifact(example);
    check.dependOn(&example.step);
    const run = b.addRunArtifact(example);
    b.step("example-smoke", "Run the two-table database example").dependOn(&run.step);
    test_step.dependOn(&run.step);

    const persistent_example = b.addExecutable(.{
        .name = "persistent-directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/persistent-directory/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-checkpoints", .module = checkpoints },
            },
        }),
    });
    b.installArtifact(persistent_example);
    check.dependOn(&persistent_example.step);
    const persistent_run = b.addRunArtifact(persistent_example);
    _ = persistent_run.addOutputDirectoryArg("store");
    b.step("persistent-example-smoke", "Run native checkpoint publication and recovery").dependOn(&persistent_run.step);
    test_step.dependOn(&persistent_run.step);

    const bench = b.addExecutable(.{
        .name = "bucketlist-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "bucketlist", .module = lib }},
        }),
    });
    b.step("bench", "Measure update and checkpoint costs").dependOn(&b.addRunArtifact(bench).step);
    const api = b.addExecutable(.{
        .name = "bucketlist-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-checkpoints", .module = checkpoints },
            },
        }),
    });
    const api_update = b.addSystemCommand(&.{ "python3", "tools/check-api.py" });
    api_update.addArtifactArg(api);
    api_update.addArgs(&.{ "docs/api.txt", "--update" });
    b.step("api-snapshot", "Update the public interface snapshot").dependOn(&api_update.step);
    const api_check = b.addSystemCommand(&.{ "python3", "tools/check-api.py" });
    api_check.addArtifactArg(api);
    api_check.addArg("docs/api.txt");
    b.step("check-api", "Check the public interface snapshot").dependOn(&api_check.step);
    test_step.dependOn(&api_check.step);
    const reject = b.addSystemCommand(&.{ "python3", "tools/check-rejections.py" });
    b.step("schema-rejections", "Check unsupported schema diagnostics").dependOn(&reject.step);
    test_step.dependOn(&reject.step);
    const generate = b.addSystemCommand(&.{ "python3", "tools/reference.py" });
    b.step("vectors", "Regenerate independent commitment fixtures").dependOn(&generate.step);
    const verify = b.addSystemCommand(&.{ "python3", "tools/reference.py", "--check" });
    b.step("vectors-check", "Verify independently generated fixture bytes").dependOn(&verify.step);

    const differential = b.addExecutable(.{
        .name = "bucketlist-differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/differential.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "bucketlist", .module = lib }, .{ .name = "reference_vectors", .module = vectors } },
        }),
    });
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm_vectors = b.createModule(.{ .root_source_file = b.path("vectors/reference.zig"), .target = wasm_target, .optimize = optimize });
    const wasm_lib = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "reference_vectors", .module = wasm_vectors }},
    });
    const wasm = b.addExecutable(.{
        .name = "bucketlist-differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/differential.zig"),
            .target = wasm_target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "bucketlist", .module = wasm_lib }, .{ .name = "reference_vectors", .module = wasm_vectors } },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.stack_size = 4 * 1024 * 1024;
    const diff = b.addSystemCommand(&.{ "node", "tools/wasm-diff.mjs" });
    diff.addArtifactArg(wasm);
    diff.addArtifactArg(differential);
    b.step("wasm-diff", "Compare native and WASM execution against independent fixtures").dependOn(&diff.step);
}
