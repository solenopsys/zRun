const std = @import("std");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;

var math_random_state = std.atomic.Value(u64).init(0x4d595df4d0f33173);

pub fn toNumber(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return Value.fromInt(0).?;
    const value = arguments[0];
    if (value.asInt() != null or value.asFloat64() != null) return value;
    if (value.asBool()) |boolean| return Value.fromInt(if (boolean) 1 else 0).?;
    if (value.isNull()) return Value.fromInt(0).?;
    if (value.isUndefined()) return Value.fromFloat64(std.math.nan(f64));

    const text = context.objects.findString(value) orelse return Value.fromFloat64(std.math.nan(f64));
    const trimmed = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
    if (trimmed.len == 0) return Value.fromInt(0).?;
    const number = std.fmt.parseFloat(f64, trimmed) catch return Value.fromFloat64(std.math.nan(f64));
    if (std.math.isFinite(number) and @trunc(number) == number) {
        const minimum = @as(f64, @floatFromInt(Value.short_int_min));
        const maximum = @as(f64, @floatFromInt(Value.short_int_max));
        if (number >= minimum and number <= maximum) {
            return Value.fromInt(@intFromFloat(number)).?;
        }
    }
    return Value.fromFloat64(number);
}

pub fn parseInt(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return Value.fromFloat64(std.math.nan(f64));
    const string_value = try toString(context, arguments[0..1]);
    const input = context.objects.findString(string_value) orelse return Value.fromFloat64(std.math.nan(f64));
    var text = std.mem.trim(u8, input, " \t\r\n\x0b\x0c");
    var negative = false;
    if (text.len > 0 and (text[0] == '+' or text[0] == '-')) {
        negative = text[0] == '-';
        text = text[1..];
    }
    var radix: u8 = 0;
    if (arguments.len > 1) {
        const radix_number = try toNumber(context, arguments[1..2]);
        if (radix_number.asInt()) |number| {
            if (number != 0) {
                if (number < 2 or number > 36) return Value.fromFloat64(std.math.nan(f64));
                radix = @intCast(number);
            }
        } else if (radix_number.asFloat64()) |number| {
            if (number != 0) {
                if (!std.math.isFinite(number) or number < 2 or number > 36) return Value.fromFloat64(std.math.nan(f64));
                radix = @intFromFloat(number);
            }
        }
    }
    if ((radix == 0 or radix == 16) and text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        text = text[2..];
        radix = 16;
    }
    if (radix == 0) radix = 10;
    var parsed = false;
    var result: f64 = 0;
    for (text) |byte| {
        const digit: u8 = if (byte >= '0' and byte <= '9')
            byte - '0'
        else if (byte >= 'a' and byte <= 'z')
            byte - 'a' + 10
        else if (byte >= 'A' and byte <= 'Z')
            byte - 'A' + 10
        else
            break;
        if (digit >= radix) break;
        parsed = true;
        result = result * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(digit));
    }
    if (!parsed) return Value.fromFloat64(std.math.nan(f64));
    if (negative) result = -result;
    const minimum = @as(f64, @floatFromInt(Value.short_int_min));
    const maximum = @as(f64, @floatFromInt(Value.short_int_max));
    if (result >= minimum and result <= maximum) return Value.fromInt(@intFromFloat(result)).?;
    return Value.fromFloat64(result);
}

pub fn mathRound(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return Value.fromInt(0).?;
    const value = try toNumber(context, arguments[0..1]);
    const number: f64 = if (value.asInt()) |integer| @floatFromInt(integer) else value.asFloat64() orelse return Value.fromFloat64(std.math.nan(f64));
    const rounded = @floor(number + 0.5);
    if (rounded >= @as(f64, @floatFromInt(Value.short_int_min)) and rounded <= @as(f64, @floatFromInt(Value.short_int_max))) {
        return Value.fromInt(@intFromFloat(rounded)).?;
    }
    return Value.fromFloat64(rounded);
}

