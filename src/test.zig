const std = @import("std");

const CID = @import("cid").CID;
const multicodec = @import("multicodec");

const Value = @import("ipld").Value;
const json = @import("dag-json");
const cbor = @import("dag-cbor");

const Fixture = struct {
    allocator: std.mem.Allocator,
    cid: CID,
    file: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, codec: multicodec.Codec) !Fixture {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            const ext_idx = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
            if (!std.mem.eql(u8, entry.name[ext_idx + 1 ..], @tagName(codec))) continue;

            const cid = try CID.parse(allocator, entry.name[0..ext_idx]);
            errdefer cid.deinit(allocator);

            const file = try dir.openFile(entry.name, .{});
            return .{ .allocator = allocator, .cid = cid, .file = file };
        }

        return error.NotFound;
    }

    pub fn deinit(self: Fixture) void {
        self.cid.deinit(self.allocator);
        self.file.close();
    }
};

test "ipld/codec-fixtures" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    const float_format = json.Encoder.FloatFormat.decimalInRange(-2, 5);
    var json_encoder = json.Encoder.init(allocator, .{ .float_format = float_format });
    defer json_encoder.deinit();
    var json_decoder = json.Decoder.init(allocator, .{});
    defer json_decoder.deinit();
    var cbor_encoder = cbor.Encoder.init(allocator, .{});
    defer cbor_encoder.deinit();
    var cbor_decoder = cbor.Decoder.init(allocator, .{});
    defer cbor_decoder.deinit();

    var cwd = std.fs.cwd();
    var fixtures = try cwd.openDir("codec-fixtures/fixtures", .{});
    defer fixtures.close();

    const ParseError = error{Overflow};
    const known_failures: []const struct { name: []const u8, err: ParseError } = &.{
        .{ .name = "int-11959030306112471731", .err = ParseError.Overflow },
        .{ .name = "int-18446744073709551615", .err = ParseError.Overflow },
        .{ .name = "int--11959030306112471732", .err = ParseError.Overflow },
    };

    var iter = fixtures.iterate();
    iter: while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        var fixture_dir = try fixtures.openDir(entry.name, .{});
        defer fixture_dir.close();

        const cbor_fixture = try Fixture.init(allocator, fixture_dir, .@"dag-cbor");
        defer cbor_fixture.deinit();

        const json_fixture = try Fixture.init(allocator, fixture_dir, .@"dag-json");
        defer json_fixture.deinit();

        for (known_failures) |failure| {
            if (std.mem.eql(u8, failure.name, entry.name)) {
                try std.testing.expectError(
                    failure.err,
                    cbor_decoder.readValue(allocator, cbor_fixture.file.reader().any()),
                );

                try std.testing.expectError(
                    failure.err,
                    json_decoder.readValue(allocator, json_fixture.file.reader().any()),
                );

                continue :iter;
            }
        }

        const cbor_fixture_bytes = try cbor_fixture.file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(cbor_fixture_bytes);

        const json_fixture_bytes = try json_fixture.file.readToEndAlloc(allocator, std.math.maxInt(usize));
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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
