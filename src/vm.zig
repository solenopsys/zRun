// Zig bytecode dispatcher for the zRun runtime.
// Copyright (c) 2017-2025 Fabrice Bellard
// Copyright (c) 2017-2025 Charlie Gordon
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const Opcode = @import("opcode.zig").Opcode;
const opcode_count = @import("opcode.zig").count;
const Value = @import("value.zig").Value;
const ObjectStore = @import("vm/objects.zig").Store;
const Cell = @import("vm/objects.zig").Cell;
const ClosureObject = @import("vm/objects.zig").ClosureObject;
const ExecutionStack = @import("vm/stack.zig").Stack;
const ascii_chars = makeAsciiChars();
const inline_execution_stack_capacity = 16;

pub const FunctionBytecode = struct {
    name: []const u8 = "",
    code: []const u8,
    constants: []const Value = &.{},
    string_values: []const StringValue = &.{},
    max_stack: usize = 256,
    local_count: usize = 0,
    argument_count: usize = 0,
    capture_count: usize = 0,
    capture_sources: []const u16 = &.{},
    capture_local_indices: []const u16 = &.{},
    arguments: []const Value = &.{},
    functions: []const FunctionBytecode = &.{},
    external_variables: []const ExternalVariable = &.{},
};

pub const ExternalKind = enum { global, argument, local, outer };

pub const ExternalVariable = struct {
    name: []const u8,
    kind: ExternalKind,
    index: u16,
    declared: bool = false,
};

pub const StringValue = @import("vm/objects.zig").StringEntry;

pub const CallFrame = struct {
    function: *const FunctionBytecode,
    captured_cells: []*Cell,
    this_value: Value = Value.undefined_value,
    binding_count: usize = 0,
    supplied_argument_count: usize = 0,
    caller_stack_len: usize = 0,
    pc: usize = 0,
    inline_stack: [inline_execution_stack_capacity]Value = undefined,
    overflow_stack: ?[]Value = null,
    stack: ExecutionStack = undefined,
    inline_bindings: [32]Binding = undefined,
    overflow_bindings: ?[]Binding = null,
    local_bindings: []Binding = &.{},
    argument_bindings: []Binding = &.{},

    fn init(self: *CallFrame, vm: VM, function: *const FunctionBytecode, supplied_arguments: []const Value, objects: *ObjectStore, captured_cells: []*Cell, this_value: Value) VM.Error!void {
        self.* = .{
            .function = function,
            .captured_cells = captured_cells,
            .this_value = this_value,
            .supplied_argument_count = supplied_arguments.len,
        };
        const stack_capacity = function.max_stack;
        const stack_storage = if (stack_capacity <= self.inline_stack.len)
            self.inline_stack[0..stack_capacity]
        else blk: {
            self.overflow_stack = vm.allocator.alloc(Value, stack_capacity) catch return error.StackOverflow;
            break :blk self.overflow_stack.?;
        };
        self.stack = ExecutionStack.init(stack_storage);

        if (function.external_variables.len != 0) {
            if (captured_cells.len != function.external_variables.len) return error.BadArgumentIndex;
        } else if (captured_cells.len != function.capture_count or function.capture_local_indices.len != captured_cells.len) {
            return error.BadArgumentIndex;
        }
        const argument_count = @max(function.argument_count, supplied_arguments.len);
        const binding_count = function.local_count + argument_count;
        self.binding_count = binding_count;
        const frame_bindings = if (binding_count <= self.inline_bindings.len)
            self.inline_bindings[0..binding_count]
        else blk: {
            self.overflow_bindings = vm.allocator.alloc(Binding, binding_count) catch return error.StackOverflow;
            break :blk self.overflow_bindings.?;
        };
        const locals = frame_bindings[0..function.local_count];
        const arguments = frame_bindings[function.local_count..];
        self.local_bindings = locals;
        self.argument_bindings = arguments;
        if (function.functions.len == 0) {
            for (locals) |*local| local.* = .{ .value = Value.undefined_value };
            for (arguments, 0..) |*argument, index| {
                argument.* = .{ .value = if (index < supplied_arguments.len) supplied_arguments[index] else Value.undefined_value };
            }
        } else {
            for (locals, 0..) |*local, index| {
                if (vm.localCapturedByChild(function.*, index)) {
                    local.* = .{ .captured = objects.createCell(Value.undefined_value) catch return error.StackOverflow };
                } else {
                    local.* = .{ .value = Value.undefined_value };
                }
            }
            for (arguments, 0..) |*argument, index| {
                const initial = if (index < supplied_arguments.len) supplied_arguments[index] else Value.undefined_value;
                if (vm.argumentCapturedByChild(function.*, index)) {
                    argument.* = .{ .captured = objects.createCell(initial) catch return error.StackOverflow };
                } else {
                    argument.* = .{ .value = initial };
                }
            }
        }
        if (function.external_variables.len == 0) {
            for (captured_cells, 0..) |cell, index| {
                const local_index = function.capture_local_indices[index];
                if (local_index >= locals.len) return error.BadLocalIndex;
                locals[local_index] = .{ .captured = cell };
            }
        }
    }

    fn deinit(self: *CallFrame, allocator: std.mem.Allocator) void {
        if (self.overflow_stack) |storage| allocator.free(storage);
        if (self.overflow_bindings) |storage| allocator.free(storage);
        self.overflow_stack = null;
        self.overflow_bindings = null;
    }

    fn rebindInlineStorage(self: *CallFrame, original: *const CallFrame) void {
        if (original.overflow_stack == null) {
            self.stack.storage = self.inline_stack[0..original.stack.storage.len];
        }
        if (original.overflow_bindings == null) {
            const local_count = original.local_bindings.len;
            self.local_bindings = self.inline_bindings[0..local_count];
            self.argument_bindings = self.inline_bindings[local_count..original.binding_count];
        }
    }
};

const Binding = struct {
    value: Value = Value.undefined_value,
    captured: ?*Cell = null,

    inline fn load(self: Binding) Value {
        return if (self.captured) |cell| cell.value else self.value;
    }

    inline fn store(self: *Binding, value: Value) void {
        if (self.captured) |cell| {
            cell.value = value;
        } else {
            self.value = value;
        }
    }
};

const NativeMethodCacheEntry = struct {
    receiver: VM.NativeReceiver,
    name: []const u8,
    native_index: usize,
};

