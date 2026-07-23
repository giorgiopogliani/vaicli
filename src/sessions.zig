const std = @import("std");
const builtin = @import("builtin");
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
            std.mem.eql(u8, args[0], "-b") or
            std.mem.eql(u8, args[0], "-bt") or
            std.mem.eql(u8, args[0], "--persistent") or
            std.mem.eql(u8, args[0], "--list") or
            std.mem.eql(u8, args[0], "-l") or
            std.mem.eql(u8, args[0], "--rm") or
            std.mem.eql(u8, args[0], "--output") or
            std.mem.eql(u8, args[0], "-o") or
            std.mem.eql(u8, args[0], "--attach") or
            std.mem.eql(u8, args[0], "-a") or
            std.mem.eql(u8, args[0], "--mode");
    }

    pub fn run(self: *Cli, args: []const []const u8) !void {
        if (std.mem.eql(u8, args[0], "--bg") or
            std.mem.eql(u8, args[0], "-b") or
            std.mem.eql(u8, args[0], "-bt") or
            std.mem.eql(u8, args[0], "--persistent"))
        {
            return self.start(args);
        }
        if (std.mem.eql(u8, args[0], "--list") or std.mem.eql(u8, args[0], "-l")) {
            while (try self.tui(args[1..])) |job_id| {
                var id_buffer: [32]u8 = undefined;
                const id = try std.fmt.bufPrint(&id_buffer, "j{d}", .{job_id});
                try self.attach(&.{id});
            }
            return;
        }
        if (std.mem.eql(u8, args[0], "--rm")) return self.remove(args[1..]);
        if (std.mem.eql(u8, args[0], "--output") or std.mem.eql(u8, args[0], "-o")) {
            return self.output(args[1..]);
        }
        if (std.mem.eql(u8, args[0], "--attach") or std.mem.eql(u8, args[0], "-a")) {
            return self.attach(args[1..]);
        }
        if (std.mem.eql(u8, args[0], "--mode")) return self.mode(args[1..]);
        return error.InvalidArguments;
    }

    const TuiJob = struct {
        id: u64,
        session_id: u64,
        persistent: bool,
        uses_pty: bool,
        status: []u8,
        command: []u8,
        log_path: []u8,

        fn deinit(job: *TuiJob, allocator: std.mem.Allocator) void {
            allocator.free(job.status);
            allocator.free(job.command);
            allocator.free(job.log_path);
        }
    };

    const TuiSnapshot = struct {
        jobs: std.ArrayList(TuiJob),

        fn deinit(snapshot: *TuiSnapshot, allocator: std.mem.Allocator) void {
            for (snapshot.jobs.items) |*job| job.deinit(allocator);
            snapshot.jobs.deinit(allocator);
        }
    };

    const Preview = struct {
        data: []u8,
        lines: std.ArrayList([]const u8),

        fn deinit(preview: *Preview, allocator: std.mem.Allocator) void {
            allocator.free(preview.data);
            preview.lines.deinit(allocator);
        }
    };

    fn tui(self: *Cli, args: []const []const u8) !?u64 {
        if (args.len != 0) return error.InvalidArguments;
        const tty = try controllingTty(self.allocator);
        defer self.allocator.free(tty);

        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        cfmakeraw(&raw);
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

        var rendered_lines: usize = 0;
        defer {
            if (rendered_lines > 0) {
                self.stdout.print("\x1b[{d}A\r\x1b[J", .{rendered_lines}) catch {};
            }
            self.stdout.writeAll("\x1b[?25h") catch {};
            self.stdout.flush() catch {};
        }
        try self.stdout.writeAll("\x1b[?25l");

        var selected: usize = 0;
        var preview_scroll: usize = 0;
        var message: ?[]u8 = null;
        defer if (message) |text| self.allocator.free(text);

        while (true) {
            var snapshot = try self.fetchTuiSnapshot();
            defer snapshot.deinit(self.allocator);
            if (snapshot.jobs.items.len == 0) {
                selected = 0;
            } else if (selected >= snapshot.jobs.items.len) {
                selected = snapshot.jobs.items.len - 1;
            }

            rendered_lines = try self.renderTui(&snapshot, selected, preview_scroll, message, rendered_lines);
            try self.stdout.flush();

            var fds = [_]std.posix.pollfd{.{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            }};
            _ = try std.posix.poll(&fds, 200);
            if (fds[0].revents & std.posix.POLL.IN == 0) continue;

            var input: [16]u8 = undefined;
            const amount = std.Io.File.stdin().readStreaming(self.io, &.{&input}) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => return err,
            };
            if (amount == 0) continue;
            const key = input[0];
            if (key == 'q' or key == 3) return null;
            if (key == 'k' or isArrow(input[0..amount], 'A')) {
                selected -|= 1;
                preview_scroll = 0;
                continue;
            }
            if (key == 'j' or isArrow(input[0..amount], 'B')) {
                if (selected + 1 < snapshot.jobs.items.len) selected += 1;
                preview_scroll = 0;
                continue;
            }
            if (isPageKey(input[0..amount], '5')) {
                preview_scroll +|= 8;
                continue;
            }
            if (isPageKey(input[0..amount], '6')) {
                preview_scroll -|= 8;
                continue;
            }

            if (key == 'a') {
                if (snapshot.jobs.items.len == 0) continue;
                const job = snapshot.jobs.items[selected];
                if (job.uses_pty and std.mem.eql(u8, job.status, "running")) return job.id;
                if (message) |text| self.allocator.free(text);
                message = try self.allocator.dupe(
                    u8,
                    if (job.uses_pty) "selected job is not running" else "selected job has no PTY",
                );
                continue;
            }

            const action_kind: ?protocol.Kind = switch (key) {
                'd' => .remove_job,
                'r' => .restart_job,
                else => null,
            };
            if (action_kind) |kind| {
                if (snapshot.jobs.items.len == 0) continue;
                const id = try std.fmt.allocPrint(self.allocator, "j{d}", .{snapshot.jobs.items[selected].id});
                defer self.allocator.free(id);
                const response = try self.idRequest(kind, id, null);
                defer response.deinit(self.allocator);
                if (message) |text| self.allocator.free(text);
                message = try self.allocator.dupe(u8, std.mem.trimEnd(u8, response.payload, "\r\n"));
                continue;
            }
            if (key == 't') {
                if (snapshot.jobs.items.len == 0) continue;
                const id = try std.fmt.allocPrint(self.allocator, "s{d}", .{snapshot.jobs.items[selected].session_id});
                defer self.allocator.free(id);
                const response = try self.idRequest(.toggle_session_mode, id, tty);
                defer response.deinit(self.allocator);
                if (message) |text| self.allocator.free(text);
                message = try self.allocator.dupe(u8, std.mem.trimEnd(u8, response.payload, "\r\n"));
            }
        }
    }

    fn fetchTuiSnapshot(self: *Cli) !TuiSnapshot {
        const response = try self.request(.session_snapshot, "");
        defer response.deinit(self.allocator);
        if (response.kind == .response_error) {
            try self.printResponse(response);
            return error.DaemonRequestFailed;
        }

        var reader = protocol.PayloadReader.init(response.payload);
        var snapshot: TuiSnapshot = .{ .jobs = .empty };
        errdefer snapshot.deinit(self.allocator);
        const count = try reader.integer();
        if (count > max_items) return error.InvalidJobCount;
        for (0..@intCast(count)) |_| {
            try snapshot.jobs.append(self.allocator, .{
                .id = try reader.integer(),
                .session_id = try reader.integer(),
                .persistent = try reader.boolean(),
                .uses_pty = try reader.boolean(),
                .status = try self.allocator.dupe(u8, try reader.string()),
                .command = try self.allocator.dupe(u8, try reader.string()),
                .log_path = try self.allocator.dupe(u8, try reader.string()),
            });
        }
        if (!reader.done()) return error.TrailingPayload;
        return snapshot;
    }

    fn renderTui(
        self: *Cli,
        snapshot: *const TuiSnapshot,
        selected: usize,
        preview_scroll: usize,
        message: ?[]const u8,
        previous_lines: usize,
    ) !usize {
        const terminal = currentTerminalSize(self.io);
        const width: usize = if (terminal.col > 4) terminal.col - 1 else 79;
        const desired_left = @min(50, @max(18, (width * 2) / 5));
        const left_width: usize = @min(desired_left, width -| 4);
        const right_width: usize = width -| (left_width + 3);
        const available_rows: usize = if (terminal.row > 3) terminal.row - 3 else 1;
        const body_rows: usize = @min(8, available_rows);
        const total_lines: usize = body_rows + 3;

        if (previous_lines > 0) try self.stdout.print("\x1b[{d}A", .{previous_lines});
        try self.stdout.writeAll("\r\x1b[J");

        var preview: Preview = if (snapshot.jobs.items.len > 0)
            try self.loadPreview(snapshot.jobs.items[selected].log_path)
        else
            .{ .data = try self.allocator.alloc(u8, 0), .lines = .empty };
        defer preview.deinit(self.allocator);
        const maximum_scroll = preview.lines.items.len -| body_rows;
        const effective_scroll = @min(preview_scroll, maximum_scroll);
        const preview_start = maximum_scroll - effective_scroll;
        const preview_row_offset = if (preview.lines.items.len < body_rows)
            body_rows - preview.lines.items.len
        else
            0;

        const left_title = "Vai jobs";
        var right_header: [64]u8 = undefined;
        const right_title = if (snapshot.jobs.items.len > 0)
            try std.fmt.bufPrint(&right_header, "Output j{d}", .{snapshot.jobs.items[selected].id})
        else
            "Output";
        try self.renderPaneLine(left_title, right_title, left_width, right_width, false);
        try self.renderPaneLine("Jobs", "", left_width, right_width, false);

        const window_start = if (selected >= body_rows) selected - body_rows + 1 else 0;
        for (0..body_rows) |row| {
            const job_index = window_start + row;
            var left_buffer: [256]u8 = undefined;
            const left = if (job_index < snapshot.jobs.items.len) blk: {
                const job = snapshot.jobs.items[job_index];
                break :blk try std.fmt.bufPrint(&left_buffer, "{s} j{d}/s{d} {s} {s} {s} {s}", .{
                    if (job_index == selected) ">" else " ",
                    job.id,
                    job.session_id,
                    if (job.persistent) "persist" else "ephem",
                    if (job.uses_pty) "pty" else "plain",
                    job.status,
                    job.command,
                });
            } else "";
            const preview_index = preview_start + (row -| preview_row_offset);
            const right = if (row >= preview_row_offset and preview_index < preview.lines.items.len)
                preview.lines.items[preview_index]
            else
                "";
            try self.renderPaneLine(
                left,
                right,
                left_width,
                right_width,
                job_index < snapshot.jobs.items.len and job_index == selected,
            );
        }

        const footer = message orelse "↑↓ select  a attach  d del  r restart  t mode  PgUp/PgDn logs  q quit";
        try self.stdout.writeAll("\r\x1b[2K");
        _ = try self.writeLimited(footer, width);
        try self.stdout.writeAll("\r\n");
        return total_lines;
    }

    fn renderPaneLine(
        self: *Cli,
        left: []const u8,
        right: []const u8,
        left_width: usize,
        right_width: usize,
        selected: bool,
    ) !void {
        try self.stdout.writeAll("\r\x1b[2K");
        if (selected) try self.stdout.writeAll("\x1b[36m");
        const left_len = try self.writeLimited(left, left_width);
        if (selected) try self.stdout.writeAll("\x1b[0m");
        try self.stdout.splatByteAll(' ', left_width - left_len);
        try self.stdout.writeAll(" │ ");
        _ = try self.writeAnsiLimited(right, right_width);
        try self.stdout.writeAll("\x1b[0m\r\n");
    }

    fn writeLimited(self: *Cli, text: []const u8, limit: usize) !usize {
        const length = @min(text.len, limit);
        try self.stdout.writeAll(text[0..length]);
        return length;
    }

    fn writeAnsiLimited(self: *Cli, text: []const u8, limit: usize) !usize {
        var index: usize = 0;
        var visible: usize = 0;
        while (index < text.len and visible < limit) {
            if (text[index] == 0x1b and index + 1 < text.len and text[index + 1] == '[') {
                const escape_start = index;
                index += 2;
                while (index < text.len) : (index += 1) {
                    if (text[index] >= 0x40 and text[index] <= 0x7e) {
                        index += 1;
                        if (text[index - 1] == 'm') try self.stdout.writeAll(text[escape_start..index]);
                        break;
                    }
                }
                continue;
            }
            const sequence_length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
            const amount: usize = @min(sequence_length, text.len - index);
            try self.stdout.writeAll(text[index .. index + amount]);
            index += amount;
            visible += 1;
        }
        return visible;
    }

    fn loadPreview(self: *Cli, path: []const u8) !Preview {
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .{ .data = try self.allocator.alloc(u8, 0), .lines = .empty },
            else => return err,
        };
        defer file.close(self.io);
        const length = try file.length(self.io);
        const amount: usize = @intCast(@min(length, 16 * 1024));
        const raw = try self.allocator.alloc(u8, amount);
        defer self.allocator.free(raw);
        _ = try file.readPositionalAll(self.io, raw, length - amount);

        var sanitized: std.ArrayList(u8) = .empty;
        errdefer sanitized.deinit(self.allocator);
        var index: usize = 0;
        while (index < raw.len) {
            const byte = raw[index];
            if (byte == 0x1b and index + 1 < raw.len) {
                if (raw[index + 1] == '[') {
                    const escape_start = index;
                    index += 2;
                    while (index < raw.len) : (index += 1) {
                        if (raw[index] >= 0x40 and raw[index] <= 0x7e) {
                            index += 1;
                            if (raw[index - 1] == 'm') {
                                try sanitized.appendSlice(self.allocator, raw[escape_start..index]);
                            }
                            break;
                        }
                    }
                    continue;
                }
                if (raw[index + 1] == ']') {
                    index += 2;
                    while (index < raw.len) : (index += 1) {
                        if (raw[index] == 0x07) {
                            index += 1;
                            break;
                        }
                        if (raw[index] == 0x1b and index + 1 < raw.len and raw[index + 1] == '\\') {
                            index += 2;
                            break;
                        }
                    }
                    continue;
                }
                index += 2;
                continue;
            }
            index += 1;
            if (byte == '\r') continue;
            if (byte == '\n' or byte >= 0x20) {
                try sanitized.append(self.allocator, byte);
            } else if (byte == '\t') {
                try sanitized.append(self.allocator, ' ');
            }
        }
        const data = try sanitized.toOwnedSlice(self.allocator);
        var lines: std.ArrayList([]const u8) = .empty;
        errdefer lines.deinit(self.allocator);
        var iterator = std.mem.splitScalar(u8, data, '\n');
        while (iterator.next()) |line| try lines.append(self.allocator, line);
        return .{ .data = data, .lines = lines };
    }

    fn isArrow(input: []const u8, direction: u8) bool {
        return input.len >= 3 and input[0] == 0x1b and input[1] == '[' and input[2] == direction;
    }

    fn isPageKey(input: []const u8, key: u8) bool {
        return input.len >= 4 and input[0] == 0x1b and input[1] == '[' and input[2] == key and input[3] == '~';
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

    const OutputSource = struct {
        id: u64,
        path: []u8,
        offset: u64 = 0,
    };

    fn output(self: *Cli, args: []const []const u8) !void {
        var follow = false;
        var job_id: ?[]const u8 = null;
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--follow")) {
                if (follow) return error.InvalidArguments;
                follow = true;
            } else if (job_id == null) {
                job_id = arg;
            } else {
                return error.InvalidArguments;
            }
        }

        var sources: std.ArrayList(OutputSource) = .empty;
        defer {
            for (sources.items) |source| self.allocator.free(source.path);
            sources.deinit(self.allocator);
        }

        if (job_id) |id| {
            const response = try self.idRequest(.job_logs, id, null);
            defer response.deinit(self.allocator);
            if (response.kind == .response_error) return self.printResponse(response);
            try sources.append(self.allocator, .{
                .id = try parseId(id, 'j'),
                .path = try self.allocator.dupe(u8, response.payload),
            });
            if (follow) return self.followOutput(&sources, null);
            _ = try self.writeAvailable(&sources.items[0], false);
            return self.stdout.flush();
        }

        const tty = try controllingTty(self.allocator);
        defer self.allocator.free(tty);
        try self.refreshSessionOutputs(&sources, tty);
        if (follow) return self.followOutput(&sources, tty);
        for (sources.items) |*source| _ = try self.writeAvailable(source, true);
        return self.stdout.flush();
    }

    fn refreshSessionOutputs(
        self: *Cli,
        sources: *std.ArrayList(OutputSource),
        tty: []const u8,
    ) !void {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.string(tty);
        const bytes = try payload.finish();
        defer self.allocator.free(bytes);

        const response = try self.request(.session_outputs, bytes);
        defer response.deinit(self.allocator);
        if (response.kind == .response_error) return self.printResponse(response);

        var reader = protocol.PayloadReader.init(response.payload);
        const count = try reader.integer();
        if (count > max_items) return error.InvalidJobCount;
        for (0..@intCast(count)) |_| {
            const id = try reader.integer();
            const path = try reader.string();
            for (sources.items) |source| {
                if (source.id == id) break;
            } else {
                try sources.append(self.allocator, .{
                    .id = id,
                    .path = try self.allocator.dupe(u8, path),
                });
            }
        }
        if (!reader.done()) return error.TrailingPayload;
    }

    fn followOutput(
        self: *Cli,
        sources: *std.ArrayList(OutputSource),
        tty: ?[]const u8,
    ) !void {
        var iteration: usize = 0;
        var last_source: ?u64 = null;
        while (true) : (iteration += 1) {
            if (tty) |path| {
                if (iteration % 10 == 0) try self.refreshSessionOutputs(sources, path);
            }

            var wrote = false;
            for (sources.items) |*source| {
                const has_output = try self.hasAvailable(source);
                if (!has_output) continue;
                const show_header = sources.items.len > 1 and last_source != source.id;
                _ = try self.writeAvailable(source, show_header);
                last_source = source.id;
                wrote = true;
            }
            if (wrote) try self.stdout.flush();
            try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
        }
    }

    fn hasAvailable(self: *Cli, source: *OutputSource) !bool {
        const file = std.Io.Dir.cwd().openFile(self.io, source.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(self.io);
        const length = try file.length(self.io);
        if (length < source.offset) source.offset = 0;
        return length > source.offset;
    }

    fn writeAvailable(self: *Cli, source: *OutputSource, show_header: bool) !bool {
        const file = std.Io.Dir.cwd().openFile(self.io, source.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        defer file.close(self.io);
        const length = try file.length(self.io);
        if (length < source.offset) source.offset = 0;
        if (length == source.offset) return false;

        if (show_header) {
            try self.stdout.print("\x1b[36m==> j{d} <==\x1b[0m\n", .{source.id});
        }
        var buffer: [16 * 1024]u8 = undefined;
        while (source.offset < length) {
            const remaining: usize = @intCast(@min(length - source.offset, buffer.len));
            const amount = try file.readPositionalAll(self.io, buffer[0..remaining], source.offset);
            if (amount == 0) break;
            try self.stdout.writeAll(buffer[0..amount]);
            source.offset += amount;
        }
        return true;
    }

    const AttachInfo = struct {
        path: []u8,
        running: bool,
    };

    fn attach(self: *Cli, args: []const []const u8) !void {
        if (args.len != 1) return error.InvalidArguments;
        const id = try parseId(args[0], 'j');
        var info = try self.attachInfo(args[0]);
        defer self.allocator.free(info.path);
        if (!info.running) return error.JobNotRunning;

        const tty_path = try controllingTty(self.allocator);
        defer self.allocator.free(tty_path);
        const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
        var raw = original;
        cfmakeraw(&raw);

        try self.stdout.print("\x1b[36mattached to j{d}; Ctrl-] detaches\x1b[0m\r\n", .{id});
        try self.stdout.flush();
        try std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw);
        defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, original) catch {};

        var size = terminalSize(self.io, tty_path);
        self.sendPtyResize(args[0], size) catch {};
        var source: OutputSource = .{ .id = id, .path = info.path };
        _ = try self.writeAvailable(&source, false);
        try self.stdout.flush();

        var iteration: usize = 0;
        var detached = false;
        while (info.running) : (iteration += 1) {
            var poll_fds = [_]std.posix.pollfd{.{
                .fd = std.posix.STDIN_FILENO,
                .events = std.posix.POLL.IN | std.posix.POLL.HUP,
                .revents = 0,
            }};
            _ = try std.posix.poll(&poll_fds, 50);
            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                var input_buffer: [4096]u8 = undefined;
                const amount = std.Io.File.stdin().readStreaming(self.io, &.{&input_buffer}) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return err,
                };
                if (amount > 0) {
                    if (std.mem.indexOfScalar(u8, input_buffer[0..amount], 0x1d)) |detach_at| {
                        if (detach_at > 0) try self.sendPtyInput(args[0], input_buffer[0..detach_at]);
                        detached = true;
                        break;
                    }
                    try self.sendPtyInput(args[0], input_buffer[0..amount]);
                }
            }

            if (try self.writeAvailable(&source, false)) try self.stdout.flush();
            if (iteration % 10 == 0) {
                const current_size = terminalSize(self.io, tty_path);
                if (!sameTerminalSize(size, current_size)) {
                    size = current_size;
                    self.sendPtyResize(args[0], size) catch {};
                }
                const status = try self.attachInfo(args[0]);
                defer self.allocator.free(status.path);
                info.running = status.running;
            }
        }
        _ = try self.writeAvailable(&source, false);
        try self.stdout.print("\r\n\x1b[36m{s} j{d}\x1b[0m\r\n", .{
            if (detached) "detached from" else "job exited",
            id,
        });
        try self.stdout.flush();
    }

    fn attachInfo(self: *Cli, id: []const u8) !AttachInfo {
        const response = try self.idRequest(.attach_info, id, null);
        defer response.deinit(self.allocator);
        if (response.kind == .response_error) {
            try self.printResponse(response);
            return error.DaemonRequestFailed;
        }
        var reader = protocol.PayloadReader.init(response.payload);
        const uses_pty = try reader.boolean();
        const running = try reader.boolean();
        const path = try reader.string();
        if (!reader.done()) return error.TrailingPayload;
        if (!uses_pty) return error.JobHasNoPty;
        return .{ .path = try self.allocator.dupe(u8, path), .running = running };
    }

    fn sendPtyInput(self: *Cli, id: []const u8, input: []const u8) !void {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.string(id);
        try payload.string(input);
        const bytes = try payload.finish();
        defer self.allocator.free(bytes);
        const response = try self.request(.pty_input, bytes);
        defer response.deinit(self.allocator);
        if (response.kind == .response_error) return self.printResponse(response);
    }

    fn sendPtyResize(self: *Cli, id: []const u8, size: std.posix.winsize) !void {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.string(id);
        try payload.integer(size.row);
        try payload.integer(size.col);
        const bytes = try payload.finish();
        defer self.allocator.free(bytes);
        const response = try self.request(.pty_resize, bytes);
        defer response.deinit(self.allocator);
        if (response.kind == .response_error) return error.ResizeUnavailable;
    }

    fn start(self: *Cli, args: []const []const u8) !void {
        var persistent = false;
        var use_pty = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            if (std.mem.eql(u8, args[index], "--bg") or std.mem.eql(u8, args[index], "-b")) continue;
            if (std.mem.eql(u8, args[index], "-t")) {
                use_pty = true;
                continue;
            }
            if (std.mem.eql(u8, args[index], "-bt")) {
                use_pty = true;
                continue;
            }
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
            return self.sendStart(persistent, use_pty, tty, cwd, command_args);
        }
        return self.sendStart(persistent, use_pty, tty, cwd, command_args);
    }

    fn sendStart(
        self: *Cli,
        persistent: bool,
        use_pty: bool,
        tty: []const u8,
        cwd: []const u8,
        command_args: []const []const u8,
    ) !void {
        var payload = protocol.PayloadWriter.init(self.allocator);
        defer payload.deinit();
        try payload.boolean(persistent);
        try payload.boolean(use_pty);
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
    argv: []const []const u8,
    cwd: []const u8,
    environ: std.process.Environ.Map,
    log_path: []const u8,
    uses_pty: bool,
    pty_master: ?std.Io.File = null,
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
    exe_path: []const u8,
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
const PtyDrainContext = struct {
    registry: *Registry,
    job: *Job,
    master: std.Io.File,
    log: std.Io.File,
};
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

fn drainPty(context: *PtyDrainContext) void {
    defer context.master.close(context.registry.io);
    defer context.log.close(context.registry.io);
    defer {
        context.registry.mutex.lock();
        defer context.registry.mutex.unlock();
        context.job.pty_master = null;
    }

    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const amount = context.master.readStreaming(context.registry.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream, error.InputOutput => return,
            else => return,
        };
        if (amount == 0) {
            std.Io.sleep(context.registry.io, .fromMilliseconds(10), .awake) catch {};
            continue;
        }
        context.log.writeStreamingAll(context.registry.io, buffer[0..amount]) catch return;
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

pub fn runPtyChild(io: std.Io, argv: []const []const u8) !void {
    if (argv.len == 0) return error.MissingCommand;
    const slave = std.c.dup(std.posix.STDIN_FILENO);
    if (slave < 0) return error.DuplicatePtySlaveFailed;
    if (login_tty(slave) != 0) {
        _ = std.c.close(slave);
        return error.LoginTtyFailed;
    }
    return std.process.replace(io, .{ .argv = argv });
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

    const exe_path = try std.process.executablePathAlloc(io, allocator);
    var registry: Registry = .{
        .gpa = gpa,
        .allocator = allocator,
        .io = io,
        .paths = paths,
        .exe_path = exe_path,
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
        .list_sessions => listSessions(registry, allocator),
        .toggle_session_mode => toggleSessionMode(registry, allocator, frame.payload),
        .remove_job => removeJob(registry, allocator, frame.payload),
        .remove_session => removeSession(registry, allocator, frame.payload),
        .session_outputs => sessionOutputs(registry, allocator, frame.payload),
        .attach_info => attachInfo(registry, allocator, frame.payload),
        .pty_input => ptyInput(registry, frame.payload),
        .pty_resize => ptyResize(registry, frame.payload),
        .restart_job => restartJob(registry, allocator, frame.payload),
        .session_snapshot => sessionSnapshot(registry, allocator, frame.payload),
        else => error.InvalidRequest,
    };
}

fn spawnJobProcess(registry: *Registry, job: *Job, tty: []const u8) !void {
    const log_file = try std.Io.Dir.cwd().createFile(registry.io, job.log_path, .{ .permissions = .fromMode(0o600) });
    var log_transferred = false;
    defer if (!log_transferred) log_file.close(registry.io);

    var pty_master: ?std.Io.File = null;
    var pty_slave: ?std.Io.File = null;
    errdefer if (pty_master) |master| master.close(registry.io);
    errdefer if (pty_slave) |slave| slave.close(registry.io);

    const child = if (job.uses_pty) blk: {
        const pty = try createPty(registry.io, tty);
        pty_master = pty.master;
        pty_slave = pty.slave;
        const bootstrap_argv = try registry.gpa.alloc([]const u8, job.argv.len + 2);
        defer registry.gpa.free(bootstrap_argv);
        bootstrap_argv[0] = registry.exe_path;
        bootstrap_argv[1] = "--pty-child";
        @memcpy(bootstrap_argv[2..], job.argv);
        const spawned = try std.process.spawn(registry.io, .{
            .argv = bootstrap_argv,
            .cwd = .{ .path = job.cwd },
            .environ_map = &job.environ,
            .stdin = .{ .file = pty.slave },
            .stdout = .{ .file = pty.slave },
            .stderr = .{ .file = pty.slave },
        });
        pty.slave.close(registry.io);
        pty_slave = null;
        break :blk spawned;
    } else try std.process.spawn(registry.io, .{
        .argv = job.argv,
        .cwd = .{ .path = job.cwd },
        .environ_map = &job.environ,
        .stdin = .ignore,
        .stdout = .{ .file = log_file },
        .stderr = .{ .file = log_file },
        .pgid = 0,
    });

    const pid = child.id.?;
    job.pid = pid;
    job.pgid = pid;
    job.status = .running;
    job.exit_code = null;
    job.signal = null;
    job.pty_master = pty_master;

    if (pty_master) |master| {
        const drain_context = try registry.allocator.create(PtyDrainContext);
        drain_context.* = .{
            .registry = registry,
            .job = job,
            .master = master,
            .log = log_file,
        };
        const drain_thread = try std.Thread.spawn(.{}, drainPty, .{drain_context});
        drain_thread.detach();
        log_transferred = true;
        pty_master = null;
    }

    const context = try registry.allocator.create(ReapContext);
    context.* = .{ .registry = registry, .job = job, .child = child };
    const thread = try std.Thread.spawn(.{}, reapJob, .{context});
    thread.detach();
}

fn handleStart(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const persistent = try reader.boolean();
    const use_pty = try reader.boolean();
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
    const stored_argv = try registry.allocator.alloc([]const u8, argv.len);
    for (argv, stored_argv) |arg, *stored| stored.* = try registry.allocator.dupe(u8, arg);
    var stored_env = std.process.Environ.Map.init(registry.allocator);
    for (env.keys(), env.values()) |key, value| try stored_env.put(key, value);

    const job = try registry.allocator.create(Job);
    job.* = .{
        .id = job_id,
        .session_id = session.id,
        .pid = 0,
        .pgid = 0,
        .command = try registry.allocator.dupe(u8, argv[0]),
        .argv = stored_argv,
        .cwd = try registry.allocator.dupe(u8, cwd),
        .environ = stored_env,
        .log_path = try std.fmt.allocPrint(registry.allocator, "{s}/job-{d}.log", .{ registry.paths.logs_dir, job_id }),
        .uses_pty = use_pty,
    };
    try registry.jobs.append(registry.allocator, job);
    try session.jobs.append(registry.allocator, job);
    try spawnJobProcess(registry, job, tty);

    return .{ .payload = try std.fmt.allocPrint(
        allocator,
        "started {s}job j{d} in session s{d}\n",
        .{ if (use_pty) "PTY " else "", job.id, session.id },
    ) };
}

fn listJobs(registry: *Registry, allocator: std.mem.Allocator) !Response {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("JOB\tSESSION\tPID\tMODE\tSTATUS\tCOMMAND\n");
    for (registry.jobs.items) |job| {
        if (!job.active) continue;
        try output.writer.print("j{d}\ts{d}\t{d}\t{s}\t{s}", .{
            job.id,
            job.session_id,
            job.pid,
            if (job.uses_pty) "pty" else "plain",
            @tagName(job.status),
        });
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

fn restartJob(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    const job = registry.findJob(id) orelse {
        registry.mutex.unlock();
        return error.JobNotFound;
    };
    const session = registry.findSession(job.session_id) orelse {
        registry.mutex.unlock();
        return error.SessionNotFound;
    };
    const tty = session.tty;
    const old_pgid = job.pgid;
    if (job.status == .running or job.status == .stopping) {
        job.status = .stopping;
        std.posix.kill(-old_pgid, .TERM) catch {};
    }
    registry.mutex.unlock();

    var stopped = false;
    for (0..100) |_| {
        registry.mutex.lock();
        stopped = job.status != .running and job.status != .stopping and job.pty_master == null;
        registry.mutex.unlock();
        if (stopped) break;
        try std.Io.sleep(registry.io, .fromMilliseconds(10), .awake);
    }
    if (!stopped) {
        std.posix.kill(-old_pgid, .KILL) catch {};
        for (0..100) |_| {
            registry.mutex.lock();
            stopped = job.status != .running and job.status != .stopping and job.pty_master == null;
            registry.mutex.unlock();
            if (stopped) break;
            try std.Io.sleep(registry.io, .fromMilliseconds(10), .awake);
        }
    }
    if (!stopped) return error.RestartTimeout;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    if (!job.active or !session.active) return error.JobNotFound;
    try spawnJobProcess(registry, job, tty);
    return .{ .payload = try std.fmt.allocPrint(allocator, "restarted job j{d}\n", .{id}) };
}

fn sessionSnapshot(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    if (payload.len != 0) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    var output = protocol.PayloadWriter.init(allocator);
    defer output.deinit();
    var count: u64 = 0;
    for (registry.jobs.items) |job| {
        if (job.active and registry.findSession(job.session_id) != null) count += 1;
    }
    try output.integer(count);
    for (registry.jobs.items) |job| {
        if (!job.active) continue;
        const session = registry.findSession(job.session_id) orelse continue;
        try output.integer(job.id);
        try output.integer(session.id);
        try output.boolean(session.policy == .persistent);
        try output.boolean(job.uses_pty);
        try output.string(@tagName(job.status));
        try output.string(job.command);
        try output.string(job.log_path);
    }
    return .{ .payload = try output.finish() };
}

fn attachInfo(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    var output = protocol.PayloadWriter.init(allocator);
    defer output.deinit();
    try output.boolean(job.uses_pty);
    try output.boolean(job.status == .running or job.status == .stopping);
    try output.string(job.log_path);
    return .{ .payload = try output.finish() };
}

fn ptyInput(registry: *Registry, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    const input = try reader.string();
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    if (!job.uses_pty) return error.JobHasNoPty;
    if (job.status != .running) return error.JobNotRunning;
    const master = job.pty_master orelse return error.PtyClosed;
    try master.writeStreamingAll(registry.io, input);
    return .{ .payload = "" };
}

fn ptyResize(registry: *Registry, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    const rows = try reader.integer();
    const columns = try reader.integer();
    if (!reader.done()) return error.TrailingPayload;
    if (rows > std.math.maxInt(u16) or columns > std.math.maxInt(u16)) return error.InvalidTerminalSize;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    if (!job.uses_pty) return error.JobHasNoPty;
    const master = job.pty_master orelse return error.PtyClosed;
    var size: std.posix.winsize = .{
        .row = @intCast(rows),
        .col = @intCast(columns),
        .xpixel = 0,
        .ypixel = 0,
    };
    if (ioctl(master.handle, terminalResizeCode(), &size) != 0) return error.ResizePtyFailed;
    return .{ .payload = "" };
}

fn sessionOutputs(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const tty = try reader.string();
    if (!reader.done()) return error.TrailingPayload;

    registry.mutex.lock();
    defer registry.mutex.unlock();
    const session = registry.findSessionByTty(tty) orelse return error.SessionNotFound;
    var output = protocol.PayloadWriter.init(allocator);
    defer output.deinit();
    var count: u64 = 0;
    for (session.jobs.items) |job| if (job.active) {
        count += 1;
    };
    try output.integer(count);
    for (session.jobs.items) |job| {
        if (!job.active) continue;
        try output.integer(job.id);
        try output.string(job.log_path);
    }
    return .{ .payload = try output.finish() };
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

fn removeJob(registry: *Registry, allocator: std.mem.Allocator, payload: []u8) !Response {
    var reader = protocol.PayloadReader.init(payload);
    const id = try parseId(try reader.string(), 'j');
    if (!reader.done()) return error.TrailingPayload;
    registry.mutex.lock();
    defer registry.mutex.unlock();
    const job = registry.findJob(id) orelse return error.JobNotFound;
    registry.stopJob(job);
    try deleteJobLog(registry, job);
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
        try deleteJobLog(registry, job);
        job.active = false;
    }
    registry.stopSession(session);
    return .{ .payload = try std.fmt.allocPrint(allocator, "removed session s{d}\n", .{id}) };
}

fn deleteJobLog(registry: *Registry, job: *const Job) !void {
    std.Io.Dir.cwd().deleteFile(registry.io, job.log_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
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

fn terminalResizeCode() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.T.IOCSWINSZ,
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => 0x80087467,
        else => @compileError("PTY resize requires a POSIX TIOCSWINSZ implementation"),
    };
}

fn sameTerminalSize(a: std.posix.winsize, b: std.posix.winsize) bool {
    return a.row == b.row and a.col == b.col and a.xpixel == b.xpixel and a.ypixel == b.ypixel;
}

const PtyPair = struct {
    master: std.Io.File,
    slave: std.Io.File,
};

fn createPty(io: std.Io, tty_path: []const u8) !PtyPair {
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    var size = terminalSize(io, tty_path);
    if (openpty(&master_fd, &slave_fd, null, null, &size) != 0) return error.OpenPtyFailed;
    return .{
        .master = .{ .handle = master_fd, .flags = .{ .nonblocking = false } },
        .slave = .{ .handle = slave_fd, .flags = .{ .nonblocking = false } },
    };
}

fn currentTerminalSize(io: std.Io) std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdin(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return size;
    if (result.device_io_control < 0 or size.row == 0 or size.col == 0) {
        return .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    }
    return size;
}

fn terminalSize(io: std.Io, tty_path: []const u8) std.posix.winsize {
    var size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    const tty = std.Io.Dir.cwd().openFile(io, tty_path, .{ .mode = .read_only }) catch return size;
    defer tty.close(io);
    const result = io.operate(.{ .device_io_control = .{
        .file = tty,
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return size;
    if (result.device_io_control < 0) {
        size = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    }
    return size;
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
extern "c" fn cfmakeraw(termios_p: *std.posix.termios) void;
extern "c" fn daemon(nochdir: c_int, noclose: c_int) c_int;
extern "c" fn login_tty(fd: c_int) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn openpty(
    amaster: *c_int,
    aslave: *c_int,
    name: ?[*]u8,
    termp: ?*std.posix.termios,
    winp: ?*std.posix.winsize,
) c_int;
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
