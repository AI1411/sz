const std = @import("std");

pub const Args = struct {
    path: []const u8,
    depth: u32,
    top: u32,
};

const default_path = ".";
const default_depth: u32 = 3;
const default_top: u32 = 10;

/// Parse CLI arguments from the real process argv.
/// `allocator` is used to duplicate the PATH string (caller must free if path != ".").
pub fn parse(allocator: std.mem.Allocator) !Args {
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var path: []const u8 = default_path;
    var depth: u32 = default_depth;
    var top: u32 = default_top;

    var i: usize = 1; // skip program name
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
            // argv is freed after this function; duplicate the path so it survives.
            path = try allocator.dupe(u8, arg);
        }
    }

    return Args{
        .path = path,
        .depth = depth,
        .top = top,
    };
}

/// Parse a slice of argument strings (argv[0] already stripped).
/// Input strings are borrowed — no allocation is performed.
/// Used for unit testing without real process args.
pub fn parseSlice(argv: []const []const u8) !Args {
    var path: []const u8 = default_path;
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
            path = arg;
        }
    }

    return Args{
        .path = path,
        .depth = depth,
        .top = top,
    };
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
