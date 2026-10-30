const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("json_patch", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run all tests");
    for ([_]*std.Build.Module{
        mod,
        testModule(b, "test/conformance.zig", mod, target, optimize),
        testModule(b, "test/differential.zig", mod, target, optimize),
    }) |root_module| {
        const tests = b.addTest(.{ .root_module = root_module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "json_patch", .module = mod }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Run benchmarks").dependOn(&run_bench.step);

    const docs_lib = b.addLibrary(.{ .name = "json_patch", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation").dependOn(&install_docs.step);
}

fn testModule(
    b: *std.Build,
    path: []const u8,
    json_patch: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "json_patch", .module = json_patch }},
    });
}
