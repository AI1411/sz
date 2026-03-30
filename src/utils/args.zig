const std = @import("std");

pub const Args = struct {
    path: []const u8,
    depth: u32,
    top: u32,
};

const default_path = ".";
const default_depth: u32 = 3;
const default_top: u32 = 10;

/// Shared parsing logic. `argv` must not include argv[0].
/// Returns parsed Args. `path` points into `argv` (borrowed).
fn parseCore(argv: []const []const u8) !Args {
    var path: []const u8 = default_path;
    var path_set = false;
    var depth: u32 = default_depth;
    var top: u32 = default_top;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a numeric argument\n", .{arg});
                return error.InvalidArgument;
            }
            depth = std.fmt.parseInt(u32, argv[i], 10) catch {
                std.debug.print("error: invalid depth value '{s}'\n", .{argv[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--top")) {
            i += 1;
            if (i >= argv.len) {
                std.debug.print("error: {s} requires a numeric argument\n", .{arg});
                return error.InvalidArgument;
            }
            top = std.fmt.parseInt(u32, argv[i], 10) catch {
                std.debug.print("error: invalid top value '{s}'\n", .{argv[i]});
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("error: unknown option '{s}'\n", .{arg});
            return error.InvalidArgument;
        } else {
            if (path_set) {
                std.debug.print("error: too many path arguments\n", .{});
                return error.InvalidArgument;
            }
            path = arg;
            path_set = true;
        }
    }

    return Args{ .path = path, .depth = depth, .top = top };
}

/// Parse CLI arguments from the real process argv.
/// `allocator` is used only when the caller supplies a PATH (to outlive argv).
pub fn parse(allocator: std.mem.Allocator) !Args {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    // Convert [][:0]u8 to [][]const u8 (skip argv[0])
    const rest: []const []const u8 = blk: {
        const n = if (argv.len > 1) argv.len - 1 else 0;
        const buf = try allocator.alloc([]const u8, n);
        for (0..n) |k| buf[k] = argv[k + 1];
        break :blk buf;
    };
    defer allocator.free(rest);

    var result = try parseCore(rest);

    // argv is freed by the defer above; always dupe path so it outlives argv.
    // Note: even if path equals default_path in content, it may point into
    // argv rather than the static literal, so the condition-based skip is unsafe.
    result.path = try allocator.dupe(u8, result.path);
    return result;
}

/// Parse a slice of argument strings (argv[0] already stripped).
/// Input strings are borrowed — no allocation is performed.
/// Used for unit testing without real process args.
pub fn parseSlice(argv: []const []const u8) !Args {
    return parseCore(argv);
}

test "default args" {
    const parsed = try parseSlice(&.{});
    try std.testing.expectEqualStrings(".", parsed.path);
    try std.testing.expectEqual(@as(u32, 3), parsed.depth);
    try std.testing.expectEqual(@as(u32, 10), parsed.top);
}

test "parse path" {
    const parsed = try parseSlice(&.{"/tmp"});
    try std.testing.expectEqualStrings("/tmp", parsed.path);
}

test "parse depth long flag" {
    const parsed = try parseSlice(&.{ "/tmp", "--depth", "5" });
    try std.testing.expectEqualStrings("/tmp", parsed.path);
    try std.testing.expectEqual(@as(u32, 5), parsed.depth);
    try std.testing.expectEqual(@as(u32, 10), parsed.top);
}

test "parse top long flag" {
    const parsed = try parseSlice(&.{ "--top", "20" });
    try std.testing.expectEqualStrings(".", parsed.path);
    try std.testing.expectEqual(@as(u32, 3), parsed.depth);
    try std.testing.expectEqual(@as(u32, 20), parsed.top);
}

test "parse short flags" {
    const parsed = try parseSlice(&.{ "-d", "2", "-t", "5" });
    try std.testing.expectEqualStrings(".", parsed.path);
    try std.testing.expectEqual(@as(u32, 2), parsed.depth);
    try std.testing.expectEqual(@as(u32, 5), parsed.top);
}

test "unknown option returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--unknown"}));
}

test "missing depth value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--depth"}));
}

test "non-numeric depth returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "--depth", "abc" }));
}

test "missing top value returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{"--top"}));
}

test "non-numeric top returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "--top", "xyz" }));
}

test "too many path arguments returns error" {
    try std.testing.expectError(error.InvalidArgument, parseSlice(&.{ "/tmp", "/var" }));
}
