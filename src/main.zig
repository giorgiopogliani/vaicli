const std = @import("std");
const Env = @import("env.zig");
const App = @import("app.zig");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;
const Sessions = @import("sessions.zig");

test {
    _ = @import("env.zig");
    _ = @import("config.zig");
    _ = @import("paths.zig");
    _ = @import("protocol.zig");
    _ = @import("sessions.zig");
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, args) |raw, *arg| arg.* = raw;

    if (args.len == 2 and
        (std.mem.eql(u8, args[1], "--daemon") or std.mem.eql(u8, args[1], "-d")))
    {
        return Sessions.runDaemon(init.gpa, arena, init.io, init.environ_map);
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--pty-child")) {
        return Sessions.runPtyChild(init.io, args[2..]);
    }
    // Keep the existing config and dotenv order: config comes from the process
    // environment, then the command environment is overlaid by .env.
    var loader = ConfigLoader.init(init.gpa, init.io, init.environ_map);
    defer loader.deinit();
    var config = try loader.load();
    defer config.deinit();

    var env = Env.init(init.gpa, init.io);
    defer env.deinit();
    for (init.environ_map.keys(), init.environ_map.values()) |key, value| {
        try env.map.put(key, value);
    }

    const cwd_path = try std.process.currentPathAlloc(init.io, init.gpa);
    defer init.gpa.free(cwd_path);
    try env.map.put("CWD", std.fs.path.basename(cwd_path));

    // Preserve the project .env loader and its override semantics.
    env.parseFile(".env") catch {};

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const command_args = args[1..];
    if (Sessions.Cli.handles(command_args)) {
        const exe_path = try std.process.executablePathAlloc(init.io, init.gpa);
        defer init.gpa.free(exe_path);
        var cli: Sessions.Cli = .{
            .allocator = init.gpa,
            .io = init.io,
            .environ = init.environ_map,
            .config = &config,
            .env = &env,
            .exe_path = exe_path,
            .stdout = stdout,
        };
        try cli.run(command_args);
        return stdout.flush();
    }

    const app = App.init(init.gpa, init.io, &env, &config);
    try app.run(command_args);
    try stdout.flush();
}
