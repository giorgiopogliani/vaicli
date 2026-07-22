const std = @import("std");

const Token = union(enum) {
    identifier: []const u8,
    equals,
    string: []const u8,
    comment: []const u8,
    newline,
    eof,
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize,

    const Self = @This();

    fn init(input: []const u8) Self {
        return Self{
            .input = input,
            .pos = 0,
        };
    }

    fn nextToken(self: *Self) Token {
        self.skipWhitespace();

        if (self.pos >= self.input.len) {
            return Token.eof;
        }

        const ch = self.input[self.pos];

        switch (ch) {
            '\n' => {
                self.pos += 1;
                return Token.newline;
            },
            '=' => {
                self.pos += 1;
                return Token.equals;
            },
            '#' => {
                const start = self.pos;
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
                return Token{ .comment = self.input[start..self.pos] };
            },
            '"', '\'' => {
                return self.readQuotedString(ch);
            },
            else => {
                return self.readIdentifier();
            },
        }
    }

    fn skipWhitespace(self: *Self) void {
        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == ' ' or ch == '\t' or ch == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn readQuotedString(self: *Self, quote: u8) Token {
        self.pos += 1; // skip opening quote
        const start = self.pos;

        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            self.pos += 1;
        }

        const value = self.input[start..self.pos];

        if (self.pos < self.input.len) {
            self.pos += 1; // skip closing quote
        }

        return Token{ .string = value };
    }

    fn readIdentifier(self: *Self) Token {
        const start = self.pos;

        while (self.pos < self.input.len) {
            const ch = self.input[self.pos];
            if (ch == '=' or ch == '\n' or ch == ' ' or ch == '\t' or ch == '\r' or ch == '#') {
                break;
            }
            self.pos += 1;
        }

        return Token{ .identifier = self.input[start..self.pos] };
    }
};

const Env = @This();

allocator: std.mem.Allocator,
map: std.process.EnvMap,
pub fn init(allocator: std.mem.Allocator) Env {
    return Env{ .allocator = allocator, .map = std.process.EnvMap.init(allocator) };
}

pub fn deinit(self: *Env) void {
    self.map.deinit();
}

pub fn boolean(self: *Env, key: []const u8) bool {
    const value = self.map.get(key) orelse "";
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    if (std.mem.eql(u8, value, "1")) return true;
    return false;
}

pub fn integer(self: *Env, key: []const u8) i64 {
    const value = self.map.get(key) orelse "0";
    return std.fmt.parseInt(i64, value, 10) catch 0;
}

pub fn float(self: *Env, key: []const u8) f64 {
    const value = self.map.get(key) orelse "0.0";
    return std.fmt.parseFloat(f64, value) catch 0.0;
}

pub fn string(self: *Env, key: []const u8) []const u8 {
    const value = self.map.get(key) orelse "";
    return value;
}

pub fn load(self: *Env, content: []const u8) !void {
    var tokenizer = Tokenizer.init(content);

    while (true) {
        const token = tokenizer.nextToken();

        switch (token) {
            .eof => break,
            .comment, .newline => continue,
            .identifier => |key| {
                const equals_token = tokenizer.nextToken();
                if (equals_token != .equals) continue;

                const value_token = tokenizer.nextToken();
                const value = switch (value_token) {
                    .string => |str| str,
                    .identifier => |str| str,
                    else => "",
                };

                try self.map.put(key, value);
            },
            else => continue,
        }
    }
}

pub fn parseFile(self: *Env, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
    defer self.allocator.free(content);

    try self.load(content);
}

test "env parser loads string values correctly" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.load(
        \\KEY1=VALUE1
        \\KEY2=VALUE2#casa
        \\#commento2
        \\KEY3="VALUE3"
    );

    try std.testing.expect(std.mem.eql(u8, env.string("KEY1"), "VALUE1"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY2"), "VALUE2"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY3"), "VALUE3"));
}

test "env parser parses integer values correctly" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.load(
        \\KEY4=10
        \\KEY5=1
    );

    try std.testing.expect(env.integer("KEY4") == 10);
    try std.testing.expect(env.integer("KEY5") == 1);
}

test "env parser parses boolean values correctly" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.load(
        \\KEY5=1
    );

    try std.testing.expect(env.boolean("KEY5") == true);
}

test "env parser handles comments correctly" {
    var env = Env.init(std.testing.allocator);
    defer env.deinit();

    try env.load(
        \\KEY1="VALUE1"
        \\#this is a comment
        \\KEY2=VALUE2#inline comment
        \\KEY3=VALUE3
        \\KEY4=VA "LU" E3
        \\KEY5='VALUE5'
    );

    try std.testing.expect(std.mem.eql(u8, env.string("KEY1"), "VALUE1"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY2"), "VALUE2"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY3"), "VALUE3"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY4"), "VA \"LU\" E3"));
    try std.testing.expect(std.mem.eql(u8, env.string("KEY5"), "VALUE5"));
}
