const std = @import("std");

const ipld = @import("ipld");
const Kind = ipld.Kind;
const Value = ipld.Value;

const json = @import("dag-json");
const Header = json.Header;
const Decoder = json.Decoder;
const Encoder = json.Encoder;

test "dynamic value fixture" {
    const Fixture = struct {
        value: Value,
        bytes: []const u8,

        pub inline fn init(value: Value, bytes: []const u8) @This() {
            return .{ .value = value, .bytes = bytes };
        }
    };

    // const allocator = std.heap.c_allocator;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const fixtures: []const Fixture = &.{
        Fixture.init(Value.False, "false"),
        Fixture.init(Value.True, "true"),
        Fixture.init(Value.Null, "null"),

        Fixture.init(Value.integer(0), "0"),
        Fixture.init(Value.integer(1), "1"),
        Fixture.init(Value.integer(23), "23"),
        Fixture.init(Value.integer(24), "24"),
        Fixture.init(Value.integer(0xff), "255"),
        Fixture.init(Value.integer(0xffff), "65535"),
        Fixture.init(Value.integer(0xffffff), "16777215"),
        Fixture.init(Value.integer(0xffffffff), "4294967295"),

        Fixture.init(Value.integer(-10), "-10"),
        Fixture.init(Value.integer(-100), "-100"),
        Fixture.init(Value.integer(-1000), "-1000"),
        Fixture.init(Value.integer(-10000), "-10000"),
        Fixture.init(Value.integer(-100000), "-100000"),

        Fixture.init(Value.integer(std.math.minInt(i64)), "-9223372036854775808"),
        Fixture.init(Value.integer(std.math.maxInt(i64)), "9223372036854775807"),

        // TODO
        Fixture.init(Value.float(1), "1.0"),
        Fixture.init(Value.float(std.math.pi), "3.141592653589793"),

        Fixture.init(try Value.createMap(allocator, .{ .foo = Value.integer(4) }),
            \\{"foo":4}
        ),

        Fixture.init(try Value.createMap(allocator, .{ .foo = Value.integer(4), .bar = Value.Null }),
            \\{"bar":null,"foo":4}
        ),

        Fixture.init(try Value.createMap(allocator, .{
            .foo = Value.integer(4),
            .bar = try Value.createList(allocator, .{
                Value.integer(0xffff),
                Value.integer(0xffffffff),
                Value.integer(0x7fffffffffffffff),
            }),
        }),
            \\{"bar":[65535,4294967295,9223372036854775807],"foo":4}
        ),

        Fixture.init(try Value.createList(allocator, .{
            Value.integer(0xffff),
            Value.integer(0xffffffff),
            Value.integer(0x7fffffffffffffff),
            try Value.createMap(allocator, .{ .foo = Value.integer(4), .bar = try Value.createString(allocator, "hello world") }),
        }),
            \\[65535,4294967295,9223372036854775807,{"bar":"hello world","foo":4}]
        ),

        Fixture.init(try Value.createList(allocator, .{
            Value.integer(0xffff),
            Value.integer(0xffffffff),
            Value.integer(0x7fffffffffffffff),
            try Value.createMap(allocator, .{
                .foo = Value.integer(4),
            }),
        }),
            \\[65535,4294967295,9223372036854775807,{"foo":4}]
        ),

        Fixture.init(try Value.parseLink(allocator, "bafybeiczsscdsbs7ffqz55asqdf3smv6klcw3gofszvwlyarci47bgf354"),
            \\{"/":"bafybeiczsscdsbs7ffqz55asqdf3smv6klcw3gofszvwlyarci47bgf354"}
        ),

        Fixture.init(try Value.createList(allocator, .{
            try Value.parseLink(allocator, "QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn"),
            try Value.parseLink(allocator, "bafybeiczsscdsbs7ffqz55asqdf3smv6klcw3gofszvwlyarci47bgf354"),
        }),
            \\[
            ++
            \\{"/":"QmUNLLsPACCz1vLxQVkXqqLX5R1X345qqfHbsf67hvA3Nn"},
            ++
            \\{"/":"bafybeiczsscdsbs7ffqz55asqdf3smv6klcw3gofszvwlyarci47bgf354"}
            ++
            \\]
        ),

        Fixture.init(try Value.createBytes(allocator, &.{ 1, 2, 3, 4, 5 }),
            \\{"/":{"bytes":"AQIDBAU"}}
        ),

        // random 32 bytes
        // zig fmt: off
        Fixture.init(try Value.createBytes(allocator, &.{
            0x1b, 0x84, 0x0c, 0x2b, 0x94, 0xc1, 0x14, 0x3e,
            0x11, 0xaf, 0x2a, 0xfa, 0xd9, 0xf3, 0xbd, 0x75,
            0xc1, 0x02, 0x2c, 0x95, 0x28, 0x1e, 0xc7, 0xf1,
            0xba, 0x89, 0xb7, 0xe6, 0x79, 0xd0, 0xe2, 0x51,
        }),
            \\{"/":{"bytes":"G4QMK5TBFD4Rryr62fO9dcECLJUoHsfxuom35nnQ4lE"}}
        ),
        // zig fmt: on
    };

    defer for (fixtures) |fixture| fixture.value.unref();

    var encoder = Encoder.init(allocator, .{.float_format = .{.decimal = {}}});
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
            const expected: *const self.T = @alignCast(@ptrCast(self.value));
            try std.testing.expectEqual(expected.*, actual_result.value);
        }

        pub fn testEncoder(self: @This(), allocator: std.mem.Allocator, encoder: *Encoder) !void {
            const value: *const self.T = @alignCast(@ptrCast(self.value));
            const actual_bytes = try encoder.encodeType(self.T, allocator, value.*);
            defer allocator.free(actual_bytes);
            try std.testing.expectEqualSlices(u8, self.bytes, actual_bytes);
        }
    };

    const fixtures: []const Fixture = &.{
        Fixture.init(bool, false, "false"),
        Fixture.init(bool, true, "true"),

        Fixture.init(u8, 0, "0"),
        Fixture.init(u8, 1, "1"),
        Fixture.init(u8, 23, "23"),
        Fixture.init(u8, 255, "255"),

        Fixture.init(?u8, 255, "255"),
        Fixture.init(?u8, null, "null"),

        Fixture.init(u16, 0, "0"),
        Fixture.init(u16, 0xffff, "65535"),
        Fixture.init(u24, 0xffffff, "16777215"),
        Fixture.init(u32, 0xffffffff, "4294967295"),

        Fixture.init(struct { foo: u32 }, .{ .foo = 4 },
        \\{"foo":4}
        ),

        Fixture.init(struct { foo: u32, bar: ?bool }, .{ .foo = 4, .bar = null },
        \\{"bar":null,"foo":4}
        ),

        Fixture.init(struct {u32, ?bool}, .{4, false},
        \\[4,false]
        ),
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

    // {
    //     // allocate a struct
    //     const User = struct {
    //         id: u32,
    //     };

    //     const expected_bytes: []const u8 = &.{
    //         // zig fmt: off
    //         (5 << 5) | 1,
    //             (3 << 5) | 2, 'i', 'd',
    //                 (0 << 5) | 24, 255,
    //             // (3 << 5) | 5, 'e', 'm', 'a', 'i', 'l',
    //             //     (3 << 5) | 17, 'h', 'e', 'l', 'l', 'o', '@', 'e', 'x', 'a', 'm', 'p', 'l', 'e', '.', 'c', 'o', 'm',
    //         // zig fmt: on
    //     };

    //     const user: *const User = try decoder.decodeType(*const User, allocator, expected_bytes);
    //     // defer allocator.free(user.email);
    //     defer allocator.destroy(user);

    //     try std.testing.expectEqual(255, user.id);
    //     // try std.testing.expectEqualSlices(u8, "hello@example.com", user.email);

    //     // const actual_bytes = try encoder.encodeType(*const User, allocator, &.{ .id = 255, .email = "hello@example.com" });
    //     const actual_bytes = try encoder.encodeType(*const User, allocator, &.{ .id = 255  });
    //     defer allocator.free(actual_bytes);
    //     try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
    // }

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

    const expected_bytes =
        \\[0,1]
    ;

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

    const expected_bytes =
        \\["Stopped","Started"]
    ;

    const expected_value: []const Status = &.{.Stopped, .Started};

    const actual_result = try decoder.decodeType([]const Status, allocator, expected_bytes);
    defer actual_result.deinit();
    try std.testing.expectEqualSlices(Status, expected_value, actual_result.value);

    const actual_bytes = try encoder.encodeType([]const Status, allocator, expected_value);
    defer allocator.free(actual_bytes);
    try std.testing.expectEqualSlices(u8, expected_bytes, actual_bytes);
}

