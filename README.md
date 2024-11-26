# zig-ipld

Zig implementation of the IPLD data model, with dag-cbor and dag-json codecs.

Currently only implements a "dynamic" heap-allocated `Value` type. An additional statically-typed variant for streaming directly to/from Zig types is in development.

Passes all tests in [ipld/codec-fixtures](https://github.com/ipld/codec-fixtures) except for `i64` integer overflow cases.

## Table of Contents

- [Install](#install)
- [Usage](#usage)
  - [Dynamic values](#dynamic-values)
  - [Encoding dynamic values](#encoding-dynamic-values)
  - [Static types](#static-types)

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

    // ... add as imports to exe or lib
}
```

## Usage

### Dynamic Values

```zig
const Value = @import("ipld").Value;

// Value is a union over Value.Kind: enum {
//   null, boolean, integer, float, string, bytes, list, map, link
// }

// the kinds [null, boolean, integer, float] have static values.
// the kinds [string, bytes, list, map, link] are pointers to
// allocated ref-counted

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

`dag-cbor` and `dag-json` both export interface-compatible `Encoder` and `Decoder` structs. See [example.zig](./example.zig) for usage.

### Static Types

In development.
