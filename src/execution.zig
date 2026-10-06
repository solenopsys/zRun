const std = @import("std");
const VM = @import("vm.zig").VM;
const FunctionBytecode = @import("vm.zig").FunctionBytecode;
const StringValue = @import("vm.zig").StringValue;
const Value = @import("value.zig").Value;
const ObjectStore = @import("vm/objects.zig").Store;
const array_plugin = @import("plugins/array.zig");
const builtin_plugin = @import("plugins/builtins.zig");
const array_methods = @import("plugins/array_methods.zig");
const string_methods = @import("plugins/string_methods.zig");
const collections = @import("plugins/collections.zig");
const regexp = @import("plugins/regexp.zig");

const max_request_arena_capacity = 512 * 1024;

const RuntimeContext = struct {
    strings: []const StringValue,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
    host_json: []const u8,
    plugin_context: ?*anyopaque = null,
    plugin_call: ?HostPluginCall = null,
    plugin_start: ?HostPluginStart = null,
    plugin_wait: ?HostPluginWait = null,
    pending_allocator: std.mem.Allocator,
    pending_task_ids: std.ArrayList(u64) = .empty,
};

const native_function_list = [_]VM.NativeFunction{
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
    externalPromiseAll,
};

pub const HostPluginCall = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror![]const u8;
pub const HostPluginStartResult = union(enum) { completed: []const u8, pending: u64 };
pub const HostPluginStart = *const fn (?*anyopaque, std.mem.Allocator, []const u8) anyerror!HostPluginStartResult;
pub const HostPluginWait = *const fn (?*anyopaque, std.mem.Allocator, u64, u64) anyerror!?[]const u8;

pub const ExecuteOptions = struct {
    host_json: []const u8 = "",
    plugin_context: ?*anyopaque = null,
    plugin_call: ?HostPluginCall = null,
    plugin_start: ?HostPluginStart = null,
    plugin_wait: ?HostPluginWait = null,
    await_timeout_ms: u64 = 30_000,
};

pub fn executeNamedWithOptions(
    allocator: std.mem.Allocator,
    module: *const @import("artifact.zig").LoadedModule,
    name: []const u8,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
    options: ExecuteOptions,
) !bool {
    const function = module.findFunction(name) orelse return error.UnknownFunction;
    return executeWithOptions(allocator, function.*, output, error_output, options);
}

/// Executes a named function from a resident module without reading or
/// decoding its bytecode again. The module must remain loaded for this call.
pub fn executeModuleFunctionWithOptions(
	allocator: std.mem.Allocator,
	modules: *@import("module_registry.zig").ModuleRegistry,
	module_name: []const u8,
	function_name: []const u8,
	output: *std.Io.Writer,
	error_output: *std.Io.Writer,
	options: ExecuteOptions,
) !bool {
	const function = try modules.findFunction(module_name, function_name);
	return executeWithOptions(allocator, function.*, output, error_output, options);
}

pub fn execute(
    allocator: std.mem.Allocator,
    function: FunctionBytecode,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
    host_json: []const u8,
) !bool {
    return executeWithOptions(allocator, function, output, error_output, .{ .host_json = host_json });
}

pub fn executeWithOptions(
    allocator: std.mem.Allocator,
    function: FunctionBytecode,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
    options: ExecuteOptions,
) !bool {
    var objects = ObjectStore.init(allocator);
    defer objects.deinit();
    var context = RuntimeContext{
        .strings = function.string_values,
        .output = output,
        .error_output = error_output,
        .host_json = options.host_json,
        .plugin_context = options.plugin_context,
        .plugin_call = options.plugin_call,
        .plugin_start = options.plugin_start,
        .plugin_wait = options.plugin_wait,
        .pending_allocator = allocator,
    };
    defer context.pending_task_ids.deinit(allocator);
    const global_this = try objects.createObject();
    try builtin_plugin.installObjectGlobal(&objects, global_this);
    const native_methods = arrayNativeMethods();
    const vm = VM{
        .allocator = allocator,
        .objects = &objects,
        .native_functions = &native_function_list,
        .native_context = &context,
        .native_methods = &native_methods,
        .global_this = global_this,
    };
    switch (try vm.executeOutcome(function)) {
        .value => |value| {
            if (value.isUndefined()) return false;
            try writeRuntimeValue(output, value, function.string_values, &objects);
            return false;
        },
        .thrown => |value| {
            try error_output.writeAll("uncaught exception: ");
            try writeRuntimeValue(error_output, value, function.string_values, &objects);
            return true;
        },
        .suspended => |suspension| {
            suspension.continuation.deinit();
            return error.AsyncExecutionRequired;
        },
    }
}

