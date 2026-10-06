const std = @import("std");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;

fn receiver(context: *VM.NativeCallContext, arguments: []const Value) anyerror!*@import("../vm/objects.zig").ArrayObject {
    if (arguments.len == 0) return error.MissingArrayReceiver;
    const array = context.objects.findArray(arguments[0]) orelse return error.InvalidArrayReceiver;
    try array.materialize(context.objects.allocator);
    return array;
}

const ResolvedCallback = union(enum) {
    closure: *@import("../vm/objects.zig").ClosureObject,
    native: usize,
    unsupported_bound_function,
};

fn callbackValue(context: *VM.NativeCallContext, arguments: []const Value) anyerror!ResolvedCallback {
    if (arguments.len < 2) return error.MissingCallback;
    const callable = arguments[1];
    if (context.objects.findClosure(callable)) |closure| return .{ .closure = closure };
    if (context.objects.findBoundFunction(callable) != null) return .unsupported_bound_function;
    if (callable.asShortFunction()) |index| {
        if (index < context.vm.native_functions.len) return .{ .native = index };
    }
    return error.NotCallable;
}

fn callback(comptime profiled: bool, context: *VM.NativeCallContext, callable: ResolvedCallback, item: Value, index: usize, accumulator: ?Value) anyerror!Value {
    const numeric_index = Value.fromInt(std.math.cast(i32, index) orelse return error.IndexOutOfRange) orelse return error.IndexOutOfRange;
    const call_arguments = if (accumulator) |initial| [3]Value{ initial, item, numeric_index } else [3]Value{ item, numeric_index, Value.undefined_value };
    const arguments = call_arguments[0..if (accumulator == null) 2 else 3];
    return switch (callable) {
        .closure => |closure| if (profiled)
            context.vm.invokeClosureWithStats(context.objects, closure, arguments, context.execution_stats orelse return error.MissingExecutionStats)
        else
            context.vm.invokeClosure(context.objects, closure, arguments),
        .native => |native_index| context.vm.native_functions[native_index](context, arguments),
        .unsupported_bound_function => error.NotCallable,
    };
}

pub fn map(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mapImpl(false, context, arguments);
}

pub fn mapProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mapImpl(true, context, arguments);
}

fn mapImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const mapper = try callbackValue(context, arguments);
    const result_value = try context.objects.createArrayWithCapacity(source.items.items.len);
    const result = context.objects.findArray(result_value).?;
    for (source.items.items, 0..) |item, index| {
        result.items.appendAssumeCapacity(try callback(profiled, context, mapper, item, index, null));
    }
    return result_value;
}

pub fn filter(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return filterImpl(false, context, arguments);
}

pub fn filterProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return filterImpl(true, context, arguments);
}

fn filterImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const predicate = try callbackValue(context, arguments);
    const result_value = try context.objects.createArrayWithCapacity(source.items.items.len);
    const result = context.objects.findArray(result_value).?;
    for (source.items.items, 0..) |item, index| {
        if (truthy(try callback(profiled, context, predicate, item, index, null))) {
            result.items.appendAssumeCapacity(item);
        }
    }
    return result_value;
}

pub fn find(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return findImpl(false, context, arguments);
}

pub fn findProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return findImpl(true, context, arguments);
}

fn findImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const predicate = try callbackValue(context, arguments);
    for (source.items.items, 0..) |item, index| {
        if (truthy(try callback(profiled, context, predicate, item, index, null))) return item;
    }
    return Value.undefined_value;
}

pub fn some(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return someImpl(false, context, arguments);
}

pub fn someProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return someImpl(true, context, arguments);
}

fn someImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const predicate = try callbackValue(context, arguments);
    for (source.items.items, 0..) |item, index| {
        if (truthy(try callback(profiled, context, predicate, item, index, null))) return Value.true_value;
    }
    return Value.false_value;
}

pub fn flatMap(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return flatMapImpl(false, context, arguments);
}

