const std = @import("std");
const protocol = @import("protocol.zig");
const Paths = @import("paths.zig").Paths;
const Config = @import("config.zig");
const Env = @import("env.zig");

const stop_timeout_seconds = 3;
const max_items = 4096;

pub const Cli = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    config: *const Config,
    env: *const Env,
    exe_path: []const u8,
    stdout: *std.Io.Writer,

    pub fn handles(args: []const []const u8) bool {
        if (args.len == 0) return false;
        return std.mem.eql(u8, args[0], "--bg") or
            std.mem.eql(u8, args[0], "--persistent") or
            std.mem.eql(u8, args[0], "--list") or
            std.mem.eql(u8, args[0], "-l") or
            std.mem.eql(u8, args[0], "--rm") or
            std.mem.eql(u8, args[0], "--output") or
            std.mem.eql(u8, args[0], "-o") or
            std.mem.eql(u8, args[0], "--mode") or
            std.mem.eql(u8, args[0], "stop");
    }

    pub fn run(self: *Cli, args: []const []const u8) !void {
        if (std.mem.eql(u8, args[0], "--bg") or std.mem.eql(u8, args[0], "--persistent")) {
            return self.start(args);
        }
        if (std.mem.eql(u8, args[0], "--list") or std.mem.eql(u8, args[0], "-l")) {
            return self.list(args[1..]);
        }
        if (std.mem.eql(u8, args[0], "--rm")) return self.remove(args[1..]);
        if (std.mem.eql(u8, args[0], "--output") or std.mem.eql(u8, args[0], "-o")) {
            if (args.len != 2) return error.InvalidArguments;
            const response = try self.idRequest(.job_logs, args[1], null);
            defer response.deinit(self.allocator);
            if (response.kind == .response_error) return self.printResponse(response);
            const content = try std.Io.Dir.cwd().readFileAlloc(
                self.io,
                response.payload,
                self.allocator,
                .limited(64 * 1024 * 1024),
            );
            defer self.allocator.free(content);
            try self.stdout.writeAll(content);
            return self.stdout.flush();
        }
        if (std.mem.eql(u8, args[0], "stop")) {
            if (args.len != 2) return error.InvalidArguments;
            const response = try self.idRequest(.stop_job, args[1], null);
            defer response.deinit(self.allocator);
            return self.printResponse(response);
        }
        if (std.mem.eql(u8, args[0], "--mode")) return self.mode(args[1..]);
        return error.InvalidArguments;
    }

    fn list(self: *Cli, args: []const []const u8) !void {
        if (args.len > 1) return error.InvalidArguments;
        const kind: protocol.Kind = if (args.len == 0 or std.mem.eql(u8, args[0], "jobs"))
            .list_jobs
        else if (std.mem.eql(u8, args[0], "sessions"))
            .list_sessions
        else
            return error.InvalidArguments;
        const response = try self.request(kind, "");
        defer response.deinit(self.allocator);
        return self.printResponse(response);
    }

    fn remove(self: *Cli, args: []const []const u8) !void {
        if (args.len != 1 or args[0].len < 2) return error.InvalidArguments;
        const kind: protocol.Kind = switch (args[0][0]) {
            'j' => .remove_job,
            's' => .remove_session,
            else => return error.InvalidId,
        };
        const response = try self.idRequest(kind, args[0], null);
        defer response.deinit(self.allocator);
        return self.printResponse(response);
    }

    fn start(self: *Cli, args: []const []const u8) !void {
        var persistent = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--bg")) continue;
            if (std.mem.eql(u8, args[index], "--persistent")) {
                persistent = true;
                continue;
            }
            break;
        }
        if (index == args.len) return error.MissingCommand;

        const tty = try controllingTty(self.allocator);
        defer self.allocator.free(tty);
        const cwd = try std.process.currentPathAlloc(self.io, self.allocator);
        defer self.allocator.free(cwd);

        var command_args: []const []const u8 = args[index..];
        var expanded: ?[]u8 = null;
        defer if (expanded) |value| self.allocator.free(value);
        var shell_args: [3][]const u8 = undefined;
        if (self.config.resolve(command_args[0])) |task| {
            expanded = try task.expandedCommand(self.allocator, command_args[1..]);
            shell_args = .{ "/usr/bin/env", "bash", "-c" };
            var with_command = try self.allocator.alloc([]const u8, 4);
            defer self.allocator.free(with_command);
            with_command[0] = shell_args[0];
            with_command[1] = shell_args[1];
            with_command[2] = shell_args[2];
            with_command[3] = expanded.?;
            command_args = with_command;
            return self.sendStart(persistent, tty, cwd, command_args);
        }
        return self.sendStart(persistent, tty, cwd, command_args);
    }

    fn sendStart(
        self: *Cli,
        persistent: bool,
        tty: []const u8,
        cwd: []const u8,
        command_args: []const []const u8,
    ) !void {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.boolean(persistent);
        try payload.string(tty);
        try payload.string(cwd);
        try payload.integer(command_args.len);
        for (command_args) |arg| try payload.string(arg);
        const keys = self.env.map.keys();
        const values = self.env.map.values();
        try payload.integer(keys.len);
        for (keys, values) |key, value| {
            try payload.string(key);
            try payload.string(value);
        }
        const bytes = try payload.finish();
        defer self.allocator.free(bytes);
        const response = try self.request(.start_job, bytes);
        defer response.deinit(self.allocator);
        try self.printResponse(response);
    }

    fn mode(self: *Cli, args: []const []const u8) !void {
        if (args.len != 1) return error.InvalidArguments;
        const tty = try controllingTty(self.allocator);
        defer self.allocator.free(tty);
        const response = try self.idRequest(.toggle_session_mode, args[0], tty);
        defer response.deinit(self.allocator);
        return self.printResponse(response);
    }

    fn idRequest(self: *Cli, kind: protocol.Kind, id: []const u8, extra: ?[]const u8) !protocol.Frame {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.string(id);
        if (extra) |value| try payload.string(value);
        const bytes = try payload.finish();
        defer self.allocator.free(bytes);
        return self.request(kind, bytes);
    }

    fn request(self: *Cli, kind: protocol.Kind, payload: []const u8) !protocol.Frame {
        var paths = try Paths.init(self.allocator, self.environ);
        defer paths.deinit(self.allocator);
        try paths.ensure(self.io);

        const address = try std.Io.net.UnixAddress.init(paths.socket_path);
        const stream = address.connect(self.io) catch retry: {
            try self.startDaemon();
            var attempts: usize = 0;
            while (attempts < 100) : (attempts += 1) {
                if (address.connect(self.io)) |connected| break :retry connected else |_| {
                    try std.Io.sleep(self.io, .fromMilliseconds(20), .awake);
                }
            }
            return error.DaemonUnavailable;
        };
        defer stream.close(self.io);

        var write_buffer: [4096]u8 = undefined;
        var stream_writer = stream.writer(self.io, &write_buffer);
        try protocol.writeFrame(&stream_writer.interface, kind, payload);
        try stream_writer.interface.flush();

        var read_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(self.io, &read_buffer);
        return protocol.readFrame(self.allocator, &stream_reader.interface);
    }

    fn startDaemon(self: *Cli) !void {
        // The daemon is intentionally orphaned; it owns and reaps its own children.
        _ = try std.process.spawn(self.io, .{
            .argv = &.{ self.exe_path, "--daemon" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }

    fn printResponse(self: *Cli, response: protocol.Frame) !void {
        try self.stdout.writeAll(response.payload);
        if (response.payload.len == 0 or response.payload[response.payload.len - 1] != '\n') {
            try self.stdout.writeByte('\n');
        }
        try self.stdout.flush();
        if (response.kind == .response_error) return error.DaemonRequestFailed;
    }
};

const Policy = enum { ephemeral, persistent };
const JobStatus = enum { running, stopping, exited, signaled, failed };

const Session = struct {
    id: u64,
    tty: []const u8,
    policy: Policy,
    active: bool = true,
    watcher_active: bool = false,
    watcher_generation: u64 = 0,
    jobs: std.ArrayList(*Job) = .empty,
};

const Job = struct {
    id: u64,
    session_id: u64,
    pid: std.posix.pid_t,
    pgid: std.posix.pid_t,
    command: []const u8,
    log_path: []const u8,
    active: bool = true,
    status: JobStatus = .running,
    exit_code: ?u8 = null,
    signal: ?std.posix.SIG = null,
};

const Mutex = struct {
    io: std.Io,
    inner: std.Io.Mutex = .init,

    fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(self.io);
    }

    fn unlock(self: *Mutex) void {
        self.inner.unlock(self.io);
    }
};

const Registry = struct {
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: Paths,
    mutex: Mutex,
    sessions: std.ArrayList(*Session) = .empty,
    jobs: std.ArrayList(*Job) = .empty,
    next_session_id: u64 = 1,
    next_job_id: u64 = 1,

    fn findSessionByTty(self: *Registry, tty: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (session.active and std.mem.eql(u8, session.tty, tty)) return session;
        }
        return null;
    }

    fn findSession(self: *Registry, id: u64) ?*Session {
        for (self.sessions.items) |session| {
            if (session.active and session.id == id) return session;
        }
        return null;
    }

    fn findJob(self: *Registry, id: u64) ?*Job {
        for (self.jobs.items) |job| if (job.active and job.id == id) return job;
        return null;
    }

    fn stopJob(self: *Registry, job: *Job) void {
        if (job.status != .running) return;
        job.status = .stopping;
        std.posix.kill(-job.pgid, .TERM) catch {};
        const context = self.allocator.create(StopContext) catch return;
        context.* = .{ .registry = self, .job = job };
        const thread = std.Thread.spawn(.{}, escalateStop, .{context}) catch return;
        thread.detach();
    }

    fn stopSession(self: *Registry, session: *Session) void {
        for (session.jobs.items) |job| self.stopJob(job);
        session.watcher_generation += 1;
        session.watcher_active = false;
        session.active = false;
    }

    fn spawnWatcher(self: *Registry, session: *Session) !void {
        if (session.policy == .persistent or session.watcher_active) return;
        session.watcher_generation += 1;
        session.watcher_active = true;
        const context = try self.allocator.create(WatcherContext);
        context.* = .{
            .registry = self,
            .session = session,
            .generation = session.watcher_generation,
        };
        const thread = try std.Thread.spawn(.{}, watchTty, .{context});
        thread.detach();
    }
};

