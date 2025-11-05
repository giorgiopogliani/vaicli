const std = @import("std");
const Env = @import("env.zig");
const Config = @import("config.zig");
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
        if (self.config.tasks.map.get(cmd)) |task| {
            try task.run(self.allocator, self.env, args);
        } else {
            self.help();
        }
    } else {
        self.help();
    }
}

pub fn help(self: *const App) void {
    std.debug.print("Usage: [command] [arguments]\n", .{});

    var copy = self.config.tasks.map.iterator();

    while (copy.next()) |entry| {
        std.debug.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.*.description });
    }
}
