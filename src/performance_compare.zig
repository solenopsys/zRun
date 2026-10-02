const std = @import("std");
const bytecode = @import("bytecode.zig");
const VM = @import("vm.zig").VM;
const Value = @import("value.zig").Value;
const ObjectStore = @import("vm/objects.zig").Store;
const Opcode = @import("opcode.zig").Opcode;
const array_plugin = @import("plugins/array.zig");
const array_methods = @import("plugins/array_methods.zig");
const builtin_plugin = @import("plugins/builtins.zig");
const collections = @import("plugins/collections.zig");
const regexp = @import("plugins/regexp.zig");
const string_methods = @import("plugins/string_methods.zig");

const CContext = opaque {};
const JSValue = u64;
const context_bytes = 1024 * 1024;
const warmup_count = 2;
const sample_count = 7;
const run_count = warmup_count + sample_count;

const benchmark_native_functions = [_]VM.NativeFunction{
    discardNative,
    array_plugin.push,
    builtin_plugin.arrayIsArray,
    builtin_plugin.objectAssign,
    builtin_plugin.objectEntries,
    builtin_plugin.objectFromEntries,
    builtin_plugin.objectKeys,
    builtin_plugin.objectValues,
    builtin_plugin.jsonParse,
    builtin_plugin.jsonStringify,
    builtin_plugin.mathImul,
    array_methods.map,
    array_methods.filter,
    array_methods.find,
    array_methods.flatMap,
    array_methods.includes,
    array_methods.join,
    array_methods.reduce,
    array_methods.slice,
    array_methods.some,
    array_methods.sort,
    string_methods.charCodeAt,
    string_methods.localeCompare,
    string_methods.padStart,
    string_methods.replace,
    string_methods.replaceAll,
    string_methods.toLowerCase,
    string_methods.toUpperCase,
    string_methods.trim,
    string_methods.toString,
    collections.mapSet,
    collections.mapGet,
    collections.mapHas,
    collections.mapKeys,
    collections.setAdd,
    collections.setHas,
    collections.setValues,
    collections.iteratorNext,
    regexp.regexTest,
    builtin_plugin.mathRandom,
    array_methods.concat,
    array_methods.indexOf,
    array_methods.shift,
    string_methods.concat,
    string_methods.indexOf,
    string_methods.startsWith,
    builtin_plugin.objectCreate,
    builtin_plugin.objectDefineProperty,
    builtin_plugin.objectGetOwnPropertyDescriptor,
    builtin_plugin.objectConstructor,
};

const benchmark_native_methods = [_]VM.NativeMethod{
    .{ .name = "push", .receiver = .array, .native_index = 1 },
    .{ .name = "map", .receiver = .array, .native_index = 11 },
    .{ .name = "filter", .receiver = .array, .native_index = 12 },
    .{ .name = "find", .receiver = .array, .native_index = 13 },
    .{ .name = "flatMap", .receiver = .array, .native_index = 14 },
    .{ .name = "includes", .receiver = .array, .native_index = 15 },
    .{ .name = "join", .receiver = .array, .native_index = 16 },
    .{ .name = "reduce", .receiver = .array, .native_index = 17 },
    .{ .name = "slice", .receiver = .array, .native_index = 18 },
    .{ .name = "some", .receiver = .array, .native_index = 19 },
    .{ .name = "sort", .receiver = .array, .native_index = 20 },
    .{ .name = "concat", .receiver = .array, .native_index = 40 },
    .{ .name = "indexOf", .receiver = .array, .native_index = 41 },
    .{ .name = "shift", .receiver = .array, .native_index = 42 },
    .{ .name = "concat", .receiver = .string, .native_index = 43 },
    .{ .name = "indexOf", .receiver = .string, .native_index = 44 },
    .{ .name = "startsWith", .receiver = .string, .native_index = 45 },
};

const benchmark_profiled_native_functions = blk: {
    var functions = benchmark_native_functions;
    functions[11] = array_methods.mapProfiled;
    functions[12] = array_methods.filterProfiled;
    functions[13] = array_methods.findProfiled;
    functions[14] = array_methods.flatMapProfiled;
    functions[17] = array_methods.reduceProfiled;
    functions[19] = array_methods.someProfiled;
    break :blk functions;
};

