const std = @import("std");
const Env = @import("env.zig");
const Config = @import("config.zig");
const Color = @import("colors.zig");
const App = @This();

allocator: std.mem.Allocator,
io: std.Io,
env: *Env,
config: *const Config,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *Env,
    config: *const Config,
) App {
    return .{ .allocator = allocator, .io = io, .env = env, .config = config };
}

pub fn run(self: *const App, args: []const []const u8) !void {
    if (args.len == 0) return self.help();
    const task = self.config.resolve(args[0]) orelse return self.help();
    try task.run(self.allocator, self.io, self.env, args[0], args[1..]);
}

pub fn help(self: *const App) void {
    Color.normal("Usage: vai [-b|--bg [-t] [--persistent]] <command> [arguments]\n", .{});
    Color.normal("       vai -bt [--persistent] <command> [arguments]\n", .{});
    Color.normal("       vai -l|--list\n", .{});
    Color.normal("       vai -o|--output [job] [-f|--follow]\n", .{});
    Color.normal("       vai -a|--attach <pty-job>\n", .{});
    Color.normal("       vai --rm <j|s-prefixed-id>\n", .{});
    Color.normal("       vai --mode <session>\n", .{});
    Color.normal("       vai -d|--daemon\n\n", .{});

    const max_len = self.getMaxLen();
    var iter = self.config.tasks.map.iterator();
    while (iter.next()) |entry| {
        const command = entry.key_ptr.*;
        if (entry.value_ptr.alias) |alias| {
            Color.normal("({s})", .{alias});
        } else {
            printMany(" ", 3);
        }
        Color.bold(" {s} ", .{command});
        printMany(".", max_len - command.len + 3);
        Color.normal(" {s}.\n", .{entry.value_ptr.description});
    }
}

fn printMany(char: []const u8, len: usize) void {
    for (0..len) |_| {
        Color.foreground(.{ .r = 110, .g = 110, .b = 110 }, "{s}", .{char});
    }
}

fn getMaxLen(self: *const App) usize {
    var max_len: usize = 0;
    var iter = self.config.tasks.map.iterator();
    while (iter.next()) |entry| {
        max_len = @max(max_len, entry.key_ptr.*.len + if (entry.value_ptr.alias) |a| a.len else 0);
    }
    return max_len;
}
