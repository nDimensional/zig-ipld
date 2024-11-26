const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const multiformats = b.dependency("multiformats", .{});

    const multicodec = multiformats.module("multicodec");
    const multibase = multiformats.module("multibase");
    const cid = multiformats.module("cid");

    // Modules

    const ipld = b.addModule("ipld", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "multibase", .module = multibase },
            .{ .name = "cid", .module = cid },
        },
    });

    const dag_cbor = b.addModule("dag-cbor", .{
        .root_source_file = b.path("src/dag_cbor.zig"),
        .imports = &.{
            .{ .name = "cid", .module = cid },
            .{ .name = "ipld", .module = ipld },
        },
    });

    const dag_json = b.addModule("dag-json", .{
        .root_source_file = b.path("src/dag_json.zig"),
        .imports = &.{
            .{ .name = "multibase", .module = multibase },
            .{ .name = "cid", .module = cid },
            .{ .name = "ipld", .module = ipld },
        },
    });

    // Tests

    const ipld_tests = b.addTest(.{ .root_source_file = b.path("src/test.zig") });
    ipld_tests.root_module.addImport("cid", cid);
    ipld_tests.root_module.addImport("multicodec", multicodec);
    ipld_tests.root_module.addImport("ipld", ipld);
    ipld_tests.root_module.addImport("dag-json", dag_json);
    ipld_tests.root_module.addImport("dag-cbor", dag_cbor);
    const run_ipld_tests = b.addRunArtifact(ipld_tests);
    b.step("test-ipld", "Run ipld tests").dependOn(&run_ipld_tests.step);

    const dag_cbor_tests = b.addTest(.{ .root_source_file = b.path("src/dag_cbor_test.zig") });
    dag_cbor_tests.root_module.addImport("ipld", ipld);
    dag_cbor_tests.root_module.addImport("dag-cbor", dag_cbor);
    const run_dag_cbor_tests = b.addRunArtifact(dag_cbor_tests);
    b.step("test-dag-cbor", "Run dag-cbor tests").dependOn(&run_dag_cbor_tests.step);

    const dag_json_tests = b.addTest(.{ .root_source_file = b.path("src/dag_json_test.zig") });
    dag_json_tests.root_module.addImport("ipld", ipld);
    dag_json_tests.root_module.addImport("dag-json", dag_json);
    const run_dag_json_tests = b.addRunArtifact(dag_json_tests);
    b.step("test-dag-json", "Run dag-json tests").dependOn(&run_dag_json_tests.step);

    const tests = b.step("test", "Run unit tests");
    tests.dependOn(&run_ipld_tests.step);
    tests.dependOn(&run_dag_cbor_tests.step);
    tests.dependOn(&run_dag_json_tests.step);

    // Example
    const example = b.addExecutable(.{
        .name = "zig-ipld-example",
        .root_source_file = b.path("example.zig"),
        .target = target,
        .optimize = optimize,
    });

    example.root_module.addImport("ipld", ipld);
    example.root_module.addImport("dag-json", dag_json);
    example.root_module.addImport("dag-cbor", dag_cbor);
    const run_example = b.addRunArtifact(example);
    b.step("run-example", "Run example.zig").dependOn(&run_example.step);
}