pub const VM = struct {
    pub const NativeCallContext = struct {
        objects: *ObjectStore,
        host_context: ?*anyopaque,
        vm: *const VM,
        execution_stats: ?*ExecutionStats = null,
    };

    pub const NativeFunction = *const fn (context: *NativeCallContext, arguments: []const Value) anyerror!Value;
    pub const EventPump = *const fn (context: *anyopaque, vm: *const VM, objects: *ObjectStore) anyerror!void;
    pub const GlobalBinding = struct {
        name: []const u8,
        cell: *Cell,
    };
    pub const NativeReceiver = enum { array, object, string, number, map, set, iterator, regex };
    pub const NativeMethod = struct {
        name: []const u8,
        receiver: NativeReceiver,
        native_index: usize,
    };

    allocator: std.mem.Allocator,
    native_functions: []const NativeFunction = &.{},
    native_context: ?*anyopaque = null,
    objects: ?*ObjectStore = null,
    event_pump: ?EventPump = null,
    event_context: ?*anyopaque = null,
    global_bindings: []GlobalBinding = &.{},
    native_methods: []const NativeMethod = &.{},
    global_this: Value = Value.undefined_value,

    pub const Outcome = union(enum) {
        value: Value,
        thrown: Value,
        suspended: Suspension,
    };

    pub const AwaitResult = union(enum) {
        resolved: Value,
        rejected: Value,
    };

    pub const Suspension = struct {
        continuation: *Continuation,
        awaited: Value,
    };

    pub const Continuation = struct {
        allocator: std.mem.Allocator,
        vm: VM,
        root_function: FunctionBytecode,
        frames: []CallFrame,
        frame_depth: usize,
        active_frames: usize,
        root_captures: []*Cell,
        objects: *ObjectStore,
        awaited: Value,
        resume_exception: ?Value = null,

        pub fn deinit(self: *Continuation) void {
            for (self.frames[0..self.active_frames]) |*frame| frame.deinit(self.allocator);
            self.allocator.free(self.frames);
            self.allocator.free(self.root_captures);
            self.allocator.destroy(self);
        }
    };

    pub const ExecutionStats = struct {
        opcode_counts: [256]u64 = @splat(0),
    };

    pub const Error = error{
        BadConstantIndex,
        BadArgumentIndex,
        BadGlobalIndex,
        BadLocalIndex,
        DivisionByZero,
        InvalidFunctionIndex,
        IntegerOverflow,
        InvalidBranch,
        InvalidOpcode,
        MaxCallDepth,
        MissingReturn,
        NativeFunctionFailed,
        NotCallable,
        StackOverflow,
        StackUnderflow,
        TruncatedBytecode,
        TypeError,
        UnknownGlobal,
        UncaughtException,
        UnsupportedOpcode,
        AsyncRequired,
        AsyncRequiresObjectStore,
    };

    pub fn execute(self: VM, function: FunctionBytecode) Error!Value {
        return switch (try self.executeOutcome(function)) {
            .value => |value| value,
            .thrown => error.UncaughtException,
            .suspended => |suspension| {
                suspension.continuation.deinit();
                return error.AsyncRequired;
            },
        };
    }

    pub fn executeAsync(self: VM, function: FunctionBytecode) Error!Outcome {
        return self.executeAsyncWithArguments(function, function.arguments);
    }

    pub fn executeAsyncWithArguments(self: VM, function: FunctionBytecode, arguments: []const Value) Error!Outcome {
        const objects = self.objects orelse return error.AsyncRequiresObjectStore;
        return self.executeOutcomeWithObjects(function, objects, null, arguments);
    }

    pub fn resumeExecution(self: VM, continuation: *Continuation, result: AwaitResult) Error!Outcome {
        const state_vm = continuation.vm;
        _ = self;
        const top = &continuation.frames[continuation.frame_depth];
        var stack = top.stack;
        const pc = top.pc;
        switch (result) {
            .resolved => |value| try state_vm.push(&stack, top.function.max_stack, value),
            .rejected => |thrown| continuation.resume_exception = thrown,
        }
        top.stack = stack;
        top.pc = pc;
        const outcome = state_vm.executeFramesAsync(false, null, &continuation.root_function, &.{}, continuation.objects, continuation.root_captures, continuation) catch |err| {
            continuation.deinit();
            return err;
        };
        if (outcome != .suspended) continuation.deinit();
        return outcome;
    }

    pub fn executeOutcome(self: VM, function: FunctionBytecode) Error!Outcome {
        return self.executeOutcomeImpl(function, false, null);
    }

    pub fn executeOutcomeWithStats(self: VM, function: FunctionBytecode, stats: *ExecutionStats) Error!Outcome {
        return self.executeOutcomeImpl(function, true, stats);
    }

    pub fn invoke(self: VM, objects: *ObjectStore, callable: Value, arguments: []const Value) Error!Value {
        const closure = objects.findClosure(callable) orelse return error.NotCallable;
        return self.invokeClosure(objects, closure, arguments);
    }

    pub fn invokeClosure(self: VM, objects: *ObjectStore, closure: *const ClosureObject, arguments: []const Value) Error!Value {
        const function: *const FunctionBytecode = @ptrCast(@alignCast(closure.function));
        return self.unwrapInvocation(try self.executeFrames(false, null, function, arguments, objects, closure.captures));
    }

    pub fn invokeClosureWithStats(self: VM, objects: *ObjectStore, closure: *const ClosureObject, arguments: []const Value, stats: *ExecutionStats) Error!Value {
        const function: *const FunctionBytecode = @ptrCast(@alignCast(closure.function));
        return self.unwrapInvocation(try self.executeFrames(true, stats, function, arguments, objects, closure.captures));
    }

    fn unwrapInvocation(self: VM, outcome: Outcome) Error!Value {
        _ = self;
        return switch (outcome) {
            .value => |value| value,
            .thrown => error.UncaughtException,
            .suspended => |suspension| {
                suspension.continuation.deinit();
                return error.AsyncRequired;
            },
        };
    }

    fn executeOutcomeImpl(self: VM, function: FunctionBytecode, comptime collect_stats: bool, stats: ?*ExecutionStats) Error!Outcome {
        const captures = self.allocator.alloc(*Cell, function.external_variables.len) catch return error.StackOverflow;
        defer self.allocator.free(captures);
        for (function.external_variables, 0..) |external, index| {
            if (external.kind != .global) return error.BadGlobalIndex;
            const global = self.findGlobal(external.name) orelse return error.UnknownGlobal;
            captures[index] = global.cell;
        }
        if (self.objects) |objects| {
            objects.static_strings = function.string_values;
            const outcome = try self.executeFrames(collect_stats, stats, &function, function.arguments, objects, captures);
            if (outcome == .suspended) {
                outcome.suspended.continuation.deinit();
                return error.AsyncRequired;
            }
            return outcome;
        }
        var objects = ObjectStore.init(self.allocator);
        defer objects.deinit();
        objects.static_strings = function.string_values;
        const outcome = try self.executeFrames(collect_stats, stats, &function, function.arguments, &objects, captures);
        if (outcome == .suspended) {
            outcome.suspended.continuation.deinit();
            return error.AsyncRequired;
        }
        return outcome;
    }

    fn executeOutcomeWithObjects(self: VM, function: FunctionBytecode, objects: *ObjectStore, continuation: ?*Continuation, arguments: []const Value) Error!Outcome {
        const captures = self.allocator.alloc(*Cell, function.external_variables.len) catch return error.StackOverflow;
        defer self.allocator.free(captures);
        for (function.external_variables, 0..) |external, index| {
            if (external.kind != .global) return error.BadGlobalIndex;
            const global = self.findGlobal(external.name) orelse return error.UnknownGlobal;
            captures[index] = global.cell;
        }
        objects.static_strings = function.string_values;
        return self.executeFramesAsync(false, null, &function, arguments, objects, captures, continuation);
    }

    fn executeFrames(self: VM, comptime collect_stats: bool, stats: ?*ExecutionStats, root_function: *const FunctionBytecode, supplied_arguments: []const Value, objects: *ObjectStore, root_captures: []*Cell) Error!Outcome {
        if (self.event_pump == null) {
            return self.executeFramesImpl(false, false, collect_stats, stats, root_function, supplied_arguments, objects, root_captures, null);
        }
        return self.executeFramesImpl(true, false, collect_stats, stats, root_function, supplied_arguments, objects, root_captures, null);
    }

    fn executeFramesAsync(self: VM, comptime collect_stats: bool, stats: ?*ExecutionStats, root_function: *const FunctionBytecode, supplied_arguments: []const Value, objects: *ObjectStore, root_captures: []*Cell, continuation: ?*Continuation) Error!Outcome {
        if (self.event_pump == null) {
            return self.executeFramesImpl(false, true, collect_stats, stats, root_function, supplied_arguments, objects, root_captures, continuation);
        }
        return self.executeFramesImpl(true, true, collect_stats, stats, root_function, supplied_arguments, objects, root_captures, continuation);
    }

    fn executeFramesImpl(self: VM, comptime pump_each_instruction: bool, comptime async_enabled: bool, comptime collect_stats: bool, stats: ?*ExecutionStats, root_function: *const FunctionBytecode, supplied_arguments: []const Value, objects: *ObjectStore, root_captures: []*Cell, continuation: ?*Continuation) Error!Outcome {
        var stack_frames: [64]CallFrame = undefined;
        var frames: []CallFrame = stack_frames[0..];
        var heap_frames: ?[]CallFrame = null;
        var frame_depth: usize = 0;
        var active_frames: usize = 0;
        var owns_frames = true;
        var method_cache: [8]?NativeMethodCacheEntry = @splat(null);
        var method_cache_next: usize = 0;
        if (comptime async_enabled) {
            if (continuation) |state| {
                frames = state.frames;
                heap_frames = state.frames;
                frame_depth = state.frame_depth;
                active_frames = state.active_frames;
                owns_frames = false;
            } else {
                active_frames = 1;
                frames[0].init(self, root_function, supplied_arguments, objects, root_captures, Value.undefined_value) catch |err| {
                    return err;
                };
            }
        } else {
            active_frames = 1;
            frames[0].init(self, root_function, supplied_arguments, objects, root_captures, Value.undefined_value) catch |err| {
                return err;
            };
        }
        defer if (owns_frames) {
            for (frames[0..active_frames]) |*active| active.deinit(self.allocator);
            if (heap_frames) |allocated| self.allocator.free(allocated);
        };

        var frame = &frames[frame_depth];
        var function = frame.function;
        var stack = frame.stack;
        var pc = frame.pc;
        var locals = frame.local_bindings;
        var arguments = frame.argument_bindings;
        var captured_cells = frame.captured_cells;
        var last_opcode: ?Opcode = null;
        errdefer if (last_opcode) |failed_opcode| {
            std.debug.print("VM failure in {s} at pc={d}, opcode={s}, stack={d}, code={d}\n", .{
                function.name, pc, @tagName(failed_opcode), stack.len, function.code.len,
            });
        };

        if (comptime async_enabled) {
            if (continuation) |state| {
                if (state.resume_exception) |thrown| {
                    state.resume_exception = null;
                    if (!try self.dispatchException(&stack, function.max_stack, thrown, &pc)) {
                        var unwind_depth = frame_depth;
                        var caught = false;
                        while (unwind_depth > 0) {
                            frames[unwind_depth].deinit(self.allocator);
                            unwind_depth -= 1;
                            const caller = &frames[unwind_depth];
                            var caller_stack = caller.stack;
                            caller_stack.truncate(frames[unwind_depth + 1].caller_stack_len);
                            var caller_pc = caller.pc;
                            if (try self.dispatchException(&caller_stack, caller.function.max_stack, thrown, &caller_pc)) {
                                caller.stack = caller_stack;
                                caller.pc = caller_pc;
                                frame_depth = unwind_depth;
                                frame = caller;
                                function = caller.function;
                                stack = caller_stack;
                                pc = caller_pc;
                                locals = caller.local_bindings;
                                arguments = caller.argument_bindings;
                                captured_cells = caller.captured_cells;
                                caught = true;
                                break;
                            }
                            caller.stack = caller_stack;
                            caller.pc = caller_pc;
                        }
                        if (!caught) return .{ .thrown = thrown };
                    }
                }
            }
        }

        dispatch: while (true) {
            if (comptime pump_each_instruction) {
                self.event_pump.?(self.event_context orelse return error.NativeFunctionFailed, &self, objects) catch return error.NativeFunctionFailed;
            }
            if (builtin.mode != .fast and pc >= function.code.len) return error.MissingReturn;
            const opcode_byte = function.code[pc];
            pc += 1;
            if (collect_stats) stats.?.opcode_counts[opcode_byte] += 1;
            if (builtin.mode != .fast and opcode_byte >= @as(u8, @intCast(opcode_count))) return error.InvalidOpcode;
            const opcode: Opcode = @enumFromInt(opcode_byte);
            last_opcode = opcode;

            if (opcode_byte >= @intFromEnum(Opcode.push_minus1) and opcode_byte <= @intFromEnum(Opcode.push_7)) {
                const number: i32 = @as(i32, opcode_byte) - @as(i32, @intFromEnum(Opcode.push_0));
                try self.push(&stack, function.max_stack, Value.fromInt(number) orelse return error.IntegerOverflow);
                continue :dispatch;
            }

            switch (opcode) {
                .push_i8 => {
                    const raw = try readByte(function.code, &pc);
                    try self.push(&stack, function.max_stack, Value.fromInt(@as(i8, @bitCast(raw))) orelse return error.IntegerOverflow);
                },
                .push_i16 => {
                    const raw = try readU16(function.code, &pc);
                    try self.push(&stack, function.max_stack, Value.fromInt(@as(i16, @bitCast(raw))) orelse return error.IntegerOverflow);
                },
                .push_value => {
                    const raw = try readU32(function.code, &pc);
                    try self.push(&stack, function.max_stack, .{ .bits = raw });
                },
                .push_const => {
                    const index = try readU16(function.code, &pc);
                    if (index >= function.constants.len) return error.BadConstantIndex;
                    try self.push(&stack, function.max_stack, function.constants[index]);
                },
                .push_const8 => {
                    const index = try readByte(function.code, &pc);
                    if (index >= function.constants.len) return error.BadConstantIndex;
                    try self.push(&stack, function.max_stack, function.constants[index]);
                },
                .to_bigint => {
                    const input = try self.pop(&stack);
                    const converted = try toBigInt(objects, function.*, input);
                    try self.push(&stack, function.max_stack, converted);
                },
                .array_from => {
                    const count = try readU16(function.code, &pc);
                    if (stack.len < count) return error.StackUnderflow;
                    const start = stack.len - count;
                    const array_value = objects.createArray(stack.storage[start..stack.len]) catch return error.StackOverflow;
                    stack.truncate(start);
                    try self.push(&stack, function.max_stack, array_value);
                },
                .array_append => {
                    const item = try self.pop(&stack);
                    const target = try self.pop(&stack);
                    const array = objects.findArray(target) orelse return error.TypeError;
                    array.items.append(self.allocator, item) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, target);
                },
                .array_spread => {
                    const source_value = try self.pop(&stack);
                    const target_value = try self.pop(&stack);
                    const target = objects.findArray(target_value) orelse return error.TypeError;
                    if (objects.findArray(source_value)) |source| {
                        target.items.appendSlice(self.allocator, source.items.items) catch return error.StackOverflow;
                    } else if (objects.findIterator(source_value)) |iterator| {
                        target.items.appendSlice(self.allocator, iterator.values.items[iterator.index..]) catch return error.StackOverflow;
                        iterator.index = iterator.values.items.len;
                    } else if (objects.findCollection(source_value)) |collection| {
                        if (collection.kind == .map) {
                            for (collection.entries.items) |entry| {
                                const pair = objects.createArray(&.{ entry.key, entry.value }) catch return error.StackOverflow;
                                target.items.append(self.allocator, pair) catch return error.StackOverflow;
                            }
                        } else {
                            for (collection.entries.items) |entry| {
                                target.items.append(self.allocator, entry.key) catch return error.StackOverflow;
                            }
                        }
                    } else if (stringBytes(function.*, objects, source_value)) |bytes| {
                        var offset: usize = 0;
                        while (offset < bytes.len) {
                            const width = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.TypeError;
                            const end = @min(offset + width, bytes.len);
                            const character = objects.createString(bytes[offset..end]) catch return error.StackOverflow;
                            target.items.append(self.allocator, character) catch return error.StackOverflow;
                            offset = end;
                        }
                    } else return error.TypeError;
                    try self.push(&stack, function.max_stack, target_value);
                },
                .object_spread => {
                    const source_value = try self.pop(&stack);
                    const target_value = try self.pop(&stack);
                    const source = objects.findObject(source_value) orelse return error.TypeError;
                    for (source.fields.items) |field| {
                        objects.putProperty(target_value, field.name, field.value) catch return error.TypeError;
                    }
                    try self.push(&stack, function.max_stack, target_value);
                },
                .object_keys => {
                    const object_value = try self.pop(&stack);
                    if (object_value.isNull() or object_value.isUndefined()) {
                        const result = objects.createArray(&.{}) catch return error.StackOverflow;
                        try self.push(&stack, function.max_stack, result);
                        continue :dispatch;
                    }
                    const object = objects.findObject(object_value) orelse {
                        return error.TypeError;
                    };
                    const keys = self.allocator.alloc(Value, object.fields.items.len) catch return error.StackOverflow;
                    defer self.allocator.free(keys);
                    for (object.fields.items, 0..) |field, index| {
                        keys[index] = objects.createString(field.name) catch return error.StackOverflow;
                    }
                    const result = objects.createArray(keys) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, result);
                },
                .function_bind => {
                    const count = try readU16(function.code, &pc);
                    if (stack.len < @as(usize, count) + 2) return error.StackUnderflow;
                    const target_position = stack.len - @as(usize, count) - 2;
                    const target = stack.storage[target_position];
                    const this_value = stack.storage[target_position + 1];
                    const bound = objects.createBoundFunction(target, this_value, stack.storage[target_position + 2 .. stack.len]) catch return error.StackOverflow;
                    stack.truncate(target_position);
                    try self.push(&stack, function.max_stack, bound);
                },
                .object => {
                    const field_count = try readU16(function.code, &pc);
                    const object_value = objects.createObjectWithCapacity(field_count) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, object_value);
                },
                .collection_new => {
                    const encoded_kind = try readByte(function.code, &pc);
                    const has_iterable = encoded_kind & 0x80 != 0;
                    const kind = encoded_kind & 0x7f;
                    const iterable = if (has_iterable) try self.pop(&stack) else null;
                    const collection_kind: @import("vm/objects.zig").CollectionKind = switch (kind) {
                        0 => .map,
                        1 => .set,
                        2 => .weak_map,
                        else => return error.InvalidOpcode,
                    };
                    const collection = objects.createCollection(collection_kind) catch return error.StackOverflow;
                    if (iterable) |source| try self.initializeCollection(function.*, objects, collection, source);
                    try self.push(&stack, function.max_stack, collection);
                },
                .regexp_new => {
                    const flags = try readByte(function.code, &pc);
                    const pattern_value = try self.pop(&stack);
                    const pattern = stringBytes(function.*, objects, pattern_value) orelse return error.TypeError;
                    const regex = objects.createRegex(pattern, flags & 1 != 0, flags & 2 != 0) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, regex);
                },
                .array_new => {
                    const length_value = try self.pop(&stack);
                    const length = length_value.asInt() orelse return error.TypeError;
                    if (length < 0) return error.TypeError;
                    const array = objects.createArrayWithCapacity(@intCast(length)) catch return error.StackOverflow;
                    const array_object = objects.findArray(array).?;
                    for (0..@intCast(length)) |_| array_object.items.appendAssumeCapacity(Value.undefined_value);
                    try self.push(&stack, function.max_stack, array);
                },
                .get_field => {
                    const property_index = try readU16(function.code, &pc);
                    if (property_index >= function.constants.len) return error.BadConstantIndex;
                    const property_name = findString(function.*, function.constants[property_index]) orelse return error.TypeError;
                    const object_value = try self.pop(&stack);
                    const property_value = if (std.mem.eql(u8, property_name, "prototype") and objects.findClosure(object_value) != null)
                        objects.ensureFunctionPrototype(object_value) catch return error.StackOverflow
                    else if (std.mem.eql(u8, property_name, "length")) length_property: {
                        const length = if (objects.findArray(object_value)) |array|
                            array.items.items.len
                        else if (stringBytes(function.*, objects, object_value)) |bytes|
                            bytes.len
                        else
                            break :length_property objects.getProperty(object_value, property_name) orelse
                                if (object_value.isNull() or object_value.isUndefined()) return error.TypeError else Value.undefined_value;
                        const as_i32 = std.math.cast(i32, length) orelse return error.IntegerOverflow;
                        break :length_property Value.fromInt(as_i32) orelse return error.IntegerOverflow;
                    } else self.resolveMethod(objects, object_value, property_name, &method_cache, &method_cache_next) orelse
                        if (object_value.isNull() or object_value.isUndefined()) {
                            std.debug.print("nullish receiver for field {s} at pc={d}\n", .{ property_name, pc });
                            return error.TypeError;
                        } else Value.undefined_value;
                    try self.push(&stack, function.max_stack, property_value);
                },
                .get_field2 => {
                    const property_index = try readU16(function.code, &pc);
                    if (property_index >= function.constants.len) return error.BadConstantIndex;
                    const property_name = findString(function.*, function.constants[property_index]) orelse return error.TypeError;
                    const object_value = try self.pop(&stack);
                    const method = self.resolveMethod(objects, object_value, property_name, &method_cache, &method_cache_next) orelse {
                        std.debug.print("missing method {s} receiver={x} at pc={d}\n", .{ property_name, object_value.raw(), pc });
                        return error.TypeError;
                    };
                    try self.push(&stack, function.max_stack, object_value);
                    try self.push(&stack, function.max_stack, method);
                },
                .put_field => {
                    const property_index = try readU16(function.code, &pc);
                    if (property_index >= function.constants.len) return error.BadConstantIndex;
                    const property_name = findString(function.*, function.constants[property_index]) orelse return error.TypeError;
                    const property_value = try self.pop(&stack);
                    const object_value = try self.pop(&stack);
                    if (std.mem.eql(u8, property_name, "length") and objects.findArray(object_value) != null) {
                        const length = property_value.asInt() orelse return error.TypeError;
                        if (length < 0) return error.TypeError;
                        objects.setArrayLength(object_value, @intCast(length)) catch return error.StackOverflow;
                        try self.push(&stack, function.max_stack, property_value);
                        continue;
                    }
                    objects.putProperty(object_value, property_name, property_value) catch {
                        return error.TypeError;
                    };
                    try self.push(&stack, function.max_stack, property_value);
                },
                .define_field => {
                    const property_index = try readU16(function.code, &pc);
                    if (property_index >= function.constants.len) return error.BadConstantIndex;
                    const property_name = findString(function.*, function.constants[property_index]) orelse return error.TypeError;
                    const property_value = try self.pop(&stack);
                    const object_value = try self.peek(&stack, 0);
                    objects.putProperty(object_value, property_name, property_value) catch return error.TypeError;
                },
                .fclosure, .fclosure8 => {
                    const index: usize = if (opcode == .fclosure) try readU16(function.code, &pc) else try readByte(function.code, &pc);
                    if (index >= function.functions.len) return error.InvalidFunctionIndex;
                    const function_pointer: *const FunctionBytecode = &function.functions[index];
                    const capture_count = if (function_pointer.external_variables.len != 0)
                        function_pointer.external_variables.len
                    else
                        function_pointer.capture_count;
                    const captures = self.allocator.alloc(*Cell, capture_count) catch return error.StackOverflow;
                    defer self.allocator.free(captures);
                    if (function_pointer.external_variables.len != 0) {
                        for (function_pointer.external_variables, 0..) |external, capture_index| {
                            captures[capture_index] = switch (external.kind) {
                                .global => (self.findGlobal(external.name) orelse return error.UnknownGlobal).cell,
                                .argument => if (external.index < arguments.len) arguments[external.index].captured orelse return error.BadArgumentIndex else return error.BadArgumentIndex,
                                .local => if (external.index < locals.len) locals[external.index].captured orelse return error.BadLocalIndex else return error.BadLocalIndex,
                                .outer => if (external.index < captured_cells.len) captured_cells[external.index] else return error.BadGlobalIndex,
                            };
                        }
                    } else if (index == 0 and function_pointer.code.ptr == function.code.ptr) {
                        for (function_pointer.capture_local_indices, 0..) |local_index, capture_index| {
                            if (local_index >= function.local_count) return error.BadLocalIndex;
                            captures[capture_index] = locals[local_index].captured orelse return error.BadLocalIndex;
                        }
                    } else {
                        for (function_pointer.capture_sources, 0..) |source, capture_index| {
                            if (source >= function.local_count) return error.BadLocalIndex;
                            captures[capture_index] = locals[source].captured orelse return error.BadLocalIndex;
                        }
                    }
                    const closure = objects.createClosure(@constCast(function_pointer), captures) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, closure);
                },
                .catch_value => {
                    const operand_pc = pc;
                    const relative = @as(i32, @bitCast(try readU32(function.code, &pc)));
                    const target = try branchTarget(function.code.len, operand_pc, relative);
                    const marker = Value.catchOffset(target) orelse return error.InvalidBranch;
                    try self.push(&stack, function.max_stack, marker);
                },
                .throw => {
                    const thrown = try self.pop(&stack);
                    if (!try self.dispatchException(&stack, function.max_stack, thrown, &pc)) {
                        if (frame_depth == 0) return .{ .thrown = thrown };
                        var unwind_depth = frame_depth;
                        while (unwind_depth > 0) {
                            frames[unwind_depth].deinit(self.allocator);
                            unwind_depth -= 1;
                            const caller = &frames[unwind_depth];
                            var caller_stack = caller.stack;
                            caller_stack.truncate(frames[unwind_depth + 1].caller_stack_len);
                            var caller_pc = caller.pc;
                            if (try self.dispatchException(&caller_stack, caller.function.max_stack, thrown, &caller_pc)) {
                                caller.stack = caller_stack;
                                caller.pc = caller_pc;
                                frame_depth = unwind_depth;
                                frame = caller;
                                function = frame.function;
                                stack = caller_stack;
                                pc = caller_pc;
                                locals = frame.local_bindings;
                                arguments = frame.argument_bindings;
                                captured_cells = frame.captured_cells;
                                continue :dispatch;
                            }
                            caller.stack = caller_stack;
                            caller.pc = caller_pc;
                        }
                        return .{ .thrown = thrown };
                    }
                },
                .undefined_value => try self.push(&stack, function.max_stack, Value.undefined_value),
                .null_value => try self.push(&stack, function.max_stack, Value.null_value),
                .push_false => try self.push(&stack, function.max_stack, Value.false_value),
                .push_true => try self.push(&stack, function.max_stack, Value.true_value),
                .push_this => try self.push(&stack, function.max_stack, frame.this_value),
                .push_global_this => try self.push(&stack, function.max_stack, self.global_this),
                .get_loc, .put_loc => {
                    const index = try readU16(function.code, &pc);
                    if (builtin.mode != .fast and index >= locals.len) return error.BadLocalIndex;
                    if (opcode == .get_loc) {
                        try self.push(&stack, function.max_stack, locals[index].load());
                    } else {
                        locals[index].store(try self.pop(&stack));
                    }
                },
                .get_loc8, .put_loc8 => {
                    const index = try readByte(function.code, &pc);
                    if (builtin.mode != .fast and index >= locals.len) return error.BadLocalIndex;
                    if (opcode == .get_loc8) {
                        try self.push(&stack, function.max_stack, locals[index].load());
                    } else {
                        locals[index].store(try self.pop(&stack));
                    }
                },
                .get_arg, .put_arg => {
                    const index = try readU16(function.code, &pc);
                    if (builtin.mode != .fast and index >= arguments.len) return error.BadArgumentIndex;
                    if (opcode == .get_arg) {
                        try self.push(&stack, function.max_stack, arguments[index].load());
                    } else {
                        arguments[index].store(try self.pop(&stack));
                    }
                },
                .arguments => {
                    const values = self.allocator.alloc(Value, frame.supplied_argument_count) catch return error.StackOverflow;
                    defer self.allocator.free(values);
                    for (values, 0..) |*value, index| value.* = arguments[index].load();
                    const array = objects.createArray(values) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, array);
                },
                .get_var_ref, .get_var_ref_nocheck => {
                    const index = try readU16(function.code, &pc);
                    if (builtin.mode != .fast and index >= captured_cells.len) return error.BadGlobalIndex;
                    const value = captured_cells[index].value;
                    if (value.isUninitialized() and opcode == .get_var_ref) return error.UnknownGlobal;
                    try self.push(&stack, function.max_stack, value);
                },
                .put_var_ref, .put_var_ref_nocheck => {
                    const index = try readU16(function.code, &pc);
                    if (builtin.mode != .fast and index >= captured_cells.len) return error.BadGlobalIndex;
                    const cell = captured_cells[index];
                    if (cell.value.isUninitialized() and opcode == .put_var_ref) return error.UnknownGlobal;
                    cell.value = try self.pop(&stack);
                },
                .drop => _ = try self.pop(&stack),
                .nip => {
                    const top = try self.pop(&stack);
                    _ = try self.pop(&stack);
                    try self.push(&stack, function.max_stack, top);
                },
                .dup => {
                    const top = try self.peek(&stack, 0);
                    try self.push(&stack, function.max_stack, top);
                },
                .dup1 => {
                    if (stack.len < 2) return error.StackUnderflow;
                    const lower = stack.storage[stack.len - 2];
                    const top = stack.storage[stack.len - 1];
                    try self.push(&stack, function.max_stack, top);
                    stack.storage[stack.len - 2] = lower;
                },
                .dup2 => {
                    if (stack.len < 2) return error.StackUnderflow;
                    const first = stack.storage[stack.len - 2];
                    const second = stack.storage[stack.len - 1];
                    try self.push(&stack, function.max_stack, first);
                    try self.push(&stack, function.max_stack, second);
                },
                .insert2 => {
                    if (stack.len < 2) return error.StackUnderflow;
                    const top = stack.storage[stack.len - 1];
                    try self.push(&stack, function.max_stack, top);
                    const start = stack.len - 3;
                    std.mem.swap(Value, &stack.storage[start], &stack.storage[start + 1]);
                },
                .insert3 => {
                    if (stack.len < 3) return error.StackUnderflow;
                    const top = stack.storage[stack.len - 1];
                    try self.push(&stack, function.max_stack, top);
                    const start = stack.len - 4;
                    const first = stack.storage[start];
                    const second = stack.storage[start + 1];
                    stack.storage[start] = top;
                    stack.storage[start + 1] = first;
                    stack.storage[start + 2] = second;
                    stack.storage[start + 3] = top;
                },
                .perm3 => {
                    if (stack.len < 3) return error.StackUnderflow;
                    const start = stack.len - 3;
                    std.mem.swap(Value, &stack.storage[start], &stack.storage[start + 1]);
                },
                .rot3l => {
                    if (stack.len < 3) return error.StackUnderflow;
                    const start = stack.len - 3;
                    const first = stack.storage[start];
                    stack.storage[start] = stack.storage[start + 1];
                    stack.storage[start + 1] = stack.storage[start + 2];
                    stack.storage[start + 2] = first;
                },
                .perm4 => {
                    if (stack.len < 4) return error.StackUnderflow;
                    const start = stack.len - 4;
                    const first = stack.storage[start];
                    stack.storage[start] = stack.storage[start + 2];
                    stack.storage[start + 2] = stack.storage[start + 1];
                    stack.storage[start + 1] = first;
                },
                .swap => {
                    if (stack.len < 2) return error.StackUnderflow;
                    std.mem.swap(Value, &stack.storage[stack.len - 1], &stack.storage[stack.len - 2]);
                },
                .add, .sub, .mul, .div, .mod, .eq, .neq, .strict_eq, .strict_neq, .lt, .lte, .gt, .gte, .and_op, .xor, .or_op, .shl, .sar, .shr, .in_operator, .instanceof => {
                    const right = try self.pop(&stack);
                    const left = try self.pop(&stack);
                    const result = switch (opcode) {
                        .add => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .add, left, right)
                        else if (left.asInt() != null and right.asInt() != null)
                            try binary(.add, left, right)
                        else
                            (try self.concatenate(function.*, objects, left, right)) orelse try binary(.add, left, right),
                        .sub => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .sub, left, right) else try binary(.sub, left, right),
                        .mul => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .mul, left, right) else try binary(.mul, left, right),
                        .div => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .div, left, right) else try binary(.div, left, right),
                        .mod => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .mod, left, right) else try binary(.mod, left, right),
                        .strict_eq => Value.boolean(self.strictlyEqual(function.*, objects, left, right)),
                        .strict_neq => Value.boolean(!self.strictlyEqual(function.*, objects, left, right)),
                        .eq => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .eq, left, right)
                        else
                            Value.boolean(self.equivalent(function.*, objects, left, right)),
                        .neq => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .neq, left, right)
                        else
                            Value.boolean(!self.equivalent(function.*, objects, left, right)),
                        .lt => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .lt, left, right)
                        else if (stringBytes(function.*, objects, left)) |left_string| if (stringBytes(function.*, objects, right)) |right_string| Value.boolean(std.mem.lessThan(u8, left_string, right_string)) else try binary(.lt, left, right) else try binary(.lt, left, right),
                        .lte => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .lte, left, right)
                        else if (stringBytes(function.*, objects, left)) |left_string| if (stringBytes(function.*, objects, right)) |right_string| Value.boolean(!std.mem.lessThan(u8, right_string, left_string)) else try binary(.lte, left, right) else try binary(.lte, left, right),
                        .gt => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .gt, left, right)
                        else if (stringBytes(function.*, objects, right)) |right_string| if (stringBytes(function.*, objects, left)) |left_string| Value.boolean(std.mem.lessThan(u8, right_string, left_string)) else try binary(.gt, left, right) else try binary(.gt, left, right),
                        .gte => if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null))
                            try binaryWithBigInt(self, objects, .gte, left, right)
                        else if (stringBytes(function.*, objects, left)) |left_string| if (stringBytes(function.*, objects, right)) |right_string| Value.boolean(!std.mem.lessThan(u8, left_string, right_string)) else try binary(.gte, left, right) else try binary(.gte, left, right),
                        .and_op => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .and_op, left, right) else try binary(.and_op, left, right),
                        .xor => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .xor, left, right) else try binary(.xor, left, right),
                        .or_op => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .or_op, left, right) else try binary(.or_op, left, right),
                        .shl => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .shl, left, right) else try binary(.shl, left, right),
                        .sar => if (left.isPointer() or right.isPointer()) try binaryWithBigInt(self, objects, .sar, left, right) else try binary(.sar, left, right),
                        .shr => try binary(.shr, left, right),
                        .in_operator => Value.boolean(objects.hasProperty(right, stringBytes(function.*, objects, left) orelse return error.TypeError)),
                        .instanceof => Value.boolean(switch (right.asShortFunction() orelse 0) {
                            65535 => objects.findObject(left) != null,
                            65534 => if (objects.findCollection(left)) |collection| collection.kind == .map else false,
                            65533 => if (objects.findCollection(left)) |collection| collection.kind == .set else false,
                            65532 => if (objects.findCollection(left)) |collection| collection.kind == .weak_map else false,
                            else => false,
                        }),
                        else => unreachable,
                    };
                    try self.push(&stack, function.max_stack, result);
                },
                .add_loc, .sub_loc => {
                    const index = try readU16(function.code, &pc);
                    if (builtin.mode != .fast and index >= locals.len) return error.BadLocalIndex;
                    const right = try self.pop(&stack);
                    const left = locals[index].load();
                    const result = if (opcode == .add_loc) add_result: {
                        if ((left.isPointer() or right.isPointer()) and (objects.findBigInt(left) != null or objects.findBigInt(right) != null)) {
                            break :add_result try binaryWithBigInt(self, objects, .add, left, right);
                        }
                        if (left.asInt() != null and right.asInt() != null) {
                            break :add_result try binary(.add, left, right);
                        }
                        break :add_result (try self.concatenate(function.*, objects, left, right)) orelse try binary(.add, left, right);
                    } else try binary(.sub, left, right);
                    locals[index].store(result);
                },
                .plus, .neg, .inc, .dec, .not, .lnot => {
                    const value = try self.peek(&stack, 0);
                    stack.storage[stack.len - 1] = try unary(opcode, value, function.*, objects);
                },
                .post_inc, .post_dec => {
                    const previous = try self.peek(&stack, 0);
                    const number = previous.asInt() orelse return error.TypeError;
                    const delta: i32 = if (opcode == .post_inc) 1 else -1;
                    const updated_number = std.math.add(i32, number, delta) catch return error.IntegerOverflow;
                    const updated = Value.fromInt(updated_number) orelse return error.IntegerOverflow;
                    try self.push(&stack, function.max_stack, updated);
                },
                .goto => {
                    const operand_pc = pc;
                    const relative = @as(i32, @bitCast(try readU32(function.code, &pc)));
                    pc = try branchTarget(function.code.len, operand_pc, relative);
                },
                .gosub => {
                    const operand_pc = pc;
                    const relative = @as(i32, @bitCast(try readU32(function.code, &pc)));
                    const return_address = Value.fromInt(std.math.cast(i32, pc) orelse return error.InvalidBranch) orelse return error.InvalidBranch;
                    try self.push(&stack, function.max_stack, return_address);
                    pc = try branchTarget(function.code.len, operand_pc, relative);
                },
                .ret => {
                    const return_address = (try self.pop(&stack)).asInt() orelse return error.InvalidBranch;
                    if (return_address < 0 or return_address >= function.code.len) return error.InvalidBranch;
                    pc = @intCast(return_address);
                },
                .if_false, .if_true => {
                    const operand_pc = pc;
                    const relative = @as(i32, @bitCast(try readU32(function.code, &pc)));
                    const condition = try self.pop(&stack);
                    const truthy = isTruthyWithObjects(function.*, objects, condition);
                    const should_branch = if (opcode == .if_true) truthy else !truthy;
                    if (should_branch) pc = try branchTarget(function.code.len, operand_pc, relative);
                },
                .call, .call_method => {
                    const call_flags = try readU16(function.code, &pc);
                    const argument_count_for_call: usize = call_flags & 0xffff;
                    const method_call = opcode == .call_method;
                    const prefix: usize = if (method_call) 2 else 1;
                    if (builtin.mode != .fast and stack.len < argument_count_for_call + prefix) return error.StackUnderflow;
                    const callee_position = stack.len - argument_count_for_call - prefix;
                    const callee_index = callee_position + @intFromBool(method_call);
                    const this_value = if (method_call) stack.storage[callee_position] else Value.undefined_value;
                    const callee_value = stack.storage[callee_index];
                    if (callee_value.asShortFunction()) |native_index| {
                        if (native_index >= self.native_functions.len) return error.NotCallable;
                        var native_context = NativeCallContext{
                            .objects = objects,
                            .host_context = self.native_context,
                            .vm = &self,
                            .execution_stats = if (collect_stats) stats else null,
                        };
                        const result = if (method_call) method_call_result: {
                            break :method_call_result self.callNativeMethod(
                                &native_context,
                                self.native_functions[native_index],
                                this_value,
                                stack.storage[callee_index + 1 .. stack.len],
                            ) catch |err| {
                                std.debug.print("native method index {d} failed: {s}\n", .{ native_index, @errorName(err) });
                                return error.NativeFunctionFailed;
                            };
                        } else self.native_functions[native_index](&native_context, stack.storage[callee_index + 1 .. stack.len]) catch |err| {
                            std.debug.print("native call {d} failed: {s}\n", .{ native_index, @errorName(err) });
                            return error.NativeFunctionFailed;
                        };
                        stack.truncate(callee_position);
                        try self.push(&stack, function.max_stack, result);
                        continue :dispatch;
                    }
                    const resolved_closure = objects.findClosure(callee_value);
                    if (resolved_closure == null and !method_call) {
                        if (objects.findBoundFunction(callee_value)) |bound| {
                            const bound_closure = objects.findClosure(bound.target) orelse return error.NotCallable;
                            const callee: *const FunctionBytecode = @ptrCast(@alignCast(bound_closure.function));
                            const current_arguments = stack.storage[callee_index + 1 .. stack.len];
                            const combined = self.allocator.alloc(Value, bound.arguments.items.len + current_arguments.len) catch return error.StackOverflow;
                            defer self.allocator.free(combined);
                            @memcpy(combined[0..bound.arguments.items.len], bound.arguments.items);
                            @memcpy(combined[bound.arguments.items.len..], current_arguments);
                            if (frame_depth + 1 >= frames.len) return error.MaxCallDepth;
                            frame.stack = stack;
                            frame.pc = pc;
                            frame_depth += 1;
                            active_frames = @max(active_frames, frame_depth + 1);
                            try frames[frame_depth].init(self, callee, combined, objects, bound_closure.captures, bound.this_value);
                            frames[frame_depth].caller_stack_len = callee_position;
                            frame = &frames[frame_depth];
                            function = frame.function;
                            stack = frame.stack;
                            pc = frame.pc;
                            locals = frame.local_bindings;
                            arguments = frame.argument_bindings;
                            captured_cells = frame.captured_cells;
                            continue :dispatch;
                        }
                    }
                    if (resolved_closure) |closure| {
                        const callee: *const FunctionBytecode = @ptrCast(@alignCast(closure.function));
                        if (frame_depth + 1 >= frames.len) return error.MaxCallDepth;
                        frame.stack = stack;
                        frame.pc = pc;
                        frame_depth += 1;
                        active_frames = @max(active_frames, frame_depth + 1);
                        if (method_call) {
                            try frames[frame_depth].init(self, callee, stack.storage[callee_index + 1 .. stack.len], objects, closure.captures, this_value);
                        } else {
                            try frames[frame_depth].init(self, callee, stack.storage[callee_index + 1 .. stack.len], objects, closure.captures, Value.undefined_value);
                        }
                        frames[frame_depth].caller_stack_len = callee_position;
                        frame = &frames[frame_depth];
                        function = frame.function;
                        stack = frame.stack;
                        pc = frame.pc;
                        locals = frame.local_bindings;
                        arguments = frame.argument_bindings;
                        captured_cells = frame.captured_cells;
                        continue :dispatch;
                    }
                    if (method_call) return error.NotCallable;
                    return error.NotCallable;
                },
                .call_spread => {
                    const arguments_value = try self.pop(&stack);
                    const argument_array = objects.findArray(arguments_value) orelse return error.TypeError;
                    const callee_value = try self.pop(&stack);
                    if (callee_value.asShortFunction()) |native_index| {
                        if (native_index >= self.native_functions.len) return error.NotCallable;
                        var native_context = NativeCallContext{
                            .objects = objects,
                            .host_context = self.native_context,
                            .vm = &self,
                            .execution_stats = if (collect_stats) stats else null,
                        };
                        const result = self.native_functions[native_index](&native_context, argument_array.items.items) catch |err| {
                            std.debug.print("native spread call {d} failed: {s}\n", .{ native_index, @errorName(err) });
                            return error.NativeFunctionFailed;
                        };
                        try self.push(&stack, function.max_stack, result);
                        continue :dispatch;
                    }
                    const closure = objects.findClosure(callee_value) orelse return error.NotCallable;
                    const callee: *const FunctionBytecode = @ptrCast(@alignCast(closure.function));
                    if (frame_depth + 1 >= frames.len) return error.MaxCallDepth;
                    frame.stack = stack;
                    frame.pc = pc;
                    frame_depth += 1;
                    active_frames = @max(active_frames, frame_depth + 1);
                    try frames[frame_depth].init(self, callee, argument_array.items.items, objects, closure.captures, Value.undefined_value);
                    frames[frame_depth].caller_stack_len = stack.len;
                    frame = &frames[frame_depth];
                    function = frame.function;
                    stack = frame.stack;
                    pc = frame.pc;
                    locals = frame.local_bindings;
                    arguments = frame.argument_bindings;
                    captured_cells = frame.captured_cells;
                    continue :dispatch;
                },
                .call_method_spread => {
                    const arguments_value = try self.pop(&stack);
                    const argument_array = objects.findArray(arguments_value) orelse return error.TypeError;
                    const callee_value = try self.pop(&stack);
                    const this_value = try self.pop(&stack);
                    const caller_stack_len = stack.len;
                    if (callee_value.asShortFunction()) |native_index| {
                        if (native_index >= self.native_functions.len) return error.NotCallable;
                        var native_context = NativeCallContext{
                            .objects = objects,
                            .host_context = self.native_context,
                            .vm = &self,
                            .execution_stats = if (collect_stats) stats else null,
                        };
                        const result = try self.callNativeMethod(
                            &native_context,
                            self.native_functions[native_index],
                            this_value,
                            argument_array.items.items,
                        );
                        try self.push(&stack, function.max_stack, result);
                        continue :dispatch;
                    }
                    const closure = objects.findClosure(callee_value) orelse return error.NotCallable;
                    const callee: *const FunctionBytecode = @ptrCast(@alignCast(closure.function));
                    if (frame_depth + 1 >= frames.len) return error.MaxCallDepth;
                    frame.stack = stack;
                    frame.pc = pc;
                    frame_depth += 1;
                    active_frames = @max(active_frames, frame_depth + 1);
                    try frames[frame_depth].init(self, callee, argument_array.items.items, objects, closure.captures, this_value);
                    frames[frame_depth].caller_stack_len = caller_stack_len;
                    frame = &frames[frame_depth];
                    function = frame.function;
                    stack = frame.stack;
                    pc = frame.pc;
                    locals = frame.local_bindings;
                    arguments = frame.argument_bindings;
                    captured_cells = frame.captured_cells;
                    continue :dispatch;
                },
                .get_array_el => {
                    const index_value = try self.pop(&stack);
                    const target = try self.pop(&stack);
                    if (objects.findArray(target)) |array| {
                        const index = index_value.asInt() orelse return error.TypeError;
                        if (index < 0 or index >= array.items.items.len) return error.TypeError;
                        try self.push(&stack, function.max_stack, array.items.items[@intCast(index)]);
                    } else if (stringBytes(function.*, objects, target)) |bytes| {
                        const index = index_value.asInt() orelse return error.TypeError;
                        const character = if (index >= 0 and index < bytes.len)
                            objects.createString(bytes[@intCast(index)..][0..1]) catch return error.StackOverflow
                        else
                            Value.undefined_value;
                        try self.push(&stack, function.max_stack, character);
                    } else if (stringBytes(function.*, objects, index_value)) |property_name| {
                        const property_value = objects.getProperty(target, property_name) orelse return error.TypeError;
                        try self.push(&stack, function.max_stack, property_value);
                    } else {
                        return error.TypeError;
                    }
                },
                .get_array_el2 => {
                    const index_value = try self.pop(&stack);
                    const target = try self.pop(&stack);
                    const property = if (objects.findArray(target)) |array| blk: {
                        const index = index_value.asInt() orelse return error.TypeError;
                        if (index < 0 or index >= array.items.items.len) return error.TypeError;
                        break :blk array.items.items[@intCast(index)];
                    } else if (stringBytes(function.*, objects, target)) |bytes| blk: {
                        const index = index_value.asInt() orelse return error.TypeError;
                        if (index < 0 or index >= bytes.len) break :blk Value.undefined_value;
                        break :blk objects.createString(bytes[@intCast(index)..][0..1]) catch return error.StackOverflow;
                    } else if (stringBytes(function.*, objects, index_value)) |property_name| blk: {
                        break :blk objects.getProperty(target, property_name) orelse return error.TypeError;
                    } else return error.TypeError;
                    try self.push(&stack, function.max_stack, target);
                    try self.push(&stack, function.max_stack, property);
                },
                .put_array_el => {
                    const value = try self.pop(&stack);
                    const index_value = try self.pop(&stack);
                    const target = try self.pop(&stack);
                    if (objects.findArray(target)) |array| {
                        const index = index_value.asInt() orelse return error.TypeError;
                        if (index < 0 or index > array.items.items.len) return error.TypeError;
                        if (index == array.items.items.len) {
                            array.items.append(self.allocator, value) catch return error.StackOverflow;
                        } else {
                            array.items.items[@intCast(index)] = value;
                        }
                    } else if (stringBytes(function.*, objects, index_value)) |property_name| {
                        objects.putProperty(target, property_name, value) catch return error.TypeError;
                    } else {
                        return error.TypeError;
                    }
                },
                .get_length, .get_length2 => {
                    const value = try self.pop(&stack);
                    const length_value = if (objects.findArray(value)) |array|
                        Value.fromInt(std.math.cast(i32, array.items.items.len) orelse return error.IntegerOverflow) orelse return error.IntegerOverflow
                    else if (objects.stringLength(function.*, value)) |string_length|
                        Value.fromInt(std.math.cast(i32, string_length) orelse return error.IntegerOverflow) orelse return error.IntegerOverflow
                    else
                        objects.getProperty(value, "length") orelse if (value.isNull() or value.isUndefined()) return error.TypeError else Value.undefined_value;
                    if (opcode == .get_length2) try self.push(&stack, function.max_stack, value);
                    try self.push(&stack, function.max_stack, length_value);
                },
                .typeof_value => {
                    const value = try self.pop(&stack);
                    const type_name: []const u8 = if (value.asInt() != null)
                        "number"
                    else if (objects.findBigInt(value) != null)
                        "bigint"
                    else if (value.asBool() != null)
                        "boolean"
                    else if (value.isUndefined())
                        "undefined"
                    else if (value.isNull())
                        "object"
                    else if (objects.findClosure(value) != null or value.asShortFunction() != null)
                        "function"
                    else if (objects.findString(value) != null)
                        "string"
                    else
                        "object";
                    const result = objects.createString(type_name) catch return error.StackOverflow;
                    try self.push(&stack, function.max_stack, result);
                },
                .get_loc0 => {
                    if (builtin.mode != .fast and locals.len <= 0) return error.BadLocalIndex;
                    try self.push(&stack, function.max_stack, locals[0].load());
                },
                .get_loc1 => {
                    if (builtin.mode != .fast and locals.len <= 1) return error.BadLocalIndex;
                    try self.push(&stack, function.max_stack, locals[1].load());
                },
                .get_loc2 => {
                    if (builtin.mode != .fast and locals.len <= 2) return error.BadLocalIndex;
                    try self.push(&stack, function.max_stack, locals[2].load());
                },
                .get_loc3 => {
                    if (builtin.mode != .fast and locals.len <= 3) return error.BadLocalIndex;
                    try self.push(&stack, function.max_stack, locals[3].load());
                },
                .put_loc0 => {
                    if (builtin.mode != .fast and locals.len <= 0) return error.BadLocalIndex;
                    locals[0].store(try self.pop(&stack));
                },
                .put_loc1 => {
                    if (builtin.mode != .fast and locals.len <= 1) return error.BadLocalIndex;
                    locals[1].store(try self.pop(&stack));
                },
                .put_loc2 => {
                    if (builtin.mode != .fast and locals.len <= 2) return error.BadLocalIndex;
                    locals[2].store(try self.pop(&stack));
                },
                .put_loc3 => {
                    if (builtin.mode != .fast and locals.len <= 3) return error.BadLocalIndex;
                    locals[3].store(try self.pop(&stack));
                },
                .get_arg0 => {
                    if (builtin.mode != .fast and arguments.len <= 0) return error.BadArgumentIndex;
                    try self.push(&stack, function.max_stack, arguments[0].load());
                },
                .get_arg1 => {
                    if (builtin.mode != .fast and arguments.len <= 1) return error.BadArgumentIndex;
                    try self.push(&stack, function.max_stack, arguments[1].load());
                },
                .get_arg2 => {
                    if (builtin.mode != .fast and arguments.len <= 2) return error.BadArgumentIndex;
                    try self.push(&stack, function.max_stack, arguments[2].load());
                },
                .get_arg3 => {
                    if (builtin.mode != .fast and arguments.len <= 3) return error.BadArgumentIndex;
                    try self.push(&stack, function.max_stack, arguments[3].load());
                },
                .put_arg0 => {
                    if (builtin.mode != .fast and arguments.len <= 0) return error.BadArgumentIndex;
                    arguments[0].store(try self.pop(&stack));
                },
                .put_arg1 => {
                    if (builtin.mode != .fast and arguments.len <= 1) return error.BadArgumentIndex;
                    arguments[1].store(try self.pop(&stack));
                },
                .put_arg2 => {
                    if (builtin.mode != .fast and arguments.len <= 2) return error.BadArgumentIndex;
                    arguments[2].store(try self.pop(&stack));
                },
                .put_arg3 => {
                    if (builtin.mode != .fast and arguments.len <= 3) return error.BadArgumentIndex;
                    arguments[3].store(try self.pop(&stack));
                },
                .return_value, .return_undef => {
                    const result = if (opcode == .return_value) try self.pop(&stack) else Value.undefined_value;
                    if (frame_depth == 0) return .{ .value = result };
                    frame.deinit(self.allocator);
                    frame_depth -= 1;
                    frame = &frames[frame_depth];
                    function = frame.function;
                    stack = frame.stack;
                    stack.truncate(frames[frame_depth + 1].caller_stack_len);
                    try self.push(&stack, function.max_stack, result);
                    frame.stack = stack;
                    pc = frame.pc;
                    locals = frame.local_bindings;
                    arguments = frame.argument_bindings;
                    captured_cells = frame.captured_cells;
                    continue :dispatch;
                },
                .await => {
                    if (comptime !async_enabled) {
                        last_opcode = null;
                        return error.AsyncRequired;
                    }
                    const awaited = try self.pop(&stack);
                    frame.stack = stack;
                    frame.pc = pc;
                    const state = if (continuation) |existing| existing else blk: {
                        const owned = self.allocator.create(Continuation) catch return error.StackOverflow;
                        const saved_captures = self.allocator.dupe(*Cell, root_captures) catch {
                            self.allocator.destroy(owned);
                            return error.StackOverflow;
                        };
                        const saved_frames = self.allocator.alloc(CallFrame, frames.len) catch {
                            self.allocator.free(saved_captures);
                            self.allocator.destroy(owned);
                            return error.StackOverflow;
                        };
                        @memcpy(saved_frames[0..active_frames], frames[0..active_frames]);
                        for (saved_frames[0..active_frames], 0..) |*saved_frame, index| {
                            saved_frame.rebindInlineStorage(&frames[index]);
                        }
                        owned.* = .{
                            .allocator = self.allocator,
                            .vm = self,
                            .root_function = root_function.*,
                            .frames = saved_frames,
                            .frame_depth = frame_depth,
                            .active_frames = active_frames,
                            .root_captures = saved_captures,
                            .objects = objects,
                            .awaited = awaited,
                        };
                        saved_frames[0].function = &owned.root_function;
                        saved_frames[0].captured_cells = owned.root_captures;
                        frames = saved_frames;
                        heap_frames = saved_frames;
                        owns_frames = false;
                        break :blk owned;
                    };
                    state.frames = frames;
                    state.frame_depth = frame_depth;
                    state.active_frames = active_frames;
                    state.awaited = awaited;
                    return .{ .suspended = .{ .continuation = state, .awaited = awaited } };
                },
                else => {
                    std.debug.print("unsupported upstream opcode {s} ({d}) in {s} at {d}\n", .{ @tagName(opcode), opcode_byte, function.name, pc - 1 });
                    return error.UnsupportedOpcode;
                },
            }
        }
    }

    inline fn push(self: VM, stack: *ExecutionStack, max_stack: usize, value: Value) Error!void {
        _ = self;
        if (builtin.mode == .fast) {
            stack.storage[stack.len] = value;
            stack.len += 1;
            return;
        }
        if (stack.len >= max_stack) return error.StackOverflow;
        try stack.push(value);
    }

    fn findGlobal(self: VM, name: []const u8) ?*GlobalBinding {
        for (self.global_bindings) |*binding| {
            if (std.mem.eql(u8, binding.name, name)) return binding;
        }
        return null;
    }

    fn localCapturedByChild(self: VM, function: FunctionBytecode, local_index: usize) bool {
        _ = self;
        for (function.functions) |child| {
            for (child.capture_sources) |source| {
                if (source == local_index) return true;
            }
            for (child.external_variables) |external| {
                if (external.kind == .local and external.index == local_index) return true;
            }
        }
        return false;
    }

    fn argumentCapturedByChild(self: VM, function: FunctionBytecode, argument_index: usize) bool {
        _ = self;
        for (function.functions) |child| {
            for (child.external_variables) |external| {
                if (external.kind == .argument and external.index == argument_index) return true;
            }
        }
        return false;
    }

    fn initializeCollection(
        self: VM,
        owner: FunctionBytecode,
        objects: *ObjectStore,
        target_value: Value,
        source_value: Value,
    ) Error!void {
        const target = objects.findCollection(target_value) orelse return error.TypeError;
        if (objects.findArray(source_value)) |array| {
            for (array.items.items) |item| try self.insertCollectionItem(owner, objects, target, item);
            return;
        }
        if (objects.findIterator(source_value)) |iterator| {
            for (iterator.values.items[iterator.index..]) |item| try self.insertCollectionItem(owner, objects, target, item);
            iterator.index = iterator.values.items.len;
            return;
        }
        if (objects.findCollection(source_value)) |source| {
            for (source.entries.items) |entry| {
                if (source.kind == .map) {
                    const pair = objects.createArray(&.{ entry.key, entry.value }) catch return error.StackOverflow;
                    try self.insertCollectionItem(owner, objects, target, pair);
                } else try self.insertCollectionItem(owner, objects, target, entry.key);
            }
            return;
        }
        if (stringBytes(owner, objects, source_value)) |bytes| {
            var offset: usize = 0;
            while (offset < bytes.len) {
                const width = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch return error.TypeError;
                const end = @min(offset + width, bytes.len);
                const character = objects.createString(bytes[offset..end]) catch return error.StackOverflow;
                try self.insertCollectionItem(owner, objects, target, character);
                offset = end;
            }
            return;
        }
        if (!source_value.isNull() and !source_value.isUndefined()) return error.TypeError;
    }

    fn insertCollectionItem(
        self: VM,
        owner: FunctionBytecode,
        objects: *ObjectStore,
        target: *@import("vm/objects.zig").CollectionObject,
        item: Value,
    ) Error!void {
        if (target.kind == .map or target.kind == .weak_map) {
            const pair = objects.findArray(item) orelse return error.TypeError;
            if (pair.items.items.len < 2) return error.TypeError;
            for (target.entries.items) |*entry| {
                if (self.strictlyEqual(owner, objects, entry.key, pair.items.items[0])) {
                    entry.value = pair.items.items[1];
                    return;
                }
            }
            target.entries.append(objects.allocator, .{ .key = pair.items.items[0], .value = pair.items.items[1] }) catch return error.StackOverflow;
            return;
        }
        for (target.entries.items) |entry| {
            if (self.strictlyEqual(owner, objects, entry.key, item)) return;
        }
        target.entries.append(objects.allocator, .{ .key = item, .value = item }) catch return error.StackOverflow;
    }

    fn resolveMethod(
        self: VM,
        objects: *ObjectStore,
        receiver: Value,
        name: []const u8,
        cache: *[8]?NativeMethodCacheEntry,
        cache_next: *usize,
    ) ?Value {
        if (objects.getOwnProperty(receiver, name)) |value| return value;
        const receiver_kind: ?NativeReceiver = if (objects.findArray(receiver) != null)
            .array
        else if (objects.findObject(receiver) != null)
            .object
        else if (objects.findString(receiver) != null)
            .string
        else if (objects.findCollection(receiver)) |collection| switch (collection.kind) {
            .map => .map,
            .set => .set,
            .weak_map => .map,
        } else if (objects.findIterator(receiver) != null)
            .iterator
        else if (objects.findRegex(receiver) != null)
            .regex
        else if (receiver.asInt() != null or receiver.asFloat64() != null)
            .number
        else
            null;
        if (receiver_kind) |kind| {
            for (cache) |entry| {
                if (entry) |cached| {
                    if (cached.receiver == kind and std.mem.eql(u8, cached.name, name)) {
                        return Value.shortFunction(cached.native_index);
                    }
                }
            }
            for (self.native_methods) |method| {
                if (method.receiver == kind and std.mem.eql(u8, method.name, name)) {
                    cache[cache_next.*] = .{ .receiver = kind, .name = name, .native_index = method.native_index };
                    cache_next.* = (cache_next.* + 1) % cache.len;
                    return Value.shortFunction(method.native_index);
                }
            }
        }
        return objects.getProperty(receiver, name);
    }

    fn callNativeMethod(
        self: VM,
        context: *NativeCallContext,
        function: NativeFunction,
        receiver: Value,
        arguments: []const Value,
    ) Error!Value {
        var inline_arguments: [8]Value = undefined;
        if (arguments.len < inline_arguments.len) {
            inline_arguments[0] = receiver;
            @memcpy(inline_arguments[1 .. arguments.len + 1], arguments);
            return function(context, inline_arguments[0 .. arguments.len + 1]) catch |err| {
                std.debug.print("native method failed: {s}\n", .{@errorName(err)});
                return error.NativeFunctionFailed;
            };
        }
        const result = self.allocator.alloc(Value, arguments.len + 1) catch return error.StackOverflow;
        defer self.allocator.free(result);
        result[0] = receiver;
        @memcpy(result[1..], arguments);
        return function(context, result) catch |err| {
            std.debug.print("native method failed: {s}\n", .{@errorName(err)});
            return error.NativeFunctionFailed;
        };
    }

    inline fn pop(self: VM, stack: *ExecutionStack) Error!Value {
        _ = self;
        if (builtin.mode == .fast) {
            stack.len -= 1;
            return stack.storage[stack.len];
        }
        return stack.pop();
    }

    inline fn peek(self: VM, stack: *const ExecutionStack, depth: usize) Error!Value {
        _ = self;
        if (builtin.mode == .fast) return stack.storage[stack.len - depth - 1];
        return stack.peek(depth);
    }

    fn resolveClosure(self: VM, owner: FunctionBytecode, value: Value) ?*const FunctionBytecode {
        _ = self;
        const address = @intFromPtr(value.asPointer() orelse return null);
        for (owner.functions) |*candidate| {
            if (@intFromPtr(candidate) == address) return candidate;
        }
        return null;
    }

    fn strictlyEqual(self: VM, owner: FunctionBytecode, objects: *ObjectStore, left: Value, right: Value) bool {
        _ = self;
        if (left.raw() == right.raw()) return true;
        if (objects.findBigInt(left)) |left_bigint| {
            const right_bigint = objects.findBigInt(right) orelse return false;
            return std.math.big.int.Managed.eql(left_bigint.value, right_bigint.value);
        }
        const left_string = stringBytes(owner, objects, left) orelse return false;
        const right_string = stringBytes(owner, objects, right) orelse return false;
        return std.mem.eql(u8, left_string, right_string);
    }

    fn equivalent(self: VM, owner: FunctionBytecode, objects: *ObjectStore, left: Value, right: Value) bool {
        if (self.strictlyEqual(owner, objects, left, right)) return true;
        if ((left.isNull() or left.isUndefined()) and (right.isNull() or right.isUndefined())) return true;
        if (left.asBool()) |boolean| return self.equivalent(owner, objects, Value.fromInt(if (boolean) 1 else 0).?, right);
        if (right.asBool()) |boolean| return self.equivalent(owner, objects, left, Value.fromInt(if (boolean) 1 else 0).?);
        return false;
    }

    fn concatenate(self: VM, function: FunctionBytecode, objects: *ObjectStore, left: Value, right: Value) Error!?Value {
        _ = self;
        const left_length = objects.stringLength(function, left);
        const right_length = objects.stringLength(function, right);
        if (left_length == null and right_length == null) return null;
        if (left_length != null and right_length != null) {
            const total = std.math.add(usize, left_length.?, right_length.?) catch return error.StackOverflow;
            if (total >= 32) {
                const left_object = objects.stringObject(function, left) catch null;
                const right_object = objects.stringObject(function, right) catch null;
                if (left_object != null and right_object != null) {
                    return objects.createConcat(left_object.?, right_object.?) catch error.StackOverflow;
                }
            }
        }
        const computed_left_length = try stringifiedLength(function, objects, left, 0);
        const computed_right_length = try stringifiedLength(function, objects, right, 0);
        const length = std.math.add(usize, computed_left_length, computed_right_length) catch return error.StackOverflow;
        const output = objects.allocator.alloc(u8, length) catch return error.StackOverflow;
        errdefer objects.allocator.free(output);
        var cursor: usize = 0;
        try writeStringified(function, objects, output, &cursor, left, 0);
        try writeStringified(function, objects, output, &cursor, right, 0);
        std.debug.assert(cursor == output.len);
        return objects.createStringOwned(output) catch error.StackOverflow;
    }

    fn dispatchException(self: VM, stack: *ExecutionStack, max_stack: usize, thrown: Value, pc: *usize) Error!bool {
        var index = stack.len;
        while (index > 0) {
            index -= 1;
            if (stack.storage[index].asCatchOffset()) |target| {
                stack.truncate(index);
                pc.* = target;
                try self.push(stack, max_stack, thrown);
                return true;
            }
        }
        return false;
    }
};