pub fn mathPow(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return Value.fromFloat64(std.math.nan(f64));
    const base_value = try toNumber(context, arguments[0..1]);
    const exponent_value = try toNumber(context, arguments[1..2]);
    const base: f64 = if (base_value.asInt()) |integer| @floatFromInt(integer) else base_value.asFloat64() orelse std.math.nan(f64);
    const exponent: f64 = if (exponent_value.asInt()) |integer| @floatFromInt(integer) else exponent_value.asFloat64() orelse std.math.nan(f64);
    return Value.fromFloat64(std.math.pow(f64, base, exponent));
}

pub fn encodeURIComponent(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const value = try toString(context, arguments);
    const text = context.objects.findString(value) orelse return error.InvalidString;
    const digits = "0123456789ABCDEF";
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(context.objects.allocator);
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-_.!~*'()", byte) != null) {
            try encoded.append(context.objects.allocator, byte);
        } else {
            try encoded.appendSlice(context.objects.allocator, "%");
            try encoded.append(context.objects.allocator, digits[byte >> 4]);
            try encoded.append(context.objects.allocator, digits[byte & 0x0f]);
        }
    }
    return context.objects.createStringOwned(try encoded.toOwnedSlice(context.objects.allocator));
}

pub fn arrayIsArray(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return Value.boolean(arguments.len != 0 and context.objects.findArray(arguments[0]) != null);
}

pub fn arrayConstructor(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 1) {
        const length_value = arguments[0];
        const requested_length = if (length_value.asInt()) |value|
            if (value >= 0) @as(?usize, @intCast(value)) else null
        else if (length_value.asFloat64()) |value|
            if (std.math.isFinite(value) and value >= 0 and @trunc(value) == value and value <= 1_000_000)
                @as(?usize, @intFromFloat(value))
            else
                null
        else
            null;
        if (length_value.asInt() != null or length_value.asFloat64() != null) {
            const length = requested_length orelse return error.InvalidArrayLength;
            const values = try context.objects.allocator.alloc(Value, length);
            defer context.objects.allocator.free(values);
            @memset(values, Value.undefined_value);
            return context.objects.createArray(values);
        }
    }
    return context.objects.createArray(arguments);
}

pub fn arrayFrom(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return context.objects.createArray(&.{});
    if (context.objects.findArray(arguments[0])) |array| return context.objects.createArray(array.items.items);
    if (context.objects.findString(arguments[0])) |string| {
        var items: std.ArrayList(Value) = .empty;
        defer items.deinit(context.objects.allocator);
        for (string) |byte| {
            const char = try context.objects.createString(&.{byte});
            try items.append(context.objects.allocator, char);
        }
        return context.objects.createArray(items.items);
    }
    return context.objects.createArray(&.{});
}

fn mathMinMax(context: *VM.NativeCallContext, arguments: []const Value, want_max: bool) anyerror!Value {
    if (arguments.len == 0) return Value.fromFloat64(if (want_max) -std.math.inf(f64) else std.math.inf(f64));
    var result: f64 = if (want_max) -std.math.inf(f64) else std.math.inf(f64);
    for (arguments) |argument| {
        const value = try toNumber(context, &.{argument});
        const number: f64 = if (value.asInt()) |integer| @floatFromInt(integer) else value.asFloat64() orelse std.math.nan(f64);
        if (std.math.isNan(number)) return Value.fromFloat64(number);
        result = if (want_max) @max(result, number) else @min(result, number);
    }
    if (result >= @as(f64, @floatFromInt(Value.short_int_min)) and result <= @as(f64, @floatFromInt(Value.short_int_max)) and @trunc(result) == result) {
        return Value.fromInt(@intFromFloat(result)).?;
    }
    return Value.fromFloat64(result);
}

pub fn mathMax(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mathMinMax(context, arguments, true);
}

pub fn mathMin(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mathMinMax(context, arguments, false);
}

pub fn objectCreate(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingPrototype;
    const prototype = arguments[0];
    if (!prototype.isNull() and context.objects.findObject(prototype) == null) return error.InvalidPrototype;
    const object_value = try context.objects.createObject();
    context.objects.findObject(object_value).?.prototype = prototype;
    return object_value;
}

