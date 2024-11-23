const std = @import("std");

const CID = @import("cid").CID;

const Value = @import("value.zig").Value;
const Kind = @import("value.zig").Kind;
const List = @import("value.zig").List;
const Map = @import("value.zig").Map;
const Link = @import("value.zig").Link;

// https://www.rfc-editor.org/rfc/rfc8949.html#section-3.1
// Major Type | Meaning               | Content                         |
// ---------- | --------------------- | ------------------------------- |
// 0          | unsigned integer N    | -                               |
// 1          | negative integer -1-N | -                               |
// 2          | byte string           | N bytes                         |
// 3          | text string           | N bytes (UTF-8 text)            |
// 4          | array                 | N data items (elements)         |
// 5          | map                   | 2N data items (key/value pairs) |
// 6          | tag of number N       | 1 data item                     |
// 7          | simple/float          | -                               |

pub const MajorType = enum(u3) {
    UnsignedInteger = 0,
    NegativeInteger = 1,
    ByteString = 2,
    TextString = 3,
    Array = 4,
    Map = 5,
    Tag = 6,
    SimpleOrFloat = 7,
};

pub const Argument = u5;

pub const SimpleValue = enum(u5) {
    False = 20,
    True = 21,
    Null = 22,
    Undefined = 23,
};

pub const Header = packed struct {
    major_type: MajorType,
    argument: Argument,

    pub inline fn fromSimpleValue(value: SimpleValue) Header {
        return .{ .major_type = .SimpleOrFloat, .argument = @intFromEnum(value) };
    }

    pub inline fn read(reader: std.io.AnyReader) !Header {
        const byte = try reader.readByte();
        return Header.decode(byte);
    }

    pub inline fn decode(byte: u8) Header {
        return .{ .major_type = @enumFromInt(byte >> 5), .argument = @truncate(byte) };
    }

    pub inline fn encode(self: Header) u8 {
        var byte: u8 = 0;
        byte |= @as(u8, @intCast(@intFromEnum(self.major_type))) << 5;
        byte |= @as(u8, @intCast(self.argument));
        return byte;
    }

    pub inline fn isSimpleValue(self: Header, value: SimpleValue) bool {
        return self.major_type == .SimpleOrFloat and self.argument == @intFromEnum(value);
    }
};

