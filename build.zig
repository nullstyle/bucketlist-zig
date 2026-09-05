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
    const disk = b.addModule("bucketlist-disk", .{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bucketlist", .module = lib },
            .{ .name = "bucketlist-store", .module = store },
        },
    });
    const tests = b.addTest(.{ .root_module = lib });
    const test_step = b.step("test", "Run library tests, seeded parser cases, and consumer examples");
    const check = b.step("check", "Compile native tests, examples, and validation tools without running them");
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

    const disk_tests = b.addTest(.{
        .filters = &.{ "disk:", "host:" },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/disk_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-store", .module = store },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(disk_tests).step);
    check.dependOn(&disk_tests.step);
    b.step("disk-test", "Run native disk and background host tests").dependOn(&b.addRunArtifact(disk_tests).step);
    const frontier_tests = b.addTest(.{
        .filters = &.{"frontier:"},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/frontier_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(frontier_tests).step);
    check.dependOn(&frontier_tests.step);

    const fuzz_smoke = b.step("fuzz-smoke", "Run bounded deterministic portable, guided corpus, and native parser cases");
    const portable_fuzz_module = b.createModule(.{
        .root_source_file = b.path("src/fuzz_portable.zig"),
        .target = target,
        .optimize = optimize,
    });
    const portable_options = b.addOptions();
    portable_options.addOption(bool, "synthetic_probe", b.option(bool, "guided-probe", "Enable the synthetic failing fuzz target used by wrapper self-tests") orelse false);
    portable_fuzz_module.addOptions("build_options", portable_options);
    const portable_fuzz_tests = b.addTest(.{ .root_module = portable_fuzz_module, .filters = &.{"portable fuzz:"} });
    const portable_fuzz_smoke = b.addRunArtifact(portable_fuzz_tests);
    fuzz_smoke.dependOn(&portable_fuzz_smoke.step);
    check.dependOn(&portable_fuzz_tests.step);
    const portable_fuzz = b.addExecutable(.{ .name = "fuzz-portable", .root_module = portable_fuzz_module });
    const portable_fuzz_run = b.addRunArtifact(portable_fuzz);
    portable_fuzz_run.addPassthruArgs();
    b.step("fuzz-portable", "Exercise portable parsers; -- --iterations N --seed N, or --replay-target/--replay-mapped for exact input replay").dependOn(&portable_fuzz_run.step);
    check.dependOn(&portable_fuzz.step);
    // The self-hosted AArch64 backend silently skips std.testing.fuzz, so the
    // guided corpus and coverage campaigns require LLVM explicitly.
    const guided_tests = b.addTest(.{ .root_module = portable_fuzz_module, .filters = &.{"portable guided:"} });
    guided_tests.use_llvm = true;
    const guided_run = b.addRunArtifact(guided_tests);
    fuzz_smoke.dependOn(&guided_run.step);
    check.dependOn(&guided_tests.step);
    b.step("guided-coverage", "Run the fixed guided corpus; pass --fuzz=N --seed=N for LLVM coverage-guided campaigns").dependOn(&guided_run.step);
    const guided_probe_tests = b.addTest(.{ .root_module = portable_fuzz_module, .filters = &.{"portable guided probe:"} });
    guided_probe_tests.use_llvm = true;
    b.step("guided-probe-coverage", "Fuzz the synthetic probe target; requires -Dguided-probe=true (wrapper self-test)").dependOn(&b.addRunArtifact(guided_probe_tests).step);
    const native_fuzz = b.addExecutable(.{
        .name = "fuzz-native",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_native.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-store", .module = store },
            },
        }),
    });
    const native_fuzz_smoke = b.addRunArtifact(native_fuzz);
    native_fuzz_smoke.addArgs(&.{ "100", "1" });
    fuzz_smoke.dependOn(&native_fuzz_smoke.step);
    const native_fuzz_run = b.addRunArtifact(native_fuzz);
    native_fuzz_run.addPassthruArgs();
    b.step("fuzz-native", "Exercise private synthetic stores; -- iterations seed [fresh-path]").dependOn(&native_fuzz_run.step);
    check.dependOn(&native_fuzz.step);
    test_step.dependOn(fuzz_smoke);

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

    const disk_example = b.addExecutable(.{
        .name = "disk-directory",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/disk-directory/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-disk", .module = disk },
            },
        }),
    });
    b.installArtifact(disk_example);
    check.dependOn(&disk_example.step);
    const disk_run = b.addRunArtifact(disk_example);
    _ = disk_run.addOutputDirectoryArg("store");
    b.step("disk-example-smoke", "Run bounded background publication and disk recovery").dependOn(&disk_run.step);
    test_step.dependOn(&disk_run.step);

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
    const scalability = b.addExecutable(.{
        .name = "bucketlist-scalability",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scalability.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-checkpoints", .module = checkpoints },
            },
        }),
    });
    const scalability_run = b.addRunArtifact(scalability);
    check.dependOn(&scalability.step);
    scalability_run.addPassthruArgs();
    b.step("scalability", "Measure large-batch staging and native checkpoint allocations (requires a fresh store path)").dependOn(&scalability_run.step);
    const disk_bench = b.addExecutable(.{
        .name = "disk-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/disk-bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-disk", .module = disk },
            },
        }),
    });
    const disk_bench_run = b.addRunArtifact(disk_bench);
    disk_bench_run.addPassthruArgs();
    b.step("disk-bench", "Measure file execution; -- fresh-path [MiB] [batch-rows] [read-samples] [trials]").dependOn(&disk_bench_run.step);
    check.dependOn(&disk_bench.step);
    const api = b.addExecutable(.{
        .name = "bucketlist-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/api.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bucketlist", .module = lib },
                .{ .name = "bucketlist-checkpoints", .module = checkpoints },
                .{ .name = "bucketlist-disk", .module = disk },
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
