const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, binary size, or compilation speed",
    ) orelse .ReleaseFast;

    const strip = b.option(bool, "strip", "Omit debug information (removes PDBs)") orelse true;

    const mod = b.addModule("rocket", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "rocket",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "rocket", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const engine_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/engine_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_engine_tests = b.addRunArtifact(engine_tests);

    const bitboard_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bitboard_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bitboard_tests = b.addRunArtifact(bitboard_tests);

    const time_test_exe = b.addExecutable(.{
        .name = "test_time_management",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_time_management.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    b.installArtifact(time_test_exe);

    const run_time_test = b.addRunArtifact(time_test_exe);
    const time_test_step = b.step("test-time", "Run time management tests");
    time_test_step.dependOn(&run_time_test.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_engine_tests.step);
    test_step.dependOn(&run_bitboard_tests.step);
}