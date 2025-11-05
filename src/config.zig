const std = @import("std");
const toml = @import("toml");
const Env = @import("env.zig");

const Task = struct {
    description: []const u8,
    command: []const u8,

    pub fn run(self: *const Task, allocator: std.mem.Allocator, env: *Env, args: *std.process.ArgIterator) !void {
        var command = try std.mem.concat(allocator, u8, &[_][]const u8{ self.command, " " });

        while (args.next()) |arg| {
            command = try std.mem.concat(allocator, u8, &[_][]const u8{ command, " ", arg });
        }

        std.debug.print("{s}", .{command});

        var child = std.process.Child.init(&[_][]const u8{ "env", "bash", "-c", self.command }, allocator);
        child.env_map = &env.map;
        try child.spawn();
        _ = try child.wait();
    }
};

const Config = @This();

tasks: toml.HashMap(Task),
