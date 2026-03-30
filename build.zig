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
    // export/json.zig: JSON出力モジュール
    const json_export_mod = b.createModule(.{
        .root_source_file = b.path("src/export/json.zig"),
    });
    json_export_mod.addImport("types", types_mod);

    // export/csv.zig: CSV出力モジュール
    const csv_export_mod = b.createModule(.{
        .root_source_file = b.path("src/export/csv.zig"),
    });
    csv_export_mod.addImport("types", types_mod);

    // export/snapshot.zig: load/save 機能。render/compare.zig から "snapshot" で参照される
    const shared_snapshot_mod = b.createModule(.{
        .root_source_file = b.path("src/export/snapshot.zig"),
    });
    shared_snapshot_mod.addImport("types", types_mod);
    shared_snapshot_mod.addImport("json_export", json_export_mod);

    // ─── メイン実行ファイル ───────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("types", types_mod);
    exe_mod.addImport("size_fmt", size_fmt_mod);
    exe_mod.addImport("bar", bar_mod);
    exe_mod.addImport("snapshot", shared_snapshot_mod);
    exe_mod.addImport("json_export", json_export_mod);
    exe_mod.addImport("csv_export", csv_export_mod);

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
    test_mod.addImport("snapshot", shared_snapshot_mod);
    test_mod.addImport("json_export", json_export_mod);
    test_mod.addImport("csv_export", csv_export_mod);

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

    // render/flat.zig テスト (types, size_fmt named imports が必要)
    const flat_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/flat.zig"),
        .target = target,
        .optimize = optimize,
    });
    flat_test_mod.addImport("types", types_mod);
    flat_test_mod.addImport("size_fmt", size_fmt_mod);
    const flat_tests = b.addTest(.{ .root_module = flat_test_mod });
    const run_flat_tests = b.addRunArtifact(flat_tests);

    // render/compare.zig テスト (types, size_fmt, snapshot named imports が必要)
    const compare_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/compare.zig"),
        .target = target,
        .optimize = optimize,
    });
    compare_test_mod.addImport("types", types_mod);
    compare_test_mod.addImport("size_fmt", size_fmt_mod);
    compare_test_mod.addImport("snapshot", shared_snapshot_mod);
    const compare_tests = b.addTest(.{ .root_module = compare_test_mod });
    const run_compare_tests = b.addRunArtifact(compare_tests);

    // render/tui.zig テスト (types, size_fmt named imports が必要)
    const tui_test_mod = b.createModule(.{
        .root_source_file = b.path("src/render/tui.zig"),
        .target = target,
        .optimize = optimize,
    });
    tui_test_mod.addImport("types", types_mod);
    tui_test_mod.addImport("size_fmt", size_fmt_mod);
    const tui_tests = b.addTest(.{ .root_module = tui_test_mod });
    const run_tui_tests = b.addRunArtifact(tui_tests);

    // filter/pattern.zig テスト
    const filter_pattern_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/pattern.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter_pattern_tests = b.addTest(.{ .root_module = filter_pattern_test_mod });
    const run_filter_pattern_tests = b.addRunArtifact(filter_pattern_tests);

    // filter/size.zig テスト
    const filter_size_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/size.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter_size_tests = b.addTest(.{ .root_module = filter_size_test_mod });
    const run_filter_size_tests = b.addRunArtifact(filter_size_tests);

    // filter/preset.zig テスト
    const filter_preset_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/preset.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter_preset_tests = b.addTest(.{ .root_module = filter_preset_test_mod });
    const run_filter_preset_tests = b.addRunArtifact(filter_preset_tests);

    // filter/date.zig テスト
    const filter_date_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/date.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter_date_tests = b.addTest(.{ .root_module = filter_date_test_mod });
    const run_filter_date_tests = b.addRunArtifact(filter_date_tests);

    // filter/age.zig テスト
    const filter_age_test_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/age.zig"),
        .target = target,
        .optimize = optimize,
    });
    const filter_age_tests = b.addTest(.{ .root_module = filter_age_test_mod });
    const run_filter_age_tests = b.addRunArtifact(filter_age_tests);

    // tests/filter_test.zig 統合テスト
    const filter_pattern_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/pattern.zig"),
    });
    const filter_size_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/size.zig"),
    });
    const filter_preset_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/preset.zig"),
    });
    const filter_date_mod = b.createModule(.{
        .root_source_file = b.path("src/filter/date.zig"),
    });
    const filter_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/filter_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    filter_integration_test_mod.addImport("filter_pattern", filter_pattern_mod);
    filter_integration_test_mod.addImport("filter_size", filter_size_mod);
    filter_integration_test_mod.addImport("filter_preset", filter_preset_mod);
    filter_integration_test_mod.addImport("filter_date", filter_date_mod);
    const filter_integration_tests = b.addTest(.{ .root_module = filter_integration_test_mod });
    const run_filter_integration_tests = b.addRunArtifact(filter_integration_tests);

    // export/json.zig テスト (types named import が必要)
    const export_json_test_mod = b.createModule(.{
        .root_source_file = b.path("src/export/json.zig"),
        .target = target,
        .optimize = optimize,
    });
    export_json_test_mod.addImport("types", types_mod);
    const export_json_tests = b.addTest(.{ .root_module = export_json_test_mod });
    const run_export_json_tests = b.addRunArtifact(export_json_tests);

    // export/csv.zig テスト (types named import が必要)
    const export_csv_test_mod = b.createModule(.{
        .root_source_file = b.path("src/export/csv.zig"),
        .target = target,
        .optimize = optimize,
    });
    export_csv_test_mod.addImport("types", types_mod);
    const export_csv_tests = b.addTest(.{ .root_module = export_csv_test_mod });
    const run_export_csv_tests = b.addRunArtifact(export_csv_tests);

    // export/snapshot.zig テスト (types, json_export named imports が必要)
    const export_snapshot_test_mod = b.createModule(.{
        .root_source_file = b.path("src/export/snapshot.zig"),
        .target = target,
        .optimize = optimize,
    });
    export_snapshot_test_mod.addImport("types", types_mod);
    export_snapshot_test_mod.addImport("json_export", json_export_mod);
    const export_snapshot_tests = b.addTest(.{ .root_module = export_snapshot_test_mod });
    const run_export_snapshot_tests = b.addRunArtifact(export_snapshot_tests);

    // tests/bench_test.zig ベンチマークテスト (scanner named import が必要)
    const scanner_parallel_mod = b.createModule(.{
        .root_source_file = b.path("src/scanner/parallel.zig"),
    });
    scanner_parallel_mod.addImport("types", types_mod);
    const bench_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/bench_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_test_mod.addImport("scanner", scanner_parallel_mod);
    const bench_tests = b.addTest(.{ .root_module = bench_test_mod });
    const run_bench_tests = b.addRunArtifact(bench_tests);

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
    test_step.dependOn(&run_flat_tests.step);
    test_step.dependOn(&run_filter_pattern_tests.step);
    test_step.dependOn(&run_filter_size_tests.step);
    test_step.dependOn(&run_filter_preset_tests.step);
    test_step.dependOn(&run_filter_date_tests.step);
    test_step.dependOn(&run_filter_age_tests.step);
    test_step.dependOn(&run_filter_integration_tests.step);
    test_step.dependOn(&run_export_json_tests.step);
    test_step.dependOn(&run_export_csv_tests.step);
    test_step.dependOn(&run_export_snapshot_tests.step);
    test_step.dependOn(&run_compare_tests.step);
    test_step.dependOn(&run_tui_tests.step);

    // ─── ベンチマーク ─────────────────────────────────────────────────────────
    const bench_step = b.step("bench", "Run benchmark tests");
    bench_step.dependOn(&run_bench_tests.step);
}
