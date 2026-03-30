const std = @import("std");
const args_mod = @import("utils/args.zig");
const scanner = @import("scanner/parallel.zig");
const tree = @import("render/tree.zig");

const version_str = "0.1.0";

const help_text =
    \\sz - directory size visualizer
    \\
    \\USAGE:
    \\  sz [OPTIONS] [PATH]
    \\
    \\ARGS:
    \\  PATH  Directory to scan (default: current directory)
    \\
    \\OPTIONS:
    \\  -d, --depth <N>    Max display depth (default: 3)
    \\  -t, --top <N>      Max entries per directory (default: 10)
    \\  -h, --help         Show this help message
    \\  -V, --version      Show version
    \\
;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = args_mod.parse(allocator) catch |err| {
        switch (err) {
            error.InvalidArgument => std.process.exit(1),
            else => return err,
        }
    };

    if (parsed.help) {
        try std.fs.File.stdout().writeAll(help_text);
        return;
    }

    if (parsed.version) {
        try std.fs.File.stdout().writeAll("sz " ++ version_str ++ "\n");
        return;
    }

    const start_ms = std.time.milliTimestamp();
    const result = try scanner.scan(allocator, parsed.path, .{});
    const elapsed_ms = std.time.milliTimestamp() - start_ms;

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try tree.render(out.writer(allocator), &result.root, .{
        .depth = parsed.depth,
        .top = parsed.top,
        .color = true,
        .bar_width = 20,
    }, elapsed_ms);
    try std.fs.File.stdout().writeAll(out.items);
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
