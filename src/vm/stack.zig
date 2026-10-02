const Value = @import("../value.zig").Value;

pub const Stack = struct {
    storage: []Value,
    len: usize = 0,

    pub fn init(storage: []Value) Stack {
        return .{ .storage = storage };
    }

    pub fn truncate(self: *Stack, length: usize) void {
        self.len = length;
    }

    pub inline fn push(self: *Stack, value: Value) error{StackOverflow}!void {
        if (self.len >= self.storage.len) return error.StackOverflow;
        self.storage[self.len] = value;
        self.len += 1;
    }

    pub inline fn pop(self: *Stack) error{StackUnderflow}!Value {
        if (self.len == 0) return error.StackUnderflow;
        self.len -= 1;
        return self.storage[self.len];
    }

    pub inline fn peek(self: *const Stack, depth: usize) error{StackUnderflow}!Value {
        if (depth >= self.len) return error.StackUnderflow;
        return self.storage[self.len - depth - 1];
    }
};

test "execution stack uses fixed storage and reports boundaries" {
    const testing = @import("std").testing;
    var storage: [2]Value = undefined;
    var stack = Stack.init(&storage);
    const first = Value.fromInt(7).?;
    const second = Value.fromInt(9).?;

    try stack.push(first);
    try stack.push(second);
    try testing.expectError(error.StackOverflow, stack.push(first));
    try testing.expectEqual(second.raw(), (try stack.peek(0)).raw());
    try testing.expectEqual(second.raw(), (try stack.pop()).raw());
    try testing.expectEqual(first.raw(), (try stack.pop()).raw());
    try testing.expectError(error.StackUnderflow, stack.pop());
}