fn findString(function: FunctionBytecode, value: Value) ?[]const u8 {
    for (function.string_values) |string| {
        if (string.value.raw() == value.raw()) return string.bytes;
    }
    return null;
}

fn stringBytes(function: FunctionBytecode, objects: *ObjectStore, value: Value) ?[]const u8 {
    if (value.asStringCharacter()) |codepoint| {
        if (codepoint >= ascii_chars.len) return null;
        return ascii_chars[@intCast(codepoint)..][0..1];
    }
    if (!value.isPointer()) return null;
    return objects.findString(value) orelse findString(function, value);
}

fn makeAsciiChars() [128]u8 {
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    return bytes;
}

fn stringifiedLength(function: FunctionBytecode, objects: *ObjectStore, value: Value, depth: usize) VM.Error!usize {
    if (depth > 16) return error.TypeError;
    if (stringBytes(function, objects, value)) |bytes| return bytes.len;
    if (value.asInt()) |number| {
        var buffer: [32]u8 = undefined;
        return (std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return error.IntegerOverflow).len;
    }
    if (objects.findBigInt(value)) |bigint| {
        const text = bigint.value.toString(objects.allocator, 10, .lower) catch return error.StackOverflow;
        defer objects.allocator.free(text);
        return text.len;
    }
    if (value.asBool()) |boolean| return if (boolean) "true".len else "false".len;
    if (value.isNull()) return "null".len;
    if (value.isUndefined()) return "undefined".len;
    if (objects.findArray(value)) |array| {
        var length: usize = array.items.items.len -| 1;
        for (array.items.items) |item| {
            if (item.isNull() or item.isUndefined()) continue;
            length = std.math.add(usize, length, try stringifiedLength(function, objects, item, depth + 1)) catch return error.StackOverflow;
        }
        return length;
    }
    if (objects.findObject(value) != null or value.isPointer()) return "[object Object]".len;
    return error.TypeError;
}

