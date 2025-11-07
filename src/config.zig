const std = @import("std");
const toml = @import("toml");
const Env = @import("env.zig");
const Color = @import("colors.zig");

const Config = @This();

pub const Task = struct {
    description: []const u8,
    command: []const u8,

    pub fn run(self: *const Task, allocator: std.mem.Allocator, env: *Env, name: []const u8, args: *std.process.ArgIterator) !void {
        var command = try std.mem.concat(allocator, u8, &[_][]const u8{self.command});
        defer allocator.free(command);

        while (args.next()) |arg| {
            const old_command = command;
            command = try std.mem.concat(allocator, u8, &[_][]const u8{ command, " ", arg });
            allocator.free(old_command);
        }

        Color.cyan("[{s}] ", .{name});
        Color.italic("{s}\n", .{command});

        // Prepare argv with null-terminated strings
        const env_path = try allocator.dupeZ(u8, "/usr/bin/env");
        defer allocator.free(env_path);
        const bash_arg = try allocator.dupeZ(u8, "bash");
        defer allocator.free(bash_arg);
        const dash_c = try allocator.dupeZ(u8, "-c");
        defer allocator.free(dash_c);
        const command_z = try allocator.dupeZ(u8, command);
        defer allocator.free(command_z);

        const argv = [_:null]?[*:0]const u8{ env_path, bash_arg, dash_c, command_z, null };

        // Prepare envp from the environment map
        var envp_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (envp_list.items) |item| {
                allocator.free(item);
            }
            envp_list.deinit(allocator);
        }

        var it = env.map.iterator();
        while (it.next()) |entry| {
            const env_str = try std.fmt.allocPrint(allocator, "{s}={s}\x00", .{ entry.key_ptr.*, entry.value_ptr.* });
            try envp_list.append(allocator, env_str);
        }

        // Convert to null-terminated array of pointers
        const envp = try allocator.allocSentinel(?[*:0]const u8, envp_list.items.len, null);
        defer allocator.free(envp);
        for (envp_list.items, 0..) |item, i| {
            envp[i] = @ptrCast(item.ptr);
        }

        const err = std.posix.execveZ(env_path, &argv, envp);
        return err;
    }
};

tasks: toml.HashMap(Task),
allocator: std.mem.Allocator,

pub fn deinit(self: *Config) void {
    // Free all task strings
    var it = self.tasks.map.iterator();
    while (it.next()) |entry| {
        self.allocator.free(entry.key_ptr.*);
        self.allocator.free(entry.value_ptr.description);
        self.allocator.free(entry.value_ptr.command);
    }
    // Free the hashmap itself
    self.tasks.map.deinit();
}