const ReapContext = struct { registry: *Registry, job: *Job, child: std.process.Child };
const StopContext = struct { registry: *Registry, job: *Job };
const WatcherContext = struct { registry: *Registry, session: *Session, generation: u64 };

fn reapJob(context: *ReapContext) void {
    const term = context.child.wait(context.registry.io) catch {
        context.registry.mutex.lock();
        defer context.registry.mutex.unlock();
        context.job.status = .failed;
        return;
    };
    context.registry.mutex.lock();
    defer context.registry.mutex.unlock();
    switch (term) {
        .exited => |code| {
            context.job.status = .exited;
            context.job.exit_code = code;
        },
        .signal => |signal| {
            context.job.status = .signaled;
            context.job.signal = signal;
        },
        else => context.job.status = .failed,
    }
}

fn escalateStop(context: *StopContext) void {
    std.Io.sleep(context.registry.io, .fromSeconds(stop_timeout_seconds), .awake) catch {};
    context.registry.mutex.lock();
    defer context.registry.mutex.unlock();
    if (context.job.status == .running or context.job.status == .stopping) {
        std.posix.kill(-context.job.pgid, .KILL) catch {};
    }
}

fn watchTty(context: *WatcherContext) void {
    const tty = std.Io.Dir.cwd().openFile(
        context.registry.io,
        context.session.tty,
        .{ .mode = .read_only },
    ) catch {
        context.registry.mutex.lock();
        defer context.registry.mutex.unlock();
        if (context.session.watcher_generation == context.generation) {
            context.session.watcher_active = false;
        }
        return;
    };
    defer tty.close(context.registry.io);

    var fds = [_]std.posix.pollfd{.{
        .fd = tty.handle,
        .events = std.posix.POLL.HUP | std.posix.POLL.ERR,
        .revents = 0,
    }};
    while (true) {
        _ = std.posix.poll(&fds, 500) catch return;

        context.registry.mutex.lock();
        defer context.registry.mutex.unlock();
        if (!context.session.active or
            context.session.policy != .ephemeral or
            context.session.watcher_generation != context.generation)
        {
            return;
        }
        if (fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) {
            context.registry.stopSession(context.session);
            return;
        }
    }
}