fn writeStringified(function: FunctionBytecode, objects: *ObjectStore, output: []u8, cursor: *usize, value: Value, depth: usize) VM.Error!void {
    if (depth > 16) return error.TypeError;
    if (stringBytes(function, objects, value)) |bytes| {
        @memcpy(output[cursor.*..][0..bytes.len], bytes);
        cursor.* += bytes.len;
    } else if (value.asInt()) |number| {
        var buffer: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return error.IntegerOverflow;
        @memcpy(output[cursor.*..][0..formatted.len], formatted);
        cursor.* += formatted.len;
    } else if (objects.findBigInt(value)) |bigint| {
        const text = bigint.value.toString(objects.allocator, 10, .lower) catch return error.StackOverflow;
        defer objects.allocator.free(text);
        @memcpy(output[cursor.*..][0..text.len], text);
        cursor.* += text.len;
    } else if (value.asBool()) |boolean| {
        const bytes = if (boolean) "true" else "false";
        @memcpy(output[cursor.*..][0..bytes.len], bytes);
        cursor.* += bytes.len;
    } else if (value.isNull() or value.isUndefined()) {
        const bytes = if (value.isNull()) "null" else "undefined";
        @memcpy(output[cursor.*..][0..bytes.len], bytes);
        cursor.* += bytes.len;
    } else if (objects.findArray(value)) |array| {
        for (array.items.items, 0..) |item, index| {
            if (index != 0) {
                output[cursor.*] = ',';
                cursor.* += 1;
            }
            if (!item.isNull() and !item.isUndefined()) try writeStringified(function, objects, output, cursor, item, depth + 1);
        }
    } else if (objects.findObject(value) != null or value.isPointer()) {
        const bytes = "[object Object]";
        @memcpy(output[cursor.*..][0..bytes.len], bytes);
        cursor.* += bytes.len;
    } else {
        return error.TypeError;
    }
}