extern "c" fn zmqjs_bench_stdlib() *const anyopaque;
extern "c" fn zmqjs_bench_suppress_output(ctx: *CContext) void;
extern "c" fn zmqjs_bench_is_exception(value: JSValue) c_int;
extern "c" fn zmqjs_bench_redirect_stdout() c_int;
extern "c" fn JS_NewContext(memory: *anyopaque, size: usize, stdlib: *const anyopaque) ?*CContext;
extern "c" fn JS_FreeContext(ctx: *CContext) void;
extern "c" fn JS_RelocateBytecode(ctx: *CContext, buffer: [*]u8, len: u32) c_int;
extern "c" fn JS_LoadBytecode(ctx: *CContext, buffer: [*]const u8) JSValue;
extern "c" fn JS_Run(ctx: *CContext, value: JSValue) JSValue;
extern "c" var zmqjs_mqjs_opcode_counts: [256]u64;

const PreparedC = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    memory: []u64,
    context: *CContext,
    entry: JSValue,

    fn init(allocator: std.mem.Allocator, original_image: []const u8) !PreparedC {
        const image = try allocator.dupe(u8, original_image);
        errdefer allocator.free(image);
        const memory = try allocator.alloc(u64, context_bytes / @sizeOf(u64));
        errdefer allocator.free(memory);
        @memset(memory, 0);
        const context = JS_NewContext(@ptrCast(memory.ptr), context_bytes, zmqjs_bench_stdlib()) orelse return error.ContextCreationFailed;
        errdefer JS_FreeContext(context);
        zmqjs_bench_suppress_output(context);
        if (image.len > std.math.maxInt(u32)) return error.ImageTooLarge;
        if (JS_RelocateBytecode(context, image.ptr, @intCast(image.len)) != 0) return error.RelocationFailed;
        const entry = JS_LoadBytecode(context, image.ptr);
        if (zmqjs_bench_is_exception(entry) != 0) return error.BytecodeLoadFailed;
        return .{ .allocator = allocator, .image = image, .memory = memory, .context = context, .entry = entry };
    }

    fn deinit(self: *PreparedC) void {
        JS_FreeContext(self.context);
        self.allocator.free(self.memory);
        self.allocator.free(self.image);
    }

    fn run(self: *PreparedC) !void {
        if (zmqjs_bench_is_exception(JS_Run(self.context, self.entry)) != 0) return error.UpstreamExecutionFailed;
    }
};

const PreparedZig = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    loaded: bytecode.Image.LoadedFunction,
    objects: ObjectStore,
    globals: []VM.GlobalBinding,
    native_functions: [benchmark_native_functions.len]VM.NativeFunction = benchmark_native_functions,

    fn init(allocator: std.mem.Allocator, original_image: []const u8) !PreparedZig {
        const owned_image = try allocator.dupe(u8, original_image);
        errdefer allocator.free(owned_image);
        var image = try bytecode.Image.initForRelocation(owned_image);
        try image.relocate();
        var loaded = try image.loadMain(allocator);
        errdefer loaded.deinit();
        var objects = ObjectStore.init(allocator);
        errdefer objects.deinit();
        objects.static_strings = loaded.bytecode.string_values;
        const globals = try allocator.alloc(VM.GlobalBinding, loaded.external_variables.len);
        errdefer allocator.free(globals);
        for (loaded.external_variables, 0..) |external, index| {
            const initial = if (external.declared) Value.undefined_value else Value.uninitialized_value;
            globals[index] = .{ .name = external.name, .cell = try objects.createCell(initial) };
            if (std.mem.eql(u8, external.name, "print")) {
                globals[index].cell.value = Value.shortFunction(0);
            } else if (std.mem.eql(u8, external.name, "undefined")) {
                globals[index].cell.value = Value.undefined_value;
            }
        }
        return .{
            .allocator = allocator,
            .image = owned_image,
            .loaded = loaded,
            .objects = objects,
            .globals = globals,
        };
    }

    fn deinit(self: *PreparedZig) void {
        self.loaded.deinit();
        self.objects.deinit();
        self.allocator.free(self.globals);
        self.allocator.free(self.image);
    }

    fn run(self: *PreparedZig) !void {
        const vm = VM{
            .allocator = self.allocator,
            .objects = &self.objects,
            .native_functions = &self.native_functions,
            .global_bindings = self.globals,
            .native_methods = &benchmark_native_methods,
        };
        switch (try vm.executeOutcome(self.loaded.bytecode)) {
            .value => {},
            .thrown => return error.ZigExecutionFailed,
            .suspended => |suspension| {
                suspension.continuation.deinit();
                return error.AsyncExecutionRequired;
            },
        }
    }

    fn runProfiled(self: *PreparedZig, stats: *VM.ExecutionStats) !void {
        const vm = VM{
            .allocator = self.allocator,
            .objects = &self.objects,
            .native_functions = &benchmark_profiled_native_functions,
            .global_bindings = self.globals,
            .native_methods = &benchmark_native_methods,
        };
        switch (try vm.executeOutcomeWithStats(self.loaded.bytecode, stats)) {
            .value => {},
            .thrown => return error.ZigExecutionFailed,
            .suspended => |suspension| {
                suspension.continuation.deinit();
                return error.AsyncExecutionRequired;
            },
        }
    }
};

