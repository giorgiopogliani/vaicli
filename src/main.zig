const std = @import("std");
const toml = @import("toml");
const Env = @import("env.zig");
const App = @import("app.zig");
const Config = @import("config.zig");
const ConfigLoader = @import("config_loader.zig").ConfigLoader;

pub fn main() anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load config with preset support
    var loader = ConfigLoader.init(allocator);
    defer loader.deinit();
    var config = try loader.load();
    defer config.deinit();

    // Loading Dotenv file if it exists
    var env = Env.init(allocator);
    defer env.deinit();
    
    // Inherit parent process environment
    var parent_env = try std.process.getEnvMap(allocator);
    defer parent_env.deinit();
    var parent_it = parent_env.iterator();
    while (parent_it.next()) |entry| {
        try env.map.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    
    // Override with .env file values
    env.parseFile(".env") catch {};

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    // Init app
    const app = App.init(allocator, &env, &config);
    try app.run(&args);
}