pub fn runDaemon(
    gpa: std.mem.Allocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !void {
    if (c_daemon() != 0) return error.DaemonizeFailed;
    var paths = try Paths.init(allocator, environ);
    try paths.ensure(io);
    const lock_file = std.Io.Dir.cwd().createFile(io, paths.lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    }) catch |err| switch (err) {
        error.WouldBlock => return,
        else => return err,
    };
    defer lock_file.close(io);

    var registry: Registry = .{
        .gpa = gpa,
        .allocator = allocator,
        .io = io,
        .paths = paths,
        .mutex = .{ .io = io },
    };

    const address = try std.Io.net.UnixAddress.init(paths.socket_path);
    var server = address.listen(io, .{}) catch |err| switch (err) {
        error.AddressInUse => blk: {
            if (address.connect(io)) |existing| {
                existing.close(io);
                return;
            } else |_| {}
            std.Io.Dir.cwd().deleteFile(io, paths.socket_path) catch {};
            break :blk try address.listen(io, .{});
        },
        else => return err,
    };
    defer server.deinit(io);
    defer std.Io.Dir.cwd().deleteFile(io, paths.socket_path) catch {};

    while (true) {
        const stream = try server.accept(io);
        serve(&registry, stream) catch {};
    }
}

fn serve(registry: *Registry, stream: std.Io.net.Stream) !void {
    defer stream.close(registry.io);
    var arena = std.heap.ArenaAllocator.init(registry.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var read_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(registry.io, &read_buffer);
    const frame = try protocol.readFrame(allocator, &stream_reader.interface);

    const response = handleRequest(registry, allocator, frame) catch |err| Response{
        .kind = .response_error,
        .payload = try std.fmt.allocPrint(allocator, "error: {s}\n", .{@errorName(err)}),
    };

    var write_buffer: [4096]u8 = undefined;
    var stream_writer = stream.writer(registry.io, &write_buffer);
    try protocol.writeFrame(&stream_writer.interface, response.kind, response.payload);
    try stream_writer.interface.flush();
}

const Response = struct { kind: protocol.Kind = .response_ok, payload: []const u8 };

fn handleRequest(registry: *Registry, allocator: std.mem.Allocator, frame: protocol.Frame) !Response {
    return switch (frame.kind) {
        .start_job => handleStart(registry, allocator, frame.payload),
        .list_jobs => listJobs(registry, allocator),
        .job_logs => jobLogs(registry, frame.payload),
        .stop_job => stopJobRequest(registry, allocator, frame.payload),
        .list_sessions => listSessions(registry, allocator),
        .toggle_session_mode => toggleSessionMode(registry, allocator, frame.payload),
        .remove_job => removeJob(registry, allocator, frame.payload),
        .remove_session => removeSession(registry, allocator, frame.payload),
        else => error.InvalidRequest,
    };
}

fn handleStart(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const persistent = try reader.boolean();
    const tty = try reader.string();
    const cwd = try reader.string();
    const argc = try reader.integer();
    if (argc == 0 or argc > max_items) return error.InvalidArgumentCount;
    const argv = try allocator.alloc([]const u8, @intCast(argc));
    for (argv) |*arg| arg.* = try reader.string();

    const env_count = try reader.integer();
    if (env_count > max_items) return error.InvalidEnvironment;
    var env = std.process.Environ.Map.init(allocator);
    for (0..@intCast(env_count)) |_| try env.put(try reader.string(), try reader.string());
    try env.put("FORCE_COLOR", "1");
    try env.put("CLICOLOR_FORCE", "1");
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();

    var session = registry.findSessionByTty(tty) orelse blk: {
        const created = try registry.allocator.create(Session);
        created.* = .{
            .id = registry.next_session_id,
            .tty = try registry.allocator.dupe(u8, tty),
            .policy = if (persistent) .persistent else .ephemeral,
        };
        registry.next_session_id += 1;
        try registry.sessions.append(registry.allocator, created);
        if (created.policy == .ephemeral) try registry.spawnWatcher(created);
        break :blk created;
    };
    if (persistent and session.policy == .ephemeral) {
        session.policy = .persistent;
        session.watcher_generation += 1;
        session.watcher_active = false;
    }

    const job_id = registry.next_job_id;
    registry.next_job_id += 1;
    const log_path = try std.fmt.allocPrint(registry.allocator, "{s}/job-{d}.log", .{ registry.paths.logs_dir, job_id });
    const log_file = try std.Io.Dir.cwd().createFile(registry.io, log_path, .{ .permissions = .fromMode(0o600) });
    defer log_file.close(registry.io);

    const child = try std.process.spawn(registry.io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        .pgid = 0,
    });
    const pid = child.id.?;
    const job = try registry.allocator.create(Job);
    job.* = .{
        .id = job_id,
        .session_id = session.id,
        .pid = pid,
        .pgid = pid,
        .command = try registry.allocator.dupe(u8, argv[0]),
        .log_path = log_path,
    };
    try registry.jobs.append(registry.allocator, job);
    try session.jobs.append(registry.allocator, job);

    const context = try registry.allocator.create(ReapContext);
    context.* = .{ .registry = registry, .job = job, .child = child };
    const thread = try std.Thread.spawn(.{}, reapJob, .{context});
    thread.detach();

    return .{ .payload = try std.fmt.allocPrint(allocator, "started job j{d} in session s{d}\n", .{ job.id, session.id }) };
}

