const std = @import("std");

const Kind = @import("value.zig").Kind;
const Value = @import("value.zig").Value;

const Header = @import("dag_cbor.zig").Header;
const Decoder = @import("dag_cbor.zig").Decoder;
const Encoder = @import("dag_cbor.zig").Encoder;

test "header" {
    try std.testing.expectEqual(@as(u8, (7 << 5) | 20), Header.fromSimpleValue(.False).encode());
    try std.testing.expectEqual(@as(u8, (7 << 5) | 21), Header.fromSimpleValue(.True).encode());
    try std.testing.expectEqual(@as(u8, (7 << 5) | 22), Header.fromSimpleValue(.Null).encode());

    try std.testing.expectEqual(Header.fromSimpleValue(.False), Header.decode((7 << 5) | 20));
    try std.testing.expectEqual(Header.fromSimpleValue(.True), Header.decode((7 << 5) | 21));
    try std.testing.expectEqual(Header.fromSimpleValue(.Null), Header.decode((7 << 5) | 22));
}

test "fixture values" {
    const Fixture = struct {
        value: Value,
        bytes: []const u8,

        pub inline fn init(value: Value, bytes: []const u8) @This() {
            return .{ .value = value, .bytes = bytes };
        }

        pub fn testDecoder(self: @This(), allocator: std.mem.Allocator, decoder: *Decoder) !void {
            const actual = try decoder.decodeValue(allocator, self.bytes);
            const expected: *const self.T = @alignCast(@ptrCast(self.value));
            try std.testing.expectEqual(expected.*, actual);
        }

        pub fn testEncoder(self: @This(), allocator: std.mem.Allocator, encoder: *Encoder) !void {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            const value: *const self.T = @alignCast(@ptrCast(self.value));
            const actual = try encoder.encode(self.T, arena.allocator(), value.*);
            try std.testing.expectEqualSlices(u8, self.bytes, actual);
        }
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const fixtures: []const Fixture = &.{
        .{ .value = Value.False, .bytes = &.{(7 << 5) | 20} },
        .{ .value = Value.True, .bytes = &.{(7 << 5) | 21} },
        .{ .value = Value.Null, .bytes = &.{(7 << 5) | 22} },

        .{ .value = Value.integer(0), .bytes = &.{(0 << 5) | 0} },
        .{ .value = Value.integer(1), .bytes = &.{(0 << 5) | 1} },
        .{ .value = Value.integer(23), .bytes = &.{(0 << 5) | 23} },
        .{ .value = Value.integer(24), .bytes = &.{ (0 << 5) | 24, 24 } },
        .{ .value = Value.integer(0xff), .bytes = &.{ (0 << 5) | 24, 255 } },
        .{ .value = Value.integer(0xffff), .bytes = &.{ (0 << 5) | 25, 255, 255 } },
        .{ .value = Value.integer(0xffffff), .bytes = &.{ (0 << 5) | 26, 0, 255, 255, 255 } },
        .{ .value = Value.integer(0xffffffff), .bytes = &.{ (0 << 5) | 26, 255, 255, 255, 255 } },

        .{ .value = Value.integer(-10), .bytes = &.{ (1 << 5) | 9 } },
        .{ .value = Value.integer(-100), .bytes = &.{ (1 << 5) | 24, 99 } },
        .{ .value = Value.integer(-1000), .bytes = &.{ (1 << 5) | 25, 3, 231 } },
        .{ .value = Value.integer(-10000), .bytes = &.{ (1 << 5) | 25, 39, 15 } },
        .{ .value = Value.integer(-100000), .bytes = &.{ (1 << 5) | 26, 0, 1, 134, 159 } },

        .{ .value = Value.integer(std.math.maxInt(i64)), .bytes = &.{ (0 << 5) | 27, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },
        .{ .value = Value.integer(std.math.minInt(i64)), .bytes = &.{ (1 << 5) | 27, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },

        .{ .value = Value.float(std.math.pi), .bytes = &.{ (7 << 5) | 27, 64, 9, 33, 251, 84, 68, 45, 24 } },

        .{
            .value = try Value.createMap(allocator, .{ .foo = Value.integer(4) }),
            .bytes = &.{
                // zig fmt: off
                (5 << 5) | 1,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
                // zig fmt: on
            },
        },

        .{
            .value = try Value.createMap(allocator, .{ .foo = Value.integer(4), .bar = Value.Null }),
            .bytes = &.{
                // zig fmt: off
                (5 << 5) | 2,
                (3 << 5) | 3, 'b', 'a', 'r', (7 << 5) | 22,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
                // zig fmt: on
            },
        },

        .{
            .value = try Value.createMap(allocator, .{
                .foo = Value.integer(4),
                .bar = try Value.createList(allocator, .{
                    Value.integer(0xffff),
                    Value.integer(0xffffffff),
                    Value.integer(0x7fffffffffffffff),
                }),
            }),
            .bytes = &.{
                // zig fmt: off
                (5 << 5) | 2,
                (3 << 5) | 3, 'b', 'a', 'r',
                    (4 << 5) | 3,
                    (0 << 5) | 25, 255, 255,
                    (0 << 5) | 26, 255, 255, 255, 255,
                    (0 << 5) | 27, 127, 255, 255, 255, 255, 255, 255, 255,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
                // zig fmt: on
            },
        },
    };

    defer for (fixtures) |fixture| fixture.value.unref();

    var encoder = Encoder.init(allocator, .{});
    defer encoder.deinit();

    for (fixtures) |fixture| {
        const actual = try encoder.encodeValue(allocator, fixture.value);
        defer allocator.free(actual);
        try std.testing.expectEqualSlices(u8, fixture.bytes, actual);
    }

    var decoder = Decoder.init(allocator, .{});
    defer decoder.deinit();

    for (fixtures) |fixture| {
        const actual = try decoder.decodeValue(allocator, fixture.bytes);
        defer actual.unref();
        try Value.expectEqual(actual, fixture.value);
    }
}
