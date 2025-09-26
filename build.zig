const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const multiformats = b.dependency("multiformats", .{});

    const multicodec = multiformats.module("multicodec");
    const multibase = multiformats.module("multibase");
    const cid = multiformats.module("cid");

    const multiformat_modules = multiformats.builder.modules;
    for (multiformat_modules.keys(), multiformat_modules.values()) |name, module| {
        b.modules.put(b.dupe(name), module) catch @panic("OOM");
    }

    const ipld = b.addModule("ipld", .{
        .root_source_file = b.path("src/lib.zig"),
        .imports = &.{
            .{ .name = "multibase", .module = multibase },
            .{ .name = "cid", .module = cid },
        },
    });

    // Shared utilities for dag-cbor and dag-json
    const utils = b.createModule(.{
        .root_source_file = b.path("src/utils.zig"),
        .imports = &.{
            .{ .name = "ipld", .module = ipld },
        },
    });

    const dag_cbor = b.addModule("dag-cbor", .{
        .root_source_file = b.path("src/dag_cbor.zig"),
        .imports = &.{
            .{ .name = "cid", .module = cid },
            .{ .name = "ipld", .module = ipld },
            .{ .name = "utils", .module = utils },
        },
    });

    const dag_json = b.addModule("dag-json", .{
        .root_source_file = b.path("src/dag_json.zig"),
        .imports = &.{
            .{ .name = "multibase", .module = multibase },
            .{ .name = "cid", .module = cid },
            .{ .name = "ipld", .module = ipld },
            .{ .name = "utils", .module = utils },
        },
    });

    // Tests

    const ipld_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/test.zig"),
            .imports = &.{
                .{ .name = "cid", .module = cid },
                .{ .name = "multicodec", .module = multicodec },
                .{ .name = "ipld", .module = ipld },
                .{ .name = "dag-json", .module = dag_json },
                .{ .name = "dag-cbor", .module = dag_cbor },
            },
        }),
    });

    const run_ipld_tests = b.addRunArtifact(ipld_tests);
    b.step("test-ipld", "Run ipld tests").dependOn(&run_ipld_tests.step);

    const dag_cbor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/dag_cbor_test.zig"),
            .imports = &.{
                .{ .name = "ipld", .module = ipld },
                .{ .name = "dag-cbor", .module = dag_cbor },
            },
        }),
    });

    const run_dag_cbor_tests = b.addRunArtifact(dag_cbor_tests);
    b.step("test-dag-cbor", "Run dag-cbor tests").dependOn(&run_dag_cbor_tests.step);

    const dag_json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/dag_json_test.zig"),
            .imports = &.{
                .{ .name = "ipld", .module = ipld },
                .{ .name = "dag-json", .module = dag_json },
            },
        }),
    });

    const run_dag_json_tests = b.addRunArtifact(dag_json_tests);
    b.step("test-dag-json", "Run dag-json tests").dependOn(&run_dag_json_tests.step);

    const tests = b.step("test", "Run unit tests");
    tests.dependOn(&run_ipld_tests.step);
    tests.dependOn(&run_dag_cbor_tests.step);
    tests.dependOn(&run_dag_json_tests.step);

    // Example
    const example = b.addExecutable(.{
        .name = "zig-ipld-example",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("example.zig"),
            .imports = &.{
                .{ .name = "ipld", .module = ipld },
                .{ .name = "dag-json", .module = dag_json },
                .{ .name = "dag-cbor", .module = dag_cbor },
            },
        }),
    });

    const run_example = b.addRunArtifact(example);
    b.step("run-example", "Run example.zig").dependOn(&run_example.step);
}
