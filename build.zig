const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Oracle Instant Client paths (from environment)
    const oracle_home = std.posix.getenv("ORACLE_HOME") orelse
        "/opt/oracle/instantclient_21_12";
    const odpic_path = std.posix.getenv("ODPIC_PATH") orelse
        "deps/odpi";

    const exe = b.addExecutable(.{
        .name = "process-sentinel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link ODPI-C (static)
    exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{odpic_path}) });
    exe.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{odpic_path}) });

    // Compile ODPI-C source files
    const odpi_sources = [_][]const u8{
        "dpiConn.c",
        "dpiContext.c",
        "dpiData.c",
        "dpiDeqOptions.c",
        "dpiEnqOptions.c",
        "dpiEnv.c",
        "dpiError.c",
        "dpiGen.c",
        "dpiGlobal.c",
        "dpiLob.c",
        "dpiMsgProps.c",
        "dpiObjectAttr.c",
        "dpiObjectType.c",
        "dpiObject.c",
        "dpiOracleType.c",
        "dpiPool.c",
        "dpiQueue.c",
        "dpiRowid.c",
        "dpiSodaColl.c",
        "dpiSodaDb.c",
        "dpiSodaDoc.c",
        "dpiSodaDocCursor.c",
        "dpiStmt.c",
        "dpiSubscr.c",
        "dpiUtils.c",
        "dpiVar.c",
        "dpiJson.c",
        "dpiVector.c",
    };

    for (odpi_sources) |src| {
        exe.addCSourceFile(.{
            .file = b.path(b.fmt("{s}/src/{s}", .{ odpic_path, src })),
            .flags = &.{ "-std=c11", "-O3", "-fPIC" },
        });
    }

    // Link Oracle Instant Client libraries
    exe.addLibraryPath(.{ .cwd_relative = oracle_home });
    exe.linkSystemLibrary("clntsh");
    exe.linkLibC();

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Process Sentinel");
    run_step.dependOn(&run_cmd.step);

    // Test configuration
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add ODPI-C for tests too
    unit_tests.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{odpic_path}) });
    unit_tests.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{odpic_path}) });
    unit_tests.addLibraryPath(.{ .cwd_relative = oracle_home });
    unit_tests.linkSystemLibrary("clntsh");
    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Check step (faster feedback - syntax only)
    const check = b.addExecutable(.{
        .name = "process-sentinel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    check.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{odpic_path}) });
    check.addIncludePath(.{ .cwd_relative = b.fmt("{s}/src", .{odpic_path}) });

    const check_step = b.step("check", "Check if code compiles");
    check_step.dependOn(&check.step);
}