pub fn objectDefineProperty(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 3) return error.MissingDescriptor;
    const descriptor = context.objects.findObject(arguments[2]) orelse return error.InvalidDescriptor;
    if (context.objects.getOwnProperty(arguments[2], "get") != null or context.objects.getOwnProperty(arguments[2], "set") != null) {
        return error.AccessorDescriptorUnsupported;
    }
    const key_value = try toString(context, arguments[1..2]);
    const key = context.objects.findString(key_value) orelse return error.InvalidPropertyKey;
    const value = context.objects.getOwnProperty(arguments[2], "value") orelse Value.undefined_value;
    if (context.objects.findObject(arguments[0]) == null and context.objects.findClosure(arguments[0]) == null) return error.InvalidTarget;
    try context.objects.putProperty(arguments[0], key, value);
    _ = descriptor;
    return arguments[0];
}

pub fn objectGetOwnPropertyDescriptor(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return Value.undefined_value;
    const key_value = try toString(context, arguments[1..2]);
    const key = context.objects.findString(key_value) orelse return error.InvalidPropertyKey;
    const value = context.objects.getOwnProperty(arguments[0], key) orelse return Value.undefined_value;
    const descriptor = try context.objects.createObject();
    try context.objects.putProperty(descriptor, "value", value);
    try context.objects.putProperty(descriptor, "writable", Value.true_value);
    try context.objects.putProperty(descriptor, "enumerable", Value.true_value);
    try context.objects.putProperty(descriptor, "configurable", Value.true_value);
    return descriptor;
}

pub fn objectConstructor(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len != 0) {
        const value = arguments[0];
        if (value.isNull() or value.isUndefined()) return context.objects.createObject();
        if (context.objects.findObject(value) != null or context.objects.findArray(value) != null or
            context.objects.findClosure(value) != null or context.objects.findCollection(value) != null) return value;
        const boxed = try context.objects.createObject();
        try context.objects.putProperty(boxed, "value", value);
        return boxed;
    }
    return context.objects.createObject();
}

pub fn objectGetPrototypeOf(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0 or arguments[0].isNull() or arguments[0].isUndefined()) {
        return error.InvalidTarget;
    }
    if (context.objects.findObject(arguments[0])) |object| {
        return if (object.prototype.isUndefined()) Value.null_value else object.prototype;
    }
    if (context.objects.findArray(arguments[0]) != null or
        context.objects.findString(arguments[0]) != null or
        context.objects.findClosure(arguments[0]) != null or
        context.objects.findCollection(arguments[0]) != null)
    {
        return context.objects.default_object_prototype;
    }
    return context.objects.default_object_prototype;
}

/// The runtime does not model non-enumerable or symbol properties yet, so its
/// own string property list is also the currently supported own-name list.
pub fn objectGetOwnPropertyNames(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return objectKeys(context, arguments);
}

pub fn objectHasOwnProperty(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return Value.false_value;
    const key_value = try toString(context, arguments[1..2]);
    const key = context.objects.findString(key_value) orelse return error.InvalidPropertyKey;
    return Value.boolean(context.objects.getOwnProperty(arguments[0], key) != null);
}

