const std = @import("std");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;
const builtins = @import("builtins.zig");
const regexp = @import("regexp.zig");

fn receiver(context: *VM.NativeCallContext, arguments: []const Value) anyerror![]const u8 {
    if (arguments.len == 0) return error.MissingStringReceiver;
    return context.objects.findString(arguments[0]) orelse error.InvalidStringReceiver;
}

fn argumentString(context: *VM.NativeCallContext, arguments: []const Value, index: usize, fallback: []const u8) []const u8 {
    if (index >= arguments.len) return fallback;
    return context.objects.findString(arguments[index]) orelse fallback;
}

pub fn concat(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(context.objects.allocator);
    try output.appendSlice(context.objects.allocator, text);
    for (arguments[1..]) |argument| {
        const converted = try builtins.toString(context, &.{argument});
        try output.appendSlice(context.objects.allocator, context.objects.findString(converted) orelse return error.InvalidString);
    }
    return context.objects.createStringOwned(try output.toOwnedSlice(context.objects.allocator));
}

pub fn indexOf(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const needle = if (arguments.len > 1) blk: {
        const converted = try builtins.toString(context, arguments[1..2]);
        break :blk context.objects.findString(converted) orelse return error.InvalidString;
    } else "undefined";
    const raw_start = if (arguments.len > 2) toInteger(arguments[2]) orelse 0 else 0;
    const start: usize = @intCast(if (raw_start < 0) 0 else @min(raw_start, text.len));
    const index = std.mem.indexOfPos(u8, text, start, needle) orelse return Value.fromInt(-1) orelse error.IntegerOverflow;
    return Value.fromInt(@intCast(index)) orelse error.IntegerOverflow;
}

pub fn startsWith(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const prefix_value = try builtins.toString(context, if (arguments.len > 1) arguments[1..2] else &.{});
    const prefix = context.objects.findString(prefix_value) orelse return error.InvalidString;
    const raw_position = if (arguments.len > 2) toInteger(arguments[2]) orelse 0 else 0;
    const position: usize = @intCast(if (raw_position < 0) 0 else @min(raw_position, text.len));
    return Value.boolean(std.mem.startsWith(u8, text[position..], prefix));
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

pub fn charCodeAt(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const position: usize = if (arguments.len > 1) @intCast(@max(0, arguments[1].asInt() orelse 0)) else 0;
    if (position >= text.len) return Value.fromInt(0) orelse error.IntegerOverflow;
    return Value.fromInt(text[position]) orelse error.IntegerOverflow;
}

pub fn localeCompare(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const left = try receiver(context, arguments);
    const right = argumentString(context, arguments, 1, "undefined");
    const order = std.mem.order(u8, left, right);
    return Value.fromInt(switch (order) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    }) orelse error.IntegerOverflow;
}

pub fn padStart(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const target: usize = if (arguments.len > 1) @intCast(@max(0, arguments[1].asInt() orelse 0)) else 0;
    if (target <= text.len) return arguments[0];
    const pad = argumentString(context, arguments, 2, " ");
    if (pad.len == 0) return arguments[0];
    const length = @min(target - text.len, 1024 * 1024);
    const result = try context.objects.allocator.alloc(u8, length + text.len);
    defer context.objects.allocator.free(result);
    for (0..length) |index| result[index] = pad[index % pad.len];
    @memcpy(result[length..], text);
    return context.objects.createStringOwned(result);
}

pub fn slice(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const start = sliceIndex(if (arguments.len > 1) arguments[1].asInt() orelse 0 else 0, text.len);
    const end = if (arguments.len > 2 and !arguments[2].isUndefined())
        sliceIndex(arguments[2].asInt() orelse 0, text.len)
    else
        text.len;
    return context.objects.createString(text[start..@max(start, end)]);
}

