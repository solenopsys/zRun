const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;

pub fn push(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len == 0) return error.MissingArrayReceiver;
    const array = context.objects.findArray(arguments[0]) orelse return error.InvalidArrayReceiver;
    try array.materialize(context.objects.allocator);
    try array.items.appendSlice(context.objects.allocator, arguments[1..]);
    const length = @import("std").math.cast(i32, array.items.items.len) orelse return error.ArrayTooLarge;
    return Value.fromInt(length) orelse error.ArrayTooLarge;
}
