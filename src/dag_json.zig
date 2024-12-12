const std = @import("std");

const CID = @import("cid").CID;
const multibase = @import("multibase");

const Value = @import("ipld").Value;
const List = Value.List;
const Map = Value.Map;
const Link = Value.Link;
const String = Value.String;
const Bytes = Value.Bytes;

/// For sorting static struct fields
/// dag-json sorts them in ordinary lexicographic order.
const FieldList = struct {
    fields: []const std.builtin.Type.StructField,

    pub fn lessThan(context: FieldList, lhs: usize, rhs: usize) bool {
        const a = context.fields[lhs].name;
        const b = context.fields[rhs].name;

        const len = @min(a.len, b.len);
        for (0..len) |i|
            if (a[i] != b[i])
                return a[i] < b[i];

        return a.len < b.len;
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

/// For sorting dynamic Value.Map entries.
/// dag-json sorts them in ordinary lexicographic order.
const SortContext = struct {
    keys: []const []const u8,

    pub fn lessThan(ctx: SortContext, a_index: usize, b_index: usize) bool {
        const a = ctx.keys[a_index];
        const b = ctx.keys[b_index];

        const len = @min(a.len, b.len);
        for (0..len) |i|
            if (a[i] != b[i])
                return a[i] < b[i];

        return a.len < b.len;
    }
};

//  <document> = <value> .end_of_document
//  <value> =
//    | <object>
//    | <array>
//    | <number>
//    | <string>
//    | .true
//    | .false
//    | .null
//  <object> = .object_begin ( <string> <value> )* .object_end
//  <array> = .array_begin ( <value> )* .array_end
//  <number> = ( .partial_number )* .number
//  <string> = ( <partial_string> )* .string
//  <partial_string> =
//    | .partial_string
//    | .partial_string_escaped_1
//    | .partial_string_escaped_2
//    | .partial_string_escaped_3
//    | .partial_string_escaped_4

pub const Decoder = struct {
    pub const Options = struct {
        strict: bool = true,
    };

    options: Options,
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator, options: Options) Decoder {
        return .{
            .options = options,
            .allocator = allocator,
            .buffer = std.ArrayListUnmanaged(u8){},
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn decodeType(self: *Decoder, comptime T: type, allocator: std.mem.Allocator, data: []const u8) !T {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader().any();
        const value = try self.readType(T, allocator, reader);
        if (stream.pos != data.len) return error.ExtraneousData;
        return value;
    }

    pub fn readType(self: *Decoder, comptime T: type, allocator: std.mem.Allocator, reader: std.io.AnyReader) !T {
        var r = std.json.reader(allocator, reader);
        defer r.deinit();

        const value = try self.readTypeNext(T, allocator, &r);

        // TODO: if this returns an error it leaks `value`
        switch (try r.next()) {
            .end_of_document => {},
            else => |token| {
                std.log.err("unexpected next token: {any}", .{token});
                return error.ExpectedEOD;
            },
        }
        return value;
    }

    fn readTypeNext(
        self: *Decoder,
        comptime T: type,
        allocator: std.mem.Allocator,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) !T {
        if (T == Value)
            return try self.readValueNext(allocator, reader);

        // if (T == String)
        //     return try writeString(writer, value.data);

        // if (T == Bytes)
        //     return try writeBytes(writer, value.data);

        // if (T == Link)
        //     return try writeLink(writer, value.cid);

        // if (T == CID)
        //     return try writeLink(writer, value);

        if (T == CID) {
            try pop(reader, .object_begin);
            try self.expectString(reader, "/");

            const str = try self.copyString(reader);

            try pop(reader, .object_end);
            return try CID.parse(allocator, str);
        }

        switch (@typeInfo(T)) {
            .Optional => |info| switch (try reader.peekNextTokenType()) {
                .null => switch (try reader.next()) {
                    .null => return null,
                    else => unreachable,
                },
                else => return try self.readTypeNext(info.child, allocator, reader),
            },
            .Bool => switch (try reader.next()) {
                .true => return true,
                .false => return false,
                else => return error.InvalidType,
            },
            .Int => |info| {
                if (info.bits > 64) @compileError("cannot decode integer types of more than 64 bits");

                const min = std.math.minInt(T);
                const max = std.math.maxInt(T);

                const str = try self.copyNumber(reader);
                if (std.mem.indexOfScalar(u8, str, '.') != null or std.mem.indexOfScalar(u8, str, 'e') != null) {
                    return error.InvalidType;
                } else {
                    const value = try std.fmt.parseInt(i64, str, 10);
                    if (min <= value and value <= max) {
                        return @intCast(value);
                    } else {
                        return error.InvalidType;
                    }
                }
            },
            .Float => {
                const str = try self.copyNumber(reader);
                return try std.fmt.parseFloat(T, str);
            },
            .Enum => |info| {
                const kind = comptime getRepresentation(T, info.decls) orelse Value.Kind.integer;
                switch (kind) {
                    .integer => {
                        const value = try self.readTypeNext(info.tag_type, allocator, reader);

                        inline for (info.fields) |field|
                            if (field.value == value)
                                return @enumFromInt(field.value);

                        return error.InvalidValue;
                    },
                    .string => {
                        const str = try self.copyString(reader);

                        inline for (info.fields) |field|
                            if (std.mem.eql(u8, field.name, str))
                                return @enumFromInt(field.value);

                        return error.InvalidValue;
                    },
                    else => @compileError("Enum representations must be Value.Kind.integer or Value.Kind.string"),
                }
            },
            .Array => |info| {
                if (info.sentinel != null) @compileError("array sentinels are not supported");

                try pop(reader, .array_begin);

                var result: T = undefined;
                for (0..info.len) |i|
                    result[i] = try self.readTypeNext(info.child, allocator, reader);

                try pop(reader, .array_end);

                return result;
            },
            .Pointer => |info| switch (info.size) {
                .One => {
                    if (info.sentinel != null) @compileError("pointer sentinels are not supported");
                    const item = try allocator.create(info.child);
                    item.* = try self.readTypeNext(info.child, allocator, reader);
                    return item;
                },
                .Slice => {
                    if (info.sentinel != null) @compileError("pointer sentinels are not supported");
                    try pop(reader, .array_begin);

                    var array = std.ArrayList(info.child).init(self.allocator);
                    defer array.deinit();

                    while (try reader.peekNextTokenType() != .array_end) {
                        const item = try self.readTypeNext(info.child, allocator, reader);
                        try array.append(item);
                    }

                    try pop(reader, .array_end);

                    const result = try allocator.alloc(info.child, array.items.len);
                    @memcpy(result, array.items);

                    return result;
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

                        const int_value = try self.readType(Int, allocator, reader);
                        return try T.decodeIpldInteger(int_value);
                    } else if (comptime std.mem.eql(u8, decl.name, "decodeIpldString")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.decodeIpldString))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.decodeIpldString must be a function"),
                        };

                        switch (@typeInfo(func_info.return_type)) {
                            .ErrorUnion => |error_union_info| if (error_union_info.payload != T)
                                @compileError("T.decodeIpldString must be a function returning an error union of T"),
                            else => @compileError("T.decodeIpldString must be a function returning an error union of T"),
                        }

                        const str = try self.copyString(reader);
                        return try T.decodeIpldString(allocator, str);
                    } else if (comptime std.mem.eql(u8, decl.name, "decodeIpldBytes")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.decodeIpldString))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.decodeIpldBytes must be a function"),
                        };

                        switch (@typeInfo(func_info.return_type)) {
                            .ErrorUnion => |error_union_info| if (error_union_info.payload != T)
                                @compileError("T.decodeIpldBytes must be a function returning an error union of T"),
                            else => @compileError("T.decodeIpldBytes must be a function returning an error union of T"),
                        }

                        try pop(reader, .object_begin);
                        try self.expectString(reader, "/");
                        try pop(reader, .object_begin);
                        try self.expectString(reader, "bytes");

                        const str = try self.copyString(reader);
                        const bytes = try multibase.base64.decode(self.allocator, str);
                        defer self.allocator.free(bytes);

                        return try T.decodeIpldBytes(allocator, bytes);
                    }
                }

                if (info.is_tuple) {
                    try pop(reader, .array_begin);

                    var result: T = undefined;
                    inline for (info.fields) |field|
                        @field(result, field.name) = try self.readTypeNext(field.type, allocator, reader);

                    try pop(reader, .array_end);

                    return result;
                } else {
                    var result: T = undefined;

                    try pop(reader, .object_begin);

                    if (self.options.strict) {
                        const field_indices = comptime FieldList.sortIndices(info.fields);
                        inline for (field_indices) |field_index| {
                            const field = info.fields[field_index];
                            if (comptime std.mem.eql(u8, field.name, "/"))
                                @compileError("Cannot decode struct field '/' (reserved key in dag-json)");

                            try self.expectString(reader, field.name);
                            @field(result, field.name) = try self.readTypeNext(field.type, allocator, reader);
                        }
                    } else {
                        var result_fields: [info.fields.len]bool = .{false} ** info.fields.len;
                        outer: for (0..info.fields.len) |_| {
                            const key = try self.copyString(reader);

                            inline for (info.fields, 0..) |field, field_index| {
                                if (comptime std.mem.eql(u8, field.name, "/"))
                                    @compileError("Cannot decode struct field '/' (reserved key in dag-json)");

                                if (std.mem.eql(u8, key, field.name)) {
                                    @field(result, field.name) = try self.readTypeNext(field.type, allocator, reader);
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

                    try pop(reader, .object_end);

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
        var r = std.json.reader(allocator, reader);
        defer r.deinit();

        const value = try self.readValueNext(allocator, &r);

        // TODO: if this returns an error it leaks `value`
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
                return try Value.createString(allocator, str);
            },
            .number => {
                const str = try self.copyNumber(reader);
                if (std.mem.indexOfScalar(u8, str, '.') != null or std.mem.indexOfScalar(u8, str, 'e') != null) {
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
                        try pop(reader, .object_end);
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

                                // closing brace for { "/": ... }
                                try pop(reader, .object_end);

                                const link = try Link.parse(allocator, str);
                                return .{ .link = link };
                            },
                            .object_begin => {
                                try pop(reader, .object_begin);

                                // parse Bytes
                                try self.expectString(reader, "bytes");
                                const bytes_value = try self.copyString(reader);

                                // closing brace for { "bytes": ... }
                                try pop(reader, .object_end);

                                // closing brace for { "/": ... }
                                try pop(reader, .object_end);

                                const bytes = try Bytes.baseDecode(allocator, bytes_value, multibase.base64);
                                return .{ .bytes = bytes };
                            },
                            else => return error.InvalidValue,
                        }
                    } else {
                        // normal map object
                        var map = try Map.create(allocator, .{});
                        errdefer map.unref();

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

                        try pop(reader, .object_end);

                        return .{ .map = map };
                    }
                },
                .array_begin => {
                    var list = try List.create(allocator, .{});
                    errdefer list.unref();

                    while (try reader.peekNextTokenType() != .array_end) {
                        const value = try self.readValueNext(allocator, reader);
                        try list.array_list.append(allocator, value);
                    }

                    try pop(reader, .array_end);

                    return .{ .list = list };
                },
                .true => return Value.True,
                .false => return Value.False,
                .null => return Value.Null,
                else => unreachable,
            },
        }
    }

    fn copyNumber(
        self: *Decoder,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        try peek(reader, .number);
        while (true) {
            const next = try reader.next();
            switch (next) {
                .partial_number => |chunk| try self.buffer.appendSlice(self.allocator, chunk),
                .number => |chunk| {
                    try self.buffer.appendSlice(self.allocator, chunk);
                    return self.buffer.items;
                },
                else => unreachable,
            }
        }
    }

    fn copyString(
        self: *Decoder,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
    ) ![]const u8 {
        self.buffer.clearRetainingCapacity();
        try peek(reader, .string);
        while (true) {
            switch (try reader.next()) {
                .partial_string => |chunk| try self.buffer.appendSlice(self.allocator, chunk),
                .partial_string_escaped_1 => |chunk| try self.buffer.appendSlice(self.allocator, &chunk),
                .partial_string_escaped_2 => |chunk| try self.buffer.appendSlice(self.allocator, &chunk),
                .partial_string_escaped_3 => |chunk| try self.buffer.appendSlice(self.allocator, &chunk),
                .partial_string_escaped_4 => |chunk| try self.buffer.appendSlice(self.allocator, &chunk),
                .string => |chunk| {
                    try self.buffer.appendSlice(self.allocator, chunk);
                    return self.buffer.items;
                },
                else => unreachable,
            }
        }
    }

    inline fn peek(
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
        expected: std.json.TokenType,
    ) !void {
        if (try reader.peekNextTokenType() != expected)
            return error.InvalidType;
    }

    inline fn pop(
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
        expected: std.json.TokenType,
    ) !void {
        try peek(reader, expected);
        _ = reader.next() catch unreachable;
    }

    inline fn expectString(
        self: *Decoder,
        reader: *std.json.Reader(std.json.default_buffer_size, std.io.AnyReader),
        expected: []const u8,
    ) !void {
        const str = try self.copyString(reader);
        if (!std.mem.eql(u8, str, expected))
            return error.InvalidType;
    }
};

