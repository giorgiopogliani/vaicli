const std = @import("std");
const toml = @import("toml");
const Config = @import("config.zig");

pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,

    const RawConfig = struct {
        tasks: toml.HashMap(Config.Task),
        preset: ?PresetMetadata = null,
    };

    pub const PresetMetadata = struct {
        when_file: ?[]const u8 = null,
        // Future: when_dir, when_env, etc.
    };

    pub fn init(allocator: std.mem.Allocator) ConfigLoader {
        return ConfigLoader{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *ConfigLoader) void {}

    /// Load and merge all applicable configs
    pub fn load(self: *ConfigLoader) !Config {
        var merged_tasks = std.StringHashMap(Config.Task).init(self.allocator);

        // 1. Load global config (~/.config/vai/vai.toml)
        try self.loadGlobalConfig(&merged_tasks);

        // 2. Load and apply activated presets from ~/.config/vai/presets/*.toml
        try self.loadAndApplyPresets(&merged_tasks);

        // 3. Load local config (./vai.toml) - highest precedence
        try self.loadLocalConfig(&merged_tasks);

        // Build alias map
        var aliases = std.StringHashMap([]const u8).init(self.allocator);
        var task_it = merged_tasks.iterator();
        while (task_it.next()) |entry| {
            if (entry.value_ptr.alias) |alias| {
                const task_name = entry.key_ptr.*;
                try aliases.put(alias, task_name);
            }
        }

        return Config{
            .tasks = toml.HashMap(Config.Task){ .map = merged_tasks },
            .aliases = aliases,
            .allocator = self.allocator,
        };
    }

    fn loadGlobalConfig(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        const home = std.posix.getenv("HOME") orelse return;
        const config_path = try std.fs.path.join(self.allocator, &[_][]const u8{ home, ".config", "vai", "vai.toml" });
        defer self.allocator.free(config_path);

        var parser = toml.Parser(RawConfig).init(self.allocator);
        defer parser.deinit();

        var result = parser.parseFile(config_path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer result.deinit();

        try self.mergeTasks(merged_tasks, result.value.tasks);
    }

    fn loadLocalConfig(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        var parser = toml.Parser(RawConfig).init(self.allocator);
        defer parser.deinit();

        var result = parser.parseFile("vai.toml") catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer result.deinit();

        try self.mergeTasks(merged_tasks, result.value.tasks);
    }

    fn loadAndApplyPresets(self: *ConfigLoader, merged_tasks: *std.StringHashMap(Config.Task)) !void {
        const home = std.posix.getenv("HOME") orelse return;
        const presets_dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{ home, ".config", "vai", "presets" });
        defer self.allocator.free(presets_dir_path);

        var presets_dir = std.fs.openDirAbsolute(presets_dir_path, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
        defer presets_dir.close();

        var iterator = presets_dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

            const preset_path = try std.fs.path.join(self.allocator, &[_][]const u8{ presets_dir_path, entry.name });
            defer self.allocator.free(preset_path);

            var parser = toml.Parser(RawConfig).init(self.allocator);
            defer parser.deinit();

            var preset_result = parser.parseFile(preset_path) catch continue;
            defer preset_result.deinit();

            // Check if preset should be activated
            if (self.shouldActivatePreset(preset_result.value.preset)) {
                try self.mergeTasks(merged_tasks, preset_result.value.tasks);
            }
        }
    }

    fn shouldActivatePreset(_: *ConfigLoader, preset_meta: ?PresetMetadata) bool {
        const meta = preset_meta orelse return false;

        // Check when_file condition
        if (meta.when_file) |filename| {
            std.fs.cwd().access(filename, .{}) catch {
                return false;
            };
            return true;
        }

        // If no conditions specified, don't activate
        return false;
    }

    fn mergeTasks(self: *ConfigLoader, dest: *std.StringHashMap(Config.Task), src: toml.HashMap(Config.Task)) !void {
        var it = src.map.iterator();
        while (it.next()) |entry| {
            // Duplicate strings so they persist after the parser result is freed
            const task_name = try self.allocator.dupe(u8, entry.key_ptr.*);
            const description = try self.allocator.dupe(u8, entry.value_ptr.description);
            const command = try self.allocator.dupe(u8, entry.value_ptr.command);
            const alias = if (entry.value_ptr.alias) |a| try self.allocator.dupe(u8, a) else null;

            const task = Config.Task{
                .description = description,
                .command = command,
                .alias = alias,
            };

            // Put will overwrite existing keys, giving us the precedence we want
            try dest.put(task_name, task);
        }
    }
};
