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
    _ = result;
    _ = parsed.depth;
    _ = parsed.top;
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
