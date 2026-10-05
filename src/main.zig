const std = @import("std");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const VM = @import("vm.zig").VM;
const Value = @import("value.zig").Value;
const array_plugin = @import("plugins/array.zig");
const builtin_plugin = @import("plugins/builtins.zig");
const array_methods = @import("plugins/array_methods.zig");
const string_methods = @import("plugins/string_methods.zig");
const collections = @import("plugins/collections.zig");
const regexp = @import("plugins/regexp.zig");
const ObjectStore = @import("vm/objects.zig").Store;
const worker_runtime = @import("worker_runtime.zig");

const PrintContext = struct {
    program: ?*compiler.Program,
    output: *std.Io.Writer,
    host_json: []const u8 = "",
};

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    const executable = args.next() orelse return error.MissingExecutableName;
    const first_arg = args.next() orelse return error.MissingScriptPath;
    if (std.mem.eql(u8, first_arg, "--workers-env")) {
        if (args.next() != null) return error.UnexpectedArgument;
        const encoded_urls = init.minimal.environ.getPosix("ZRUN_WORKERS") orelse return error.MissingWorkersEnvironment;
        var urls = try worker_runtime.parseWorkerUrls(init.arena.allocator(), encoded_urls);
        defer urls.deinit();
        try worker_runtime.spawnWorkers(init.arena.allocator(), init.io, init.environ_map, executable, urls.items);
        return;
    }
    const bytecode_mode = std.mem.eql(u8, first_arg, "--bytecode");
    const bytecode_env_mode = std.mem.eql(u8, first_arg, "--bytecode-env");
    const path = if (bytecode_mode) args.next() orelse return error.MissingScriptPath else first_arg;
    if (bytecode_env_mode and args.next() != null) return error.UnexpectedArgument;
    var host_json: []const u8 = "";
    if (args.next()) |option| {
        if (!std.mem.eql(u8, option, "--host-json")) return error.UnexpectedArgument;
        const host_path = args.next() orelse return error.MissingHostJsonPath;
        host_json = try std.Io.Dir.cwd().readFileAlloc(init.io, host_path, init.arena.allocator(), .limited(1024 * 1024));
    }
    if (args.next() != null) return error.UnexpectedArgument;

    const allocator = init.arena.allocator();
    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const output = &stdout.interface;
    if (bytecode_mode or bytecode_env_mode) {
        var stderr_buffer: [256]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
        const uncaught = if (bytecode_env_mode) blk: {
            const url = init.minimal.environ.getPosix("ZRUN_BYTECODE_URL") orelse return error.MissingBytecodeUrlEnvironment;
            const bytes = try worker_runtime.fetchBytecode(allocator, init.io, url);
            break :blk try runBytecodeBytes(allocator, bytes, output, &stderr.interface, host_json);
        } else try runBytecode(init.io, allocator, path, output, &stderr.interface, host_json);
        try output.flush();
        try stderr.interface.flush();
        if (uncaught) std.process.exit(1);
        return;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    var program = try compiler.compile(allocator, source);
    defer program.deinit(allocator);

    var print_context = PrintContext{ .program = &program, .output = output, .host_json = host_json };
    var objects = ObjectStore.init(allocator);
    defer objects.deinit();
    const global_this = try objects.createObject();
    try builtin_plugin.installObjectGlobal(&objects, global_this);
    const native_functions = [_]VM.NativeFunction{
        writePrint,
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
        hostBridge,
        string_methods.slice,
        builtin_plugin.toBoolean,
        builtin_plugin.toString,
        string_methods.split,
        builtin_plugin.toNumber,
        builtin_plugin.encodeURIComponent,
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
        builtin_plugin.objectGetPrototypeOf,
        builtin_plugin.objectGetOwnPropertyNames,
        builtin_plugin.objectHasOwnProperty,
        builtin_plugin.arrayConstructor,
        builtin_plugin.parseInt,
        builtin_plugin.mathRound,
        builtin_plugin.mathPow,
        builtin_plugin.arrayFrom,
        builtin_plugin.mathMax,
        builtin_plugin.mathMin,
    };
    const native_methods = arrayNativeMethods();
    const vm = VM{
        .allocator = allocator,
        .native_functions = &native_functions,
        .native_context = &print_context,
        .objects = &objects,
        .native_methods = &native_methods,
        .global_this = global_this,
    };
    const result = try vm.execute(program.bytecode());
    if (result.asInt()) |number| {
        try output.print("{d}\n", .{number});
    } else if (result.asFloat64()) |number| {
        try output.print("{d}\n", .{number});
    } else if (result.asBool()) |boolean| {
        try output.print("{s}\n", .{if (boolean) "true" else "false"});
    } else if (result.isNull()) {
        try output.writeAll("null\n");
    } else if (program.stringBytes(result) orelse objects.findString(result)) |bytes| {
        try output.writeAll(bytes);
        try output.writeByte('\n');
    } else if (result.isUndefined()) {
        // A print-only script has already produced its observable output.
    } else {
        return error.UnsupportedResultType;
    }
    try output.flush();
}