pub fn split(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    if (arguments.len < 2 or arguments[1].isUndefined()) return context.objects.createArray(arguments[0..1]);
    const separator = argumentString(context, arguments, 1, "undefined");
    const limit: usize = if (arguments.len > 2 and !arguments[2].isUndefined())
        if (arguments[2].asInt()) |number| @as(u32, @bitCast(number)) else if (arguments[2].asBool()) |boolean| @intFromBool(boolean) else 0
    else
        std.math.maxInt(u32);
    var values: std.ArrayList(Value) = .empty;
    defer values.deinit(context.objects.allocator);
    if (limit == 0) return context.objects.createArray(&.{});

    if (separator.len == 0) {
        var cursor: usize = 0;
        while (cursor < text.len and values.items.len < limit) {
            const width = std.unicode.utf8ByteSequenceLength(text[cursor]) catch 1;
            const end = @min(cursor + width, text.len);
            try values.append(context.objects.allocator, try context.objects.createString(text[cursor..end]));
            cursor = end;
        }
    } else {
        var cursor: usize = 0;
        while (values.items.len < limit) {
            const position = std.mem.indexOfPos(u8, text, cursor, separator) orelse {
                try values.append(context.objects.allocator, try context.objects.createString(text[cursor..]));
                break;
            };
            try values.append(context.objects.allocator, try context.objects.createString(text[cursor..position]));
            cursor = position + separator.len;
        }
    }
    return context.objects.createArray(values.items);
}

fn sliceIndex(index: i32, length: usize) usize {
    const signed_length: i64 = @intCast(length);
    const signed_index: i64 = index;
    return @intCast(if (signed_index < 0) @max(signed_length + signed_index, 0) else @min(signed_index, signed_length));
}

pub fn replace(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return replaceImpl(context, arguments, false);
}

pub fn replaceAll(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return replaceImpl(context, arguments, true);
}

fn replaceImpl(context: *VM.NativeCallContext, arguments: []const Value, replace_all: bool) anyerror!Value {
    const text = try receiver(context, arguments);
    if (arguments.len > 1) {
        if (context.objects.findRegex(arguments[1])) |regex| {
            return replaceRegex(context, arguments, text, regex, replace_all);
        }
    }
    const needle = argumentString(context, arguments, 1, "undefined");
    const replacement = argumentString(context, arguments, 2, "undefined");
    if (needle.len == 0) {
        const result = try context.objects.allocator.alloc(u8, replacement.len + text.len);
        errdefer context.objects.allocator.free(result);
        @memcpy(result[0..replacement.len], replacement);
        @memcpy(result[replacement.len..], text);
        return context.objects.createStringOwned(result);
    }

    const count = std.mem.count(u8, text, needle);
    if (count == 0) return arguments[0];
    const replacements = if (replace_all) count else 1;
    const removed = replacements * needle.len;
    const added = std.math.mul(usize, replacements, replacement.len) catch return error.StringTooLarge;
    const result_len = std.math.add(usize, text.len - removed, added) catch return error.StringTooLarge;
    const result = try context.objects.allocator.alloc(u8, result_len);
    errdefer context.objects.allocator.free(result);

    var cursor: usize = 0;
    var output_cursor: usize = 0;
    var remaining = replacements;
    while (remaining > 0) : (remaining -= 1) {
        const position = std.mem.indexOfPos(u8, text, cursor, needle) orelse return error.InvalidReplacement;
        const prefix = text[cursor..position];
        @memcpy(result[output_cursor .. output_cursor + prefix.len], prefix);
        output_cursor += prefix.len;
        @memcpy(result[output_cursor .. output_cursor + replacement.len], replacement);
        output_cursor += replacement.len;
        cursor = position + needle.len;
    }
    @memcpy(result[output_cursor..], text[cursor..]);
    return context.objects.createStringOwned(result);
}