fn testFloatEncoding(allocator: std.mem.Allocator, float_format: Encoder.FloatFormat, value: f64, expected: []const u8) !void {
    var encoder = Encoder.init(allocator, .{.float_format = float_format});
    defer encoder.deinit();
    const actual = try encoder.encodeType(f64, allocator, value);
    defer allocator.free(actual);
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "float encoding modes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    try testFloatEncoding(allocator, .{.scientific = {}}, 0, "0e0");
    try testFloatEncoding(allocator, .{.scientific = {}}, 1, "1e0");
    try testFloatEncoding(allocator, .{.decimal = {}}, 0.01, "0.01");
    try testFloatEncoding(allocator, .{.decimal_in_range = .{
        .min_exp10 = -2,
    }}, 0.01, "0.01");
    try testFloatEncoding(allocator, .{.decimal_in_range = .{
        .min_exp10 = -2,
    }}, 0.009, "9e-3");
    try testFloatEncoding(allocator, .{.decimal_in_range = .{
        .min_exp10 = -1,
        .max_exp10 = 1,
    }}, 10, "10.0");
    try testFloatEncoding(allocator, .{.decimal_in_range = .{
        .min_exp10 = -1,
        .max_exp10 = 1,
    }}, 99.99, "99.99");
    try testFloatEncoding(allocator, .{.decimal_in_range = .{
        .min_exp10 = -1,
        .max_exp10 = 1,
    }}, 100.111, "1.00111e2");
}
