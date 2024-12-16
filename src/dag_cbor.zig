const std = @import("std");

const CID = @import("cid").CID;

const ipld = @import("ipld");
const Kind = ipld.Kind;
const Value = ipld.Value;
const List = Value.List;
const Map = Value.Map;
const Link = Value.Link;
const String = Value.String;
const Bytes = Value.Bytes;

const utils = @import("utils");
const getRepresentation = utils.getRepresentation;

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
        return self.major_type == .SimpleOrFloat and
            self.argument == @intFromEnum(value);
    }

    pub inline fn expectType(self: Header, expected: MajorType) !void {
        if (self.major_type != expected) {
            std.log.err("expected: {s}, actual: {s}", .{ @tagName(expected), @tagName(self.major_type) });
            return error.InvalidType;
        }
    }
};

/// For sorting static struct fields
/// dag-cbor sorts them by length ascending,
/// and then in ordinary lexicographic order.
const FieldList = struct {
    fields: []const std.builtin.Type.StructField,

    pub fn lessThan(context: FieldList, lhs: usize, rhs: usize) bool {
        const a = context.fields[lhs].name;
        const b = context.fields[rhs].name;

        // First compare lengths
        if (a.len != b.len) {
            return a.len < b.len;
        }

        // If lengths are equal, compare lexicographically
        var i: usize = 0;
        while (i < a.len) : (i += 1) {
            if (a[i] != b[i]) {
                return a[i] < b[i];
            }
        }

        return false;
    }

    pub fn sortIndices(fields: []const std.builtin.Type.StructField) [fields.len]usize {
        var indices: [fields.len]usize = undefined;
        inline for (0..fields.len) |i| indices[i] = i;

        std.mem.sort(usize, &indices, FieldList{ .fields = fields }, lessThan);
        return indices;
    }

    test "FieldList.sort" {
        const Item = struct {
            a: u32,
            c: u32,
            b: u32,
            aaa: u32,
            aa: u32,
        };

        switch (@typeInfo(Item)) {
            .Struct => |info| {
                const indices = comptime sortIndices(info.fields);
                try std.testing.expectEqualSlices(usize, &.{ 0, 2, 1, 4, 3 }, &indices);
            },
            else => {},
        }
    }
};

/// For sorting dynamic Value.Map entries
/// dag-cbor sorts them by length ascending,
/// and then in ordinary lexicographic order.
const SortContext = struct {
    keys: []const []const u8,

    pub fn lessThan(ctx: SortContext, a_index: usize, b_index: usize) bool {
        const a = ctx.keys[a_index];
        const b = ctx.keys[b_index];

        // First compare lengths
        if (a.len != b.len)
            return a.len < b.len;

        // If lengths are equal, compare lexicographically
        for (0..a.len) |i|
            if (a[i] != b[i])
                return a[i] < b[i];

        return false;
    }
};