pub const AsyncSession = struct {
    allocator: std.mem.Allocator,
    function: FunctionBytecode,
    request_arena: std.heap.ArenaAllocator,
    objects: ObjectStore,
    context: RuntimeContext,
    output: std.Io.Writer.Allocating,
    error_output: std.Io.Writer.Allocating,
    host_json: std.ArrayList(u8) = .empty,
    native_methods: @TypeOf(arrayNativeMethods()),
    vm: VM,
    pending: ?*VM.Continuation = null,
    arguments: []Value = &.{},
    await_timeout_ms: u64,
    timed_out: bool = false,
    started: bool = false,

    pub fn create(allocator: std.mem.Allocator, function: FunctionBytecode, options: ExecuteOptions) !*AsyncSession {
        const self = try allocator.create(AsyncSession);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .function = function,
            .request_arena = std.heap.ArenaAllocator.init(allocator),
            .objects = ObjectStore.init(allocator),
            .context = undefined,
            .output = .init(allocator),
            .error_output = .init(allocator),
            .host_json = .empty,
            .native_methods = arrayNativeMethods(),
            .vm = undefined,
            .await_timeout_ms = options.await_timeout_ms,
        };
        self.objects = ObjectStore.init(self.request_arena.allocator());
        errdefer {
            self.output.deinit();
            self.error_output.deinit();
            self.host_json.deinit(allocator);
            self.objects.deinit();
            self.request_arena.deinit();
        }
        try self.host_json.appendSlice(allocator, options.host_json);
        self.context = .{
            .strings = function.string_values,
            .output = &self.output.writer,
            .error_output = &self.error_output.writer,
            .host_json = self.host_json.items,
            .plugin_context = options.plugin_context,
            .plugin_call = options.plugin_call,
            .plugin_start = options.plugin_start,
            .plugin_wait = options.plugin_wait,
            .pending_allocator = allocator,
        };
        const global_this = try self.objects.createObject();
        try builtin_plugin.installObjectGlobal(&self.objects, global_this);
        self.vm = .{
            .allocator = self.request_arena.allocator(),
            .objects = &self.objects,
            .native_functions = &native_function_list,
            .native_context = &self.context,
            .native_methods = &self.native_methods,
            .global_this = global_this,
        };
        return self;
    }

    pub fn start(self: *AsyncSession) !VM.Outcome {
        if (self.started) return error.ExecutionAlreadyStarted;
        self.started = true;
        const arguments = if (self.arguments.len == 0) self.function.arguments else self.arguments;
        const outcome = try self.vm.executeAsyncWithArguments(self.function, arguments);
        self.track(outcome);
        return outcome;
    }

    pub fn setArguments(self: *AsyncSession, arguments: []const Value) !void {
        if (self.started) return error.ExecutionAlreadyStarted;
        if (self.arguments.len == arguments.len) {
            @memcpy(self.arguments, arguments);
            return;
        }
        const copy = try self.allocator.dupe(Value, arguments);
        if (self.arguments.len != 0) self.allocator.free(self.arguments);
        self.arguments = copy;
    }

    pub fn beginRequest(self: *AsyncSession, host_json: []const u8, arguments: []const Value) !void {
        if (self.pending) |continuation| {
            continuation.deinit();
            self.pending = null;
        }
        self.context.pending_task_ids.clearRetainingCapacity();
        if (self.started) {
            _ = self.request_arena.reset(.{ .retain_with_limit = max_request_arena_capacity });
            self.objects = ObjectStore.init(self.request_arena.allocator());
            self.vm.global_this = try self.objects.createObject();
            try builtin_plugin.installObjectGlobal(&self.objects, self.vm.global_this);
        }
        self.output.writer.end = 0;
        self.error_output.writer.end = 0;
        self.host_json.clearRetainingCapacity();
        try self.host_json.appendSlice(self.allocator, host_json);
        self.context.host_json = self.host_json.items;
        self.timed_out = false;
        self.started = false;
        try self.setArguments(arguments);
    }

    pub fn createString(self: *AsyncSession, bytes: []const u8) !Value {
        return self.objects.createString(bytes);
    }

    pub fn resumeExecution(self: *AsyncSession, result: VM.AwaitResult) !VM.Outcome {
        const continuation = self.pending orelse return error.NoPendingExecution;
        self.pending = null;
        self.context.pending_task_ids.clearRetainingCapacity();
        const outcome = try self.vm.resumeExecution(continuation, result);
        self.track(outcome);
        return outcome;
    }

    pub fn rejectTimedOut(self: *AsyncSession) !VM.Outcome {
        self.timed_out = true;
        self.context.pending_task_ids.clearRetainingCapacity();
        const reason = try self.objects.createString("TimeoutError: awaited host operation timed out");
        return self.resumeExecution(.{ .rejected = reason });
    }

    pub fn timedOut(self: *const AsyncSession) bool {
        return self.timed_out;
    }

    pub fn pendingHostTask(self: *const AsyncSession) ?u64 {
        return if (self.context.pending_task_ids.items.len == 0) null else self.context.pending_task_ids.items[0];
    }

    pub fn waitForHostTask(self: *AsyncSession) !VM.Outcome {
        const continuation = self.pending orelse return error.NoPendingExecution;
        const wait = self.context.plugin_wait orelse return error.PluginWaitUnavailable;
        const awaited = continuation.awaited;
        if (self.objects.findExternalTaskGroup(awaited)) |group| {
            const values = try self.allocator.alloc(Value, group.entries.items.len);
            defer self.allocator.free(values);
            for (group.entries.items, 0..) |entry, index| {
                switch (entry) {
                    .value => |value| values[index] = value,
                    .task_id => |task_id| {
                        const response = wait(self.context.plugin_context, self.allocator, task_id, self.await_timeout_ms) catch |err| {
                            self.context.pending_task_ids.clearRetainingCapacity();
                            const reason = try self.objects.createString(@errorName(err));
                            return self.resumeExecution(.{ .rejected = reason });
                        };
                        const bytes = response orelse return self.rejectTimedOut();
                        values[index] = try self.objects.createString(bytes);
                    },
                }
            }
            self.context.pending_task_ids.clearRetainingCapacity();
            const result = try self.objects.createArray(values);
            return self.resumeExecution(.{ .resolved = result });
        }
        const promise = self.objects.findExternalTaskPromise(awaited) orelse return error.NoPendingHostTask;
        const response = wait(self.context.plugin_context, self.allocator, promise.task_id, self.await_timeout_ms) catch |err| {
            self.context.pending_task_ids.clearRetainingCapacity();
            const reason = try self.objects.createString(@errorName(err));
            return self.resumeExecution(.{ .rejected = reason });
        };
        const bytes = response orelse return self.rejectTimedOut();
        self.context.pending_task_ids.clearRetainingCapacity();
        const value = try self.objects.createString(bytes);
        return self.resumeExecution(.{ .resolved = value });
    }

    pub fn writeResult(self: *AsyncSession, value: Value) !void {
        if (!value.isUndefined()) try writeRuntimeValue(&self.output.writer, value, self.function.string_values, &self.objects);
    }

    pub fn writeError(self: *AsyncSession, value: Value) !void {
        try self.error_output.writer.writeAll("uncaught exception: ");
        try writeRuntimeValue(&self.error_output.writer, value, self.function.string_values, &self.objects);
    }

    pub fn outputBytes(self: *AsyncSession) []const u8 {
        return self.output.written();
    }

    pub fn errorBytes(self: *AsyncSession) []const u8 {
        return self.error_output.written();
    }

    pub fn deinit(self: *AsyncSession) void {
        if (self.pending) |continuation| continuation.deinit();
        self.request_arena.deinit();
        self.output.deinit();
        self.error_output.deinit();
        self.host_json.deinit(self.allocator);
        self.context.pending_task_ids.deinit(self.allocator);
        if (self.arguments.len != 0) self.allocator.free(self.arguments);
        self.allocator.destroy(self);
    }

    fn track(self: *AsyncSession, outcome: VM.Outcome) void {
        self.pending = if (outcome == .suspended) outcome.suspended.continuation else null;
    }
};

