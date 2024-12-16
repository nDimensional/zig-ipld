# zig-ipld

Zig implementation of the [IPLD](https://ipld.io/) data model, with dag-cbor and dag-json codecs.

Provides two parallel APIs:

- a "dynamic" heap-allocated `Value` type for manipulating arbitrary/heterogenous values
- a "static" API for generating encoders and decoders for native Zig types at comptime

Passes all tests in [ipld/codec-fixtures](https://github.com/ipld/codec-fixtures) except for `i64` integer overflow cases.

## Table of Contents

- [Install](#install)
- [Usage](#usage)
  - [Creating dynamic values](#creating-dynamic-values)
  - [Encoding dynamic values](#encoding-dynamic-values)
  - [Decoding dynamic values](#decoding-dynamic-values)
  - [Static types](#static-types)
  - [Strings and bytes](#strings-and-bytes)

## Install

Add to `build.zig.zon`:

```zig
.{
    // ...
    .dependencies = .{
        .ipld = .{
            .url = "https://github.com/nDimensional/zig-ipld/archive/${COMMIT}.tar.gz",
            // .hash = "...",
        },
    }
}
```

Then in `build.zig`:

```zig
pub fn build(b: *std.Build) !void {
    const ipld_dep = b.dependency("ipld", .{});

    const ipld = ipld_dep.module("ipld");
    const json = ipld_dep.module("dag-json");
    const cbor = ipld_dep.module("dag-cbor");

    // All of the modules from zig-multiformats are also re-exported
    // from zig-ipld, for convenience and to ensure consistent versions.
    const varint = ipld_dep.module("varint");
    const multibase = ipld_dep.module("multibase");
    const multihash = ipld_dep.module("multihash");
    const cid = ipld_dep.module("cid");

    // add as imports to your exe or lib...
}
```

## Usage

### Creating dynamic Values

```zig
const ipld = @import("ipld");
const Kind = ipld.Kind;
const Value = ipld.Value;

// ipld.Value is a union over ipld.Kind: enum {
//   null, boolean, integer, float, string, bytes, list, map, link
// }

// the kinds [null, boolean, integer, float] have static values.
// the kinds [string, bytes, list, map, link] are pointers to
// allocated ref-counted objects

const false_val = Value.False;
const true_val = Value.True;
const null_val = Value.Null;
const float_val = Value.float(15.901241);

// integer values are all i64.
// integer values outside this range are not supported.
const int_val = Value.integer(-8391042);

pub fn main() !void {
    // this copies the contents of the argument,
    // the object string_val owns its own data.
    const string_val = try Value.createString(allocator, "hello world");
    defer string_val.unref(); // unref() decrements the refcount

    const list_val = try Value.createList(allocator, .{});

    // appending an existing value here will increment string_val's refcount,
    // keeping it alive for as long as list_val lives.
    try list_val.list.append(string_val);

    // for convenience, you can also pass a tuple of "initial values" to createList.
    // this *will not* increment the refcount of the initial values, which is
    // useful for initializing deeply nested objects in a single expression.
    const list_val2 = try Value.createList(allocator, .{
        try Value.createList(allocator, .{
            try Value.createList(allocator, .{
                try Value.createList(allocator, .{}),
            }),
        }),
    });
    defer list_val2.unref();
    // this created [[[[]]]], which will all be freed
    // when `defer list_val2.unref()` is invoked

    // maps are similar, with an initial struct argument that
    // doesn't increment initial value's refcounts
    const map_val = try Value.createMap(allocator, .{
        .foo = try Value.createString(allocator, "initial value 1"),
        .bar = try Value.createString(allocator, "initial value 2"),
    });
    defer map_val.unref();

    // this increments string_val's refcount.
    // map keys are copied with the map's allocator and managed by the map.
    try map_val.map.set("baz", string_val);
}
```

### Encoding dynamic values

`dag-cbor` and `dag-json` both export `Encoder` structs with identical APIs. Here's an example with a dag-json encoder:

```zig
const std = @import("std");
const ipld = @import("ipld");
const Value = ipld.Value;

test "encode a dynamic value" {
    const allocator = std.heap.c_allocator;
    const example_value = try Value.createList(allocator, .{
        try Value.createList(allocator, .{}),
        try Value.createList(allocator, .{
            Value.Null,
            Value.integer(42),
            Value.True,
        }),
    });

    var encoder = json.Encoder.init(allocator, .{});
    defer encoder.deinit();

    const bytes = try encoder.encodeValue(allocator, example_value);
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "[[],[null,42,true]]", json_bytes);
}
```

The encoders must be initialized with an allocator, which is used for internal encoder state. Each `encodeValue` call takes its own allocator that it **only** uses for allocating the resulting `[]const u8` slice.

### Decoding dynamic values

`dag-cbor` and `dag-json` both export `Decoder` structs with identical APIs.

Here's an example with a dag-json decoder:

```zig
const std = @import("std");
const ipld = @import("ipld");
const Value = ipld.Value;

test "decode a dynamic value" {
    const allocator = std.heap.c_allocator;

    var decoder = json.Decoder.init(allocator, .{});
    defer decoder.deinit();

    const value = try decoder.decodeValue(allocator, "[[],[null,42,true]]");
    defer value.unref();

    const expected_value = try Value.createList(allocator, .{
        try Value.createList(allocator, .{}),
        try Value.createList(allocator, .{
            Value.Null,
            Value.integer(42),
            Value.True,
        }),
    });
    defer expected_value.unref();

    try value.exepctEqual(expected_value);
```

The decoders must be initialized with an allocator, which is used for internal encoder state. Each `decodeValue` call takes its own allocator that it uses for creating the actual Value elements, which does not have to be the same allocator used internally by the encoder.

### Static Types

Instead of allocating dynamic `Value` values, you can also decode directly into Zig types using the `decodeType` / `readType` decoder methods, and encode Zig types directly with `encodeType` / `writeType` decoder methods.

The patterns for Zig type mapping are as follows:

0. `ipld.Value` types use the dynamic API; this is like an "any" type.
1. booleans are IPLD Booleans
2. integer types are IPLD Integers, and error when decoding an integer out of range
3. float types are IPLD Floats
4. slices, arrays, and tuple `struct` types are IPLD lists
5. non-tuple `struct` types are IPLD Maps
6. optional types are `null` for IPLD Null, and match the unwrapped child type otherwise
7. for pointer types:
   - encoding dereferences the pointer and encodes the child type
   - decoding allocates an element with `allocator.create` and decodes the child type into it

A simple encoding example looks like this

```zig
const ipld = @import("ipld");
const json = @import("dag-json");

const Foo = struct { abc: u32, xyz: bool };

test "encode a static type" {
    var encoder = json.Encoder.init(allocator, .{});
    defer encoder.deinit();

    const data = try encoder.encodeType(Foo, allocator, .{
        .bar = 8,
        .baz = false,
    });
    defer allocator.free(data);

    try std.testing.expectEqualSlices(u8, "{\"abc\":8,\"xyz\":false}", data);
}
```

For decoding, `decodeType` returns a generic `Result(T)` struct that includes both the decoded `value: T` and a new `arena: ArenaAllocator` used for allocations within the value. This is unfortunately necessary since the decoder may encounter an error in the middle of decoding, and needs to be able to free the allocations in the partially-decoded value before returning the error to the user.

```zig
const ipld = @import("ipld");
const json = @import("dag-json");

const Foo = struct { abc: u32, xyz: *const Bar };
const Bar = struct { id: u32, children: []const u32 };

test "decode nested static types" {
    var decoder = json.Decoder.init(allocator, .{});
    defer decoder.deinit();

    const result = try encoder.decodeType(Foo, allocator,
        \\{"abc":8,"xyz":{"id":9,"children":[1,2,10,87421]}}"
    );
    defer result.deinit(); // calls result.arena.deinit() inline
    // result: json.Decoder.Result(Foo) is a struct {
    //     arena: std.heap.ArenaAllocator,
    //     value: Foo,
    // }

    try std.testing.expectEqual(result.value.abc, 8);
    try std.testing.expectEqual(result.value.xyz.id, 9);
    try std.testing.expectEqualSlices(u32, result.value.xyz.children, &.{1, 2, 10, 87421});
}
```

### Strings and Bytes

Handling strings and bytes is a point of unavoidable awkwardness. Idiomatic Zig generally uses `[]const u8` for both of these, but this is indistinguishable from "an array of `u8`" to zig-ipld. Furthermore, it's not possible to tell whether a user intends `[]const u8` to mean "string" or "bytes", and would be inappropriate to guess.

The simplest way to use strings and bytes in static types is to use the special struct types `String` and `Bytes` exported from the `ipld` module, which have a single `data: []const u8` field. Note that these are different than the dynamic values `Value.String` and `Value.Bytes`.

```zig
const std = @import("std");
const allocator = std.heap.c_allocator;

const ipld = @import("ipld");
const json = @import("dag-json");

const User = struct {
    id: u32,
    email: ipld.String,
};

test "encode static User" {
    var encoder = json.Encoder.init(allocator, .{});
    defer encoder.deinit();

    const bytes = try encoder.encodeType(User, allocator, .{
        .id = 10,
        .email = .{ .data = "johndoe@example.com" },
    });
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, bytes,
    \\{"email":"johndoe@example.com","id":10}
    );
}

test "decode static User" {
    var decoder = json.Decoder.init(allocator, .{});
    defer decoder.deinit();

    const result = try decoder.decodeType(User, allocator,
        \\{"email":"johndoe@example.com","id":1}
    );
    defer result.deinit();

    try std.testing.expectEqual(result.value.id, 1);
    try std.testing.expectEqualSlices(u8, result.value.email.data, "johndoe@example.com");
}
```

If you want more flexibility, you can also add public function declarations to your struct/enum/union types to handle parsing to and from strings or bytes manually.

To represent a struct/enum/union as a string, add declarations

- `pub fn parseIpldString(allocator: std.mem.Allocator, data: []const u8) !@This()`
- `pub fn writeIpldString(self: @This(), writer: std.io.AnyWriter) !void`

For bytes, add

- `pub fn parseIpldBytes(allocator: std.mem.Allocator, data: []const u8) !@This()`
- `pub fn writeIpldBytes(self: @This(), writer: std.io.AnyWriter) !void`

These are what the `String` and `Bytes` structs internally. When parsing, they copy `data` using `allocator`, and when writing, they just call `writer.writeAll(self.data)`.

```zig
pub const Bytes = struct {
    data: []const u8,

    pub fn parseIpldBytes(allocator: std.mem.Allocator, data: []const u8) !Bytes {
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return .{ .data = copy };
    }

    pub fn writeIpldBytes(self: Bytes, writer: std.io.AnyWriter) !void {
        try writer.writeAll(self.data);
    }
};

pub const String = struct {
    data: []const u8,

    pub fn parseIpldString(allocator: std.mem.Allocator, data: []const u8) !String {
        const copy = try allocator.alloc(u8, data.len);
        @memcpy(copy, data);
        return .{ .data = copy };
    }

    pub fn writeIpldString(self: String, writer: std.io.AnyWriter) !void {
        try writer.writeAll(self.data);
    }
};
```

For parsing, keep in mind that `allocator` is an arena allocator attached to the top-level `Result(T)`, so try to avoid making temporary allocations since they will be tied to the lifetime of the result even if you call `allocator.free(...)` etc.
