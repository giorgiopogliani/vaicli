const std = @import("std");

pub const RESET = "\x1b[0m";
pub const RED = "\x1b[31m";
pub const GREEN = "\x1b[32m";
pub const YELLOW = "\x1b[33m";
pub const BLUE = "\x1b[34m";
pub const CYAN = "\x1b[96m";
pub const ITALIC = "\x1b[3m";
pub const BOLD = "\x1b[1m";

pub fn red(comptime format: []const u8, args: anytype) void {
    std.debug.print(RED ++ format ++ RESET, args);
}

pub fn green(comptime format: []const u8, args: anytype) void {
    std.debug.print(GREEN ++ format ++ RESET, args);
}

pub fn yellow(comptime format: []const u8, args: anytype) void {
    std.debug.print(YELLOW ++ format ++ RESET, args);
}

pub fn blue(comptime format: []const u8, args: anytype) void {
    std.debug.print(BLUE ++ format ++ RESET, args);
}

pub fn cyan(comptime format: []const u8, args: anytype) void {
    std.debug.print(CYAN ++ format ++ RESET, args);
}

pub fn italic(comptime format: []const u8, args: anytype) void {
    std.debug.print(ITALIC ++ format ++ RESET, args);
}

pub fn bold(comptime format: []const u8, args: anytype) void {
    std.debug.print(BOLD ++ format ++ RESET, args);
}

pub fn normal(comptime format: []const u8, args: anytype) void {
    std.debug.print(RESET ++ format ++ RESET, args);
}
