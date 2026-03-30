const std = @import("std");
const args = @import("utils/args.zig");
const scanner = @import("scanner/posix.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = args.parse(allocator) catch |err| {
        switch (err) {
            error.InvalidArgument => std.process.exit(1),
            else => return err,
        }
    };

    const result = try scanner.scan(allocator, parsed.path, .{});
    _ = parsed.depth;
    _ = parsed.top;

    var buf: [4096]u8 = undefined;
    const stdout = std.fs.File.stdout();
    const line = try std.fmt.bufPrint(&buf, "{s}: {d} bytes, {d} files, {d} dirs\n", .{
        parsed.path,
        result.root.total_size,
        result.root.file_count,
        result.root.dir_count,
    });
    try stdout.writeAll(line);
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
