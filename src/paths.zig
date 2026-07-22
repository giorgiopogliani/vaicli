const std = @import("std");

pub const Paths = struct {
    runtime_dir: []u8,
    state_dir: []u8,
    socket_path: []u8,
    lock_path: []u8,
    logs_dir: []u8,

    pub fn init(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) !Paths {
        const home = environ.get("HOME");
        const runtime_dir = if (environ.get("VAI_RUNTIME_DIR")) |path|
            try allocator.dupe(u8, path)
        else if (home) |base|
            try std.fs.path.join(allocator, &.{ base, ".config", "vai" })
        else
            return error.HomeNotSet;
        errdefer allocator.free(runtime_dir);

        const state_dir = if (environ.get("VAI_STATE_DIR")) |path|
            try allocator.dupe(u8, path)
        else if (home) |base|
            try std.fs.path.join(allocator, &.{ base, ".config", "vai" })
        else
            return error.HomeNotSet;
        errdefer allocator.free(state_dir);

        const socket_path = try std.fs.path.join(allocator, &.{ runtime_dir, "daemon.sock" });
        errdefer allocator.free(socket_path);
        const lock_path = try std.fs.path.join(allocator, &.{ runtime_dir, "daemon.lock" });
        errdefer allocator.free(lock_path);
        const logs_dir = try std.fs.path.join(allocator, &.{ state_dir, "logs" });
        errdefer allocator.free(logs_dir);

        if (socket_path.len > std.Io.net.UnixAddress.max_len) return error.SocketPathTooLong;
        return .{
            .runtime_dir = runtime_dir,
            .state_dir = state_dir,
            .socket_path = socket_path,
            .lock_path = lock_path,
            .logs_dir = logs_dir,
        };
    }

    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_dir);
        allocator.free(self.state_dir);
        allocator.free(self.socket_path);
        allocator.free(self.lock_path);
        allocator.free(self.logs_dir);
        self.* = undefined;
    }

    pub fn ensure(self: *const Paths, io: std.Io) !void {
        try std.Io.Dir.cwd().createDirPath(io, self.runtime_dir);
        var runtime = try std.Io.Dir.cwd().openDir(io, self.runtime_dir, .{});
        defer runtime.close(io);
        runtime.setPermissions(io, .fromMode(0o700)) catch {};

        try std.Io.Dir.cwd().createDirPath(io, self.logs_dir);
        var state = try std.Io.Dir.cwd().openDir(io, self.state_dir, .{});
        defer state.close(io);
        state.setPermissions(io, .fromMode(0o700)) catch {};
    }
};

test "defaults to the vai config directory" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("HOME", "/home/tester");
    var paths = try Paths.init(std.testing.allocator, &env);
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/home/tester/.config/vai/daemon.sock", paths.socket_path);
    try std.testing.expectEqualStrings("/home/tester/.config/vai/daemon.lock", paths.lock_path);
    try std.testing.expectEqualStrings("/home/tester/.config/vai/logs", paths.logs_dir);
}

test "explicit runtime and state paths" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("VAI_RUNTIME_DIR", "/tmp/vai-runtime-test");
    try env.put("VAI_STATE_DIR", "/tmp/vai-state-test");
    var paths = try Paths.init(std.testing.allocator, &env);
    defer paths.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/tmp/vai-runtime-test/daemon.sock", paths.socket_path);
    try std.testing.expectEqualStrings("/tmp/vai-runtime-test/daemon.lock", paths.lock_path);
    try std.testing.expectEqualStrings("/tmp/vai-state-test/logs", paths.logs_dir);
}
