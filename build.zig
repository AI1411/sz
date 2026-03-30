const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ─── 共有モジュール定義 ───────────────────────────────────────────────────
    const types_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/types.zig"),
    });
    const size_fmt_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/size_fmt.zig"),
    });
    const bar_mod = b.createModule(.{
        .root_source_file = b.path("src/render/bar.zig"),
    });

    // ─── メイン実行ファイル ───────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("types", types_mod);
    exe_mod.addImport("size_fmt", size_fmt_mod);
    exe_mod.addImport("bar", bar_mod);

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

    // ─── テストモジュール ────────────────────────────────────────────────────

    // main.zig テスト (exe と同じ依存関係)
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("types", types_mod);
    test_mod.addImport("size_fmt", size_fmt_mod);
    test_mod.addImport("bar", bar_mod);

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // args.zig テスト
    const args_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/args.zig"),
        .target = target,
        .optimize = optimize,
    });
    const args_tests = b.addTest(.{ .root_module = args_test_mod });
    const run_args_tests = b.addRunArtifact(args_tests);

    // scanner/types.zig テスト
    const scanner_types_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/types.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_types_tests = b.addTest(.{ .root_module = scanner_types_test_mod });
    const run_scanner_types_tests = b.addRunArtifact(scanner_types_tests);

    // scanner/posix.zig テスト
    const scanner_posix_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/posix.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_posix_tests = b.addTest(.{ .root_module = scanner_posix_test_mod });
    const run_scanner_posix_tests = b.addRunArtifact(scanner_posix_tests);

    // scanner/parallel.zig テスト (types named import が必要)
    const scanner_parallel_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/parallel.zig"),
        .target = target,
        .optimize = optimize,
    });
    scanner_parallel_test_mod.addImport("types", types_mod);
    const scanner_parallel_tests = b.addTest(.{ .root_module = scanner_parallel_test_mod });
    const run_scanner_parallel_tests = b.addRunArtifact(scanner_parallel_tests);

    // utils/size_fmt.zig テスト
    const size_fmt_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/size_fmt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const size_fmt_tests = b.addTest(.{ .root_module = size_fmt_test_mod });
    const run_size_fmt_tests = b.addRunArtifact(size_fmt_tests);

    // utils/ansi.zig テスト
    const ansi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/utils/ansi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ansi_tests = b.addTest(.{ .root_module = ansi_test_mod });
    const run_ansi_tests = b.addRunArtifact(ansi_tests);

    // render/bar.zig テスト
    const bar_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/bar.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bar_tests = b.addTest(.{ .root_module = bar_test_mod });
    const run_bar_tests = b.addRunArtifact(bar_tests);

    // render/tree.zig テスト (types, size_fmt, bar named imports が必要)
    const tree_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/tree.zig"),
        .target = target,
        .optimize = optimize,
    });
    tree_test_mod.addImport("types", types_mod);
    tree_test_mod.addImport("size_fmt", size_fmt_mod);
    tree_test_mod.addImport("bar", bar_mod);
    const tree_tests = b.addTest(.{ .root_module = tree_test_mod });
    const run_tree_tests = b.addRunArtifact(tree_tests);

    // scanner/queue.zig テスト
    const scanner_queue_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_queue_tests = b.addTest(.{ .root_module = scanner_queue_test_mod });
    const run_scanner_queue_tests = b.addRunArtifact(scanner_queue_tests);

    // scanner/worker.zig テスト
    const scanner_worker_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_worker_tests = b.addTest(.{ .root_module = scanner_worker_test_mod });
    const run_scanner_worker_tests = b.addRunArtifact(scanner_worker_tests);

    // tests/scanner_test.zig 統合テスト (scanner named import が必要)
    const scanner_posix_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/posix.zig"),
    });
    const scanner_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/scanner_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    scanner_integration_test_mod.addImport("scanner", scanner_posix_mod);
    const scanner_integration_tests = b.addTest(.{ .root_module = scanner_integration_test_mod });
    const run_scanner_integration_tests = b.addRunArtifact(scanner_integration_tests);

    // scanner/linux.zig テスト
    const scanner_linux_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/linux.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scanner_linux_tests = b.addTest(.{ .root_module = scanner_linux_test_mod });
    const run_scanner_linux_tests = b.addRunArtifact(scanner_linux_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_scanner_queue_tests.step);
    test_step.dependOn(&run_scanner_worker_tests.step);
    test_step.dependOn(&run_scanner_integration_tests.step);
    test_step.dependOn(&run_args_tests.step);
    test_step.dependOn(&run_scanner_types_tests.step);
    test_step.dependOn(&run_scanner_posix_tests.step);
    test_step.dependOn(&run_scanner_parallel_tests.step);
    test_step.dependOn(&run_scanner_linux_tests.step);
    test_step.dependOn(&run_size_fmt_tests.step);
    test_step.dependOn(&run_ansi_tests.step);
    test_step.dependOn(&run_bar_tests.step);
    test_step.dependOn(&run_tree_tests.step);
}