fn toBigInt(objects: *ObjectStore, function: FunctionBytecode, input: Value) VM.Error!Value {
    if (objects.findBigInt(input) != null) return input;
    if (stringBytes(function, objects, input)) |text| {
        return objects.createBigIntFromString(text) catch error.TypeError;
    }
    if (input.asInt()) |number| return objects.createBigIntFromInt(number) catch error.StackOverflow;
    if (input.asBool()) |boolean| return objects.createBigIntFromInt(@intFromBool(boolean)) catch error.StackOverflow;
    if (input.asFloat64()) |number| {
        if (!std.math.isFinite(number) or @trunc(number) != number or number < -9.22e18 or number >= 9.22e18) return error.TypeError;
        return objects.createBigIntFromInt(@intFromFloat(number)) catch error.StackOverflow;
    }
    return error.TypeError;
}

inline fn binaryWithBigInt(vm: VM, objects: *ObjectStore, comptime opcode: Opcode, left: Value, right: Value) VM.Error!Value {
    const left_bigint = objects.findBigInt(left);
    const right_bigint = objects.findBigInt(right);
    if (left_bigint == null and right_bigint == null) return binary(opcode, left, right);

    if (opcode == .strict_eq or opcode == .strict_neq) {
        const equal = if (left_bigint != null and right_bigint != null)
            std.math.big.int.Managed.eql(left_bigint.?.value, right_bigint.?.value)
        else
            false;
        return Value.boolean(if (opcode == .strict_eq) equal else !equal);
    }
    if (opcode == .eq or opcode == .neq) {
        var equal = false;
        if (left_bigint != null and right_bigint != null) {
            equal = std.math.big.int.Managed.eql(left_bigint.?.value, right_bigint.?.value);
        } else if (left_bigint) |bigint| {
            if (right.asInt()) |number| {
                var numeric = std.math.big.int.Managed.init(vm.allocator) catch return error.StackOverflow;
                defer numeric.deinit();
                numeric.set(number) catch return error.StackOverflow;
                equal = std.math.big.int.Managed.eql(bigint.value, numeric);
            }
        } else if (right_bigint) |bigint| {
            if (left.asInt()) |number| {
                var numeric = std.math.big.int.Managed.init(vm.allocator) catch return error.StackOverflow;
                defer numeric.deinit();
                numeric.set(number) catch return error.StackOverflow;
                equal = std.math.big.int.Managed.eql(bigint.value, numeric);
            }
        }
        return Value.boolean(if (opcode == .eq) equal else !equal);
    }

    const a = left_bigint orelse return error.TypeError;
    const b = right_bigint orelse return error.TypeError;
    if (opcode == .lt or opcode == .lte or opcode == .gt or opcode == .gte) {
        const order = std.math.big.int.Managed.order(a.value, b.value);
        return Value.boolean(switch (opcode) {
            .lt => order == .lt,
            .lte => order != .gt,
            .gt => order == .gt,
            .gte => order != .lt,
            else => unreachable,
        });
    }

    const result_value = objects.createBigInt() catch return error.StackOverflow;
    const result = &objects.findBigInt(result_value).?.value;
    switch (opcode) {
        .add => std.math.big.int.Managed.add(result, &a.value, &b.value) catch return error.StackOverflow,
        .sub => std.math.big.int.Managed.sub(result, &a.value, &b.value) catch return error.StackOverflow,
        .mul => std.math.big.int.Managed.mul(result, &a.value, &b.value) catch return error.StackOverflow,
        .div, .mod => {
            if (std.math.big.int.Managed.eqlZero(b.value)) return error.TypeError;
            var remainder = std.math.big.int.Managed.init(vm.allocator) catch return error.StackOverflow;
            defer remainder.deinit();
            std.math.big.int.Managed.divTrunc(result, &remainder, &a.value, &b.value) catch return error.StackOverflow;
            if (opcode == .mod) {
                result.deinit();
                result.* = remainder;
                remainder = std.math.big.int.Managed.init(vm.allocator) catch return error.StackOverflow;
            }
        },
        .and_op => std.math.big.int.Managed.bitAnd(result, &a.value, &b.value) catch return error.StackOverflow,
        .xor => std.math.big.int.Managed.bitXor(result, &a.value, &b.value) catch return error.StackOverflow,
        .or_op => std.math.big.int.Managed.bitOr(result, &a.value, &b.value) catch return error.StackOverflow,
        .shl, .sar => {
            const shift = b.value.toInt(usize) catch return error.TypeError;
            if (opcode == .shl) {
                std.math.big.int.Managed.shiftLeft(result, &a.value, shift) catch return error.StackOverflow;
            } else {
                std.math.big.int.Managed.shiftRight(result, &a.value, shift) catch return error.StackOverflow;
            }
        },
        else => return binary(opcode, left, right),
    }
    return result_value;
}