pub fn flatMapProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return flatMapImpl(true, context, arguments);
}

fn flatMapImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const mapper = try callbackValue(context, arguments);
    const result_value = try context.objects.createArrayWithCapacity(source.items.items.len);
    const result = context.objects.findArray(result_value).?;
    for (source.items.items, 0..) |item, index| {
        const mapped = try callback(profiled, context, mapper, item, index, null);
        if (context.objects.findArray(mapped)) |array| {
            try array.materialize(context.objects.allocator);
            try result.items.appendSlice(context.objects.allocator, array.items.items);
        } else {
            try result.items.append(context.objects.allocator, mapped);
        }
    }
    return result_value;
}

pub fn reduce(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return reduceImpl(false, context, arguments);
}

pub fn reduceProfiled(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return reduceImpl(true, context, arguments);
}

fn reduceImpl(comptime profiled: bool, context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const reducer = try callbackValue(context, arguments);
    var index: usize = 0;
    var accumulator: Value = undefined;
    if (arguments.len > 2) {
        accumulator = arguments[2];
    } else {
        if (source.items.items.len == 0) return error.EmptyArray;
        accumulator = source.items.items[0];
        index = 1;
    }
    while (index < source.items.items.len) : (index += 1) {
        accumulator = try callback(profiled, context, reducer, source.items.items[index], index, accumulator);
    }
    return accumulator;
}

pub fn includes(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    if (arguments.len < 2) return Value.false_value;
    for (source.items.items) |item| if (item.raw() == arguments[1].raw()) return Value.true_value;
    return Value.false_value;
}

pub fn concat(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    var length = source.items.items.len;
    for (arguments[1..]) |argument| {
        length = std.math.add(usize, length, if (context.objects.findArray(argument)) |array|
            array.len()
        else
            1) catch return error.ArrayTooLarge;
    }

    const result_value = try context.objects.createArrayWithCapacity(length);
    const result = context.objects.findArray(result_value).?;
    try result.items.appendSlice(context.objects.allocator, source.items.items);
    for (arguments[1..]) |argument| {
        if (context.objects.findArray(argument)) |array| {
            try array.materialize(context.objects.allocator);
            try result.items.appendSlice(context.objects.allocator, array.items.items);
        } else {
            try result.items.append(context.objects.allocator, argument);
        }
    }
    return result_value;
}

pub fn shift(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    if (source.items.items.len == 0) return Value.undefined_value;
    const first = source.items.items[0];
    std.mem.copyForwards(Value, source.items.items[0 .. source.items.items.len - 1], source.items.items[1..]);
    source.items.items = source.items.items[0 .. source.items.items.len - 1];
    source.logical_length = source.items.items.len;
    return first;
}

pub fn indexOf(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const length: i64 = @intCast(source.items.items.len);
    const requested: i64 = if (arguments.len > 2) toInteger(arguments[2]) orelse 0 else 0;
    const start: usize = @intCast(if (requested < 0) @max(length + requested, 0) else @min(requested, length));
    const searched = if (arguments.len > 1) arguments[1] else Value.undefined_value;
    for (source.items.items[start..], start..) |item, index| {
        if (strictEqual(context, item, searched)) return Value.fromInt(@intCast(index)) orelse error.IntegerOverflow;
    }
    return Value.fromInt(-1) orelse error.IntegerOverflow;
}

fn strictEqual(context: *VM.NativeCallContext, left: Value, right: Value) bool {
    if (left.asFloat64()) |left_number| {
        if (std.math.isNan(left_number)) return false;
        if (right.asInt()) |right_number| return left_number == @as(f64, @floatFromInt(right_number));
        if (right.asFloat64()) |right_number| return !std.math.isNan(right_number) and left_number == right_number;
    }
    if (right.asFloat64()) |right_number| {
        if (std.math.isNan(right_number)) return false;
        if (left.asInt()) |left_number| return @as(f64, @floatFromInt(left_number)) == right_number;
    }
    if (left.raw() == right.raw()) return true;
    const left_string = context.objects.findString(left) orelse return false;
    const right_string = context.objects.findString(right) orelse return false;
    return std.mem.eql(u8, left_string, right_string);
}

