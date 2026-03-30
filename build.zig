const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sz",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run sz");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const args_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/args.zig"),
        .target = target,
        .optimize = optimize,
    });

    const args_tests = b.addTest(.{
        .root_module = args_test_mod,
    });

    const run_args_tests = b.addRunArtifact(args_tests);

    const scanner_types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/types.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scanner_types_tests = b.addTest(.{
        .root_module = scanner_types_test_mod,
    });

    const run_scanner_types_tests = b.addRunArtifact(scanner_types_tests);

    const scanner_posix_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/posix.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scanner_posix_tests = b.addTest(.{
        .root_module = scanner_posix_test_mod,
    });

    const run_scanner_posix_tests = b.addRunArtifact(scanner_posix_tests);

    const scanner_parallel_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/parallel.zig"),
        .target = target,
        .optimize = optimize,
    });

    const scanner_parallel_tests = b.addTest(.{
        .root_module = scanner_parallel_test_mod,
    });

    const run_scanner_parallel_tests = b.addRunArtifact(scanner_parallel_tests);

    const size_fmt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/size_fmt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const size_fmt_tests = b.addTest(.{
        .root_module = size_fmt_test_mod,
    });

    const run_size_fmt_tests = b.addRunArtifact(size_fmt_tests);

    const ansi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/ansi.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ansi_tests = b.addTest(.{
        .root_module = ansi_test_mod,
    });

    const run_ansi_tests = b.addRunArtifact(ansi_tests);

    const bar_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/bar.zig"),
        .target = target,
        .optimize = optimize,
    });

    const bar_tests = b.addTest(.{
        .root_module = bar_test_mod,
    });

    const run_bar_tests = b.addRunArtifact(bar_tests);

    // tree.zig は scanner/types.zig と utils/size_fmt.zig に依存するため、
    // 名前付きモジュールとして依存関係を注入する
    const scanner_types_dep = b.createModule(.{
        .root_source_file = b.path("src/scanner/types.zig"),
    });

    const size_fmt_dep = b.createModule(.{
        .root_source_file = b.path("src/utils/size_fmt.zig"),
    });

    const bar_dep = b.createModule(.{
        .root_source_file = b.path("src/render/bar.zig"),
    });

    const tree_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_test_mod.addImport("types", scanner_types_dep);
    tree_test_mod.addImport("size_fmt", size_fmt_dep);
    tree_test_mod.addImport("bar", bar_dep);

    const tree_tests = b.addTest(.{
        .root_module = tree_test_mod,
    });

    const run_tree_tests = b.addRunArtifact(tree_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_args_tests.step);
    test_step.dependOn(&run_scanner_types_tests.step);
    test_step.dependOn(&run_scanner_posix_tests.step);
    test_step.dependOn(&run_scanner_parallel_tests.step);
    test_step.dependOn(&run_size_fmt_tests.step);
    test_step.dependOn(&run_ansi_tests.step);
    test_step.dependOn(&run_bar_tests.step);
    test_step.dependOn(&run_tree_tests.step);
}
