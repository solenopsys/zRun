const std = @import("std");
const compiler = @import("compiler.zig");
const VM = @import("vm.zig").VM;
const Value = @import("value.zig").Value;
const Stack = @import("vm/stack.zig").Stack;
const ObjectStore = @import("vm/objects.zig").Store;
const array_methods = @import("plugins/array_methods.zig");
const string_methods = @import("plugins/string_methods.zig");

const method_functions = [_]VM.NativeFunction{
    array_methods.concat,
    array_methods.indexOf,
    array_methods.shift,
    string_methods.concat,
    string_methods.indexOf,
    string_methods.startsWith,
};
const method_bindings = [_]VM.NativeMethod{
    .{ .name = "concat", .receiver = .array, .native_index = 0 },
    .{ .name = "indexOf", .receiver = .array, .native_index = 1 },
    .{ .name = "shift", .receiver = .array, .native_index = 2 },
    .{ .name = "concat", .receiver = .string, .native_index = 3 },
    .{ .name = "indexOf", .receiver = .string, .native_index = 4 },
    .{ .name = "startsWith", .receiver = .string, .native_index = 5 },
};

const sample_count = 5;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    try benchmarkStack(init.io);
    try benchmarkVmScript(init.io, allocator, "arithmetic dispatch", "var i = 0; var sum = 0; while (i < 50000) { sum = sum + 1; i = i + 1; } sum;", 50000, 1, 50000);
    try benchmarkVmScript(init.io, allocator, "function call frames", "function addOne(value) { return value + 1; } var i = 0; var sum = 0; while (i < 5000) { sum = sum + addOne(1); i = i + 1; } sum;", 5000, 1, 10000);
    try benchmarkNativeMethods(init.io, allocator);
}

fn benchmarkNativeMethods(io: std.Io, allocator: std.mem.Allocator) !void {
    const source = "var i = 0; var sum = 0; var seed = [\"--x\", \"y\"]; while (i < 5000) { var values = seed.concat([i]); sum = sum + values.indexOf(i); var queue = values.concat(); sum = sum + (queue.shift() == \"--x\" ? 1 : 0); sum = sum + (\"--x\".startsWith(\"--\") ? 1 : 0); i++; } sum;";
    const expected = 20000;
    var program = try compiler.compile(allocator, source);
    defer program.deinit(allocator);
    const bytecode = program.bytecode();

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var objects = ObjectStore.init(arena.allocator());
        defer objects.deinit();
        const vm = VM{ .allocator = arena.allocator(), .objects = &objects, .native_functions = &method_functions, .native_methods = &method_bindings };
        try checkResult(try vm.execute(bytecode), expected);
    }

    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var objects = ObjectStore.init(arena.allocator());
        defer objects.deinit();
        const vm = VM{ .allocator = arena.allocator(), .objects = &objects, .native_functions = &method_functions, .native_methods = &method_bindings };
        const start = std.Io.Clock.awake.now(io);
        try checkResult(try vm.execute(bytecode), expected);
        sample.* = elapsedNs(start, std.Io.Clock.awake.now(io));
    }
    sortSamples(&samples);
    std.debug.print("array/string native methods: 20,000 method calls, median {d} ns/run\n", .{samples[sample_count / 2]});
}

fn benchmarkStack(io: std.Io) !void {
    const batches = 50000;
    var storage: [256]Value = undefined;
    var samples: [sample_count]u64 = undefined;
    var checksum: i64 = 0;

    for (&samples) |*sample| {
        var stack = Stack.init(&storage);
        const start = std.Io.Clock.awake.now(io);
        for (0..batches) |batch| {
            for (0..storage.len) |index| {
                const value = Value.fromInt(@intCast((batch + index) & 0x3fff)).?;
                try stack.push(value);
            }
            std.mem.doNotOptimizeAway(&storage);
            while (stack.len > 0) checksum += (try stack.pop()).asInt().?;
        }
        sample.* = elapsedNs(start, std.Io.Clock.awake.now(io));
    }
    sortSamples(&samples);
    const pairs = batches * storage.len;
    const ns_hundredths = samples[sample_count / 2] * 100 / pairs;
    std.debug.print("stack push/pop: {d} pairs, median {d} us total, {d}.{d} ns/pair, checksum {d}\n", .{
        pairs,
        samples[sample_count / 2] / 1000,
        ns_hundredths / 100,
        ns_hundredths % 100,
        checksum,
    });
}

fn benchmarkVmScript(io: std.Io, allocator: std.mem.Allocator, label: []const u8, source: []const u8, units_per_run: usize, repetitions: usize, expected: i32) !void {
    var program = try compiler.compile(allocator, source);
    defer program.deinit(allocator);

    const bytecode = program.bytecode();
    {
        var warm_arena = std.heap.ArenaAllocator.init(allocator);
        defer warm_arena.deinit();
        var warm_objects = ObjectStore.init(warm_arena.allocator());
        defer warm_objects.deinit();
        const warm_vm = VM{ .allocator = warm_arena.allocator(), .objects = &warm_objects };
        try checkResult(try warm_vm.execute(bytecode), expected);
    }

    var samples: [sample_count]u64 = undefined;
    for (&samples) |*sample| {
        var sample_arena = std.heap.ArenaAllocator.init(allocator);
        defer sample_arena.deinit();
        var objects = ObjectStore.init(sample_arena.allocator());
        defer objects.deinit();
        const vm = VM{ .allocator = sample_arena.allocator(), .objects = &objects };
        const start = std.Io.Clock.awake.now(io);
        for (0..repetitions) |_| try checkResult(try vm.execute(bytecode), expected);
        sample.* = elapsedNs(start, std.Io.Clock.awake.now(io));
    }
    sortSamples(&samples);
    std.debug.print("{s}: {d} units/run, median {d} ns/run\n", .{
        label,
        units_per_run,
        samples[sample_count / 2] / repetitions,
    });
}

fn checkResult(value: Value, expected: i32) error{UnexpectedBenchmarkResult}!void {
    if (value.asInt() == null or value.asInt().? != expected) return error.UnexpectedBenchmarkResult;
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
