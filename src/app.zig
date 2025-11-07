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
    std.debug.print("Usage: [command] [arguments]\n", .{});

    var copy = self.config.tasks.map.iterator();

    while (copy.next()) |entry| {
        Color.bold(" {s}", .{entry.key_ptr.*});
        if (entry.value_ptr.*.alias) |alias| {
            Color.normal(" ({s})", .{alias});
        }
        Color.normal(": {s}.\n", .{entry.value_ptr.*.description});
    }
}