fn runBytecode(io: std.Io, allocator: std.mem.Allocator, path: []const u8, output: *std.Io.Writer, error_output: *std.Io.Writer, host_json: []const u8) !bool {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    return runBytecodeBytes(allocator, bytes, output, error_output, host_json);
}

fn runBytecodeBytes(allocator: std.mem.Allocator, bytes: []u8, output: *std.Io.Writer, error_output: *std.Io.Writer, host_json: []const u8) !bool {
    var image = try bytecode.Image.initForRelocation(bytes);
    try image.relocate();
    var loaded = try image.loadMain(allocator);
    defer loaded.deinit();

    var objects = ObjectStore.init(allocator);
    defer objects.deinit();
    const globals = allocator.alloc(VM.GlobalBinding, loaded.external_variables.len) catch return error.OutOfMemory;
    for (loaded.external_variables, 0..) |external, index| {
        if (external.kind != .global) return error.UnsupportedGlobalBinding;
        const name = external.name;
        const initial_value = if (external.declared) Value.undefined_value else Value.uninitialized_value;
        globals[index] = .{ .name = name, .cell = try objects.createCell(initial_value) };
        if (std.mem.eql(u8, name, "print")) {
            globals[index].cell.value = Value.shortFunction(0);
        } else if (std.mem.eql(u8, name, "undefined")) {
            globals[index].cell.value = Value.undefined_value;
        }
    }
    const native_functions = [_]VM.NativeFunction{
        writePrint,
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
        hostBridge,
        string_methods.slice,
        builtin_plugin.toBoolean,
        builtin_plugin.toString,
        string_methods.split,
        builtin_plugin.toNumber,
        builtin_plugin.encodeURIComponent,
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
        builtin_plugin.objectGetPrototypeOf,
        builtin_plugin.objectGetOwnPropertyNames,
        builtin_plugin.objectHasOwnProperty,
        builtin_plugin.arrayConstructor,
        builtin_plugin.parseInt,
        builtin_plugin.mathRound,
        builtin_plugin.mathPow,
        builtin_plugin.arrayFrom,
        builtin_plugin.mathMax,
        builtin_plugin.mathMin,
    };
    const native_methods = arrayNativeMethods();
    var print_context = PrintContext{ .program = null, .output = output, .host_json = host_json };
    const global_this = try objects.createObject();
    try builtin_plugin.installObjectGlobal(&objects, global_this);
    const vm = VM{
        .allocator = allocator,
        .objects = &objects,
        .native_functions = &native_functions,
        .native_context = &print_context,
        .global_bindings = globals,
        .native_methods = &native_methods,
        .global_this = global_this,
    };
    switch (try vm.executeOutcome(loaded.bytecode)) {
        .value => |value| {
            if (value.isUndefined()) return false;
            try writeRuntimeValue(output, value, loaded.string_values, &objects);
            return false;
        },
        .thrown => |value| {
            try error_output.writeAll("uncaught exception: ");
            try writeRuntimeValue(error_output, value, loaded.string_values, &objects);
            return true;
        },
        .suspended => |suspension| {
            suspension.continuation.deinit();
            return error.AsyncExecutionRequired;
        },
    }
}