inline fn binary(comptime opcode: Opcode, left: Value, right: Value) VM.Error!Value {
    if (opcode == .strict_eq or opcode == .strict_neq) {
        const equal = left.raw() == right.raw();
        return Value.boolean(if (opcode == .strict_eq) equal else !equal);
    }
    if (opcode == .eq or opcode == .neq) {
        const equal = looselyEqual(left, right);
        return Value.boolean(if (opcode == .eq) equal else !equal);
    }
    if (opcode == .add or opcode == .sub) {
        if (((left.raw() | right.raw()) & 1) == 0) {
            const left_encoded: i32 = @bitCast(@as(u32, @truncate(left.raw())));
            const right_encoded: i32 = @bitCast(@as(u32, @truncate(right.raw())));
            const result = if (opcode == .add)
                @addWithOverflow(left_encoded, right_encoded)
            else
                @subWithOverflow(left_encoded, right_encoded);
            if (result[1] != 0) return error.IntegerOverflow;
            return .{ .bits = @as(u32, @bitCast(result[0])) };
        }
    }
    if (opcode == .lt or opcode == .lte or opcode == .gt or opcode == .gte) {
        if (((left.raw() | right.raw()) & 1) == 0) {
            const left_encoded: i32 = @bitCast(@as(u32, @truncate(left.raw())));
            const right_encoded: i32 = @bitCast(@as(u32, @truncate(right.raw())));
            const comparison = switch (opcode) {
                .lt => left_encoded < right_encoded,
                .lte => left_encoded <= right_encoded,
                .gt => left_encoded > right_encoded,
                .gte => left_encoded >= right_encoded,
                else => unreachable,
            };
            return Value.boolean(comparison);
        }
        const left_number = numericValue(left) orelse return error.TypeError;
        const right_number = numericValue(right) orelse return error.TypeError;
        return Value.boolean(switch (opcode) {
            .lt => left_number < right_number,
            .lte => left_number <= right_number,
            .gt => left_number > right_number,
            .gte => left_number >= right_number,
            else => unreachable,
        });
    }
    if (opcode == .and_op or opcode == .xor or opcode == .or_op or opcode == .shl or opcode == .sar or opcode == .shr) {
        const a = toInt32(left) orelse return error.TypeError;
        const b = toInt32(right) orelse return error.TypeError;
        return switch (opcode) {
            .and_op => numberFromInt32(a & b),
            .xor => numberFromInt32(a ^ b),
            .or_op => numberFromInt32(a | b),
            .shl => blk: {
                const shift: u5 = @truncate(@as(u32, @bitCast(b)) & 31);
                const shifted: i32 = @bitCast(@as(u32, @bitCast(a)) << shift);
                break :blk numberFromInt32(shifted);
            },
            .sar => blk: {
                const shift: u5 = @truncate(@as(u32, @bitCast(b)) & 31);
                break :blk numberFromInt32(a >> shift);
            },
            .shr => blk: {
                const shift: u5 = @truncate(@as(u32, @bitCast(b)) & 31);
                const shifted = @as(u32, @bitCast(a)) >> shift;
                break :blk if (shifted <= Value.short_int_max)
                    Value.fromInt(@intCast(shifted)).?
                else
                    Value.fromFloat64(@floatFromInt(shifted));
            },
            else => unreachable,
        };
    }
    const a = left.asInt() orelse return error.TypeError;
    const b = right.asInt() orelse return error.TypeError;
    return switch (opcode) {
        .add => Value.fromInt(std.math.add(i32, a, b) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        .sub => Value.fromInt(std.math.sub(i32, a, b) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        .mul => Value.fromInt(std.math.mul(i32, a, b) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        .div => blk: {
            if (b == 0) return error.DivisionByZero;
            const result = std.math.divTrunc(i32, a, b) catch return error.IntegerOverflow;
            break :blk Value.fromInt(result) orelse error.IntegerOverflow;
        },
        .mod => blk: {
            if (b == 0) return error.DivisionByZero;
            const result = std.math.rem(i32, a, b) catch return error.IntegerOverflow;
            break :blk Value.fromInt(result) orelse error.IntegerOverflow;
        },
        .lt => Value.boolean(a < b),
        .lte => Value.boolean(a <= b),
        .gt => Value.boolean(a > b),
        .gte => Value.boolean(a >= b),
        else => error.UnsupportedOpcode,
    };
}

fn numericValue(value: Value) ?f64 {
    if (value.asInt()) |number| return @floatFromInt(number);
    if (value.asBool()) |boolean| return if (boolean) 1 else 0;
    if (value.isNull()) return 0;
    if (value.isUndefined()) return std.math.nan(f64);
    return value.asFloat64();
}

fn toInt32(value: Value) ?i32 {
    if (value.asInt()) |number| return number;
    if (value.asBool()) |boolean| return if (boolean) 1 else 0;
    if (value.isNull() or value.isUndefined()) return 0;
    if (value.asFloat64()) |number| {
        if (!std.math.isFinite(number) or number == 0) return 0;
        const truncated = @trunc(number);
        if (truncated < -9.22e18 or truncated > 9.22e18) return null;
        const wide: i64 = @intFromFloat(truncated);
        return @bitCast(@as(u32, @truncate(@as(u64, @bitCast(wide)))));
    }
    return null;
}

fn numberFromInt32(value: i32) Value {
    return Value.fromInt(value) orelse Value.fromFloat64(@floatFromInt(value));
}

fn looselyEqual(left: Value, right: Value) bool {
    if ((left.isNull() or left.isUndefined()) and (right.isNull() or right.isUndefined())) return true;
    if (left.raw() == right.raw()) return true;

    if (left.asBool()) |boolean| {
        const numeric = Value.fromInt(if (boolean) 1 else 0).?;
        return looselyEqual(numeric, right);
    }
    if (right.asBool()) |boolean| {
        const numeric = Value.fromInt(if (boolean) 1 else 0).?;
        return looselyEqual(left, numeric);
    }
    return false;
}

fn unary(opcode: Opcode, value: Value, function: FunctionBytecode, objects: *ObjectStore) VM.Error!Value {
    if (opcode == .lnot) return Value.boolean(!isTruthyWithObjects(function, objects, value));
    if (opcode == .not) return Value.fromInt(~(value.asInt() orelse return error.TypeError)) orelse error.IntegerOverflow;
    if (objects.findBigInt(value)) |bigint| {
        if (opcode != .neg) return error.TypeError;
        const result_value = objects.createBigInt() catch return error.StackOverflow;
        const result = objects.findBigInt(result_value).?;
        result.value.copy(bigint.value.toConst()) catch return error.StackOverflow;
        result.value.negate();
        return result_value;
    }
    if (value.asFloat64()) |number| {
        return switch (opcode) {
            .plus => value,
            .neg => Value.fromFloat64(-number),
            .inc => Value.fromFloat64(number + 1),
            .dec => Value.fromFloat64(number - 1),
            else => error.UnsupportedOpcode,
        };
    }
    const number = value.asInt() orelse {
        return error.TypeError;
    };
    return switch (opcode) {
        .plus => value,
        .neg => Value.fromInt(std.math.negate(number) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        .inc => Value.fromInt(std.math.add(i32, number, 1) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        .dec => Value.fromInt(std.math.sub(i32, number, 1) catch return error.IntegerOverflow) orelse error.IntegerOverflow,
        else => error.UnsupportedOpcode,
    };
}

pub fn isTruthy(value: Value) bool {
    if (value.asInt()) |number| return number != 0;
    if (value.asFloat64()) |number| return number != 0 and !std.math.isNan(number);
    if (value.asBool()) |boolean| return boolean;
    return !value.isNull() and !value.isUndefined();
}

fn isTruthyWithObjects(function: FunctionBytecode, objects: *ObjectStore, value: Value) bool {
    if (!value.isPointer() and value.asStringCharacter() == null) return isTruthy(value);
    if (stringBytes(function, objects, value)) |bytes| return bytes.len != 0;
    if (objects.findBigInt(value)) |bigint| return !std.math.big.int.Managed.eqlZero(bigint.value);
    return isTruthy(value);
}

test "string lookup resolves static and dynamic strings but skips immediate values" {
    var objects = ObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    var static_storage: usize align(8) = 0;
    const static_value = Value.fromPointer(@ptrCast(&static_storage));
    const static_strings = [_]StringValue{.{ .value = static_value, .bytes = "static" }};
    const function = FunctionBytecode{ .code = &.{}, .string_values = &static_strings };

    try std.testing.expect(stringBytes(function, &objects, Value.fromInt(7).?) == null);
    try std.testing.expect(stringBytes(function, &objects, Value.true_value) == null);
    try std.testing.expectEqualStrings("static", stringBytes(function, &objects, static_value).?);
    const dynamic_value = try objects.createString("dynamic");
    try std.testing.expectEqualStrings("dynamic", stringBytes(function, &objects, dynamic_value).?);
}

test "truthiness handles immediate values and strings" {
    var objects = ObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    const function = FunctionBytecode{ .code = &.{} };

    try std.testing.expect(!isTruthyWithObjects(function, &objects, Value.fromInt(0).?));
    try std.testing.expect(isTruthyWithObjects(function, &objects, Value.fromInt(1).?));
    try std.testing.expect(!isTruthyWithObjects(function, &objects, Value.false_value));
    try std.testing.expect(isTruthyWithObjects(function, &objects, Value.true_value));
    try std.testing.expect(!isTruthyWithObjects(function, &objects, try objects.createString("")));
    try std.testing.expect(isTruthyWithObjects(function, &objects, try objects.createString("x")));
}

fn branchTarget(code_len: usize, operand_pc: usize, relative: i32) VM.Error!usize {
    if (builtin.mode == .fast) {
        return if (relative < 0)
            operand_pc - @as(usize, @intCast(-@as(i64, relative)))
        else
            operand_pc + @as(usize, @intCast(relative));
    }
    const base: i64 = @intCast(operand_pc);
    const target = base + relative;
    if (target < 0 or target >= code_len) return error.InvalidBranch;
    return @intCast(target);
}

fn readByte(code: []const u8, pc: *usize) VM.Error!u8 {
    if (builtin.mode != .fast and pc.* >= code.len) return error.TruncatedBytecode;
    const byte = code[pc.*];
    pc.* += 1;
    return byte;
}

fn readU16(code: []const u8, pc: *usize) VM.Error!u16 {
    if (builtin.mode != .fast and code.len -| pc.* < 2) return error.TruncatedBytecode;
    const value = std.mem.readInt(u16, code[pc.*..][0..2], .little);
    pc.* += 2;
    return value;
}

fn readU32(code: []const u8, pc: *usize) VM.Error!u32 {
    if (builtin.mode != .fast and code.len -| pc.* < 4) return error.TruncatedBytecode;
    const value = std.mem.readInt(u32, code[pc.*..][0..4], .little);
    pc.* += 4;
    return value;
}

test "zRun bytecode push, arithmetic, and return execute in Zig" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
}

test "zRun suspends an execution at await and resumes it with the host result" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_i8), 7,
        @intFromEnum(Opcode.await),   @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.add),     @intFromEnum(Opcode.return_value),
    };
    var objects = ObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = std.testing.allocator, .objects = &objects };
    var outcome = try vm.executeAsync(.{ .code = &code });
    const suspended = switch (outcome) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    try std.testing.expectEqual(@as(?i32, 7), suspended.awaited.asInt());

    outcome = try vm.resumeExecution(suspended.continuation, .{ .resolved = Value.fromInt(41).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "synchronous execution rejects await without leaking its continuation" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.await),
        @intFromEnum(Opcode.return_value),
    };
    var objects = ObjectStore.init(std.testing.allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = std.testing.allocator, .objects = &objects };
    try std.testing.expectError(error.AsyncRequired, vm.execute(.{ .code = &code }));
}

