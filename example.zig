const std = @import("std");

const ipld = @import("ipld");
const Value = ipld.Value;

const cbor = @import("dag-cbor");
const json = @import("dag-json");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const example_value = try Value.createList(allocator, .{
        try Value.createList(allocator, .{}),
        try Value.createList(allocator, .{
            Value.Null,
            Value.integer(42),
            Value.True,
        }),
    });

    defer example_value.unref();

    // Encode a Value into bytes

    var cbor_encoder = cbor.Encoder.init(allocator, .{});
    defer cbor_encoder.deinit();

    const cbor_bytes = try cbor_encoder.encodeValue(allocator, example_value);
    defer allocator.free(cbor_bytes);

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x82, 0x80, 0x83, 0xf6, 0x18, 0x2a, 0xf5 },
        cbor_bytes,
    );

    var json_encoder = json.Encoder.init(allocator, .{});
    defer json_encoder.deinit();

    const json_bytes = try json_encoder.encodeValue(allocator, example_value);
    defer allocator.free(json_bytes);

    try std.testing.expectEqualSlices(u8, "[[],[null,42,true]]", json_bytes);

    // Decode bytes into a Value

    var cbor_decoder = cbor.Decoder.init(allocator, .{});
    defer cbor_decoder.deinit();

    const cbor_value = try cbor_decoder.decodeValue(allocator, cbor_bytes);
    defer cbor_value.unref();
    try Value.expectEqual(cbor_value, example_value);

    var json_decoder = json.Decoder.init(allocator, .{});
    defer json_decoder.deinit();

    const json_value = try json_decoder.decodeValue(allocator, json_bytes);
    defer json_value.unref();
    try Value.expectEqual(json_value, example_value);

    // Encode a static type
    const User = struct {
        id: u32,
        email: ipld.String,
    };

    const user_json_bytes = try json_encoder.encodeType(User, allocator, .{
        .id = 10,
        .email = .{ .data = "johndoe@example.com" },
    });
    defer allocator.free(user_json_bytes);

    try std.testing.expectEqualSlices(u8, user_json_bytes,
    \\{"email":"johndoe@example.com","id":10}
    );

    // Decode a static type
    const json_user_result = try json_decoder.decodeType(User, allocator, user_json_bytes);
    defer json_user_result.deinit();

    try std.testing.expectEqual(json_user_result.value.id, 10);
    try std.testing.expectEqualSlices(u8, json_user_result.value.email.data, "johndoe@example.com");

    const cbor_user_bytes = try cbor_encoder.encodeType(User, allocator, .{
        .id = 10,
        .email = .{ .data = "johndoe@example.com" },
    });
    defer allocator.free(cbor_user_bytes);

    // try std.testing.expectEqualSlices(u8, cbor_user_bytes,
    // \\{"email":"johndoe@example.com","id":10}
    // );

    // Decode a static type
    const cbor_user_result = try cbor_decoder.decodeType(User, allocator, cbor_user_bytes);
    defer cbor_user_result.deinit();

    try std.testing.expectEqual(cbor_user_result.value.id, 10);
    try std.testing.expectEqualSlices(u8, cbor_user_result.value.email.data, "johndoe@example.com");
}
