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

    // Encode value to bytes

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

    try std.testing.expectEqualSlices(
        u8,
        "[[],[null,42,true]]",
        json_bytes,
    );

    // Decode bytes into Values

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
}
