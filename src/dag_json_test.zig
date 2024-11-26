const std = @import("std");

const Value = @import("ipld").Value;

const json = @import("dag-json");
const Header = json.Header;
const Decoder = json.Decoder;
const Encoder = json.Encoder;

test "fixture values" {
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
