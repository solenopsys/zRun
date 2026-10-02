//! Compact tagged values used by the zRun bytecode ABI.
//! Behavior follows upstream; the Zig surface keeps representation details
//! behind a value type instead of exposing C-style bit macros to the VM.

const std = @import("std");

pub const Word = usize;

const Tag = struct {
    const integer: Word = 0;
    const pointer: Word = 1;
    const boolean: Word = 3;
    const null_value: Word = 7;
    const undefined_value: Word = 11;
    const exception: Word = 15;
    const short_function: Word = 19;
    const uninitialized: Word = 23;
    const string_character: Word = 27;
    const catch_offset: Word = 31;
    const short_float: Word = 5;
};

const special_tag_bits: u6 = 5;
const special_tag_mask: Word = (@as(Word, 1) << special_tag_bits) - 1;
const pointer_tag_mask: Word = @sizeOf(Word) - 1;
const float64_value_exp_min: u64 = 1023 - 127;
const float64_value_addend: u64 = (float64_value_exp_min -% (@as(u64, Tag.short_float) << 8)) << 52;

pub const Value = packed struct(Word) {
    bits: Word,

    pub const null_value: Value = .{ .bits = Tag.null_value };
    pub const undefined_value: Value = .{ .bits = Tag.undefined_value };
    pub const exception_value: Value = .{ .bits = Tag.exception };
    pub const uninitialized_value: Value = .{ .bits = Tag.uninitialized };
    pub const false_value: Value = .{ .bits = Tag.boolean };
    pub const true_value: Value = makeSpecial(Tag.boolean, 1);

    pub const short_int_min: i32 = -(1 << 30);
    pub const short_int_max: i32 = (1 << 30) - 1;

    pub fn fromInt(number: i32) ?Value {
        if (number < short_int_min or number > short_int_max) return null;
        const signed_word: isize = number;
        return .{ .bits = @as(Word, @bitCast(signed_word)) << 1 };
    }

    pub fn fromFloat64(number: f64) Value {
        const bits: u64 = @bitCast(number);
        const adjusted = bits -% float64_value_addend;
        return .{ .bits = @bitCast((adjusted << 4) | (adjusted >> 60)) };
    }

    pub fn isShortFloat(self: Value) bool {
        return (self.bits & 7) == Tag.short_float;
    }

    pub fn asFloat64(self: Value) ?f64 {
        if (!self.isShortFloat()) return null;
        const rotated: u64 = @bitCast(self.bits);
        const bits = ((rotated >> 4) | (rotated << 60)) +% float64_value_addend;
        return @bitCast(bits);
    }

    pub fn isInt(self: Value) bool {
        return (self.bits & 1) == Tag.integer;
    }

    pub fn asInt(self: Value) ?i32 {
        if (!self.isInt()) return null;
        const low: u32 = @truncate(self.bits);
        return @as(i32, @bitCast(low)) >> 1;
    }

    pub fn boolean(value: bool) Value {
        return if (value) true_value else false_value;
    }

    pub fn isBool(self: Value) bool {
        return self.isSpecial(Tag.boolean);
    }

    pub fn asBool(self: Value) ?bool {
        if (!self.isBool()) return null;
        return self.specialPayload() != 0;
    }

    pub fn shortFunction(index: usize) Value {
        return makeSpecial(Tag.short_function, index);
    }

    pub fn asShortFunction(self: Value) ?usize {
        if (!self.isSpecial(Tag.short_function)) return null;
        return @intCast(self.specialPayload());
    }

    pub fn isNull(self: Value) bool {
        return self.bits == null_value.bits;
    }

    pub fn isUndefined(self: Value) bool {
        return self.bits == undefined_value.bits;
    }

    pub fn isUninitialized(self: Value) bool {
        return self.bits == uninitialized_value.bits;
    }

    pub fn asStringCharacter(self: Value) ?u21 {
        if (!self.isSpecial(Tag.string_character)) return null;
        const codepoint = self.specialPayload();
        if (codepoint > 0x10ffff) return null;
        return @intCast(codepoint);
    }

    pub fn isException(self: Value) bool {
        return self.bits == exception_value.bits;
    }

    pub fn catchOffset(offset: usize) ?Value {
        const max_offset = std.math.maxInt(Word) >> special_tag_bits;
        if (offset > max_offset) return null;
        return makeSpecial(Tag.catch_offset, offset);
    }

    pub fn asCatchOffset(self: Value) ?usize {
        if (!self.isSpecial(Tag.catch_offset)) return null;
        return @intCast(self.specialPayload());
    }

    pub fn isPointer(self: Value) bool {
        return (self.bits & pointer_tag_mask) == Tag.pointer;
    }

    pub fn fromPointer(pointer: *anyopaque) Value {
        const address = @intFromPtr(pointer);
        std.debug.assert((address & pointer_tag_mask) == 0);
        return .{ .bits = address + 1 };
    }

    pub fn asPointer(self: Value) ?*anyopaque {
        if (!self.isPointer()) return null;
        return @ptrFromInt(self.bits - 1);
    }

    pub fn raw(self: Value) Word {
        return self.bits;
    }

    fn isSpecial(self: Value, tag: Word) bool {
        return (self.bits & special_tag_mask) == tag;
    }

    fn specialPayload(self: Value) Word {
        return self.bits >> special_tag_bits;
    }

    fn makeSpecial(tag: Word, payload: Word) Value {
        return .{ .bits = tag | (payload << special_tag_bits) };
    }
};

