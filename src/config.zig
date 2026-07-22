const std = @import("std");
const toml = @import("toml");
const Env = @import("env.zig");
const Color = @import("colors.zig");

const Config = @This();

pub const Task = struct {
    description: []const u8,
    command: []const u8,
    alias: ?[]const u8 = null,

    pub fn expandedCommand(
        self: *const Task,
        allocator: std.mem.Allocator,
        args: []const []const u8,
    ) ![]u8 {
        var output: std.Io.Writer.Allocating = .init(allocator);
        errdefer output.deinit();
        try output.writer.writeAll(self.command);
        for (args) |arg| {
            try output.writer.writeAll(" '");
            for (arg) |byte| {
                if (byte == '\'') try output.writer.writeAll("'\\''") else try output.writer.writeByte(byte);
            }
            try output.writer.writeByte('\'');
        }
        return output.toOwnedSlice();
    }

    pub fn run(
        self: *const Task,
        allocator: std.mem.Allocator,
        io: std.Io,
        env: *const Env,
        name: []const u8,
        args: []const []const u8,
    ) !void {
        const command = try self.expandedCommand(allocator, args);
        defer allocator.free(command);

        Color.cyan("[{s}] ", .{name});
        Color.italic("{s}\n", .{command});

        return std.process.replace(io, .{
            .argv = &.{ "/usr/bin/env", "bash", "-c", command },
            .environ_map = &env.map,
        });
    }
};

tasks: toml.HashMap(Task),
aliases: std.StringHashMap([]const u8),
allocator: std.mem.Allocator,

pub fn resolve(self: *const Config, name: []const u8) ?*const Task {
    if (self.tasks.map.getPtr(name)) |task| return task;
    if (self.aliases.get(name)) |task_name| return self.tasks.map.getPtr(task_name);
    return null;
}

pub fn deinit(self: *Config) void {
    var it = self.tasks.map.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.description);
        self.allocator.free(entry.value_ptr.command);
        if (entry.value_ptr.alias) |alias| self.allocator.free(alias);
    }
    self.tasks.map.deinit();
    self.aliases.deinit();
}

test "task arguments remain single shell arguments" {
    const task: Task = .{ .description = "test", .command = "echo" };
    const command = try task.expandedCommand(std.testing.allocator, &.{ "hello world", "a'b" });
    defer std.testing.allocator.free(command);
    try std.testing.expectEqualStrings("echo 'hello world' 'a'\\''b'", command);
}
