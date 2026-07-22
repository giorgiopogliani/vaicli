const std = @import("std");
const toml = @import("toml");
const Config = @import("config.zig");

pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,

    const RawConfig = struct {
        tasks: toml.HashMap(Config.Task),
        preset: ?PresetMetadata = null,
    };

    pub const Rule = struct {
        when_file: ?[]const u8 = null,
    };

    pub const PresetMetadata = struct {
        when_file: ?[]const u8 = null,
        rules: ?[]Rule = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        environ: *const std.process.Environ.Map,
    ) ConfigLoader {
        return .{ .allocator = allocator, .io = io, .environ = environ };
    }

    pub fn deinit(_: *ConfigLoader) void {}

    pub fn load(self: *ConfigLoader) !Config {
        var merged_tasks = std.StringHashMap(Config.Task).init(self.allocator);

        try self.loadGlobalConfig(&merged_tasks);
        try self.loadAndApplyPresets(&merged_tasks);
        try self.loadLocalConfig(&merged_tasks);

        var aliases = std.StringHashMap([]const u8).init(self.allocator);
        var task_it = merged_tasks.iterator();
        while (task_it.next()) |entry| {
            if (entry.value_ptr.alias) |alias| {
                try aliases.put(alias, entry.key_ptr.*);
            }
        }

        return .{
            .tasks = .{ .map = merged_tasks },
            .aliases = aliases,
            .allocator = self.allocator,
        };
    }

    fn loadGlobalConfig(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        const home = self.environ.get("HOME") orelse return;
        const config_path = try std.fs.path.join(self.allocator, &.{ home, ".config", "vai", "vai.toml" });
        defer self.allocator.free(config_path);

        std.Io.Dir.cwd().access(self.io, config_path, .{}) catch |err| {
            if (err == error.FileNotFound) return;
            std.debug.print("Warning: cannot access global config {s}: {}\n", .{ config_path, err });
            return;
        };

        var parser = toml.Parser(RawConfig).init(self.allocator);
        defer parser.deinit();
        var result = parser.parseFile(self.io, config_path) catch |err| {
            std.debug.print("Warning: failed to parse global config {s}: {}\n", .{ config_path, err });
            return;
        };
        defer result.deinit();
        try self.mergeTasks(merged_tasks, result.value.tasks);
    }

    fn loadLocalConfig(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        std.Io.Dir.cwd().access(self.io, "vai.toml", .{}) catch |err| {
            if (err == error.FileNotFound) return;
            std.debug.print("Warning: cannot access ./vai.toml: {}\n", .{err});
            return;
        };

        var parser = toml.Parser(RawConfig).init(self.allocator);
        defer parser.deinit();
        var result = parser.parseFile(self.io, "vai.toml") catch |err| {
            std.debug.print("Warning: failed to parse ./vai.toml: {}\n", .{err});
            return;
        };
        defer result.deinit();
        try self.mergeTasks(merged_tasks, result.value.tasks);
    }

    fn loadAndApplyPresets(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        const home = self.environ.get("HOME") orelse return;
        const presets_path = try std.fs.path.join(self.allocator, &.{ home, ".config", "vai", "presets" });
        defer self.allocator.free(presets_path);

        var presets_dir = std.Io.Dir.cwd().openDir(self.io, presets_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer presets_dir.close(self.io);

        var iterator = presets_dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".toml")) continue;

            const preset_path = try std.fs.path.join(self.allocator, &.{ presets_path, entry.name });
            defer self.allocator.free(preset_path);

            var parser = toml.Parser(RawConfig).init(self.allocator);
            defer parser.deinit();
            var result = parser.parseFile(self.io, preset_path) catch |err| {
                std.debug.print("Warning: failed to parse preset {s}: {}\n", .{ preset_path, err });
                continue;
            };
            defer result.deinit();

            if (self.shouldActivatePreset(result.value.preset)) {
                try self.mergeTasks(merged_tasks, result.value.tasks);
            }
        }
    }

    fn shouldActivatePreset(self: *ConfigLoader, preset_meta: ?PresetMetadata) bool {
        const meta = preset_meta orelse return false;

        if (meta.when_file) |filename| {
            std.Io.Dir.cwd().access(self.io, filename, .{}) catch return false;
            return true;
        }

        if (meta.rules) |rules| {
            for (rules) |rule| {
                if (rule.when_file) |filename| {
                    std.Io.Dir.cwd().access(self.io, filename, .{}) catch return false;
                }
            }
            return true;
        }

        return false;
    }

    fn mergeTasks(
        self: *ConfigLoader,
        dest: *std.StringHashMap(Config.Task),
        src: toml.HashMap(Config.Task),
    ) !void {
        var it = src.map.iterator();
        while (it.next()) |entry| {
            const gop = try dest.getOrPut(entry.key_ptr.*);
            if (gop.found_existing) {
                self.allocator.free(gop.value_ptr.description);
                self.allocator.free(gop.value_ptr.command);
                if (gop.value_ptr.alias) |old_alias| self.allocator.free(old_alias);
            } else {
                gop.key_ptr.* = try self.allocator.dupe(u8, entry.key_ptr.*);
            }

            gop.value_ptr.* = .{
                .description = try self.allocator.dupe(u8, entry.value_ptr.description),
                .command = try self.allocator.dupe(u8, entry.value_ptr.command),
                .alias = if (entry.value_ptr.alias) |alias|
                    try self.allocator.dupe(u8, alias)
                else
                    null,
            };
        }
    }
};