fn listJobs(registry: *Registry, allocator: std.mem.Allocator) !Response {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("JOB\tSESSION\tPID\tSTATUS\tCOMMAND\n");
    for (registry.jobs.items) |job| {
        if (!job.active) continue;
        try output.writer.print("j{d}\ts{d}\t{d}\t{s}", .{ job.id, job.session_id, job.pid, @tagName(job.status) });
        if (job.exit_code) |code| try output.writer.print("({d})", .{code});
        if (job.signal) |signal| try output.writer.print("({s})", .{@tagName(signal)});
        try output.writer.print("\t{s}\n", .{job.command});
    }
    return .{ .payload = try output.toOwnedSlice() };
}

fn listSessions(registry: *Registry, allocator: std.mem.Allocator) !Response {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("SESSION\tPOLICY\tJOBS\tTTY\n");
    for (registry.sessions.items) |session| {
        if (!session.active) continue;
        var job_count: usize = 0;
        for (session.jobs.items) |job| if (job.active) {
            job_count += 1;
        };
        try output.writer.print("s{d}\t{s}\t{d}\t{s}\n", .{
            session.id,
            @tagName(session.policy),
            job_count,
            session.tty,
        });
    }
    return .{ .payload = try output.toOwnedSlice() };
}

fn jobLogs(registry: *Registry, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;
    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    return .{ .payload = job.log_path };
}