test "zRun VM pumps host events on its execution thread" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    var pump_count: usize = 0;
    const result = try (VM{
        .allocator = std.testing.allocator,
        .event_pump = countPumpedEvents,
        .event_context = @ptrCast(&pump_count),
    }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
    try std.testing.expectEqual(@as(usize, code.len), pump_count);
}

fn countPumpedEvents(context: *anyopaque, _: *const VM, _: *ObjectStore) anyerror!void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

test "zRun signed immediate operands decode little endian" {
    const code = [_]u8{ @intFromEnum(Opcode.push_i16), 0xfe, 0xff, @intFromEnum(Opcode.return_value) };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, -2), result.asInt().?);
}

test "zRun conditional branch uses operand-relative byte offsets" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_false),
        @intFromEnum(Opcode.if_false),
        6,
        0,
        0,
        0,
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.return_value),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 2), result.asInt().?);
}

test "zRun compact local opcodes store and load frame locals" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_5),
        @intFromEnum(Opcode.put_loc2),
        @intFromEnum(Opcode.get_loc2),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .local_count = 3 });
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
}

test "zRun argument opcodes read frame arguments" {
    const code = [_]u8{ @intFromEnum(Opcode.get_arg0), @intFromEnum(Opcode.return_value) };
    const args = [_]Value{Value.fromInt(17).?};
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .arguments = &args });
    try std.testing.expectEqual(@as(i32, 17), result.asInt().?);
}

