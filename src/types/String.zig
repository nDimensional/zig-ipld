const std = @import("std");

const String = @This();

data: []const u8,

pub fn parseIpldString(allocator: std.mem.Allocator, data: []const u8) !String {
    const copy = try allocator.alloc(u8, data.len);
    @memcpy(copy, data);
    return .{ .data = copy };
}

pub fn writeIpldString(self: String, writer: *std.io.Writer) std.io.Writer.Error!void {
    try writer.writeAll(self.data);
}