fn replaceRegex(
    context: *VM.NativeCallContext,
    arguments: []const Value,
    text: []const u8,
    regex: *const @import("../vm/objects.zig").RegexObject,
    replace_all: bool,
) anyerror!Value {
    const replacement = argumentString(context, arguments, 2, "undefined");
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(context.objects.allocator);
    var input_cursor: usize = 0;
    var search_cursor: usize = 0;
    var replacements: usize = 0;

    while (regexp.findMatch(regex.pattern, text, search_cursor, regex.ignore_case)) |matched| {
        try result.appendSlice(context.objects.allocator, text[input_cursor..matched.start]);
        try result.appendSlice(context.objects.allocator, replacement);
        input_cursor = matched.end;
        replacements += 1;
        if (!(regex.global or replace_all)) break;
        search_cursor = if (matched.end == matched.start) @min(matched.end + 1, text.len + 1) else matched.end;
        if (search_cursor > text.len) break;
    }
    if (replacements == 0) return arguments[0];
    try result.appendSlice(context.objects.allocator, text[input_cursor..]);
    return context.objects.createStringOwned(try result.toOwnedSlice(context.objects.allocator));
}

pub fn toLowerCase(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mapAsciiCase(context, arguments, false);
}

pub fn toUpperCase(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    return mapAsciiCase(context, arguments, true);
}

fn mapAsciiCase(context: *VM.NativeCallContext, arguments: []const Value, upper: bool) anyerror!Value {
    const text = try receiver(context, arguments);
    const result = try context.objects.allocator.dupe(u8, text);
    defer context.objects.allocator.free(result);
    for (result) |*byte| byte.* = if (upper) std.ascii.toUpper(byte.*) else std.ascii.toLower(byte.*);
    return context.objects.createStringOwned(result);
}

pub fn trim(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const text = try receiver(context, arguments);
    const trimmed = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
    if (trimmed.len == text.len) return arguments[0];
    return context.objects.createString(trimmed);
}

pub fn toString(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingReceiver;
    if (context.objects.findString(arguments[0]) != null) return arguments[0];
    const radix: u8 = if (arguments.len > 1) @intCast(arguments[1].asInt() orelse return error.InvalidRadix) else 10;
    if (radix < 2 or radix > 36) return error.InvalidRadix;
    const text = if (arguments[0].asInt()) |integer|
        if (radix == 10)
            try std.fmt.allocPrint(context.objects.allocator, "{d}", .{integer})
        else
            try formatRadix(context.objects.allocator, integer, radix)
    else if (arguments[0].asFloat64()) |float|
        if (!std.math.isFinite(float))
            return error.InvalidReceiver
        else if (radix == 10)
            try std.fmt.allocPrint(context.objects.allocator, "{d}", .{float})
        else
            try formatFloatRadix(context.objects.allocator, float, radix)
    else
        return error.InvalidReceiver;
    defer context.objects.allocator.free(text);
    return context.objects.createString(text);
}

fn formatRadix(allocator: std.mem.Allocator, value: i64, radix: u8) ![]u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var buffer: [66]u8 = undefined;
    var cursor = buffer.len;
    var magnitude: u64 = if (value < 0) @intCast(-value) else @intCast(value);
    if (magnitude == 0) {
        cursor -= 1;
        buffer[cursor] = '0';
    } else while (magnitude != 0) {
        const remainder: usize = @intCast(magnitude % radix);
        cursor -= 1;
        buffer[cursor] = digits[remainder];
        magnitude /= radix;
    }
    if (value < 0) {
        cursor -= 1;
        buffer[cursor] = '-';
    }
    return allocator.dupe(u8, buffer[cursor..]);
}

fn formatFloatRadix(allocator: std.mem.Allocator, value: f64, radix: u8) ![]u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    const negative = value < 0;
    const absolute = @abs(value);
    const integer_part = @floor(absolute);
    if (integer_part > 9.22e18) return error.InvalidReceiver;
    const integer_text = try formatRadix(allocator, @intFromFloat(integer_part), radix);
    defer allocator.free(integer_text);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    if (negative) try output.append(allocator, '-');
    try output.appendSlice(allocator, integer_text);
    var fraction = absolute - integer_part;
    if (fraction > 0) {
        try output.append(allocator, '.');
        for (0..32) |_| {
            fraction *= @as(f64, @floatFromInt(radix));
            const digit: u8 = @intFromFloat(@floor(fraction));
            try output.append(allocator, digits[digit]);
            fraction -= @as(f64, @floatFromInt(digit));
            if (fraction == 0) break;
        }
    }
    return output.toOwnedSlice(allocator);
}
