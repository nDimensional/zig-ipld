const std = @import("std");

const value = @import("value.zig");
pub const Kind = value.Kind;
pub const Value = value.Value;

pub const Bytes = @import("types/Bytes.zig");
pub const String = @import("types/Bytes.zig");

// pub const Bytes = struct {
//     data: []const u8,

//     pub fn parseIpldBytes(allocator: std.mem.Allocator, data: []const u8) !Bytes {
//         const copy = try allocator.alloc(u8, data.len);
//         @memcpy(copy, data);
//         return .{ .data = copy };
//     }

//     pub fn writeIpldBytes(self: Bytes, writer: *std.io.Writer) !void {
//         try writer.writeAll(self.data);
//     }
// };

// pub const String = struct {
//     data: []const u8,

//     pub fn parseIpldString(allocator: std.mem.Allocator, data: []const u8) !String {
//         const copy = try allocator.alloc(u8, data.len);
//         @memcpy(copy, data);
//         return .{ .data = copy };
//     }

//     pub fn writeIpldString(self: String, writer: *std.io.Writer) !void {
//         try writer.writeAll(self.data);
//     }
// };