pub fn createNamedAsyncSession(
    allocator: std.mem.Allocator,
    module: *const @import("artifact.zig").LoadedModule,
    name: []const u8,
    options: ExecuteOptions,
) !*AsyncSession {
    const function = module.findFunction(name) orelse return error.UnknownFunction;
    return AsyncSession.create(allocator, function.*, options);
}

/// Creates an execution session for a function in a resident named module.
/// Keep the module loaded until the returned session has been deinitialized.
pub fn createModuleFunctionAsyncSession(
	allocator: std.mem.Allocator,
	modules: *@import("module_registry.zig").ModuleRegistry,
	module_name: []const u8,
	function_name: []const u8,
	options: ExecuteOptions,
) !*AsyncSession {
	const function = try modules.findFunction(module_name, function_name);
	return AsyncSession.create(allocator, function.*, options);
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

fn writeRuntimeValue(output: *std.Io.Writer, value: Value, strings: []const StringValue, objects: *ObjectStore) !void {
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
    } else if (objects.findBigInt(value)) |bigint| {
        const text = try bigint.value.toString(objects.allocator, 10, .lower);
        defer objects.allocator.free(text);
        try output.writeAll(text);
    } else {
        return error.UnsupportedResultType;
    }
    try output.writeByte('\n');
}

