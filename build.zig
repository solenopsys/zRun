const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const runtime_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const runtime = b.addExecutable(.{
        .name = "zrun",
        .root_module = runtime_module,
    });
    const runtime_install = b.addInstallArtifact(runtime, .{});
    b.getInstallStep().dependOn(&runtime_install.step);

    const compiler_exe = b.addExecutable(.{
        .name = "zrun-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const compiler_install = b.addInstallArtifact(compiler_exe, .{});
    b.getInstallStep().dependOn(&compiler_install.step);

    const runtime_exe = b.addExecutable(.{
        .name = "zrun-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const runtime_exe_install = b.addInstallArtifact(runtime_exe, .{});
    b.getInstallStep().dependOn(&runtime_exe_install.step);

    const run_command = b.addRunArtifact(runtime);
    if (b.args) |args| run_command.addArgs(args);
    b.step("run", "Compile and execute a source file on the Zig VM").dependOn(&run_command.step);

    const memory_probe = b.addExecutable(.{
        .name = "zrun-memory-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/memory_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_memory_probe = b.addRunArtifact(memory_probe);
    b.step("memory-probe", "Measure retained memory for 100 idle script contexts").dependOn(&run_memory_probe.step);

    const performance = b.addExecutable(.{
        .name = "zrun-perf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/performance.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_performance = b.addRunArtifact(performance);
    b.step("bench", "Run in-process VM microbenchmarks").dependOn(&run_performance.step);

    const make_reference_headers = b.addSystemCommand(&.{ "make", "-C", "../mquickjs", "mqjs" });
    const compare_module = b.createModule(.{
        .root_source_file = b.path("src/performance_compare.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    compare_module.addIncludePath(b.path("../mquickjs"));
    compare_module.addCSourceFile(.{
        .file = b.path("performance/reference_stdlib.c"),
        .flags = &.{ "-O3", "-D_GNU_SOURCE" },
    });
    compare_module.addCSourceFiles(.{
        .root = b.path("../mquickjs"),
        .files = &.{ "mquickjs.c", "cutils.c", "dtoa.c", "libm.c", "readline.c", "readline_tty.c" },
        .flags = &.{ "-O3", "-D_GNU_SOURCE", "-fno-math-errno", "-fno-trapping-math" },
    });
    compare_module.linkSystemLibrary("m", .{});
    const compare = b.addExecutable(.{
        .name = "zrun-compare",
        .root_module = compare_module,
    });
    compare.step.dependOn(&make_reference_headers.step);
    const run_compare = b.addRunArtifact(compare);
    if (b.args) |args| run_compare.addArgs(args);
    b.step("compare", "Compare both VMs in process on one upstream bytecode image").dependOn(&run_compare.step);

    const compare_stats_module = b.createModule(.{
        .root_source_file = b.path("src/performance_compare_stats.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    compare_stats_module.addIncludePath(b.path("../mquickjs"));
    compare_stats_module.addCSourceFile(.{
        .file = b.path("performance/reference_stdlib.c"),
        .flags = &.{ "-O3", "-D_GNU_SOURCE" },
    });
    compare_stats_module.addCSourceFiles(.{
        .root = b.path("../mquickjs"),
        .files = &.{ "mquickjs.c", "cutils.c", "dtoa.c", "libm.c", "readline.c", "readline_tty.c" },
        .flags = &.{ "-O3", "-D_GNU_SOURCE", "-DZMQJS_BENCH_STATS", "-fno-math-errno", "-fno-trapping-math" },
    });
    compare_stats_module.linkSystemLibrary("m", .{});
    const compare_stats = b.addExecutable(.{
        .name = "zrun-compare-stats",
        .root_module = compare_stats_module,
    });
    compare_stats.step.dependOn(&make_reference_headers.step);
    const run_compare_stats = b.addRunArtifact(compare_stats);
    if (b.args) |args| run_compare_stats.addArgs(args);
    b.step("compare-stats", "Collect opcode histograms from both VMs in diagnostic builds").dependOn(&run_compare_stats.step);

    const compile_bench_module = b.createModule(.{
        .root_source_file = b.path("performance/compiler_benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    compile_bench_module.addImport("compiler", b.createModule(.{
        .root_source_file = b.path("src/compiler.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    }));
    compile_bench_module.addIncludePath(b.path("../mquickjs"));
    compile_bench_module.addCSourceFile(.{
        .file = b.path("performance/reference_stdlib.c"),
        .flags = &.{ "-O3", "-D_GNU_SOURCE" },
    });
    compile_bench_module.addCSourceFiles(.{
        .root = b.path("../mquickjs"),
        .files = &.{ "mquickjs.c", "cutils.c", "dtoa.c", "libm.c", "readline.c", "readline_tty.c" },
        .flags = &.{ "-O3", "-D_GNU_SOURCE", "-fno-math-errno", "-fno-trapping-math" },
    });
    compile_bench_module.linkSystemLibrary("m", .{});
    const compile_bench = b.addExecutable(.{
        .name = "zrun-compile-bench",
        .root_module = compile_bench_module,
    });
    compile_bench.step.dependOn(&make_reference_headers.step);
    const run_compile_bench = b.addRunArtifact(compile_bench);
    b.step("compile-bench", "Compare source compilation only, without running either VM").dependOn(&run_compile_bench.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zRun unit tests");
    test_step.dependOn(&run_tests.step);
}
