const std = @import("std");

const multibase = @import("multibase");
const CID = @import("cid").CID;

pub const Kind = enum {
    null,
    boolean,
    integer,
    float,
    string,
    bytes,
    list,
    map,
    link,
};

pub const Value = union(Kind) {
    pub const String = struct {
        allocator: std.mem.Allocator,
        refs: u32,
        data: []const u8,

        /// copies `data` using `allocator`
        pub fn create(allocator: std.mem.Allocator, data: []const u8) !*String {
            const data_copy = try allocator.alloc(u8, data.len);
            @memcpy(data_copy, data);
            errdefer allocator.free(data_copy);

            const string = try allocator.create(String);
            string.allocator = allocator;
            string.refs = 1;
            string.data = data_copy;
            return string;
        }

        /// increment reference count
        pub inline fn ref(self: *String) void {
            self.refs += 1;
        }

        /// decrement reference count, freeing all data on self.refs == 0
        pub fn unref(self: *String) void {
            if (self.refs == 0) @panic("ref count already at zero");

            self.refs -= 1;
            if (self.refs == 0) {
                self.allocator.free(self.data);
                self.allocator.destroy(self);
            }
        }

        pub inline fn eql(self: *const String, other: *const String) bool {
            return std.mem.eql(u8, self.data, other.data);
        }

        pub inline fn expectEqual(actual: *const String, expected: *const String) error{TestExpectedEqual}!void {
            try std.testing.expectEqualSlices(u8, actual.data, expected.data);
        }
    };

    pub const Bytes = struct {
        allocator: std.mem.Allocator,
        refs: u32,
        data: []const u8,

        /// copies `data` using `allocator`
        pub fn create(allocator: std.mem.Allocator, data: []const u8) !*Bytes {
            const data_copy = try allocator.alloc(u8, data.len);
            @memcpy(data_copy, data);
            errdefer allocator.free(data_copy);

            const bytes = try allocator.create(Bytes);
            bytes.allocator = allocator;
            bytes.refs = 1;
            bytes.data = data_copy;
            return bytes;
        }

        /// decodes base-prefixed `str` using `base` and `allocator`
        pub fn baseDecode(allocator: std.mem.Allocator, str: []const u8, base: multibase.Base) !*Bytes {
            const data_copy = try base.baseDecode(allocator, str);
            errdefer allocator.free(data_copy);

            const bytes = try allocator.create(Bytes);
            bytes.allocator = allocator;
            bytes.refs = 1;
            bytes.data = data_copy;
            return bytes;
        }

        /// increment reference count
        pub inline fn ref(self: *Bytes) void {
            self.refs += 1;
        }

        /// decrement reference count, freeing all data on self.refs == 0
        pub fn unref(self: *Bytes) void {
            if (self.refs == 0) @panic("ref count already at zero");

            self.refs -= 1;
            if (self.refs == 0) {
                self.allocator.free(self.data);
                self.allocator.destroy(self);
            }
        }

        pub inline fn eql(self: *const Bytes, other: *const Bytes) bool {
            return std.mem.eql(u8, self.data, other.data);
        }

        pub inline fn expectEqual(actual: *const Bytes, expected: *const Bytes) error{TestExpectedEqual}!void {
            try std.testing.expectEqualSlices(u8, actual.data, expected.data);
        }
    };

    pub const Link = struct {
        allocator: std.mem.Allocator,
        refs: u32,
        cid: CID,

        /// copies `cid` using `allocator`
        pub fn create(allocator: std.mem.Allocator, cid: CID) !*Link {
            const cid_copy = try cid.copy(allocator);
            errdefer cid_copy.deinit(allocator);

            const link = try allocator.create(Link);
            link.allocator = allocator;
            link.refs = 1;
            link.cid = cid_copy;
            return link;
        }

        /// parse a new CID from `str` using `allocator`
        pub fn parse(allocator: std.mem.Allocator, str: []const u8) !*Link {
            const cid = try CID.parse(allocator, str);
            errdefer cid.deinit(allocator);

            const link = try allocator.create(Link);
            link.allocator = allocator;
            link.refs = 1;
            link.cid = cid;
            return link;
        }

        /// decode a new CID from `bytes` using `allocator`
        pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !*Link {
            const cid = try CID.decode(allocator, bytes);
            errdefer cid.deinit(allocator);

            const link = try allocator.create(Link);
            link.allocator = allocator;
            link.refs = 1;
            link.cid = cid;
            return link;
        }

        /// increment reference count
        pub inline fn ref(self: *Link) void {
            self.refs += 1;
        }

        /// decrement reference count, freeing all data on self.refs == 0
        pub fn unref(self: *Link) void {
            if (self.refs == 0) @panic("ref count already at zero");

            self.refs -= 1;
            if (self.refs == 0) {
                self.cid.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        }

        pub inline fn eql(self: *const Link, other: *const Link) bool {
            return self.cid.eql(other.cid);
        }

        pub inline fn expectEqual(actual: *const Link, expected: *const Link) error{TestExpectedEqual}!void {
            try actual.cid.expectEqual(expected.cid);
        }
    };

    pub const List = struct {
        allocator: std.mem.Allocator,
        refs: u32,
        array_list: std.ArrayListUnmanaged(Value),

        pub fn create(allocator: std.mem.Allocator, initial_values: anytype) !*List {
            var array_list = std.ArrayListUnmanaged(Value){};
            errdefer array_list.deinit(allocator);

            const tuple_info = switch (@typeInfo(@TypeOf(initial_values))) {
                .@"struct" => |info| info,
                else => @compileError("initial_values must be a tuple"),
            };

            if (!tuple_info.is_tuple) @compileError("initial_values must be a tuple");

            try array_list.ensureTotalCapacity(allocator, tuple_info.fields.len);
            inline for (tuple_info.fields) |field| {
                if (field.type != Value) @compileError("map fields must be Value types");
                const value = @field(initial_values, field.name);
                array_list.appendAssumeCapacity(value);
            }

            const list = try allocator.create(List);
            list.allocator = allocator;
            list.refs = 1;
            list.array_list = array_list;
            return list;
        }

        /// increment reference count
        pub inline fn ref(self: *List) void {
            self.refs += 1;
        }

        /// decrement reference count, freeing all data on self.refs == 0
        pub fn unref(self: *List) void {
            if (self.refs == 0) @panic("ref count already at zero");

            self.refs -= 1;
            if (self.refs == 0) {
                for (self.array_list.items) |*item| item.unref();
                self.array_list.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        }

        pub fn eql(self: *const List, other: *const List) bool {
            const values_self = self.values();
            const values_other = other.values();
            if (values_self.len != values_other.len) return false;
            for (0..values_self.len) |i|
                if (!values_self[i].eql(values_other[i])) return false;

            return true;
        }

        pub fn expectEqual(actual: *const List, expected: *const List) error{TestExpectedEqual}!void {
            try std.testing.expectEqual(actual.len(), expected.len());
            for (actual.array_list.items, expected.array_list.items) |actual_item, expected_item| {
                try actual_item.expectEqual(expected_item);
            }
        }

        pub inline fn len(self: *const List) usize {
            return self.array_list.items.len;
        }

        pub inline fn get(self: *const List, index: usize) Value {
            return self.array_list.items[index];
        }

        pub inline fn values(self: *const List) []const Value {
            return self.array_list.items;
        }

        pub inline fn append(self: *List, value: Value) !void {
            try self.array_list.append(self.allocator, value);
            value.ref();
        }

        pub inline fn pop(self: *List) !Value {
            return try self.array_list.pop();
        }

        pub inline fn insert(self: *List, index: usize, value: Value) !void {
            try self.array_list.insert(self.allocator, index, value);
            value.ref();
        }

        pub inline fn remove(self: *List, index: usize) void {
            self.array_list.orderedRemove(index).unref();
        }
    };

    pub const Map = struct {
        const HashMap = std.StringArrayHashMapUnmanaged(Value);

        allocator: std.mem.Allocator,
        refs: u32,
        hash_map: HashMap,

        pub fn create(allocator: std.mem.Allocator, initial_entries: anytype) !*Map {
            var hash_map = HashMap{};
            errdefer hash_map.deinit(allocator);

            const struct_info = switch (@typeInfo(@TypeOf(initial_entries))) {
                .@"struct" => |info| info,
                else => @compileError("initial_entries must be a struct"),
            };

            if (struct_info.is_tuple and struct_info.fields.len > 0)
                @compileError("initial_entries must be a struct");

            try hash_map.ensureTotalCapacity(allocator, struct_info.fields.len);
            inline for (struct_info.fields) |field| {
                if (field.type != Value) @compileError("map fields must be Value types");
                const value = @field(initial_entries, field.name);

                const key = try allocator.alloc(u8, field.name.len);
                @memcpy(key, field.name);
                hash_map.putAssumeCapacity(key, value);
            }

            const map = try allocator.create(Map);
            map.allocator = allocator;
            map.refs = 1;
            map.hash_map = hash_map;
            return map;
        }

        /// increment reference count
        pub inline fn ref(self: *Map) void {
            self.refs += 1;
        }

        /// decrement reference count, freeing all data on self.refs == 0
        pub fn unref(self: *Map) void {
            if (self.refs == 0) @panic("ref count already at zero");

            self.refs -= 1;
            if (self.refs == 0) {
                for (self.hash_map.keys()) |key| self.allocator.free(key);
                for (self.hash_map.values()) |value| value.unref();
                self.hash_map.deinit(self.allocator);
                self.allocator.destroy(self);
            }
        }

        pub fn eql(self: *const Map, other: *const Map) bool {
            if (self.len() != other.len()) return false;
            for (self.keys()) |key| {
                const value_other = other.get(key) orelse return false;
                if (self.get(key)) |value_self|
                    if (!value_self.eql(value_other)) return false;
            }

            return true;
        }

        pub fn expectEqual(expected: *const Map, actual: *const Map) error{TestExpectedEqual}!void {
            for (expected.keys(), expected.values()) |expected_key, expected_value| {
                if (actual.get(expected_key)) |actual_value| {
                    try expected_value.expectEqual(actual_value);
                } else {
                    std.log.err("missing expected key {s}", .{expected_key});
                    return error.TestExpectedEqual;
                }
            }

            for (actual.keys()) |actual_key| {
                _ = expected.get(actual_key) orelse {
                    std.log.err("extraneous entry {s}", .{actual_key});
                    return error.TestExpectedEqual;
                };
            }
        }

        pub inline fn len(self: *const Map) usize {
            return self.hash_map.entries.len;
        }

        pub fn set(self: *Map, key: []const u8, value: Value) !void {
            const key_copy = try self.allocator.alloc(u8, key.len);
            @memcpy(key_copy, key);
            errdefer self.allocator.free(key_copy);

            // TODO: check/free existing entry

            try self.hash_map.put(self.allocator, key_copy, value);
            value.ref();
        }

        pub fn delete(self: *Map, key: []const u8) !void {
            if (self.hash_map.fetchSwapRemove(key)) |entry| {
                self.allocator.free(entry.key);
                entry.value.unref();
            }
        }

        pub inline fn get(self: *const Map, key: []const u8) ?Value {
            return self.hash_map.get(key);
        }

        pub inline fn keys(self: *const Map) []const []const u8 {
            return self.hash_map.keys();
        }

        pub inline fn values(self: *const Map) []const Value {
            return self.hash_map.values();
        }

        pub inline fn sort(self: *Map, sort_ctx: anytype) void {
            self.hash_map.sortUnstable(sort_ctx);
        }
    };

    null: void,
    boolean: bool,
    integer: i64,
    float: f64,
    string: *String,
    bytes: *Bytes,
    list: *List,
    map: *Map,
    link: *Link,

    pub const False = Value{ .boolean = false };
    pub const True = Value{ .boolean = true };
    pub const Null = Value{ .null = {} };

    pub inline fn createInteger(value: i64) Value {
        return .{ .integer = value };
    }

    pub inline fn createFloat(value: f64) Value {
        return .{ .float = value };
    }

    /// copies `data` using `allocator`
    pub inline fn createString(allocator: std.mem.Allocator, data: []const u8) !Value {
        return .{ .string = try String.create(allocator, data) };
    }

    /// copies `data` using `allocator`
    pub inline fn createBytes(allocator: std.mem.Allocator, data: []const u8) !Value {
        return .{ .bytes = try Bytes.create(allocator, data) };
    }

    /// decodes base-prefixed `str` using `base` and `allocator`
    pub inline fn baseDecodeBytes(allocator: std.mem.Allocator, str: []const u8) !Value {
        return .{ .bytes = try Bytes.baseDecode(allocator, str) };
    }

    pub inline fn createList(allocator: std.mem.Allocator, initial_values: anytype) !Value {
        return .{ .list = try List.create(allocator, initial_values) };
    }

    pub inline fn createMap(allocator: std.mem.Allocator, initial_entries: anytype) !Value {
        return .{ .map = try Map.create(allocator, initial_entries) };
    }

    /// copies `cid` using `allocator`
    pub inline fn createLink(allocator: std.mem.Allocator, cid: CID) !Value {
        return .{ .link = try Link.create(allocator, cid) };
    }

    /// parse a new CID from `str` using `allocator`
    pub inline fn parseLink(allocator: std.mem.Allocator, str: []const u8) !Value {
        return .{ .link = try Link.parse(allocator, str) };
    }

    /// decode a new CID from `bytes` using `allocator`
    pub inline fn decodeLink(allocator: std.mem.Allocator, bytes: []const u8) !Value {
        return .{ .link = try Link.decode(allocator, bytes) };
    }

    pub fn ref(self: Value) void {
        switch (self) {
            .null => {},
            .boolean => {},
            .integer => {},
            .float => {},
            .string => |string| string.ref(),
            .bytes => |bytes| bytes.ref(),
            .list => |list| list.ref(),
            .map => |map| map.ref(),
            .link => |link| link.ref(),
        }
    }

    pub fn unref(self: Value) void {
        switch (self) {
            .null => {},
            .boolean => {},
            .integer => {},
            .float => {},
            .string => |string| string.unref(),
            .bytes => |bytes| bytes.unref(),
            .list => |list| list.unref(),
            .map => |map| map.unref(),
            .link => |link| link.unref(),
        }
    }

    pub fn eql(self: Value, other: Value) bool {
        return switch (self) {
            .null => switch (other) {
                .null => true,
                else => false,
            },
            .boolean => switch (other) {
                .boolean => self.boolean == other.boolean,
                else => false,
            },
            .integer => switch (other) {
                .integer => self.integer == other.integer,
                else => false,
            },
            .float => switch (other) {
                .float => self.float == other.float,
                else => false,
            },
            .string => switch (other) {
                .string => self.string.eql(other.string),
                else => false,
            },
            .bytes => switch (other) {
                .bytes => self.bytes.eql(other.bytes),
                else => false,
            },
            .list => switch (other) {
                .list => self.list.eql(other.list),
                else => false,
            },
            .map => switch (other) {
                .map => self.map.eql(other.map),
                else => false,
            },
            .link => switch (other) {
                .link => self.link.eql(other.link),
                else => false,
            },
        };
    }

    pub fn expectEqual(actual: Value, expected: Value) error{TestExpectedEqual}!void {
        switch (actual) {
            .null => try std.testing.expectEqual(actual, expected),
            .boolean => try std.testing.expectEqual(actual, expected),
            .integer => try std.testing.expectEqual(actual, expected),
            .float => try std.testing.expectEqual(actual, expected),
            .string => |string_self| switch (expected) {
                .string => |string_other| try string_self.expectEqual(string_other),
                else => return error.TestExpectedEqual,
            },
            .bytes => |bytes_self| switch (expected) {
                .bytes => |bytes_other| try bytes_self.expectEqual(bytes_other),
                else => return error.TestExpectedEqual,
            },
            .list => |list_self| switch (expected) {
                .list => |list_other| try list_self.expectEqual(list_other),
                else => return error.TestExpectedEqual,
            },
            .map => |map_self| switch (expected) {
                .map => |map_other| try map_self.expectEqual(map_other),
                else => return error.TestExpectedEqual,
            },
            .link => |link_self| switch (expected) {
                .link => |link_other| try link_self.expectEqual(link_other),
                else => return error.TestExpectedEqual,
            },
        }
    }

    /// Format a Value
    pub fn format(self: Value, writer: *std.io.Writer) !void {
        switch (self) {
            .null => try writer.print("Value(Null)", .{}),
            .boolean => |value| try writer.print("Value(Boolean: {any})", .{value}),
            .integer => |value| try writer.print("Value(Integer: {d})", .{value}),
            .float => |value| try writer.print("Value(Float: {e})", .{value}),
            .string => |value| {
                try writer.writeAll("Value(String: ");
                try std.json.Stringify.encodeJsonString(value.data, .{ .escape_unicode = true }, writer);
                try writer.writeAll(")");
            },
            .bytes => |value| {
                try writer.print("Value(Bytes: 0x{x})", .{value.data});
            },
            .list => |value| {
                const items = value.values();
                if (items.len == 0)
                    return try writer.writeAll("Value(List: [])");

                try writer.writeAll("Value(List: [ ");
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try item.format(writer);
                }

                try writer.writeAll(" ])");
            },
            .map => |value| {
                if (value.len() == 0)
                    return try writer.writeAll("Value(Map: {})");

                try writer.writeAll("Value(Map: { ");
                for (value.keys(), value.values(), 0..) |k, v, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try std.json.Stringify.encodeJsonString(k, .{ .escape_unicode = true }, writer);
                    try writer.writeAll(" -> ");
                    try v.format(writer);
                }
                try writer.writeAll(" })");
            },
            .link => |value| try writer.print("Value(Link: {s})", .{value.cid}),
        }
    }
};

