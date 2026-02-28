const std = @import("std");
const Env = @import("env.zig");
const Config = @import("config.zig");
const Color = @import("colors.zig");
const App = @This();

allocator: std.mem.Allocator,
env: *Env,
config: *const Config,

pub fn init(allocator: std.mem.Allocator, env: *Env, config: *const Config) App {
    return App{
        .allocator = allocator,
        .env = env,
        .config = config,
    };
}

pub fn run(self: *const App, args: *std.process.ArgIterator) !void {
    const command = args.next();

    if (command) |cmd| {
        // First check if it's a task name
        if (self.config.tasks.map.get(cmd)) |task| {
            try task.run(self.allocator, self.env, cmd, args);
            return;
        }

        // If not, check if it's an alias
        if (self.config.aliases.get(cmd)) |task_name| {
            if (self.config.tasks.map.get(task_name)) |task| {
                try task.run(self.allocator, self.env, task_name, args);
                return;
            }
        }

        // Command not found
        self.help();
    } else {
        self.help();
    }
}

pub fn help(self: *const App) void {
    Color.normal("Usage: [command] [arguments]\n", .{});
    const maxLen: usize = self.getMaxLen();
    var iter = self.config.tasks.map.iterator();

    while (iter.next()) |entry| {
        const command = entry.key_ptr.*;

        if (entry.value_ptr.*.alias) |alias| {
            Color.normal("({s})", .{alias});
        } else {
            printMany(" ", "   ".len);
        }
        Color.bold(" {s} ", .{command});

        const alignSpaces = maxLen - command.len;
        printMany(".", alignSpaces + 3);
        Color.normal(" {s}.\n", .{entry.value_ptr.*.description});
    }
}

fn printMany(char: []const u8, len: usize) void {
    var i: u8 = 0;
    while (i < len) {
        Color.foreground(.{ .r = 110, .g = 110, .b = 110 }, "{s}", .{char});
        i += 1;
    }
}

fn getMaxLen(self: *const App) usize {
    var maxLen: usize = 0;
    var iter = self.config.tasks.map.iterator();
    while (iter.next()) |entry| {
        const name = entry.key_ptr.*;
        var aliasLen: usize = 0;
        if (entry.value_ptr.*.alias) |alias| {
            aliasLen = alias.len;
        }
        maxLen = @max(maxLen, name.len + aliasLen);
    }
    return maxLen;
}