test "zRun byte-sized local opcodes decode indices" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_6),
        @intFromEnum(Opcode.put_loc8),
        4,
        @intFromEnum(Opcode.get_loc8),
        4,
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .local_count = 5 });
    try std.testing.expectEqual(@as(i32, 6), result.asInt().?);
}

test "zRun dup2 preserves both stack values" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.dup2),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 8), result.asInt().?);
}

test "zRun insert and permutation opcodes preserve source stack order" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.perm3),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.insert2),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 3), result.asInt().?);
}

test "zRun insert3 and perm4 preserve exact stack order" {
    const insert_code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.insert3),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.return_value),
    };
    const insert_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &insert_code });
    try std.testing.expectEqual(@as(i32, 3), insert_result.asInt().?);

    const permute_code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.push_4),
        @intFromEnum(Opcode.perm4),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.drop),
        @intFromEnum(Opcode.return_value),
    };
    const permute_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &permute_code });
    try std.testing.expectEqual(@as(i32, 1), permute_result.asInt().?);
}

test "zRun push_const8 loads a constant using its compact index" {
    const code = [_]u8{ @intFromEnum(Opcode.push_const8), 1, @intFromEnum(Opcode.return_value) };
    const constants = [_]Value{ Value.fromInt(11).?, Value.fromInt(29).? };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .constants = &constants });
    try std.testing.expectEqual(@as(i32, 29), result.asInt().?);
}

test "zRun dup1 duplicates the lower value while preserving top order" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.dup1),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 4), result.asInt().?);
}

test "zRun post increment and decrement leave old and new values on stack" {
    const increment_code = [_]u8{
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.post_inc),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const increment_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &increment_code });
    try std.testing.expectEqual(@as(i32, 7), increment_result.asInt().?);

    const decrement_code = [_]u8{
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.post_dec),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const decrement_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &decrement_code });
    try std.testing.expectEqual(@as(i32, 5), decrement_result.asInt().?);
}

test "zRun shifts mask the shift count to five bits" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.shl),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.push_i8),
        33,
        @intFromEnum(Opcode.sar),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.push_4),
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.shr),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 11), result.asInt().?);
}

test "zRun loose equality coerces booleans and matches null with undefined" {
    const boolean_code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_true),
        @intFromEnum(Opcode.eq),
        @intFromEnum(Opcode.return_value),
    };
    const boolean_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &boolean_code });
    try std.testing.expectEqual(true, boolean_result.asBool().?);

    const null_code = [_]u8{
        @intFromEnum(Opcode.null_value),
        @intFromEnum(Opcode.undefined_value),
        @intFromEnum(Opcode.eq),
        @intFromEnum(Opcode.return_value),
    };
    const null_result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &null_code });
    try std.testing.expectEqual(true, null_result.asBool().?);
}

test "zRun loose inequality inverts primitive equality" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.push_true),
        @intFromEnum(Opcode.neq),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(false, result.asBool().?);
}

test "zRun closure bytecode calls a nested function with frame arguments" {
    const child_code = [_]u8{
        @intFromEnum(Opcode.get_arg0),
        @intFromEnum(Opcode.push_2),
        @intFromEnum(Opcode.add),
        @intFromEnum(Opcode.return_value),
    };
    const child = FunctionBytecode{ .code = &child_code, .argument_count = 1 };
    const functions = [_]FunctionBytecode{child};
    const code = [_]u8{
        @intFromEnum(Opcode.fclosure),
        0,
        0,
        @intFromEnum(Opcode.push_3),
        @intFromEnum(Opcode.call),
        1,
        0,
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .functions = &functions });
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
}

test "zRun compact closure opcode calls a zero-argument function" {
    const child_code = [_]u8{ @intFromEnum(Opcode.push_7), @intFromEnum(Opcode.return_value) };
    const child = FunctionBytecode{ .code = &child_code };
    const functions = [_]FunctionBytecode{child};
    const code = [_]u8{
        @intFromEnum(Opcode.fclosure8),
        0,
        @intFromEnum(Opcode.call),
        0,
        0,
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .functions = &functions });
    try std.testing.expectEqual(@as(i32, 7), result.asInt().?);
}

test "zRun call rejects non-function values without dereferencing them" {
    const code = [_]u8{
        @intFromEnum(Opcode.push_1),
        @intFromEnum(Opcode.call),
        0,
        0,
        @intFromEnum(Opcode.return_value),
    };
    try std.testing.expectError(error.NotCallable, (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code }));
}

test "zRun nested function calls stop at the recursion limit" {
    const code = [_]u8{
        @intFromEnum(Opcode.fclosure8),
        0,
        @intFromEnum(Opcode.call),
        0,
        0,
        @intFromEnum(Opcode.return_value),
    };
    var functions: [1]FunctionBytecode = undefined;
    functions[0] = .{ .code = &code, .functions = &functions };
    try std.testing.expectError(error.MaxCallDepth, (VM{ .allocator = std.testing.allocator }).execute(functions[0]));
}

test "zRun catch handler receives a thrown value in the same frame" {
    const code = [_]u8{
        @intFromEnum(Opcode.catch_value),
        7,
        0,
        0,
        0,
        @intFromEnum(Opcode.push_7),
        @intFromEnum(Opcode.throw),
        @intFromEnum(Opcode.return_undef),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code });
    try std.testing.expectEqual(@as(i32, 7), result.asInt().?);
}

test "zRun thrown values propagate through nested calls into caller catch" {
    const child_code = [_]u8{ @intFromEnum(Opcode.push_5), @intFromEnum(Opcode.throw) };
    const child = FunctionBytecode{ .code = &child_code };
    const functions = [_]FunctionBytecode{child};
    const code = [_]u8{
        @intFromEnum(Opcode.catch_value),
        10,
        0,
        0,
        0,
        @intFromEnum(Opcode.fclosure8),
        0,
        @intFromEnum(Opcode.call),
        0,
        0,
        @intFromEnum(Opcode.return_undef),
        @intFromEnum(Opcode.return_value),
    };
    const result = try (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code, .functions = &functions });
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
}

test "zRun uncaught throw reports an exception outcome" {
    const code = [_]u8{ @intFromEnum(Opcode.push_3), @intFromEnum(Opcode.throw) };
    try std.testing.expectError(error.UncaughtException, (VM{ .allocator = std.testing.allocator }).execute(.{ .code = &code }));
}

test "zRun execution outcome preserves the uncaught exception value" {
    const code = [_]u8{ @intFromEnum(Opcode.push_4), @intFromEnum(Opcode.throw) };
    const outcome = try (VM{ .allocator = std.testing.allocator }).executeOutcome(.{ .code = &code });
    switch (outcome) {
        .value => return error.TestUnexpectedResult,
        .thrown => |value| try std.testing.expectEqual(@as(i32, 4), value.asInt().?),
        .suspended => |suspension| {
            suspension.continuation.deinit();
            return error.TestUnexpectedResult;
        },
    }
}

test "zRun VM calls an externally supplied native function module" {
    const constants = [_]Value{Value.shortFunction(0)};
    const code = [_]u8{
        @intFromEnum(Opcode.push_const8), 0,
        @intFromEnum(Opcode.push_i8),     9,
        @intFromEnum(Opcode.call),        1,
        0,                               @intFromEnum(Opcode.return_value),
    };
    const natives = [_]VM.NativeFunction{nativeDouble};
    const function = FunctionBytecode{ .code = &code, .constants = &constants };
    const result = try (VM{ .allocator = std.testing.allocator, .native_functions = &natives }).execute(function);
    try std.testing.expectEqual(@as(?i32, 18), result.asInt());
}

fn nativeDouble(_: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const number = arguments[0].asInt() orelse return error.ExpectedInteger;
    return Value.fromInt(number * 2) orelse error.IntegerOverflow;
}
