const std = @import("std");

pub const version: u16 = 4;
pub const max_payload: usize = 16 * 1024 * 1024;
const magic = "VAI1";

pub const Kind = enum(u8) {
    start_job = 1,
    list_jobs = 2,
    job_logs = 3,
    list_sessions = 4,
    toggle_session_mode = 5,
    remove_job = 6,
    remove_session = 7,
    session_outputs = 8,
    attach_info = 9,
    pty_input = 10,
    pty_resize = 11,
    restart_job = 12,
    session_snapshot = 13,
    response_ok = 100,
    response_error = 101,
};

pub const Frame = struct {
    kind: Kind,
    payload: []u8,

    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
    }
};

pub fn writeFrame(writer: *std.Io.Writer, kind: Kind, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;
    try writer.writeAll(magic);
    try writer.writeInt(u16, version, .big);
    try writer.writeByte(@intFromEnum(kind));
    try writer.writeInt(u32, @intCast(payload.len), .big);
    try writer.writeAll(payload);
}

pub fn readFrame(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Frame {
    var received_magic: [magic.len]u8 = undefined;
    try reader.readSliceAll(&received_magic);
    if (!std.mem.eql(u8, &received_magic, magic)) return error.InvalidMagic;
    if (try reader.takeInt(u16, .big) != version) return error.UnsupportedVersion;
    const kind = std.enums.fromInt(Kind, try reader.takeByte()) orelse return error.InvalidKind;
    const payload_len = try reader.takeInt(u32, .big);
    if (payload_len > max_payload) return error.PayloadTooLarge;
    const payload = try allocator.alloc(u8, payload_len);
    errdefer allocator.free(payload);
    try reader.readSliceAll(payload);
    return .{ .kind = kind, .payload = payload };
}

pub const PayloadWriter = struct {
    allocating: std.Io.Writer.Allocating,

    pub fn init(allocator: std.mem.Allocator) PayloadWriter {
        return .{ .allocating = .init(allocator) };
    }

    pub fn deinit(self: *PayloadWriter) void {
        self.allocating.deinit();
    }

    pub fn boolean(self: *PayloadWriter, value: bool) !void {
        try self.allocating.writer.writeByte(@intFromBool(value));
    }

    pub fn integer(self: *PayloadWriter, value: u64) !void {
        try self.allocating.writer.writeInt(u64, value, .big);
    }

    pub fn string(self: *PayloadWriter, value: []const u8) !void {
        if (value.len > max_payload) return error.PayloadTooLarge;
        try self.allocating.writer.writeInt(u32, @intCast(value.len), .big);
        try self.allocating.writer.writeAll(value);
    }

    pub fn finish(self: *PayloadWriter) ![]u8 {
        if (self.allocating.writer.end > max_payload) return error.PayloadTooLarge;
        return self.allocating.toOwnedSlice();
    }
};

pub const PayloadReader = struct {
    reader: std.Io.Reader,

    pub fn init(payload: []u8) PayloadReader {
        return .{ .reader = .fixed(payload) };
    }

    pub fn boolean(self: *PayloadReader) !bool {
        return switch (try self.reader.takeByte()) {
            0 => false,
            1 => true,
            else => error.InvalidBoolean,
        };
    }

    pub fn integer(self: *PayloadReader) !u64 {
        return self.reader.takeInt(u64, .big);
    }

    pub fn string(self: *PayloadReader) ![]const u8 {
        const len = try self.reader.takeInt(u32, .big);
        if (len > max_payload) return error.PayloadTooLarge;
        return self.reader.take(len);
    }

    pub fn done(self: *const PayloadReader) bool {
        return self.reader.seek == self.reader.end;
    }
};

test "framed protocol round trip" {
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try writeFrame(&writer, .start_job, "payload");

    var reader = std.Io.Reader.fixed(writer.buffered());
    const frame = try readFrame(std.testing.allocator, &reader);
    defer frame.deinit(std.testing.allocator);
    try std.testing.expectEqual(Kind.start_job, frame.kind);
    try std.testing.expectEqualStrings("payload", frame.payload);
}

test "payload strings, integer, and boolean round trip" {
    var pw = PayloadWriter.init(std.testing.allocator);
    defer pw.deinit();
    try pw.string("hello");
    try pw.integer(42);
    try pw.boolean(true);
    const bytes = try pw.finish();
    defer std.testing.allocator.free(bytes);

    var pr = PayloadReader.init(bytes);
    try std.testing.expectEqualStrings("hello", try pr.string());
    try std.testing.expectEqual(@as(u64, 42), try pr.integer());
    try std.testing.expect(try pr.boolean());
    try std.testing.expect(pr.done());
}

test "reject oversized frame header" {
    var bytes: [11]u8 = undefined;
    @memcpy(bytes[0..4], magic);
    std.mem.writeInt(u16, bytes[4..6], version, .big);
    bytes[6] = @intFromEnum(Kind.list_jobs);
    std.mem.writeInt(u32, bytes[7..11], @intCast(max_payload + 1), .big);
    var reader = std.Io.Reader.fixed(&bytes);
    try std.testing.expectError(error.PayloadTooLarge, readFrame(std.testing.allocator, &reader));
}
