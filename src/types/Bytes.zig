const std = @import("std");

const Bytes = @This();

data: []const u8,

pub fn parseIpldBytes(allocator: std.mem.Allocator, data: []const u8) !Bytes {
    const copy = try allocator.alloc(u8, data.len);
    @memcpy(copy, data);
    return .{ .data = copy };
}

pub fn writeIpldBytes(self: Bytes, writer: std.io.AnyWriter) !void {
    try writer.writeAll(self.data);
}