fn findStaticString(strings: []const StringValue, value: Value) ?[]const u8 {
    for (strings) |string| {
        if (string.value.raw() == value.raw()) return string.bytes;
    }
    return null;
}

fn writePrint(native_context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const context: *RuntimeContext = @ptrCast(@alignCast(native_context.host_context.?));
    for (arguments, 0..) |argument, index| {
        if (index != 0) try context.output.writeByte(' ');
        if (findStaticString(context.strings, argument) orelse native_context.objects.findString(argument)) |bytes| {
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
    const context: *RuntimeContext = @ptrCast(@alignCast(native_context.host_context.?));
    if (arguments.len == 0) return Value.undefined_value;
    const name = native_context.objects.findString(arguments[0]) orelse return Value.undefined_value;
    if (name.len == 0) return native_context.objects.createString(context.host_json);

    const parsed_request = try std.json.parseFromSlice(std.json.Value, native_context.objects.allocator, name, .{ .allocate = .alloc_always });
    defer parsed_request.deinit();
    const request = parsed_request.value;
    const request_object = switch (request) {
        .object => |object| object,
        else => return error.InvalidHostRequest,
    };
    const operation = request_object.get("op") orelse return error.MissingHostOperation;
    const operation_name = switch (operation) {
        .string => |value| value,
        else => return error.UnsupportedHostOperation,
    };
    if (std.mem.eql(u8, operation_name, "plugin.call")) {
        if (context.plugin_start) |start| {
            return switch (try start(context.plugin_context, native_context.objects.allocator, name)) {
                .completed => |response| try native_context.objects.createString(response),
                .pending => |task_id| blk: {
                    try context.pending_task_ids.append(context.pending_allocator, task_id);
                    break :blk try native_context.objects.createExternalTaskPromise(task_id);
                },
            };
        }
        const dispatch = context.plugin_call orelse return error.PluginDispatchUnavailable;
        const response = try dispatch(context.plugin_context, native_context.objects.allocator, name);
        return native_context.objects.createString(response);
    }
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

fn externalPromiseAll(native_context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return native_context.objects.createArray(&.{});
    const array = native_context.objects.findArray(arguments[0]) orelse return error.TypeError;
    const entries = try native_context.objects.allocator.alloc(@import("vm/objects.zig").ExternalTaskEntry, array.items.items.len);
    defer native_context.objects.allocator.free(entries);
    var has_external_task = false;
    for (array.items.items, 0..) |value, index| {
        if (native_context.objects.findExternalTaskPromise(value)) |promise| {
            has_external_task = true;
            entries[index] = .{ .task_id = promise.task_id };
        } else if (native_context.objects.findExternalTaskGroup(value) != null) {
            return error.NestedExternalTaskGroupUnsupported;
        } else {
            entries[index] = .{ .value = value };
        }
    }
    if (!has_external_task) return native_context.objects.createArray(array.items.items);
    return native_context.objects.createExternalTaskGroup(entries);
}

test "loaded module invokes a named function without decoding the image again" {
    const allocator = std.testing.allocator;
    var program = try @import("compiler.zig").compile(allocator, "function first() { return 40 + 2; } function second() { return 21 * 2; } function calculate(value) { return value + 2; }");
    defer program.deinit(allocator);
    var image_arena = std.heap.ArenaAllocator.init(allocator);
    defer image_arena.deinit();
    const image_allocator = image_arena.allocator();
    const unit = try @import("artifact.zig").unitFromProgram(image_allocator, program);
    const image = try @import("artifact.zig").encode(image_allocator, unit);
    var module = try @import("artifact.zig").LoadedModule.init(allocator, image);
    defer module.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var errors: std.Io.Writer.Allocating = .init(allocator);
    defer errors.deinit();

    try std.testing.expect(!try executeNamedWithOptions(allocator, &module, "second", &output.writer, &errors.writer, .{}));
    try std.testing.expect(!try executeNamedWithOptions(allocator, &module, "first", &output.writer, &errors.writer, .{}));
    try std.testing.expectEqualStrings("42\n42\n", output.written());

    const session = try createNamedAsyncSession(allocator, &module, "calculate", .{});
    defer session.deinit();
    const argument = Value.fromInt(40).?;
    try session.setArguments(&.{argument});
    const result = switch (try session.start()) {
        .value => |value| value,
        else => return error.ExpectedNamedFunctionResult,
    };
    try session.writeResult(result);
    try std.testing.expectEqualStrings("42\n", session.outputBytes());
}

test "async session reuses its VM and releases request objects between invocations" {
    const allocator = std.testing.allocator;
    var program = try @import("compiler.zig").compile(allocator, "function handle(value) { return value; } handle('seed');");
    defer program.deinit(allocator);
    const session = try AsyncSession.create(allocator, program.functions[0], .{});
    defer session.deinit();
    const vm_address = @intFromPtr(&session.vm);
    const baseline_object_count = session.objects.objects.items.len;
    try std.testing.expectEqual(@intFromPtr(&session.request_arena), @intFromPtr(session.vm.allocator.ptr));

    try session.beginRequest("{\"path\":\"/first\"}", &.{});
    const first_argument = try session.createString("first");
    try session.setArguments(&.{first_argument});
    const first = try session.start();
    try session.writeResult(first.value);
    try std.testing.expectEqualStrings("first\n", session.outputBytes());
    try std.testing.expectEqual(@as(usize, 1), session.objects.strings.items.len);
    _ = try session.objects.createArray(&.{});
    _ = try session.objects.createObject();
    _ = try session.objects.createRegex("x", false, false);
    try session.beginRequest("{\"path\":\"/second\"}", &.{});
    try std.testing.expectEqual(vm_address, @intFromPtr(&session.vm));
    try std.testing.expect(session.request_arena.queryCapacity() <= max_request_arena_capacity);
    try std.testing.expectEqual(@as(usize, 0), session.objects.strings.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.objects.arrays.items.len);
    try std.testing.expectEqual(baseline_object_count, session.objects.objects.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.objects.regexes.items.len);
    try std.testing.expectEqualStrings("", session.outputBytes());
    try std.testing.expectEqualStrings("{\"path\":\"/second\"}", session.context.host_json);

    const second_argument = try session.createString("second");
    try session.setArguments(&.{second_argument});
    const second = try session.start();
    try session.writeResult(second.value);
    try std.testing.expectEqualStrings("second\n", session.outputBytes());

    for (0..1_000) |_| {
        try session.beginRequest("{\"path\":\"/repeat\"}", &.{});
        try std.testing.expectEqual(vm_address, @intFromPtr(&session.vm));
        const argument = try session.createString("repeat");
        try session.setArguments(&.{argument});
        const repeated = try session.start();
        try session.writeResult(repeated.value);
        try std.testing.expectEqualStrings("repeat\n", session.outputBytes());
        _ = try session.objects.createArray(&.{});
        _ = try session.objects.createObject();
        _ = try session.objects.createRegex("x", false, false);
        try std.testing.expect(session.request_arena.queryCapacity() <= max_request_arena_capacity);
    }
}

test "async session timeout rejects await and clears its continuation" {
    const allocator = std.testing.allocator;
    var program = try @import("compiler.zig").compile(allocator, "async function load() { try { return await 40; } catch (reason) { return 504; } } load();");
    defer program.deinit(allocator);
    const session = try AsyncSession.create(allocator, program.bytecode(), .{});
    defer session.deinit();

    const pending = try session.start();
    try std.testing.expect(pending == .suspended);
    const timed_out = try session.rejectTimedOut();
    const value = switch (timed_out) {
        .value => |result| result,
        else => return error.ExpectedHandledTimeout,
    };
    try session.writeResult(value);
    try std.testing.expectEqualStrings("504\n", session.outputBytes());
    try std.testing.expect(session.pending == null);
}

test "async session keeps runtime state alive across multiple awaits" {
    const allocator = std.testing.allocator;
    var program = try @import("compiler.zig").compile(allocator, "async function load() { let value = await 10; value = await value + 5; return value; } load();");
    defer program.deinit(allocator);
    const session = try AsyncSession.create(allocator, program.bytecode(), .{});
    defer session.deinit();

    var outcome = try session.start();
    var await_count: usize = 0;
    while (outcome == .suspended) {
        await_count += 1;
        outcome = try session.resumeExecution(.{ .resolved = outcome.suspended.awaited });
    }
    try std.testing.expectEqual(@as(usize, 2), await_count);
    const value = switch (outcome) {
        .value => |result| result,
        else => return error.ExpectedCompletedExecution,
    };
    try session.writeResult(value);
    try std.testing.expectEqualStrings("15\n", session.outputBytes());
    try std.testing.expect(session.pending == null);
}

const TestAsyncPlugin = struct {
    complete: bool,
    timeout_ms: u64 = 0,

    fn start(context: ?*anyopaque, _: std.mem.Allocator, _: []const u8) anyerror!HostPluginStartResult {
        _ = context orelse return error.MissingTestContext;
        return .{ .pending = 73 };
    }

    fn wait(context: ?*anyopaque, _: std.mem.Allocator, task_id: u64, timeout_ms: u64) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context orelse return error.MissingTestContext));
        if (task_id != 73) return error.UnknownTestTask;
        self.timeout_ms = timeout_ms;
        return if (self.complete) "database row" else null;
    }
};