fn arrayNativeMethods() [37]VM.NativeMethod {
    return .{
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
        .{ .name = "charCodeAt", .receiver = .string, .native_index = 21 },
        .{ .name = "localeCompare", .receiver = .string, .native_index = 22 },
        .{ .name = "padStart", .receiver = .string, .native_index = 23 },
        .{ .name = "replace", .receiver = .string, .native_index = 24 },
        .{ .name = "replaceAll", .receiver = .string, .native_index = 25 },
        .{ .name = "toLowerCase", .receiver = .string, .native_index = 26 },
        .{ .name = "toUpperCase", .receiver = .string, .native_index = 27 },
        .{ .name = "trim", .receiver = .string, .native_index = 28 },
        .{ .name = "toString", .receiver = .number, .native_index = 29 },
        .{ .name = "set", .receiver = .map, .native_index = 30 },
        .{ .name = "get", .receiver = .map, .native_index = 31 },
        .{ .name = "has", .receiver = .map, .native_index = 32 },
        .{ .name = "keys", .receiver = .map, .native_index = 33 },
        .{ .name = "add", .receiver = .set, .native_index = 34 },
        .{ .name = "has", .receiver = .set, .native_index = 35 },
        .{ .name = "values", .receiver = .set, .native_index = 36 },
        .{ .name = "next", .receiver = .iterator, .native_index = 37 },
        .{ .name = "test", .receiver = .regex, .native_index = 38 },
        .{ .name = "slice", .receiver = .string, .native_index = 40 },
        .{ .name = "split", .receiver = .string, .native_index = 43 },
        .{ .name = "concat", .receiver = .array, .native_index = 47 },
        .{ .name = "indexOf", .receiver = .array, .native_index = 48 },
        .{ .name = "shift", .receiver = .array, .native_index = 49 },
        .{ .name = "concat", .receiver = .string, .native_index = 50 },
        .{ .name = "indexOf", .receiver = .string, .native_index = 51 },
        .{ .name = "startsWith", .receiver = .string, .native_index = 52 },
    };
}

fn writeRuntimeValue(output: *std.Io.Writer, value: Value, strings: []const @import("vm.zig").StringValue, objects: *ObjectStore) !void {
    if (value.asInt()) |number| {
        try output.print("{d}", .{number});
    } else if (value.asFloat64()) |number| {
        try output.print("{d}", .{number});
    } else if (value.asBool()) |boolean| {
        try output.writeAll(if (boolean) "true" else "false");
    } else if (value.isNull()) {
        try output.writeAll("null");
    } else if (value.isUndefined()) {
        try output.writeAll("undefined");
    } else if (findStaticString(strings, value) orelse objects.findString(value)) |bytes| {
        try output.writeAll(bytes);
    } else {
        return error.UnsupportedResultType;
    }
    try output.writeByte('\n');
}

fn findStaticString(strings: []const @import("vm.zig").StringValue, value: Value) ?[]const u8 {
    for (strings) |string| {
        if (string.value.raw() == value.raw()) return string.bytes;
    }
    return null;
}

fn writePrint(native_context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const context: *PrintContext = @ptrCast(@alignCast(native_context.host_context.?));
    for (arguments, 0..) |argument, index| {
        if (index != 0) try context.output.writeByte(' ');
        if ((if (context.program) |program| program.stringBytes(argument) else null) orelse native_context.objects.findString(argument)) |bytes| {
            try context.output.writeAll(bytes);
        } else if (argument.asInt()) |number| {
            try context.output.print("{d}", .{number});
		} else if (argument.asFloat64()) |number| {
			try context.output.print("{d}", .{number});
		} else if (native_context.objects.findBigInt(argument)) |bigint| {
			const text = try bigint.value.toString(native_context.objects.allocator, 10, .lower);
			defer native_context.objects.allocator.free(text);
			try context.output.writeAll(text);
		} else if (argument.asBool()) |boolean| {
            try context.output.writeAll(if (boolean) "true" else "false");
        } else if (argument.isNull()) {
            try context.output.writeAll("null");
        } else if (argument.isUndefined()) {
            try context.output.writeAll("undefined");
        } else {
            return error.UnsupportedPrintValue;
        }
    }
    try context.output.writeByte('\n');
    return Value.undefined_value;
}

fn hostBridge(native_context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const context: *PrintContext = @ptrCast(@alignCast(native_context.host_context.?));
    if (arguments.len == 0) return Value.undefined_value;
    const name = native_context.objects.findString(arguments[0]) orelse return Value.undefined_value;
    if (name.len == 0) return native_context.objects.createString(context.host_json);

    const request = try std.json.parseFromSliceLeaky(std.json.Value, native_context.objects.allocator, name, .{ .allocate = .alloc_always });
    const request_object = switch (request) {
        .object => |object| object,
        else => return error.InvalidHostRequest,
    };
    const operation = request_object.get("op") orelse return error.MissingHostOperation;
    const operation_name = switch (operation) {
        .string => |value| value,
        else => return error.UnsupportedHostOperation,
    };
    if (!std.mem.eql(u8, operation_name, "sha256")) return error.UnsupportedHostOperation;
    const data_value = request_object.get("data") orelse return error.MissingHostData;
    const data = switch (data_value) {
        .string => |value| value,
        else => return error.InvalidHostData,
    };

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return native_context.objects.createString(&hex);
}