pub const Decoder = struct {
    pub const Options = struct {
        strict: bool = true,
    };

    options: Options,
    buffer: std.ArrayList(u8),
    argument_buffer: [8]u8 = undefined,

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

    pub fn readValue(self: *Decoder, allocator: std.mem.Allocator, reader: std.io.AnyReader) !Value {
        const header = try Header.read(reader);

        switch (header.major_type) {
            .UnsignedInteger => {
                const max = comptime std.math.maxInt(i64);
                const value = try self.readArgumentInt(header, reader);
                if (value > max) return error.IntegerOverflow;
                return Value.integer(@intCast(value));
            },
            .NegativeInteger => {
                const max = comptime (1 << 63) - 1;
                const value = try self.readArgumentInt(header, reader);
                if (value > max) return error.IntegerUnderflow;
                return Value.integer(-1 - @as(i64, @intCast(value)));
            },
            .ByteString => {
                const len = try self.readArgumentInt(header, reader);
                try self.buffer.resize(len);
                try reader.readNoEof(self.buffer.items);
                return try Value.createBytes(allocator, self.buffer.items);
            },
            .TextString => {
                const len = try self.readArgumentInt(header, reader);
                try self.buffer.resize(len);
                try reader.readNoEof(self.buffer.items);
                return try Value.createString(allocator, self.buffer.items);
            },
            .Array => {
                const list = try List.create(allocator, .{});
                const len = try self.readArgumentInt(header, reader);
                try list.array_list.ensureTotalCapacity(allocator, len);
                for (0..len) |_| {
                    const value = try self.readValue(allocator, reader);
                    list.array_list.appendAssumeCapacity(value);
                }

                return .{ .list = list };
            },
            .Map => {
                const len = try self.readArgumentInt(header, reader);
                var map = try Map.create(allocator, .{});
                try map.hash_map.ensureTotalCapacity(allocator, len);
                for (0..len) |_| {
                    const key = try self.copyTextString(reader);
                    try map.set(key, Value.Null);
                    const ptr = map.hash_map.getPtr(key) orelse @panic("internal error - bad hash map");
                    ptr.* = try self.readValue(allocator, reader);
                }

                return .{ .map = map };
            },
            .Tag => {
                const tag = try self.readArgumentInt(header, reader);
                if (tag != 42) return error.InvalidType;
                const bytes = try self.copyByteString(reader);

                // CIDs are prefixed with the raw-binary identity multibase
                if (bytes.len == 0 or bytes[0] != 0x00) return error.InvalidType;

                const link = try Link.decode(allocator, bytes[1..]);
                return .{ .link = link };
            },
            .SimpleOrFloat => {
                if (header.isSimpleValue(.False)) return Value.False;
                if (header.isSimpleValue(.True)) return Value.True;
                if (header.isSimpleValue(.Null)) return Value.Null;

                const value = try self.readArgumentFloat(header, reader);
                return Value.float(value);
            },
        }
    }

    fn readArgumentInt(self: *Decoder, header: Header, reader: std.io.AnyReader) !u64 {
        if (header.argument < 24) {
            return @intCast(header.argument);
        } else if (header.argument == 24) {
            const value = try reader.readByte();
            if (self.options.strict and value < 24) return error.Strict;
            return @intCast(value);
        } else if (header.argument == 25) {
            try reader.readNoEof(self.argument_buffer[0..2]);
            const value = std.mem.readInt(u16, self.argument_buffer[0..2], .big);
            if (self.options.strict and value <= std.math.maxInt(u8)) return error.Strict;
            return @intCast(value);
        } else if (header.argument == 26) {
            try reader.readNoEof(self.argument_buffer[0..4]);
            const value = std.mem.readInt(u32, self.argument_buffer[0..4], .big);
            if (self.options.strict and value <= std.math.maxInt(u16)) return error.Strict;
            return @intCast(value);
        } else if (header.argument == 27) {
            try reader.readNoEof(self.argument_buffer[0..8]);
            const value = std.mem.readInt(u64, self.argument_buffer[0..8], .big);
            if (self.options.strict and value <= std.math.maxInt(u32)) return error.Strict;
            return value;
        } else {
            return error.InvalidType;
        }
    }

    fn readArgumentFloat(self: *Decoder, header: Header, reader: std.io.AnyReader) !f64 {
        if (header.argument == 25) {
            if (self.options.strict) return error.InvalidType;
            try reader.readNoEof(self.argument_buffer[0..2]);
            return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, self.argument_buffer[0..2], .big))));
        } else if (header.argument == 26) {
            if (self.options.strict) return error.InvalidType;
            try reader.readNoEof(self.argument_buffer[0..4]);
            return @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, self.argument_buffer[0..4], .big))));
        } else if (header.argument == 27) {
            try reader.readNoEof(self.argument_buffer[0..8]);
            return @bitCast(std.mem.readInt(u64, self.argument_buffer[0..8], .big));
        } else {
            return error.InvalidType;
        }
    }

    fn copyTextString(self: *Decoder, reader: std.io.AnyReader) ![]const u8 {
        const header = try Header.read(reader);
        if (header.major_type != .TextString) return error.InvalidType;
        const len = try self.readArgumentInt(header, reader);
        try self.buffer.resize(len);
        try reader.readNoEof(self.buffer.items);
        return self.buffer.items;
    }

    fn copyByteString(self: *Decoder, reader: std.io.AnyReader) ![]const u8 {
        const header = try Header.read(reader);
        if (header.major_type != .ByteString) return error.InvalidType;
        const len = try self.readArgumentInt(header, reader);
        try self.buffer.resize(len);
        try reader.readNoEof(self.buffer.items);
        return self.buffer.items;
    }
};