test "async plugin result resumes await and timeout becomes a catchable error" {
    const allocator = std.testing.allocator;
    const source = "async function load() { try { return await __host('{\\\"op\\\":\\\"plugin.call\\\"}'); } catch (reason) { return 504; } } load();";
    var program = try @import("compiler.zig").compile(allocator, source);
    defer program.deinit(allocator);

    var successful_plugin = TestAsyncPlugin{ .complete = true };
    const success = try AsyncSession.create(allocator, program.bytecode(), .{
        .plugin_context = &successful_plugin,
        .plugin_start = TestAsyncPlugin.start,
        .plugin_wait = TestAsyncPlugin.wait,
        .await_timeout_ms = 250,
    });
    defer success.deinit();
    const pending = try success.start();
    try std.testing.expect(pending == .suspended);
    try std.testing.expectEqual(@as(?u64, 73), success.pendingHostTask());
    const completed = try success.waitForHostTask();
    const value = switch (completed) {
        .value => |result| result,
        else => return error.ExpectedPluginCompletion,
    };
    try success.writeResult(value);
    try std.testing.expectEqualStrings("database row\n", success.outputBytes());
    try std.testing.expectEqual(@as(u64, 250), successful_plugin.timeout_ms);

    var timed_out_plugin = TestAsyncPlugin{ .complete = false };
    const timed_out = try AsyncSession.create(allocator, program.bytecode(), .{
        .plugin_context = &timed_out_plugin,
        .plugin_start = TestAsyncPlugin.start,
        .plugin_wait = TestAsyncPlugin.wait,
        .await_timeout_ms = 10,
    });
    defer timed_out.deinit();
    _ = try timed_out.start();
    const rejected = try timed_out.waitForHostTask();
    const timeout_value = switch (rejected) {
        .value => |result| result,
        else => return error.ExpectedCatchableTimeout,
    };
    try timed_out.writeResult(timeout_value);
    try std.testing.expectEqualStrings("504\n", timed_out.outputBytes());
    try std.testing.expect(timed_out.pending == null);
}

