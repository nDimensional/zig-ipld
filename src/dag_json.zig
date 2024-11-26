const std = @import("std");

const CID = @import("cid").CID;
const multibase = @import("multibase");

const Value = @import("value.zig").Value;
const Kind = @import("value.zig").Kind;
const List = @import("value.zig").List;
const Map = @import("value.zig").Map;
const Link = @import("value.zig").Link;
const String = @import("value.zig").String;
const Bytes = @import("value.zig").Bytes;

pub const Decoder = struct {
    pub const Options = struct {
        strict: bool = true,
    };

    options: Options,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, options: Options) Decoder {
        return .{
            .options = options,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit();
    }

    pub fn decodeValue(self: *Decoder, allocator: std.mem.Allocator, data: []const u8) !Value {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader().any();
        const value = try self.readValue(allocator, reader);
        if (stream.pos != data.len) return error.ExtraneousData;
        return value;
    }

    ///  <document> = <value> .end_of_document
    ///  <value> =
    ///    | <object>
    ///    | <array>
    ///    | <number>
    ///    | <string>
    ///    | .true
    ///    | .false
    ///    | .null
    ///  <object> = .object_begin ( <string> <value> )* .object_end
    ///  <array> = .array_begin ( <value> )* .array_end
    ///  <number> = ( .partial_number )* .number
    ///  <string> = ( <partial_string> )* .string
    ///  <partial_string> =
    ///    | .partial_string
    ///    | .partial_string_escaped_1
    ///    | .partial_string_escaped_2
    ///    | .partial_string_escaped_3
    ///    | .partial_string_escaped_4

    // object_begin,
    // object_end,
    // array_begin,
    // array_end,

    // true,
    // false,
    // null,

    // number: []const u8,
    // partial_number: []const u8,
    // allocated_number: []u8,

    // string: []const u8,
    // partial_string: []const u8,
    // partial_string_escaped_1: [1]u8,
    // partial_string_escaped_2: [2]u8,
    // partial_string_escaped_3: [3]u8,
    // partial_string_escaped_4: [4]u8,
    // allocated_string: []u8,

    // end_of_document,
    pub fn readValue(self: *Decoder, allocator: std.mem.Allocator, reader: std.io.AnyReader) !Value {
        var r = std.json.reader(allocator, reader);
        defer r.deinit();

        const value = try self.readValueNext(allocator, &r);
        switch (try r.next()) {
            .end_of_document => {},
            else => |token| {
                std.log.err("unexpected next token: {any}", .{token});
                return error.ExpectedEOD;
            },
        }
        return value;
    }

    fn readValueNext(
        self: *Decoder,
        allocator: std.mem.Allocator,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) !Value {
        switch (try reader.peekNextTokenType()) {
            .string => {
                const str = try self.copyString(reader);
                return Value.createString(allocator, str);
            },
            .number => {
                const str = try self.copyNumber(reader);
                if (std.mem.indexOf(u8, str, ".")) |_| {
                    const value = try std.fmt.parseFloat(f64, str);
                    return Value.float(value);
                } else {
                    const value = try std.fmt.parseInt(i64, str, 10);
                    return Value.integer(value);
                }
            },
            else => switch (try reader.next()) {
                .object_begin => {
                    // handle empty object case first
                    if (try reader.peekNextTokenType() == .object_end) {
                        const object_end = try reader.next();
                        std.debug.assert(object_end == .object_end);
                        const map = try Map.create(allocator, .{});
                        return .{ .map = map };
                    }

                    // parse the first key to handle CIDs and bytes
                    const first_key = try self.copyString(reader);
                    if (std.mem.eql(u8, first_key, "/")) {
                        switch (try reader.peekNextTokenType()) {
                            .string => {
                                // parse Link
                                const str = try self.copyString(reader);
                                const link = try Link.parse(allocator, str);

                                // closing brace for { "/": ... }
                                switch (try reader.next()) {
                                    .object_end => {},
                                    else => return error.InvalidValue,
                                }

                                return .{ .link = link };
                            },
                            .object_begin => {
                                const object_begin = try reader.next();
                                std.debug.assert(object_begin == .object_begin);

                                // parse Bytes
                                const bytes_key = try self.copyString(reader);
                                if (!std.mem.eql(u8, bytes_key, "bytes"))
                                    return error.InvalidValue;

                                const bytes_value = try self.copyString(reader);

                                // closing brace for { "bytes": ... }
                                switch (try reader.next()) {
                                    .object_end => {},
                                    else => return error.InvalidValue,
                                }

                                // closing brace for { "/": ... }
                                switch (try reader.next()) {
                                    .object_end => {},
                                    else => return error.InvalidValue,
                                }

                                const bytes = try Bytes.baseDecode(allocator, bytes_value, multibase.base64);
                                return .{ .bytes = bytes };
                            },
                            else => return error.InvalidValue,
                        }
                    } else {
                        // normal map object
                        var map = try Map.create(allocator, .{});

                        // parse value for first key
                        try map.set(first_key, Value.Null);
                        const first_ptr = map.hash_map.getPtr(first_key) orelse unreachable;
                        first_ptr.* = try self.readValueNext(allocator, reader);

                        // parse remaining entries
                        while (try reader.peekNextTokenType() != .object_end) {
                            const key = try self.copyString(reader);
                            if (std.mem.eql(u8, key, "/")) return error.InvalidValue;
                            try map.set(key, Value.Null);
                            const ptr = map.hash_map.getPtr(key) orelse unreachable;
                            ptr.* = try self.readValueNext(allocator, reader);
                        }

                        const object_end = try reader.next();
                        std.debug.assert(object_end == .object_end);

                        return .{ .map = map };
                    }
                },
                .object_end => unreachable,
                .array_begin => {
                    var list = try List.create(allocator, .{});
                    while (try reader.peekNextTokenType() != .array_end) {
                        const value = try self.readValueNext(allocator, reader);
                        try list.array_list.append(allocator, value);
                    }

                    const array_end = try reader.next();
                    std.debug.assert(array_end == .array_end);

                    return .{ .list = list };
                },
                .array_end => unreachable,
                .true => return Value.True,
                .false => return Value.False,
                .null => return Value.Null,
                .number => unreachable,
                .partial_number => unreachable,
                .allocated_number => unreachable,
                .string => unreachable,
                .partial_string => unreachable,
                .partial_string_escaped_1 => unreachable,
                .partial_string_escaped_2 => unreachable,
                .partial_string_escaped_3 => unreachable,
                .partial_string_escaped_4 => unreachable,
                .allocated_string => unreachable,
                .end_of_document => unreachable,
            },
        }
    }

    fn copyNumber(
        self: *Decoder,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        while (true) {
            const next = try reader.next();
            switch (next) {
                .partial_number => |chunk| {
                    try self.buffer.appendSlice(chunk);
                },
                .number => |chunk| {
                    try self.buffer.appendSlice(chunk);
                    return self.buffer.items;
                },
                else => return error.InvalidJSON,
            }
        }
    }

    fn copyString(
        self: *Decoder,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        while (true) {
            switch (try reader.next()) {
                .partial_string => |chunk| {
                    std.log.warn("partial_string: {s}", .{chunk});
                    try self.buffer.appendSlice(chunk);
                },
                .partial_string_escaped_1 => |chunk| {
                    std.log.warn("partial_string_escaped_1: {s}", .{chunk});
                },
                .partial_string_escaped_2 => |chunk| {
                    std.log.warn("partial_string_escaped_2: {s}", .{chunk});
                    // ...
                },
                .partial_string_escaped_3 => |chunk| {
                    std.log.warn("partial_string_escaped_3: {s}", .{chunk});
                },
                .partial_string_escaped_4 => |chunk| {
                    std.log.warn("partial_string_escaped_4: {s}", .{chunk});
                },
                .string => |chunk| {
                    std.log.warn("string: {s}", .{chunk});
                    try self.buffer.appendSlice(chunk);
                    return self.buffer.items;
                },
                else => return error.InvalidJSON,
            }
        }
    }
};