test "primitive values" {
    try std.testing.expectEqual(Value.Null.null, {});
    try std.testing.expectEqual(Value.False.boolean, false);
    try std.testing.expectEqual(Value.True.boolean, true);

    const max = std.math.maxInt(i64);
    const min = std.math.minInt(i64);
    try std.testing.expectEqual(Value.createInteger(0).integer, 0);
    try std.testing.expectEqual(Value.createInteger(min).integer, min);
    try std.testing.expectEqual(Value.createInteger(max).integer, max);

    try std.testing.expectEqual(Value.createFloat(std.math.pi).float, @as(f64, std.math.pi));
}

test "complex values" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var map = try Value.createMap(allocator, .{
        .foo = try Value.createString(allocator, "hello world"),
        .bar = Value.createInteger(9),
        .baz = Value.True,
    });

    defer map.unref();

    var list = try Value.createList(allocator, .{
        try Value.createString(allocator, "hello world"),
        Value.createInteger(9),
        Value.True,
        try Value.createMap(allocator, .{
            .foo = try Value.createString(allocator, "hello world"),
            .bar = Value.createInteger(9),
            .baz = try Value.createMap(allocator, .{
                .foo = try Value.createString(allocator, "hello world"),
                .bar = Value.createInteger(9),
                .baz = Value.True,
            }),
        }),
    });

    defer list.unref();
}