fn toInteger(value: Value) ?i64 {
    if (value.asInt()) |integer| return integer;
    if (value.asFloat64()) |number| {
        if (!std.math.isFinite(number)) return 0;
        if (number <= -9223372036854775808.0) return std.math.minInt(i64);
        if (number >= 9223372036854775807.0) return std.math.maxInt(i64);
        return @intFromFloat(@trunc(number));
    }
    if (value.asBool()) |boolean| return @intFromBool(boolean);
    if (value.isNull()) return 0;
    return null;
}

pub fn slice(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const len = source.len();
    const raw_start: i64 = if (arguments.len > 1) arguments[1].asInt() orelse 0 else 0;
    const start: usize = if (raw_start < 0) @intCast(@max(0, @as(i64, @intCast(len)) + raw_start)) else @intCast(@min(raw_start, @as(i64, @intCast(len))));
    const raw_end: i64 = if (arguments.len > 2) arguments[2].asInt() orelse @intCast(len) else @intCast(len);
    const end: usize = if (raw_end < 0) @intCast(@max(0, @as(i64, @intCast(len)) + raw_end)) else @intCast(@min(raw_end, @as(i64, @intCast(len))));
    if (source.byte_storage) |bytes| {
        const output = try context.objects.createByteArray(@max(start, end) - start);
        const target = context.objects.findArray(output).?.byte_storage.?;
        @memcpy(target, bytes[start..@max(start, end)]);
        return output;
    }
    return context.objects.createArray(source.items.items[start..@max(start, end)]);
}

pub fn byteSet(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return error.MissingArrayReceiver;
    const target = context.objects.findArray(arguments[0]) orelse return error.InvalidArrayReceiver;
    const output = target.byte_storage orelse return error.InvalidArrayReceiver;
    const source = context.objects.findArray(arguments[1]) orelse return error.InvalidArrayReceiver;
    const raw_offset: i32 = if (arguments.len > 2) arguments[2].asInt() orelse return error.InvalidOffset else 0;
    if (raw_offset < 0) return error.InvalidOffset;
    const offset: usize = @intCast(raw_offset);
    if (offset > output.len or source.len() > output.len - offset) return error.InvalidOffset;
    for (0..source.len()) |index| {
        const byte = source.get(index).asInt() orelse return error.InvalidByte;
        output[offset + index] = @truncate(@as(u32, @bitCast(byte)));
    }
    return Value.undefined_value;
}

pub fn join(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    const separator = if (arguments.len > 1) context.objects.findString(arguments[1]) orelse "," else ",";
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(context.objects.allocator);
    for (source.items.items, 0..) |item, index| {
        if (index != 0) try output.appendSlice(context.objects.allocator, separator);
        if (context.objects.findString(item)) |bytes| {
            try output.appendSlice(context.objects.allocator, bytes);
        } else if (item.asInt()) |number| {
            try output.appendSlice(context.objects.allocator, try std.fmt.allocPrint(context.objects.allocator, "{d}", .{number}));
        } else if (item.isNull() or item.isUndefined()) {
            continue;
        } else {
            return error.UnsupportedArrayElement;
        }
    }
    return context.objects.createString(output.items);
}

pub fn sort(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const source = try receiver(context, arguments);
    std.mem.sort(Value, source.items.items, {}, struct {
        fn less(_: void, left: Value, right: Value) bool {
            if (left.asInt()) |a| if (right.asInt()) |b| return a < b;
            return left.raw() < right.raw();
        }
    }.less);
    return arguments[0];
}

fn truthy(value: Value) bool {
    if (value.asBool()) |boolean| return boolean;
    if (value.asInt()) |number| return number != 0;
    return !value.isNull() and !value.isUndefined();
}
