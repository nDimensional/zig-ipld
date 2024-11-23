const std = @import("std");

pub fn build(b: *std.Build) void {
    // Dependencies
    const multiformats = b.dependency("multiformats", .{});

    // const varint = multiformats.module("varint");
    const multicodec = multiformats.module("multicodec");
    // const multibase = multiformats.module("multibase");
    // const multihash = multiformats.module("multihash");
    const cid = multiformats.module("cid");

    // Modules

    const ipld = b.addModule("src", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "multicodec", .module = multicodec },
            .{ .name = "cid", .module = cid },
        },
    });

    // Tests

    const ipld_tests = b.addTest(.{ .root_source_file = b.path("src/test.zig") });
    ipld_tests.root_module.addImport("multicodec", multicodec);
    ipld_tests.root_module.addImport("cid", cid);
    ipld_tests.root_module.addImport("ipld", ipld);
    const run_ipld_tests = b.addRunArtifact(ipld_tests);
    b.step("test-ipld", "Run ipld tests").dependOn(&run_ipld_tests.step);

    const dag_cbor_tests = b.addTest(.{ .root_source_file = b.path("src/dag_cbor_test.zig") });
    dag_cbor_tests.root_module.addImport("multicodec", multicodec);
    dag_cbor_tests.root_module.addImport("cid", cid);
    dag_cbor_tests.root_module.addImport("ipld", ipld);
    const run_dag_cbor_tests = b.addRunArtifact(dag_cbor_tests);
    b.step("test-dag-cbor", "Run dag-cbor tests").dependOn(&run_dag_cbor_tests.step);

    const tests = b.step("test", "Run unit tests");
    tests.dependOn(&run_ipld_tests.step);
    tests.dependOn(&run_dag_cbor_tests.step);
}
