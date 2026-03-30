const std = @import("std");

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("sz: disk usage analyzer\n");
}

test "main compiles" {
    // placeholder test to satisfy `zig build test`
}