pub const Decoder = struct {
    pub const Options = struct {
        /// strict enforces sorted map keys and the "minimal size" requirements
        strict: bool = true,
    };

    pub fn Result(comptime T: type) type {
        return struct {
            arena: std.heap.ArenaAllocator,
            value: T,

            pub inline fn deinit(self: @This()) void {
                self.arena.deinit();
            }
        };
    }

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

    pub fn decodeType(self: *Decoder, comptime T: type, allocator: std.mem.Allocator, data: []const u8) !Result(T) {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader().any();
        const result = try self.readType(T, allocator, reader);
        if (stream.pos != data.len) {
            result.deinit();
            return error.ExtraneousData;
        }

        return result;
    }

    pub fn readType(self: *Decoder, comptime T: type, allocator: std.mem.Allocator, reader: std.io.AnyReader) !Result(T) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const value = try self.readTypeAlloc(T, arena.allocator(), reader);
        return .{ .arena = arena, .value = value };
    }

    inline fn readTypeAlloc(self: *Decoder, comptime T: type, allocator: std.mem.Allocator, reader: std.io.AnyReader) !T {
        if (T == Value)
            return try self.readValue(allocator, reader);

        const header = try Header.read(reader);
        return try self.readTypeFromHeader(T, allocator, reader, header);
    }

    fn readTypeFromHeader(
        self: *Decoder,
        comptime T: type,
        allocator: std.mem.Allocator,
        reader: std.io.AnyReader,
        header: Header,
    ) !T {
        if (T == CID) {
            try header.expectType(.Tag);
            const tag = try self.readArgumentInt(header, reader);
            if (tag != 42) return error.InvalidType;
            const bytes = try self.copyByteString(reader);

            // CIDs are prefixed with the raw-binary identity multibase
            if (bytes.len == 0 or bytes[0] != 0x00) return error.InvalidType;

            return try CID.decode(allocator, bytes[1..]);
        }

        switch (@typeInfo(T)) {
            .Optional => |info| {
                if (header.isSimpleValue(.Null)) return null;
                return try self.readTypeFromHeader(info.child, allocator, reader, header);
            },
            .Bool => {
                if (header.isSimpleValue(.False)) return false;
                if (header.isSimpleValue(.True)) return true;
                return error.InvalidType;
            },
            .Int => |info| {
                if (info.bits > 64) @compileError("cannot decode integer types of more than 64 bits");

                const min = std.math.minInt(T);
                const max = std.math.maxInt(T);

                const value = try self.readArgumentInt(header, reader);
                switch (info.signedness) {
                    .unsigned => {
                        try header.expectType(.UnsignedInteger);
                        if (value > max) return error.Overflow;
                        return @truncate(value);
                    },
                    .signed => switch (header.major_type) {
                        .UnsignedInteger => {
                            if (value > max) return error.Overflow;
                            return @intCast(value);
                        },
                        .NegativeInteger => {
                            if (value > -(min + 1)) return error.Overflow;
                            return -1 - @as(T, @intCast(value));
                        },
                        else => return error.InvalidType,
                    },
                }
            },
            .Float => {
                try header.expectType(.SimpleOrFloat);
                const value = try self.readArgumentFloat(header, reader);
                return @floatCast(value);
            },
            .Enum => |info| {
                const kind = comptime getRepresentation(T, info.decls) orelse Kind.integer;
                switch (kind) {
                    .integer => {
                        const value = try self.readTypeFromHeader(info.tag_type, allocator, reader, header);

                        inline for (info.fields) |field|
                            if (field.value == value)
                                return @enumFromInt(value);

                        return error.InvalidValue;
                    },
                    .string => {
                        try header.expectType(.TextString);
                        const len = try self.readArgumentInt(header, reader);
                        try self.buffer.resize(len);
                        try reader.readNoEof(self.buffer.items);

                        inline for (info.fields) |field|
                            if (std.mem.eql(u8, field.name, self.buffer.items))
                                return @enumFromInt(field.value);

                        return error.InvalidValue;
                    },
                    else => @compileError("Enum representations must be Value.Kind.integer or Value.Kind.string"),
                }
            },
            .Array => |info| {
                if (info.sentinel != null) @compileError("array sentinels are not supported");
                try header.expectType(.Array);

                const len = try self.readArgumentInt(header, reader);
                if (len != info.len) return error.InvalidType;

                var result: T = undefined;
                for (0..len) |i|
                    result[i] = try self.readTypeAlloc(info.child, allocator, reader);

                return result;
            },
            .Pointer => |info| switch (info.size) {
                .One => {
                    if (info.sentinel != null) @compileError("pointer sentinels are not supported");
                    const item = try allocator.create(info.child);
                    errdefer allocator.destroy(item);
                    item.* = try self.readTypeFromHeader(info.child, allocator, reader, header);
                    return item;
                },
                .Slice => {
                    if (info.sentinel != null) @compileError("pointer sentinels are not supported");
                    const len = try self.readArgumentInt(header, reader);
                    const items = try allocator.alloc(info.child, len);
                    errdefer allocator.free(items);

                    for (items) |*item| item.* = try self.readTypeAlloc(info.child, allocator, reader);
                    return items;
                },
                .Many => @compileError("cannot generate IPLD decoder for [*]T pointers"),
                .C => @compileError("cannot generate IPLD decoder for [*c]T pointers"),
            },
            .Struct => |info| {
                inline for (info.decls) |decl| {
                    if (comptime std.mem.eql(u8, decl.name, "decodeIpldInteger")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.decodeIpldInteger))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.decodeIpldInteger must be a function"),
                        };

                        switch (@typeInfo(func_info.return_type)) {
                            .ErrorUnion => |error_union_info| if (error_union_info.payload != T)
                                @compileError("T.decodeIpldInteger must be a function returning an error union of T"),
                            else => @compileError("T.decodeIpldInteger must be a function returning an error union of T"),
                        }

                        if (func_info.params.len != 1)
                            @compileError("T.decodeIpldInteger must be a function of a single integer argument");

                        const Int = func_info.params[0].type;
                        switch (@typeInfo(Int)) {
                            .Int => {},
                            else => @compileError("T.decodeIpldInteger must be a function of a single integer argument"),
                        }

                        const int_value = try self.readTypeAlloc(Int, allocator, reader);
                        return try T.decodeIpldInteger(int_value);
                    } else if (comptime std.mem.eql(u8, decl.name, "parseIpldString")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.parseIpldString))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.parseIpldString must be a function"),
                        };

                        switch (@typeInfo(func_info.return_type orelse .NoReturn)) {
                            .ErrorUnion => |error_union_info| if (error_union_info.payload != T)
                                @compileError("T.parseIpldString must be a function returning an error union of T"),
                            else => @compileError("T.parseIpldString must be a function returning an error union of T"),
                        }

                        try header.expectType(.TextString);
                        const len = try self.readArgumentInt(header, reader);
                        try self.buffer.resize(len);
                        try reader.readNoEof(self.buffer.items);
                        return try T.parseIpldString(allocator, self.buffer.items);
                    } else if (comptime std.mem.eql(u8, decl.name, "parseIpldBytes")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.parseIpldBytes))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.parseIpldBytes must be a function"),
                        };

                        const error_payload = switch (@typeInfo(func_info.return_type orelse .NoReturn)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => .NoReturn,
                        };

                        if (error_payload != T)
                            @compileError("T.parseIpldBytes must be a function returning an error union of T");

                        try header.expectType(.ByteString);
                        const len = try self.readArgumentInt(header, reader);
                        try self.buffer.resize(len);
                        try reader.readNoEof(self.buffer.items);
                        return try T.parseIpldBytes(allocator, self.buffer.items);
                    }
                }

                if (info.is_tuple) {
                    try header.expectType(.Array);

                    const len = try self.readArgumentInt(header, reader);
                    if (len != info.fields.len) return error.InvalidType;

                    var result: T = undefined;
                    inline for (info.fields) |field|
                        @field(result, field.name) = try self.readTypeAlloc(field.type, allocator, reader);

                    return result;
                } else {
                    try header.expectType(.Map);

                    const len = try self.readArgumentInt(header, reader);
                    if (len != info.fields.len) return error.InvalidType;

                    var result: T = undefined;

                    if (self.options.strict) {
                        const field_indices = comptime FieldList.sortIndices(info.fields);
                        inline for (field_indices) |field_index| {
                            const field = info.fields[field_index];
                            const key = try self.copyTextString(reader);
                            if (!std.mem.eql(u8, key, field.name)) return error.InvalidType;
                            @field(result, field.name) = try self.readTypeAlloc(field.type, allocator, reader);
                        }
                    } else {
                        var result_fields: [info.fields.len]bool = .{false} ** info.fields.len;
                        outer: for (0..info.fields.len) |_| {
                            const key = try self.copyTextString(reader);
                            inline for (info.fields, 0..) |field, field_index| {
                                if (std.mem.eql(u8, key, field.name)) {
                                    @field(result, field.name) = try self.readTypeAlloc(field.type, allocator, reader);
                                    result_fields[field_index] = true;
                                    continue :outer;
                                }
                            }

                            return error.InvalidType;
                        }

                        for (result_fields) |result_field_present| {
                            if (!result_field_present) return error.InvalidType;
                        }
                    }

                    return result;
                }
            },
            else => @compileError("cannot generate IPLD decoder for type T"),
        }
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
                if (value > max) return error.Overflow;
                return Value.integer(@intCast(value));
            },
            .NegativeInteger => {
                const max = comptime (1 << 63) - 1;
                const value = try self.readArgumentInt(header, reader);
                if (value > max) return error.Overflow;
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
                const len = try self.readArgumentInt(header, reader);

                const list = try List.create(allocator, .{});
                errdefer list.unref();

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
                errdefer map.unref();

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
        try header.expectType(.TextString);
        const len = try self.readArgumentInt(header, reader);
        try self.buffer.resize(len);
        try reader.readNoEof(self.buffer.items);
        return self.buffer.items;
    }

    fn copyByteString(self: *Decoder, reader: std.io.AnyReader) ![]const u8 {
        const header = try Header.read(reader);
        try header.expectType(.ByteString);
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
    string_buffer: std.ArrayList(u8),
    argument_buffer: [8]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, options: Options) Encoder {
        return .{
            .options = options,
            .buffer = std.ArrayList(u8).init(allocator),
            .string_buffer = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.buffer.deinit();
        self.string_buffer.deinit();
    }

    pub fn encodeType(self: *Encoder, T: type, allocator: std.mem.Allocator, value: T) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        try self.writeType(T, value, self.buffer.writer().any());

        const bytes = try allocator.alloc(u8, self.buffer.items.len);
        @memcpy(bytes, self.buffer.items);
        return bytes;
    }

    pub fn writeType(self: *Encoder, comptime T: type, value: T, writer: std.io.AnyWriter) !void {
        if (T == Value)
            return try self.writeValue(value, writer);

        if (T == CID)
            return try self.writeLink(value, writer);

        switch (@typeInfo(T)) {
            .Optional => |info| {
                if (value) |child_value| {
                    try self.writeType(info.child, child_value, writer);
                } else {
                    try writer.writeByte(Header.fromSimpleValue(.Null).encode());
                }
            },
            .Bool => switch (value) {
                false => try writer.writeByte(Header.fromSimpleValue(.False).encode()),
                true => try writer.writeByte(Header.fromSimpleValue(.True).encode()),
            },
            .Int => |info| {
                if (info.bits > 64) @compileError("cannot encode integer types of more than 64 bits");
                if (0 <= value) {
                    try self.writeArgumentInt(.UnsignedInteger, @intCast(value), writer);
                } else {
                    try self.writeArgumentInt(.NegativeInteger, @intCast(-(value + 1)), writer);
                }
            },
            .Float => {
                try self.writeArgumentFloat(.SimpleOrFloat, @floatCast(value), writer);
            },
            .Enum => |info| {
                const kind = comptime getRepresentation(T, info.decls) orelse Value.Kind.integer;
                switch (kind) {
                    .integer => try self.writeType(info.tag_type, @intFromEnum(value), writer),
                    .string => {
                        const str = @tagName(value);
                        try self.writeArgumentInt(.TextString, @intCast(str.len), writer);
                        try writer.writeAll(str);
                    },
                    else => @compileError("Enum representations must be Value.Kind.integer or Value.Kind.string"),
                }
            },
            .Array => |info| {
                if (info.sentinel != null) @compileError("array sentinels are not supported");
                try self.writeArgumentInt(.Array, info.len, writer);
                for (value) |item| {
                    try self.writeType(info.child, item, writer);
                }
            },
            .Pointer => |info| switch (info.size) {
                .One => try self.writeType(info.child, value.*, writer),
                .Slice => {
                    try self.writeArgumentInt(.Array, value.len, writer);
                    for (value) |item| {
                        try self.writeType(info.child, item, writer);
                    }
                },
                .Many => @compileError("cannot generate IPLD encoder for [*]T pointers"),
                .C => @compileError("cannot generate IPLD encoder for [*c]T pointers"),
            },
            .Struct => |info| {
                inline for (info.decls) |decl| {
                    if (comptime std.mem.eql(u8, decl.name, "encodeIpldInteger")) {
                        const return_type = switch (@typeInfo(@TypeOf(T.encodeIpldInteger))) {
                            .Fn => |func_info| func_info.return_type orelse .NoReturn,
                            else => @compileError("T.encodeIpldInteger must be a function"),
                        };

                        const return_payload = switch (@typeInfo(return_type)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => @compileError("T.encodeIpldInteger must return an error union of an integer type"),
                        };

                        switch (@typeInfo(return_payload)) {
                            .Int => {},
                            else => @compileError("T.encodeIpldInteger must return an error union of an integer type"),
                        }

                        const value_int = try value.encodeIpldInteger();
                        return try self.writeType(return_payload, value_int, writer);
                    } else if (comptime std.mem.eql(u8, decl.name, "writeIpldString")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.writeIpldString))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.writeIpldString must be a function"),
                        };

                        const return_payload = switch (@typeInfo(func_info.return_type orelse .NoReturn)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => @compileError("T.writeIpldString must return a void error union"),
                        };

                        switch (@typeInfo(return_payload)) {
                            .Void => {},
                            else => @compileError("T.writeIpldString must return a void error union"),
                        }

                        self.string_buffer.clearRetainingCapacity();
                        try value.writeIpldString(self.string_buffer.writer().any());
                        const text_string = self.string_buffer.items;
                        try self.writeArgumentInt(.TextString, @intCast(text_string.len), writer);
                        try writer.writeAll(text_string);
                        return;
                    } else if (comptime std.mem.eql(u8, decl.name, "writeIpldBytes")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.writeIpldBytes))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.writeIpldBytes must be a function"),
                        };

                        const return_payload = switch (@typeInfo(func_info.return_type orelse .NoReturn)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => @compileError("T.writeIpldBytes must return a void error union"),
                        };

                        switch (@typeInfo(return_payload)) {
                            .Void => {},
                            else => @compileError("T.writeIpldBytes must return a void error union"),
                        }

                        self.string_buffer.clearRetainingCapacity();
                        try value.writeIpldBytes(self.string_buffer.writer().any());
                        const byte_string = self.string_buffer.items;
                        try self.writeArgumentInt(.ByteString, @intCast(byte_string.len), writer);
                        try writer.writeAll(byte_string);
                        return;
                    }
                }

                if (info.is_tuple) {
                    try self.writeArgumentInt(.Array, info.fields.len, writer);
                    inline for (info.fields) |field| {
                        try self.writeType(field.type, @field(value, field.name), writer);
                    }
                } else {
                    try self.writeArgumentInt(.Map, info.fields.len, writer);

                    const indices = comptime FieldList.sortIndices(info.fields);
                    inline for (indices) |i| {
                        const field = info.fields[i];
                        try self.writeArgumentInt(.TextString, field.name.len, writer);
                        try writer.writeAll(field.name);
                        try self.writeType(field.type, @field(value, field.name), writer);
                    }
                }
            },
            else => @compileError("cannot generate IPLD encoder for type T"),
        }
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
                map.sort(SortContext{ .keys = map.keys() });
                try self.writeArgumentInt(.Map, map.len(), writer);
                for (map.keys(), map.values()) |k, v| {
                    try self.writeArgumentInt(.TextString, k.len, writer);
                    try writer.writeAll(k);
                    try self.writeValue(v, writer);
                }
            },
            .link => |link| try self.writeLink(link.cid, writer),
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

    fn writeLink(self: *Encoder, cid: CID, writer: std.io.AnyWriter) !void {
        try writer.writeByte(Header.encode(.{ .major_type = .Tag, .argument = 24 }));
        try writer.writeByte(42);
        try self.writeArgumentInt(.ByteString, cid.encodingLength() + 1, writer);
        try writer.writeByte(0x00); // Multibase identity prefix
        try cid.write(writer);
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
                for (map.keys(), map.values()) |k, v| {
                    sum += argumentEncodingLength(k.len);
                    sum += k.len;
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