/// Installs the Object namespace and the shared ordinary-object prototype in
/// each VM global. Object calls remain specially lowered by the compiler;
/// storing the namespace also supports `globalThis.Object` and `.prototype`.
pub fn installObjectGlobal(objects: *@import("../vm/objects.zig").Store, global_this: Value) !void {
    const object_prototype = try objects.createObject();
    objects.findObject(object_prototype).?.prototype = Value.null_value;
    objects.default_object_prototype = object_prototype;
    if (objects.findObject(global_this)) |global| global.prototype = object_prototype;

    const object_namespace = try objects.createObject();
    objects.findObject(object_namespace).?.prototype = object_prototype;
    try objects.putProperty(object_prototype, "hasOwnProperty", Value.shortFunction(59));
    try objects.putProperty(object_namespace, "prototype", object_prototype);
    try objects.putProperty(object_namespace, "create", Value.shortFunction(53));
    try objects.putProperty(object_namespace, "defineProperty", Value.shortFunction(54));
    try objects.putProperty(object_namespace, "getOwnPropertyDescriptor", Value.shortFunction(55));
    try objects.putProperty(object_namespace, "getPrototypeOf", Value.shortFunction(57));
    try objects.putProperty(object_namespace, "getOwnPropertyNames", Value.shortFunction(58));
    try objects.putProperty(object_namespace, "assign", Value.shortFunction(3));
    try objects.putProperty(object_namespace, "entries", Value.shortFunction(4));
    try objects.putProperty(object_namespace, "fromEntries", Value.shortFunction(5));
    try objects.putProperty(object_namespace, "keys", Value.shortFunction(6));
    try objects.putProperty(object_namespace, "values", Value.shortFunction(7));
    try objects.putProperty(global_this, "Object", object_namespace);
}

pub fn toBoolean(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return Value.false_value;
    const value = arguments[0];
    const truthy = if (value.asInt()) |number|
        number != 0
    else if (value.asFloat64()) |number|
        number != 0 and !std.math.isNan(number)
    else if (value.asBool()) |boolean_value|
        boolean_value
    else if (value.isNull() or value.isUndefined())
        false
    else if (context.objects.findString(value)) |string|
        string.len != 0
    else
        true;
    return Value.boolean(truthy);
}

pub fn toString(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return context.objects.createString("undefined");
    const value = arguments[0];
    if (context.objects.findString(value) != null) return value;
    if (value.asInt()) |number| {
        const text = try std.fmt.allocPrint(context.objects.allocator, "{d}", .{number});
        defer context.objects.allocator.free(text);
        return context.objects.createString(text);
    }
    if (value.asFloat64()) |number| {
        const text = try std.fmt.allocPrint(context.objects.allocator, "{d}", .{number});
        defer context.objects.allocator.free(text);
        return context.objects.createString(text);
    }
    if (value.asBool()) |boolean_value| return context.objects.createString(if (boolean_value) "true" else "false");
    if (value.isNull()) return context.objects.createString("null");
    if (value.isUndefined()) return context.objects.createString("undefined");
    return context.objects.createString("[object Object]");
}

pub fn objectAssign(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingTarget;
    const target = context.objects.findObject(arguments[0]) orelse return error.InvalidTarget;
    for (arguments[1..]) |source_value| {
        const source = context.objects.findObject(source_value) orelse continue;
        for (source.fields.items) |field| try context.objects.putProperty(arguments[0], field.name, field.value);
    }
    _ = target;
    return arguments[0];
}

pub fn objectKeys(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingTarget;
    const object = context.objects.findObject(arguments[0]) orelse return error.InvalidTarget;
    const keys = try context.objects.allocator.alloc(Value, object.fields.items.len);
    defer context.objects.allocator.free(keys);
    for (object.fields.items, 0..) |field, index| keys[index] = try context.objects.createString(field.name);
    return try context.objects.createArray(keys);
}

pub fn objectValues(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingTarget;
    const object = context.objects.findObject(arguments[0]) orelse return error.InvalidTarget;
    const values = try context.objects.allocator.alloc(Value, object.fields.items.len);
    defer context.objects.allocator.free(values);
    for (object.fields.items, 0..) |field, index| values[index] = field.value;
    return try context.objects.createArray(values);
}

pub fn objectEntries(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingTarget;
    const object = context.objects.findObject(arguments[0]) orelse return error.InvalidTarget;
    const entries = try context.objects.allocator.alloc(Value, object.fields.items.len);
    defer context.objects.allocator.free(entries);
    for (object.fields.items, 0..) |field, index| {
        const key = try context.objects.createString(field.name);
        entries[index] = try context.objects.createArray(&.{ key, field.value });
    }
    return try context.objects.createArray(entries);
}

