const std = @import("std");

const CID = @import("cid").CID;
const multicodec = @import("multicodec");

const Value = @import("ipld").Value;
const json = @import("dag-json");
const cbor = @import("dag-cbor");

const Fixture = struct {
    allocator: std.mem.Allocator,
    cid: CID,
    file: std.Io.File,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, codec: multicodec.Codec) !Fixture {
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const ext_idx = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
            if (!std.mem.eql(u8, entry.name[ext_idx + 1 ..], @tagName(codec))) continue;

            const cid = try CID.parse(allocator, entry.name[0..ext_idx]);
            errdefer cid.deinit(allocator);

            const file = try dir.openFile(io, entry.name, .{});
            return .{ .allocator = allocator, .cid = cid, .file = file };
        }

        return error.NotFound;
    }

    pub fn deinit(self: Fixture, io: std.Io) void {
        self.cid.deinit(self.allocator);
        self.file.close(io);
    }
};

test "ipld/codec-fixtures" {
    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const io = std.testing.io;

    const float_format = json.Encoder.FloatFormat.decimalInRange(-2, 5);
    var json_encoder = json.Encoder.init(allocator, .{ .float_format = float_format });
    defer json_encoder.deinit();
    var json_decoder = json.Decoder.init(allocator, .{});
    defer json_decoder.deinit();
    var cbor_encoder = cbor.Encoder.init(allocator, .{});
    defer cbor_encoder.deinit();
    var cbor_decoder = cbor.Decoder.init(allocator, .{});
    defer cbor_decoder.deinit();

    var cwd = std.Io.Dir.cwd();
    var fixtures = try cwd.openDir(io, "codec-fixtures/fixtures", .{});
    defer fixtures.close(io);

    const ParseError = error{Overflow};
    const known_failures: []const struct { name: []const u8, err: ParseError } = &.{
        .{ .name = "int-11959030306112471731", .err = ParseError.Overflow },
        .{ .name = "int-18446744073709551615", .err = ParseError.Overflow },
        .{ .name = "int--11959030306112471732", .err = ParseError.Overflow },
    };

    var iter = fixtures.iterate();
    iter: while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;

        var fixture_dir = try fixtures.openDir(io, entry.name, .{});
        defer fixture_dir.close(io);

        const cbor_fixture = try Fixture.init(allocator, io, fixture_dir, .@"dag-cbor");
        defer cbor_fixture.deinit(io);

        const json_fixture = try Fixture.init(allocator, io, fixture_dir, .@"dag-json");
        defer json_fixture.deinit(io);

        var cbor_file_buffer: [4096]u8 = undefined;
        var json_file_buffer: [4096]u8 = undefined;

        for (known_failures) |failure| {
            if (std.mem.eql(u8, failure.name, entry.name)) {
                var cbor_file_reader = cbor_fixture.file.reader(io, &cbor_file_buffer);
                try std.testing.expectError(
                    failure.err,
                    cbor_decoder.readValue(allocator, &cbor_file_reader.interface),
                );

                var json_file_reader = json_fixture.file.reader(io, &json_file_buffer);
                try std.testing.expectError(
                    failure.err,
                    json_decoder.readValue(allocator, &json_file_reader.interface),
                );

                continue :iter;
            }
        }

        var cbor_file_reader = cbor_fixture.file.reader(io, &cbor_file_buffer);
        const cbor_fixture_bytes = try cbor_file_reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(cbor_fixture_bytes);

        var json_file_reader = json_fixture.file.reader(io, &json_file_buffer);
        const json_fixture_bytes = try json_file_reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(json_fixture_bytes);

        // std.log.warn("now decoding {s}/{s}.dag-cbor", .{ entry.name, cbor_fixture.cid });
        const cbor_value = try cbor_decoder.decodeValue(allocator, cbor_fixture_bytes);
        defer cbor_value.unref();

        // std.log.warn("now decoding {s}/{s}.dag-json", .{ entry.name, json_fixture.cid });
        const json_value = try json_decoder.decodeValue(allocator, json_fixture_bytes);
        defer json_value.unref();

        try Value.expectEqual(cbor_value, json_value);

        // std.log.warn("got cbor value: {any}", .{cbor_value});
        // std.log.warn("got json value: {any}", .{json_value});

        const encoded_cbor_bytes = try cbor_encoder.encodeValue(allocator, json_value);
        defer allocator.free(encoded_cbor_bytes);
        try std.testing.expectEqualSlices(u8, cbor_fixture_bytes, encoded_cbor_bytes);

        const encoded_json_bytes = try json_encoder.encodeValue(allocator, cbor_value);
        defer allocator.free(encoded_json_bytes);
        try std.testing.expectEqualSlices(u8, json_fixture_bytes, encoded_json_bytes);
    }
}

test "make sure failed parses free partial data" {
    // this will fail to parse with error Overflow,
    // but the objects and strings can't be leaked.
    const examples: []const []const u8 = &.{
        \\[{"foo":"bar"},18446744073709551615]
        ,
        \\[{"aaa":["bbb", "ccc"],"zzz":18446744073709551615}]
        ,
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var json_decoder = json.Decoder.init(allocator, .{});
    defer json_decoder.deinit();

    for (examples) |bytes| {
        try std.testing.expectError(
            error.Overflow,
            json_decoder.decodeValue(allocator, bytes),
        );
    }
}