pub const Encoder = struct {
    pub const Options = struct {};

    options: Options,
    buffer: std.ArrayList(u8),
    argument_buffer: [8]u8 = undefined,

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
        const len = encodingLengthValue(value);
        const bytes = try allocator.alloc(u8, len);
        errdefer allocator.free(bytes);

        var stream = std.io.fixedBufferStream(bytes);
        const writer = stream.writer().any();
        try self.writeValue(value, writer);

        return bytes;
    }

    pub fn writeValue(self: *Encoder, value: Value, writer: std.io.AnyWriter) !void {
        switch (value) {
            .null => try writer.writeByte(Header.fromSimpleValue(.Null).encode()),
            .boolean => |value_bool| switch (value_bool) {
                false => try writer.writeByte(Header.fromSimpleValue(.False).encode()),
                true => try writer.writeByte(Header.fromSimpleValue(.True).encode()),
            },
            .integer => |value_int| {
                if (0 <= value_int) {
                    try self.writeArgumentInt(.UnsignedInteger, @intCast(value_int), writer);
                } else {
                    try self.writeArgumentInt(.NegativeInteger, @intCast(-(value_int + 1)), writer);
                }
            },
            .float => |value_float| try self.writeArgumentFloat(.SimpleOrFloat, value_float, writer),
            .string => |string| {
                try self.writeArgumentInt(.TextString, string.data.len, writer);
                try writer.writeAll(string.data);
            },
            .bytes => |bytes| {
                try self.writeArgumentInt(.ByteString, bytes.data.len, writer);
                try writer.writeAll(bytes.data);
            },
            .list => |list| {
                // TODO: detect cycles
                try self.writeArgumentInt(.Array, list.len(), writer);
                for (list.values()) |item| try self.writeValue(item, writer);
            },
            .map => |map| {
                // TODO: detect cycles
                map.sort();
                try self.writeArgumentInt(.Map, map.len(), writer);
                for (map.keys()) |key| {
                    const v = map.get(key) orelse continue;
                    try self.writeArgumentInt(.TextString, key.len, writer);
                    try writer.writeAll(key);
                    try self.writeValue(v, writer);
                }
            },
            .link => |link| {
                try writer.writeByte(Header.encode(.{ .major_type = .Tag, .argument = 24 }));
                try writer.writeByte(42);
                try self.writeArgumentInt(.ByteString, link.cid.encodingLength(), writer);
                try link.cid.write(writer);
            },
        }
    }

    fn writeArgumentInt(self: *Encoder, major_type: MajorType, value: u64, writer: std.io.AnyWriter) !void {
        if (value < 24) {
            try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = @truncate(value) }));
        } else if (value <= 0xff) {
            try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = 24 }));
            try writer.writeByte(@truncate(value));
        } else if (value <= 0xffff) {
            std.mem.writeInt(u16, self.argument_buffer[0..2], @truncate(value), .big);
            try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = 25 }));
            try writer.writeAll(self.argument_buffer[0..2]);
        } else if (value <= 0xffffffff) {
            std.mem.writeInt(u32, self.argument_buffer[0..4], @truncate(value), .big);
            try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = 26 }));
            try writer.writeAll(self.argument_buffer[0..4]);
        } else {
            std.mem.writeInt(u64, self.argument_buffer[0..8], value, .big);
            try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = 27 }));
            try writer.writeAll(self.argument_buffer[0..8]);
        }
    }

    fn writeArgumentFloat(self: *Encoder, major_type: MajorType, value: f64, writer: std.io.AnyWriter) !void {
        const value_bytes = @as(u64, @bitCast(value));
        std.mem.writeInt(u64, self.argument_buffer[0..8], value_bytes, .big);

        try writer.writeByte(Header.encode(.{ .major_type = major_type, .argument = 27 }));
        try writer.writeAll(self.argument_buffer[0..8]);
    }

    pub fn encodingLengthValue(value: Value) usize {
        switch (value) {
            .null => return 1,
            .boolean => return 1,
            .integer => |value_int| {
                if (0 <= value_int) {
                    return argumentEncodingLength(@intCast(value_int));
                } else {
                    return argumentEncodingLength(@intCast(-(value_int + 1)));
                }
            },
            .float => return 9,
            .string => |string| {
                const arg_len = argumentEncodingLength(string.data.len);
                return arg_len + string.data.len;
            },
            .bytes => |bytes| {
                const arg_len = argumentEncodingLength(bytes.data.len);
                return arg_len + bytes.data.len;
            },
            .list => |list| {
                var sum: usize = argumentEncodingLength(list.len());
                for (list.values()) |item|
                    sum += encodingLengthValue(item);

                return sum;
            },
            .map => |map| {
                var sum: usize = argumentEncodingLength(map.len());
                for (map.keys()) |key| {
                    const v = map.get(key) orelse continue;
                    sum += argumentEncodingLength(key.len);
                    sum += key.len;
                    sum += encodingLengthValue(v);
                }
                return sum;
            },
            .link => |link| {
                const cid_len = 1 + link.cid.encodingLength();
                const arg_len = argumentEncodingLength(cid_len);
                return 2 + arg_len + cid_len;
            },
        }
    }

    fn argumentEncodingLength(value: u64) usize {
        if (value < 24) {
            return 1;
        } else if (value <= 0xff) {
            return 1 + 1;
        } else if (value <= 0xffff) {
            return 1 + 2;
        } else if (value <= 0xffffffff) {
            return 1 + 4;
        } else {
            return 1 + 8;
        }
    }
};
