const std = @import("std");
const args = @import("utils/args.zig");

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

    var buf: [4096]u8 = undefined;
    const stdout = std.fs.File.stdout();
    const line = try std.fmt.bufPrint(&buf, "path={s} depth={d} top={d}\n", .{
        parsed.path,
        parsed.depth,
        parsed.top,
    });
    try stdout.writeAll(line);
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