const TestConcurrentAsyncPlugin = struct {
    started: usize = 0,
    waited: usize = 0,

    fn start(context: ?*anyopaque, _: std.mem.Allocator, request: []const u8) anyerror!HostPluginStartResult {
        const self: *@This() = @ptrCast(@alignCast(context orelse return error.MissingTestContext));
        self.started += 1;
        if (std.mem.indexOf(u8, request, "first") != null) return .{ .pending = 81 };
        if (std.mem.indexOf(u8, request, "second") != null) return .{ .pending = 82 };
        return error.UnknownTestRequest;
    }

    fn wait(context: ?*anyopaque, _: std.mem.Allocator, task_id: u64, _: u64) anyerror!?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(context orelse return error.MissingTestContext));
        self.waited += 1;
        return switch (task_id) {
            81 => "one",
            82 => "two",
            else => error.UnknownTestTask,
        };
    }
};

test "Promise.all awaits multiple external plugin tasks and preserves input order" {
    const allocator = std.testing.allocator;
    const source = "async function load() { var call1 = __host('{\\\"op\\\":\\\"plugin.call\\\",\\\"which\\\":\\\"first\\\"}'); var label = 'done:'; var call2 = __host('{\\\"op\\\":\\\"plugin.call\\\",\\\"which\\\":\\\"second\\\"}'); var values = await Promise.all([call1, call2]); return label + values[0] + values[1]; } load();";
    var program = try @import("compiler.zig").compile(allocator, source);
    defer program.deinit(allocator);

    var plugin = TestConcurrentAsyncPlugin{};
    const session = try AsyncSession.create(allocator, program.bytecode(), .{
        .plugin_context = &plugin,
        .plugin_start = TestConcurrentAsyncPlugin.start,
        .plugin_wait = TestConcurrentAsyncPlugin.wait,
    });
    defer session.deinit();

    const pending = try session.start();
    try std.testing.expect(pending == .suspended);
    try std.testing.expectEqual(@as(usize, 2), plugin.started);
    try std.testing.expectEqual(@as(?u64, 81), session.pendingHostTask());

    const completed = try session.waitForHostTask();
    const value = switch (completed) {
        .value => |result| result,
        else => return error.ExpectedCompletedExecution,
    };
    try session.writeResult(value);
    try std.testing.expectEqual(@as(usize, 2), plugin.waited);
    try std.testing.expectEqualStrings("done:onetwo\n", session.outputBytes());
}