pub fn main(init: std.process.Init) !void {
    try runTimedComparison(init);
}

pub fn runStats(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.MissingExecutableName;
    const path = args.next() orelse return error.MissingBytecodeImage;
    if (args.next() != null) return error.UnexpectedArgument;

    const allocator = init.arena.allocator();
    if (zmqjs_bench_redirect_stdout() != 0) return error.CannotRedirectStdout;
    const image = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024));
    var c_run = try PreparedC.init(allocator, image);
    defer c_run.deinit();
    var zig_run = try PreparedZig.init(allocator, image);
    defer zig_run.deinit();
    var zig_stats: VM.ExecutionStats = .{};
    try c_run.run();
    try zig_run.runProfiled(&zig_stats);

    std.debug.print("opcode histogram from one execution per VM; profiling overhead enabled\n", .{});
    std.debug.print("id  opcode                 MQuickJS        zRun\n", .{});
    for (0..256) |index| {
        if (zmqjs_mqjs_opcode_counts[index] == 0 and zig_stats.opcode_counts[index] == 0) continue;
        const opcode = std.enums.fromInt(Opcode, @as(u8, @intCast(index))) orelse continue;
        std.debug.print("{d:3} {s:22} {d:14} {d:14}\n", .{
            index,
            @tagName(opcode),
            zmqjs_mqjs_opcode_counts[index],
            zig_stats.opcode_counts[index],
        });
    }
}

fn runTimedComparison(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next() orelse return error.MissingExecutableName;
    const path = args.next() orelse return error.MissingBytecodeImage;
    if (args.next() != null) return error.UnexpectedArgument;

    const allocator = init.arena.allocator();
    if (zmqjs_bench_redirect_stdout() != 0) return error.CannotRedirectStdout;
    const image = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024));
    var c_runs: [run_count]PreparedC = undefined;
    var zig_runs: [run_count]PreparedZig = undefined;
    var prepared_c: usize = 0;
    var prepared_zig: usize = 0;
    defer for (c_runs[0..prepared_c]) |*run| run.deinit();
    defer for (zig_runs[0..prepared_zig]) |*run| run.deinit();
    for (0..run_count) |index| {
        c_runs[index] = try PreparedC.init(allocator, image);
        prepared_c += 1;
        zig_runs[index] = try PreparedZig.init(allocator, image);
        prepared_zig += 1;
    }

    for (0..warmup_count) |index| {
        try c_runs[index].run();
        try zig_runs[index].run();
    }

    var c_samples: [sample_count]u64 = undefined;
    var zig_samples: [sample_count]u64 = undefined;
    for (0..sample_count) |index| {
        const run_index = warmup_count + index;
        if (index % 2 == 0) {
            c_samples[index] = try timedRun(init.io, &c_runs[run_index]);
            zig_samples[index] = try timedRun(init.io, &zig_runs[run_index]);
        } else {
            zig_samples[index] = try timedRun(init.io, &zig_runs[run_index]);
            c_samples[index] = try timedRun(init.io, &c_runs[run_index]);
        }
    }
    sortSamples(&c_samples);
    sortSamples(&zig_samples);
    const c_median = c_samples[sample_count / 2];
    const zig_median = zig_samples[sample_count / 2];
    std.debug.print("in-process JS_Run only; C -O3 vs Zig ReleaseFast; median of {d} runs\n", .{sample_count});
    std.debug.print("MQuickJS: {d} ns\nzRun:    {d} ns\nC/Zig:    {d:.2}x\n", .{ c_median, zig_median, @as(f64, @floatFromInt(c_median)) / @as(f64, @floatFromInt(zig_median)) });
}

fn timedRun(io: std.Io, prepared: anytype) !u64 {
    const start = std.Io.Clock.awake.now(io);
    try prepared.run();
    return @intCast(start.durationTo(std.Io.Clock.awake.now(io)).nanoseconds);
}

fn discardNative(_: *VM.NativeCallContext, _: []const Value) anyerror!Value {
    return Value.undefined_value;
}

fn sortSamples(samples: *[sample_count]u64) void {
    for (1..samples.len) |index| {
        var cursor = index;
        while (cursor > 0 and samples[cursor] < samples[cursor - 1]) : (cursor -= 1) {
            std.mem.swap(u64, &samples[cursor], &samples[cursor - 1]);
        }
    }
}