pub fn objectFromEntries(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingEntries;
    const entries = context.objects.findArray(arguments[0]) orelse return error.InvalidEntries;
    const result = try context.objects.createObject();
    for (entries.items.items) |entry_value| {
        const entry = context.objects.findArray(entry_value) orelse return error.InvalidEntry;
        if (entry.items.items.len < 2) return error.InvalidEntry;
        const key = context.objects.findString(entry.items.items[0]) orelse return error.InvalidEntry;
        try context.objects.putProperty(result, key, entry.items.items[1]);
    }
    return result;
}

pub fn mathImul(_: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return error.MissingArgument;
    const left = toInt32(arguments[0]) orelse return error.InvalidArgument;
    const right = toInt32(arguments[1]) orelse return error.InvalidArgument;
    const product: i32 = @bitCast(@as(u32, @bitCast(left)) *% @as(u32, @bitCast(right)));
    return Value.fromInt(product) orelse Value.fromFloat64(@floatFromInt(product));
}

pub fn mathRandom(_: *VM.NativeCallContext, _: []const Value) anyerror!Value {
    const seed = math_random_state.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
    var value = seed;
    value = (value ^ (value >> 30)) *% 0xbf58476d1ce4e5b9;
    value = (value ^ (value >> 27)) *% 0x94d049bb133111eb;
    value ^= value >> 31;
    const unit = @as(f64, @floatFromInt(value >> 11)) / 9007199254740992.0;
    return Value.fromFloat64(unit);
}

pub fn toInt32(value: Value) ?i32 {
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

pub fn jsonParse(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingArgument;
    const source = context.objects.findString(arguments[0]) orelse return error.InvalidArgument;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, context.objects.allocator, source, .{ .allocate = .alloc_always });
    return fromJson(context.objects, parsed);
}

pub fn jsonStringify(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingArgument;
    const json_value = try toJson(context.objects, arguments[0]);
    const indent = arguments.len > 2 and (arguments[2].asInt() orelse 0) > 0;
    const options = if (indent)
        std.json.Stringify.Options{ .whitespace = .indent_2 }
    else
        std.json.Stringify.Options{};
    const encoded = try std.json.Stringify.valueAlloc(context.objects.allocator, json_value, options);
    return try context.objects.createString(encoded);
}

fn fromJson(objects: anytype, source: std.json.Value) anyerror!Value {
    return switch (source) {
        .null => Value.null_value,
        .bool => |value| Value.boolean(value),
        .integer => |value| Value.fromInt(std.math.cast(i32, value) orelse return error.IntegerOutOfRange) orelse error.IntegerOutOfRange,
        .float, .number_string => return error.UnsupportedJsonNumber,
        .string => |value| try objects.createString(value),
        .array => |value| blk: {
            const items = try objects.allocator.alloc(Value, value.items.len);
            defer objects.allocator.free(items);
            for (value.items, 0..) |item, index| items[index] = try fromJson(objects, item);
            break :blk try objects.createArray(items);
        },
        .object => |value| blk: {
            const result = try objects.createObject();
            var iterator = value.iterator();
            while (iterator.next()) |entry| try objects.putProperty(result, entry.key_ptr.*, try fromJson(objects, entry.value_ptr.*));
            break :blk result;
        },
    };
}

fn toJson(objects: anytype, value: Value) anyerror!std.json.Value {
    if (value.asInt()) |number| return .{ .integer = number };
    if (value.asBool()) |boolean| return .{ .bool = boolean };
    if (value.isNull() or value.isUndefined()) return .null;
    if (objects.findString(value)) |string| return .{ .string = string };
    if (objects.findArray(value)) |array| {
        var result = std.json.Array.init(objects.allocator);
        for (array.items.items) |item| try result.append(try toJson(objects, item));
        return .{ .array = result };
    }
    if (objects.findObject(value)) |object| {
        var result: std.json.ObjectMap = .empty;
        for (object.fields.items) |field| try result.put(objects.allocator, field.name, try toJson(objects, field.value));
        return .{ .object = result };
    }
    return error.UnsupportedJsonValue;
}
