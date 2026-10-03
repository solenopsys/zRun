const std = @import("std");
const compiler = @import("compiler");

const CContext = opaque {};
const JSValue = u64;
const context_bytes = 1024 * 1024;
const warmup_count = 3;
const sample_count = 15;

const Case = struct { name: []const u8, source: []const u8 };
const cases = [_]Case{
    .{ .name = "arithmetic", .source = @embedFile("workloads/cli/arithmetic.js") },
    .{ .name = "calls", .source = @embedFile("workloads/cli/calls.js") },
    .{ .name = "arrays", .source = @embedFile("workloads/cli/arrays.js") },
    .{ .name = "ssr", .source = @embedFile("workloads/cli/ssr.js") },
};

extern "c" fn zmqjs_bench_new_compile_context(memory: *anyopaque, size: usize) ?*CContext;
extern "c" fn zmqjs_bench_parse(ctx: *CContext, source: [*:0]const u8, length: usize) JSValue;
extern "c" fn zmqjs_bench_is_exception(value: JSValue) c_int;
extern "c" fn JS_FreeContext(ctx: *CContext) void;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("Compile-only source benchmark; MQuickJS C -O3 JS_Parse vs zRun Zig ReleaseFast compiler.compile. Setup, file I/O, teardown, and execution excluded; median of {d} samples.\n", .{sample_count});
    std.debug.print("A ratio below 1.00x means zRun compiled faster. Inputs are identical; compiler outputs/optimization pipelines differ.\n\n", .{});
    std.debug.print("| Workload | MQuickJS us | zRun us | MQuickJS/zRun |\n|---|---:|---:|---:|\n", .{});
    for (cases) |test_case| {
        const source_z = try allocator.dupeSentinel(u8, test_case.source, 0);
        defer allocator.free(source_z);
        for (0..warmup_count) |_| {
            _ = try compileMquick(allocator, source_z, test_case.source.len, init.io);
            _ = try compileZig(allocator, test_case.source, init.io);
        }

        var c_samples: [sample_count]u64 = undefined;
        var zig_samples: [sample_count]u64 = undefined;
        for (0..sample_count) |index| {
            if (index % 2 == 0) {
                c_samples[index] = try compileMquick(allocator, source_z, test_case.source.len, init.io);
                zig_samples[index] = try compileZig(allocator, test_case.source, init.io);
            } else {
                zig_samples[index] = try compileZig(allocator, test_case.source, init.io);
                c_samples[index] = try compileMquick(allocator, source_z, test_case.source.len, init.io);
            }
        }
        sortSamples(&c_samples);
        sortSamples(&zig_samples);
        const c_median = c_samples[sample_count / 2];
        const zig_median = zig_samples[sample_count / 2];
        const ratio = @as(f64, @floatFromInt(c_median)) / @as(f64, @floatFromInt(zig_median));
        std.debug.print("| {s} | {d:.2} | {d:.2} | {d:.2}x |\n", .{
            test_case.name,
            @as(f64, @floatFromInt(c_median)) / 1000.0,
            @as(f64, @floatFromInt(zig_median)) / 1000.0,
            ratio,
        });
    }
}

fn compileMquick(allocator: std.mem.Allocator, source: [:0]const u8, length: usize, io: std.Io) !u64 {
    const memory = try allocator.alloc(u64, context_bytes / @sizeOf(u64));
    defer allocator.free(memory);
    @memset(memory, 0);
    const ctx = zmqjs_bench_new_compile_context(@ptrCast(memory.ptr), context_bytes) orelse return error.ContextCreationFailed;
    defer JS_FreeContext(ctx);
    const start = std.Io.Clock.awake.now(io);
    const result = zmqjs_bench_parse(ctx, source, length);
    const elapsed = elapsedNs(start, std.Io.Clock.awake.now(io));
    if (zmqjs_bench_is_exception(result) != 0) return error.MquickCompileFailed;
    return elapsed;
}

fn compileZig(allocator: std.mem.Allocator, source: []const u8, io: std.Io) !u64 {
    const memory = try allocator.alloc(u8, context_bytes);
    defer allocator.free(memory);
    var pool = std.heap.FixedBufferAllocator.init(memory);
    const start = std.Io.Clock.awake.now(io);
    var program = try compiler.compile(pool.allocator(), source);
    const elapsed = elapsedNs(start, std.Io.Clock.awake.now(io));
    std.mem.doNotOptimizeAway(program.code.ptr);
    program.deinit(pool.allocator());
    return elapsed;
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(end).nanoseconds);
}

fn sortSamples(samples: *[sample_count]u64) void {
    for (1..sample_count) |index| {
        var cursor = index;
        while (cursor > 0 and samples[cursor] < samples[cursor - 1]) : (cursor -= 1) {
            std.mem.swap(u64, &samples[cursor], &samples[cursor - 1]);
        }
    }
}