pub const Encoder = struct {
    pub const Options = struct {};

    options: Options,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator, options: Options) Encoder {
        return .{
            .options = options,
            .buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit();
    }

    pub fn encodeValue(self: *Encoder, allocator: std.mem.Allocator, value: Value) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        try self.writeValue(value, self.buffer.writer().any());
        const copy = try allocator.alloc(u8, self.buffer.items.len);
        @memcpy(copy, self.buffer.items);
        return copy;
    }

    pub fn writeValue(self: *Encoder, value: Value, writer: std.io.AnyWriter) !void {
        switch (value) {
            .null => try writer.writeAll("null"),
            .boolean => |value_bool| switch (value_bool) {
                false => try writer.writeAll("false"),
                true => try writer.writeAll("true"),
            },
            .integer => |value_int| try std.fmt.format(writer, "{d}", .{value_int}),
            .float => |value_float| try std.fmt.format(writer, "{d}", .{value_float}),
            .string => |string| {
                try std.json.encodeJsonString(string.data, .{
                    .escape_unicode = false,
                }, writer);
            },
            .bytes => |bytes| {
                try writer.writeAll(
                    \\{"/":{"bytes":"
                );
                try multibase.base64.writeAll(writer, bytes.data);
                try writer.writeAll(
                    \\"}}
                );
            },
            .list => |list| {
                // TODO: detect cycles
                try writer.writeByte('[');
                var first_item = true;
                for (list.array_list.items) |item| {
                    if (first_item) {
                        first_item = false;
                    } else {
                        try writer.writeByte(',');
                    }

                    try self.writeValue(item, writer);
                }
                try writer.writeByte(']');
            },
            .map => |map| {
                // TODO: detect cycles
                map.sort();
                try writer.writeByte('{');
                var first_entry = true;
                for (map.keys(), map.values()) |k, v| {
                    if (first_entry) {
                        first_entry = false;
                    } else {
                        try writer.writeByte(',');
                    }

                    try std.json.encodeJsonString(k, .{
                        .escape_unicode = false,
                    }, writer);
                    try writer.writeByte(':');
                    try self.writeValue(v, writer);
                }
                try writer.writeByte('}');
            },
            .link => |link| {
                try writer.writeAll(
                    \\{"/":"
                );
                try std.fmt.format(writer, "{s}", .{link.cid});
                try writer.writeAll(
                    \\"}
                );
            },
        }
    }
};
