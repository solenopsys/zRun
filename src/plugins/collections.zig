const std = @import("std");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;

fn collection(context: *VM.NativeCallContext, arguments: []const Value, expected: @import("../vm/objects.zig").CollectionKind) anyerror!*@import("../vm/objects.zig").CollectionObject {
    if (arguments.len == 0) return error.MissingCollectionReceiver;
    const result = context.objects.findCollection(arguments[0]) orelse return error.InvalidCollectionReceiver;
    if (result.kind != expected) return error.InvalidCollectionReceiver;
    return result;
}

fn mapLike(context: *VM.NativeCallContext, arguments: []const Value) anyerror!*@import("../vm/objects.zig").CollectionObject {
    if (arguments.len == 0) return error.MissingCollectionReceiver;
    const result = context.objects.findCollection(arguments[0]) orelse return error.InvalidCollectionReceiver;
    if (result.kind == .set) return error.InvalidCollectionReceiver;
    return result;
}

fn equal(context: *VM.NativeCallContext, left: Value, right: Value) bool {
    if (left.raw() == right.raw()) return true;
    if (context.objects.findString(left)) |left_string| {
        if (context.objects.findString(right)) |right_string| return std.mem.eql(u8, left_string, right_string);
    }
    return (left.isNull() or left.isUndefined()) and (right.isNull() or right.isUndefined());
}

pub fn mapSet(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try mapLike(context, arguments);
    if (arguments.len < 3) return error.MissingEntry;
    for (target.entries.items) |*entry| {
        if (equal(context, entry.key, arguments[1])) {
            entry.value = arguments[2];
            return arguments[0];
        }
    }
    try target.entries.append(context.objects.allocator, .{ .key = arguments[1], .value = arguments[2] });
    return arguments[0];
}

pub fn mapGet(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try mapLike(context, arguments);
    if (arguments.len < 2) return Value.undefined_value;
    for (target.entries.items) |entry| if (equal(context, entry.key, arguments[1])) return entry.value;
    return Value.undefined_value;
}

pub fn mapHas(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try mapLike(context, arguments);
    if (arguments.len < 2) return Value.false_value;
    for (target.entries.items) |entry| if (equal(context, entry.key, arguments[1])) return Value.true_value;
    return Value.false_value;
}

pub fn mapKeys(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try collection(context, arguments, .map);
    const values = try context.objects.allocator.alloc(Value, target.entries.items.len);
    defer context.objects.allocator.free(values);
    for (target.entries.items, 0..) |entry, index| values[index] = entry.key;
    return context.objects.createIterator(values);
}

pub fn setAdd(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try collection(context, arguments, .set);
    if (arguments.len < 2) return error.MissingEntry;
    for (target.entries.items) |entry| if (equal(context, entry.key, arguments[1])) return arguments[0];
    try target.entries.append(context.objects.allocator, .{ .key = arguments[1], .value = arguments[1] });
    return arguments[0];
}

pub fn setHas(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try collection(context, arguments, .set);
    if (arguments.len < 2) return Value.false_value;
    for (target.entries.items) |entry| if (equal(context, entry.key, arguments[1])) return Value.true_value;
    return Value.false_value;
}

pub fn setValues(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const target = try collection(context, arguments, .set);
    const values = try context.objects.allocator.alloc(Value, target.entries.items.len);
    defer context.objects.allocator.free(values);
    for (target.entries.items, 0..) |entry, index| values[index] = entry.key;
    return context.objects.createIterator(values);
}

pub fn iteratorNext(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingIteratorReceiver;
    const iterator = context.objects.findIterator(arguments[0]) orelse return error.InvalidIteratorReceiver;
    const result = try context.objects.createObject();
    const done = iterator.index >= iterator.values.items.len;
    const value = if (done) Value.undefined_value else iterator.values.items[iterator.index];
    if (!done) iterator.index += 1;
    try context.objects.putProperty(result, "value", value);
    try context.objects.putProperty(result, "done", Value.boolean(done));
    return result;
}