pub const Encoder = struct {
    pub const FloatFormat = union(enum) {
        pub inline fn scientific() FloatFormat {
            return .{ .scientific = {} };
        }

        pub inline fn decimal() FloatFormat {
            return .{ .decimal = {} };
        }

        pub inline fn decimalInRange(min_exp10: ?i10, max_exp10: ?i10) FloatFormat {
            return .{ .decimal_in_range = .{
                .min_exp10 = min_exp10,
                .max_exp10 = max_exp10,
            } };
        }

        scientific: void,
        decimal: void,
        decimal_in_range: struct { min_exp10: ?i10 = null, max_exp10: ?i10 = null },
    };

    pub const Options = struct {
        float_format: FloatFormat = FloatFormat.decimal(),
    };

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

        if (T == String)
            return try writeString(writer, value.data);

        if (T == Bytes)
            return try writeBytes(writer, value.data);

        if (T == Link)
            return try writeLink(writer, value.cid);

        if (T == CID)
            return try writeLink(writer, value);

        switch (@typeInfo(T)) {
            .Optional => |info| {
                if (value) |child_value| {
                    try self.writeType(info.child, child_value, writer);
                } else {
                    try writer.writeAll("null");
                }
            },
            .Bool => switch (value) {
                false => try writer.writeAll("false"),
                true => try writer.writeAll("true"),
            },
            .Int => try std.fmt.format(writer, "{d}", .{value}),
            .Float => try self.writeFloat(writer, @floatCast(value)),
            .Enum => |info| {
                const kind = comptime getRepresentation(T, info.decls) orelse Value.Kind.integer;
                switch (kind) {
                    .integer => try self.writeType(info.tag_type, @intFromEnum(value), writer),
                    .string => try writeString(writer, @tagName(value)),
                    else => @compileError("Enum representations must be Value.Kind.integer or Value.Kind.string"),
                }
            },
            .Array => |info| {
                if (info.sentinel != null) @compileError("array sentinels are not supported");
                try writer.writeByte('[');
                for (value, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try self.writeType(info.child, item, writer);
                }
                try writer.writeByte(']');
            },
            .Pointer => |info| switch (info.size) {
                .One => try self.writeType(info.child, value.*, writer),
                .Slice => {
                    try writer.writeByte('[');
                    for (value, 0..) |item, i| {
                        if (i > 0) try writer.writeByte(',');
                        try self.writeType(info.child, item, writer);
                    }
                    try writer.writeByte(']');
                },
                .Many => @compileError("cannot generate IPLD encoder for [*]T pointers"),
                .C => @compileError("cannot generate IPLD encoder for [*c]T pointers"),
            },
            .Struct => |info| {
                inline for (info.decls) |decl| {
                    if (comptime std.mem.eql(u8, decl.name, "encodeIpldInteger")) {
                        const return_type = switch (@typeInfo(@TypeOf(T.encodeIpldInteger))) {
                            .Fn => |func_info| func_info.return_type,
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

                        const return_payload = switch (@typeInfo(func_info.return_type)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => @compileError("T.writeIpldString must return a void error union"),
                        };

                        switch (@typeInfo(return_payload)) {
                            .Void => {},
                            else => @compileError("T.writeIpldString must return a void error union"),
                        }

                        self.string_buffer.clearRetainingCapacity();
                        try value.writeIpldString(self.string_buffer.writer().any());
                        try writeString(writer, self.string_buffer.items);
                        return;
                    } else if (comptime std.mem.eql(u8, decl.name, "writeIpldBytes")) {
                        const func_info = switch (@typeInfo(@TypeOf(T.writeIpldBytes))) {
                            .Fn => |func_info| func_info,
                            else => @compileError("T.writeIpldBytes must be a function"),
                        };

                        const return_payload = switch (@typeInfo(func_info.return_type)) {
                            .ErrorUnion => |error_union_info| error_union_info.payload,
                            else => @compileError("T.writeIpldBytes must return a void error union"),
                        };

                        switch (@typeInfo(return_payload)) {
                            .Void => {},
                            else => @compileError("T.writeIpldBytes must return a void error union"),
                        }

                        self.string_buffer.clearRetainingCapacity();
                        try value.writeIpldBytes(self.string_buffer.writer().any());
                        try writeBytes(writer, self.string_buffer.items);
                        return;
                    }
                }

                if (info.is_tuple) {
                    try writer.writeByte('[');
                    inline for (info.fields, 0..) |field, i| {
                        if (i > 0) try writer.writeByte(',');
                        try self.writeType(field.type, @field(value, field.name), writer);
                    }
                    try writer.writeByte(']');
                } else {
                    try writer.writeByte('{');

                    const indices = comptime FieldList.sortIndices(info.fields);
                    inline for (indices, 0..) |i, j| {
                        if (j > 0) try writer.writeByte(',');

                        const field = info.fields[i];
                        try writeString(writer, field.name);
                        try writer.writeByte(':');
                        try self.writeType(field.type, @field(value, field.name), writer);
                    }

                    try writer.writeByte('}');
                }
            },
            else => @compileError("cannot generate IPLD encoder for type T"),
        }
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
            .float => |value_float| try self.writeFloat(writer, @floatCast(value_float)),
            .string => |string| try writeString(writer, string.data),
            .bytes => |bytes| try writeBytes(writer, bytes.data),
            .link => |link| try writeLink(writer, link.cid),
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
                map.sort(SortContext{ .keys = map.keys() });
                try writer.writeByte('{');
                var first_entry = true;
                for (map.keys(), map.values()) |k, v| {
                    if (first_entry) {
                        first_entry = false;
                    } else {
                        try writer.writeByte(',');
                    }

                    try writeString(writer, k);
                    try writer.writeByte(':');
                    try self.writeValue(v, writer);
                }
                try writer.writeByte('}');
            },
        }
    }

    fn writeLink(writer: std.io.AnyWriter, cid: CID) !void {
        try writer.writeAll(
            \\{"/":"
        );
        try std.fmt.format(writer, "{s}", .{cid});
        try writer.writeAll(
            \\"}
        );
    }

    inline fn writeFloat(self: *Encoder, writer: std.io.AnyWriter, value: f64) !void {
        if (std.math.isNan(value) or std.math.isInf(value))
            return error.UnsupportedValue;

        if (std.math.isNegativeZero(value))
            return try writer.writeAll("-0.");

        switch (self.options.float_format) {
            .scientific => {
                try std.fmt.format(writer, "{e}", .{value});
            },
            .decimal => {
                try std.fmt.format(writer, "{d}", .{value});
                if (@floor(value) == value)
                    try writer.writeAll(".0");
            },
            .decimal_in_range => |range| {
                const exp: i10 = @intFromFloat(@floor(@log10(@abs(value))));

                if (range.min_exp10) |min_exp10|
                    if (exp < min_exp10)
                        return try std.fmt.format(writer, "{e}", .{value});

                if (range.max_exp10) |max_exp10|
                    if (max_exp10 < exp)
                        return try std.fmt.format(writer, "{e}", .{value});

                try std.fmt.format(writer, "{d}", .{value});
                if (@floor(value) == value)
                    try writer.writeAll(".0");
            },
        }
    }

    inline fn writeString(writer: std.io.AnyWriter, data: []const u8) !void {
        try std.json.encodeJsonString(data, .{
            .escape_unicode = false,
        }, writer);
    }

    fn writeBytes(writer: std.io.AnyWriter, data: []const u8) !void {
        try writer.writeAll(
            \\{"/":{"bytes":"
        );
        try multibase.base64.writeAll(writer, data);
        try writer.writeAll(
            \\"}}
        );
    }
};

fn getRepresentation(comptime T: type, comptime decls: []const std.builtin.Type.Declaration) ?Value.Kind {
    inline for (decls) |decl| {
        if (comptime std.mem.eql(u8, decl.name, "IpldKind")) {
            if (@TypeOf(T.IpldKind) != Value.Kind)
                @compileError("expcted declaration T.IpldKind to be a Value.Kind");

            return T.IpldKind;
        }
    }

    return null;
}