comptime {
    if (@sizeOf(Value) != @sizeOf(Word)) @compileError("JSValue must stay one machine word");
}

test "immediate tags and signed 31-bit integer range match the bytecode ABI" {
    try std.testing.expectEqual(@as(Word, 3), Value.false_value.raw());
    try std.testing.expectEqual(@as(Word, 7), Value.null_value.raw());
    try std.testing.expectEqual(@as(Word, 11), Value.undefined_value.raw());
    try std.testing.expectEqual(@as(Word, 15), Value.exception_value.raw());

    const minimum = Value.fromInt(Value.short_int_min).?;
    const maximum = Value.fromInt(Value.short_int_max).?;
    try std.testing.expectEqual(Value.short_int_min, minimum.asInt().?);
    try std.testing.expectEqual(Value.short_int_max, maximum.asInt().?);
    try std.testing.expect(Value.fromInt(Value.short_int_min - 1) == null);
    try std.testing.expect(Value.fromInt(Value.short_int_max + 1) == null);
}

test "booleans are a special-value family" {
    const no = Value.boolean(false);
    const yes = Value.boolean(true);
    try std.testing.expect(no.isBool());
    try std.testing.expect(yes.isBool());
    try std.testing.expectEqual(false, no.asBool().?);
    try std.testing.expectEqual(true, yes.asBool().?);
    try std.testing.expect(Value.null_value.asBool() == null);
}

test "short floats preserve finite values and 32-bit integer magnitudes" {
    for ([_]f64{ 0.5, -7.25, -1088058456 }) |number| {
        const encoded = Value.fromFloat64(number);
        try std.testing.expect(encoded.isShortFloat());
        try std.testing.expectEqual(number, encoded.asFloat64().?);
    }
}

test "aligned heap pointers use the low-bit pointer tag" {
    var storage: u64 align(@alignOf(Word)) = 0;
    const value = Value.fromPointer(&storage);
    try std.testing.expect(value.isPointer());
    try std.testing.expectEqual(@intFromPtr(&storage), @intFromPtr(value.asPointer().?));
}

test "native function values encode an index in the short-function tag" {
    const value = Value.shortFunction(37);
    try std.testing.expectEqual(@as(?usize, 37), value.asShortFunction());
    try std.testing.expect(value.asInt() == null);
}
