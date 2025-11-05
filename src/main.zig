const std = @import("std");
const toml = @import("toml");
const Env = @import("env.zig");
const App = @import("app.zig");
const Config = @import("config.zig");

pub fn main() anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Creating parser
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    // Parsing config
    var result = try parser.parseFile("test.toml");
    defer result.deinit();
    const config = result.value;

    // Loading Dotenv file if it exists
    var env = Env.init(allocator);
    defer env.deinit();
    env.parseFile(".env") catch {};

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    // Init app
    const app = App.init(allocator, &env, &config);
    try app.run(&args);
}