fn stopJobRequest(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;
    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    registry.stopJob(job);
    return .{ .payload = try std.fmt.allocPrint(allocator, "stopping job j{d}\n", .{id}) };
}

fn removeJob(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;
    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    registry.stopJob(job);
    job.active = false;
    return .{ .payload = try std.fmt.allocPrint(allocator, "removed job j{d}\n", .{id}) };
}

fn removeSession(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 's');
    if (!reader.done()) return error.TrailingPayload;
    registry.mutex.lock();
    defer registry.mutex.unlock();
    const session = registry.findSession(id) orelse return error.SessionNotFound;
    for (session.jobs.items) |job| {
        registry.stopJob(job);
        job.active = false;
    }
    registry.stopSession(session);
    return .{ .payload = try std.fmt.allocPrint(allocator, "removed session s{d}\n", .{id}) };
}

fn toggleSessionMode(
    registry: *Registry,
    allocator: std.mem.Allocator,
    payload: []u8,
) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 's');
    const tty = try reader.string();
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    const session = registry.findSession(id) orelse return error.SessionNotFound;
    switch (session.policy) {
        .ephemeral => {
            session.policy = .persistent;
            session.watcher_generation += 1;
            session.watcher_active = false;
        },
        .persistent => {
            session.policy = .ephemeral;
            session.watcher_generation += 1;
            session.watcher_active = false;
            session.tty = try registry.allocator.dupe(u8, tty);
            try registry.spawnWatcher(session);
        },
    }
    return .{ .payload = try std.fmt.allocPrint(
        allocator,
        "session s{d}: {s}\n",
        .{ id, @tagName(session.policy) },
    ) };
}

fn parseId(text: []const u8, prefix: u8) !u64 {
    const digits = if (text.len > 0 and text[0] == prefix) text[1..] else text;
    if (digits.len == 0) return error.InvalidId;
    return std.fmt.parseInt(u64, digits, 10) catch error.InvalidId;
}

fn controllingTty(allocator: std.mem.Allocator) ![]u8 {
    for ([_]c_int{ 0, 1, 2 }) |fd| {
        if (c_ttyname(fd)) |name| return allocator.dupe(u8, std.mem.span(name));
    }
    return error.NoControllingTty;
}

extern "c" fn ttyname(fd: c_int) ?[*:0]u8;
extern "c" fn daemon(nochdir: c_int, noclose: c_int) c_int;
fn c_ttyname(fd: c_int) ?[*:0]u8 {
    return ttyname(fd);
}
fn c_daemon() c_int {
    return daemon(1, 0);
}

test "job and session ids accept prefixes" {
    try std.testing.expectEqual(@as(u64, 12), try parseId("j12", 'j'));
    try std.testing.expectEqual(@as(u64, 7), try parseId("7", 's'));
    try std.testing.expectError(error.InvalidId, parseId("j", 'j'));
}
