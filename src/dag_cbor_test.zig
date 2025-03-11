const std = @import("std");

const ipld = @import("ipld");
const Kind = ipld.Kind;
const Value = ipld.Value;

const cbor = @import("dag-cbor");
const Header = cbor.Header;
const Decoder = cbor.Decoder;
const Encoder = cbor.Encoder;

test "header" {
    try std.testing.expectEqual(@as(u8, (7 << 5) | 20), Header.fromSimpleValue(.False).encode());
    try std.testing.expectEqual(@as(u8, (7 << 5) | 21), Header.fromSimpleValue(.True).encode());
    try std.testing.expectEqual(@as(u8, (7 << 5) | 22), Header.fromSimpleValue(.Null).encode());

    try std.testing.expectEqual(Header.fromSimpleValue(.False), Header.decode((7 << 5) | 20));
    try std.testing.expectEqual(Header.fromSimpleValue(.True), Header.decode((7 << 5) | 21));
    try std.testing.expectEqual(Header.fromSimpleValue(.Null), Header.decode((7 << 5) | 22));
}

test "static type fixtures" {
    const Fixture = struct {
        T: type,
        value: *const anyopaque,
        bytes: []const u8,

        pub fn init(comptime T: type, comptime value: T, comptime bytes: []const u8) @This() {
            return .{ .T = T, .value = &value, .bytes = bytes };
        }

        pub fn testDecoder(self: @This(), allocator: std.mem.Allocator, decoder: *Decoder) !void {
            const actual_result = try decoder.decodeType(self.T, allocator, self.bytes);
            defer actual_result.deinit();

            const expected_value: *const self.T = @alignCast(@ptrCast(self.value));
            try std.testing.expectEqual(expected_value.*, actual_result.value);
        }

        pub fn testEncoder(self: @This(), allocator: std.mem.Allocator, encoder: *Encoder) !void {
            const value: *const self.T = @alignCast(@ptrCast(self.value));
            const actual_bytes = try encoder.encodeType(self.T, allocator, value.*);
            defer allocator.free(actual_bytes);
            try std.testing.expectEqualSlices(u8, self.bytes, actual_bytes);
        }
    };

    const fixtures: []const Fixture = &.{
        Fixture.init(bool, false, &.{(7 << 5) | 20}),
        Fixture.init(bool, true, &.{(7 << 5) | 21}),

        Fixture.init(u8, 0, &.{0}),
        Fixture.init(u8, 1, &.{1}),
        Fixture.init(u8, 23, &.{23}),
        Fixture.init(u8, 24, &.{ 24, 24 }),
        Fixture.init(u8, 255, &.{ 24, 255 }),

        Fixture.init(?u8, 255, &.{ 24, 255 }),
        Fixture.init(?u8, null, &.{(7 << 5) | 22}),

        Fixture.init(u16, 0, &.{0}),
        Fixture.init(u16, 0xffff, &.{ 25, 255, 255 }),
        Fixture.init(u24, 0xffffff, &.{ 26, 0, 255, 255, 255 }),
        Fixture.init(u32, 0xffffffff, &.{ 26, 255, 255, 255, 255 }),

        Fixture.init(struct { foo: u32 }, .{ .foo = 4 }, &.{
            // zig fmt: off
            (5 << 5) | 1,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
            // zig fmt: on
        }),

        Fixture.init(struct { foo: u32, bar: ?bool }, .{ .foo = 4, .bar = null }, &.{
            // zig fmt: off
            (5 << 5) | 2,
                (3 << 5) | 3, 'b', 'a', 'r', (7 << 5) | 22,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
            // zig fmt: on
        }),

        Fixture.init(struct {u32, ?bool}, .{4, false}, &.{
            // zig fmt: off
            (4 << 5) | 2,
                (0 << 5) | 4,
                (7 << 5) | 20,
            // zig fmt: on
        }),
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var encoder = Encoder.init(allocator, .{});
    defer encoder.deinit();

    var decoder = Decoder.init(allocator, .{});
    defer decoder.deinit();

    inline for (fixtures) |fixture| {
        const value: *const fixture.T = @alignCast(@ptrCast(fixture.value));

        fixture.testDecoder(allocator, &decoder) catch |err| {
            std.log.err("failed to decode fixture", .{});
            std.log.err("- value {any}: {any}", .{fixture.T, value.*});
            std.log.err("- bytes {}", .{std.fmt.fmtSliceHexLower(fixture.bytes)});
            return err;
        };

        fixture.testEncoder(allocator, &encoder) catch |err| {
            std.log.err("failed to encode fixture", .{});
            std.log.err("- value {any}: {any}", .{fixture.T, value.*});
            std.log.err("- bytes {}", .{std.fmt.fmtSliceHexLower(fixture.bytes)});
            return err;
        };
    }

    {
        // allocate a struct
        const User = struct {
            id: u32,
        };

        const expected_bytes: []const u8 = &.{
            // zig fmt: off
            (5 << 5) | 1,
                (3 << 5) | 2, 'i', 'd',
                    (0 << 5) | 24, 255,
                // (3 << 5) | 5, 'e', 'm', 'a', 'i', 'l',
                //     (3 << 5) | 17, 'h', 'e', 'l', 'l', 'o', '@', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
            // zig fmt: on
        };

        const user_result = try decoder.decodeType(*const User, allocator, expected_bytes);
        defer user_result.deinit();
        const user: *const User = user_result.value;

        try std.testing.expectEqual(255, user.id);
        // try std.testing.expectEqualSlices(u8, "hello@example.com", user.email);

        // const actual_bytes = try encoder.encodeType(*const User, allocator, &.{ .id = 255, .email = "hello@example.com" });
        const actual_bytes = try encoder.encodeType(*const User, allocator, &.{ .id = 255  });
        defer allocator.free(actual_bytes);
        try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
    }

}

test "encode and decode Enum as integer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var encoder = Encoder.init(allocator, .{});
    defer encoder.deinit();

    var decoder = Decoder.init(allocator, .{});
    defer decoder.deinit();

    // allocate a struct
    const Status = enum(u8) {
        pub const IpldKind = Kind.integer;

        Stopped = 0,
        Started = 1,
    };

    const expected_bytes: []const u8 = &.{
        // zig fmt: off
        (4 << 5) | 2,
            (0 << 5) | 0,
            (0 << 5) | 1,
        // zig fmt: on
    };

    const expected_value: []const Status = &.{.Stopped, .Started};

    const actual_result = try decoder.decodeType([]const Status, allocator, expected_bytes);
    defer actual_result.deinit();
    try std.testing.expectEqualSlices(Status, expected_value, actual_result.value);

    const actual_bytes = try encoder.encodeType([]const Status, allocator, expected_value);
    defer allocator.free(actual_bytes);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

test "encode and decode Enum as string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var encoder = Encoder.init(allocator, .{});
    defer encoder.deinit();

    var decoder = Decoder.init(allocator, .{});
    defer decoder.deinit();

    // encode/decode Enum as a string
    // allocate a struct
    const Status = enum(u8) {
        pub const IpldKind = Kind.string;

        Stopped = 0,
        Started = 1,
    };

    const expected_bytes: []const u8 = &.{
        // zig fmt: off
        (4 << 5) | 2,
            (3 << 5) | 7, 'S', 't', 'o', 'p', 'p', 'e', 'd',
            (3 << 5) | 7, 'S', 't', 'a', 'r', 't', 'e', 'd',
        // zig fmt: on
    };

    const expected_value: []const Status = &.{.Stopped, .Started};

    const actual_result = try decoder.decodeType([]const Status, allocator, expected_bytes);
    defer actual_result.deinit();
    try std.testing.expectEqualSlices(Status, expected_value, actual_result.value);

    const actual_bytes = try encoder.encodeType([]const Status, allocator, expected_value);
    defer allocator.free(actual_bytes);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

test "dynamic value fixture" {
    const Fixture = struct {
        value: Value,
        bytes: []const u8,

        pub inline fn init(value: Value, bytes: []const u8) @This() {
            return .{ .value = value, .bytes = bytes };
        }
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const fixtures: []const Fixture = &.{
        .{ .value = Value.False, .bytes = &.{(7 << 5) | 20} },
        .{ .value = Value.True, .bytes = &.{(7 << 5) | 21} },
        .{ .value = Value.Null, .bytes = &.{(7 << 5) | 22} },

        .{ .value = Value.createInteger(0), .bytes = &.{(0 << 5) | 0} },
        .{ .value = Value.createInteger(1), .bytes = &.{(0 << 5) | 1} },
        .{ .value = Value.createInteger(23), .bytes = &.{(0 << 5) | 23} },
        .{ .value = Value.createInteger(24), .bytes = &.{ (0 << 5) | 24, 24 } },
        .{ .value = Value.createInteger(0xff), .bytes = &.{ (0 << 5) | 24, 255 } },
        .{ .value = Value.createInteger(0xffff), .bytes = &.{ (0 << 5) | 25, 255, 255 } },
        .{ .value = Value.createInteger(0xffffff), .bytes = &.{ (0 << 5) | 26, 0, 255, 255, 255 } },
        .{ .value = Value.createInteger(0xffffffff), .bytes = &.{ (0 << 5) | 26, 255, 255, 255, 255 } },

        .{ .value = Value.createInteger(-10), .bytes = &.{ (1 << 5) | 9 } },
        .{ .value = Value.createInteger(-100), .bytes = &.{ (1 << 5) | 24, 99 } },
        .{ .value = Value.createInteger(-1000), .bytes = &.{ (1 << 5) | 25, 3, 231 } },
        .{ .value = Value.createInteger(-10000), .bytes = &.{ (1 << 5) | 25, 39, 15 } },
        .{ .value = Value.createInteger(-100000), .bytes = &.{ (1 << 5) | 26, 0, 1, 134, 159 } },

        .{ .value = Value.createInteger(std.math.maxInt(i64)), .bytes = &.{ (0 << 5) | 27, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },
        .{ .value = Value.createInteger(std.math.minInt(i64)), .bytes = &.{ (1 << 5) | 27, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff } },

        .{ .value = Value.createFloat(std.math.pi), .bytes = &.{ (7 << 5) | 27, 64, 9, 33, 251, 84, 68, 45, 24 } },

        .{
            .value = try Value.createMap(allocator, .{ .foo = Value.createInteger(4) }),
            .bytes = &.{
                // zig fmt: off
                (5 << 5) | 1,
                (3 << 5) | 3, 'f', 'o', 'o', (0 << 5) | 4,
                // zig fmt: on
            },
        },

        .{
            .value = try Value.createMap(allocator, .{ .foo = Value.createInteger(4), .bar = Value.Null }),
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
                .foo = Value.createInteger(4),
                .bar = try Value.createList(allocator, .{
                    Value.createInteger(0xffff),
                    Value.createInteger(0xffffffff),
                    Value.createInteger(0x7fffffffffffffff),
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
