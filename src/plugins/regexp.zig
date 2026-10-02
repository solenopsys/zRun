const std = @import("std");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig").VM;

pub fn regexTest(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    if (arguments.len < 2) return Value.false_value;
    const regex = context.objects.findRegex(arguments[0]) orelse return error.InvalidRegexReceiver;
    const text = context.objects.findString(arguments[1]) orelse return error.InvalidRegexInput;
    return if (findMatch(regex.pattern, text, 0, regex.ignore_case) != null) Value.true_value else Value.false_value;
}

pub const Match = struct { start: usize, end: usize };
const Atom = union(enum) { literal: u8, any, character_class: []const u8 };

pub fn findMatch(pattern: []const u8, text: []const u8, from: usize, ignore_case: bool) ?Match {
    if (std.mem.indexOfScalar(u8, pattern, '|')) |separator| {
        const left = findMatch(pattern[0..separator], text, from, ignore_case);
        const right = findMatch(pattern[separator + 1 ..], text, from, ignore_case);
        if (left == null) return right;
        if (right == null) return left;
        if (left.?.start <= right.?.start) return left;
        return right;
    }
    if (from > text.len) return null;
    var start = from;
    while (start <= text.len) : (start += 1) {
        if (matchFrom(pattern, text, 0, start, ignore_case)) |end| return .{ .start = start, .end = end };
        if (pattern.len > 0 and pattern[0] == '^') return null;
    }
    return null;
}

fn matchFrom(pattern: []const u8, text: []const u8, pattern_index: usize, text_index: usize, ignore_case: bool) ?usize {
    if (pattern_index >= pattern.len) return text_index;
    var atom: Atom = .{ .literal = pattern[pattern_index] };
    var next_pattern = pattern_index + 1;
    if (pattern[pattern_index] == '[') {
        const class_start = next_pattern;
        if (class_start < pattern.len and pattern[class_start] == '^') next_pattern += 1;
        while (next_pattern < pattern.len and pattern[next_pattern] != ']') : (next_pattern += 1) {}
        if (next_pattern == pattern.len) return null;
        atom = .{ .character_class = pattern[class_start..next_pattern] };
        next_pattern += 1;
    } else if (pattern[pattern_index] == '\\' and next_pattern < pattern.len) {
        atom = .{ .literal = pattern[next_pattern] };
        next_pattern += 1;
    } else if (pattern[pattern_index] == '.') {
        atom = .any;
    }
    if (pattern_index == next_pattern - 1 and pattern[pattern_index] == '$' and next_pattern == pattern.len) return if (text_index == text.len) text_index else null;
    if (pattern_index == next_pattern - 1 and pattern[pattern_index] == '^' and pattern_index == 0) return if (text_index == 0) matchFrom(pattern, text, next_pattern, text_index, ignore_case) else null;
    var quantifier: ?u8 = null;
    if (next_pattern < pattern.len and (pattern[next_pattern] == '+' or pattern[next_pattern] == '*' or pattern[next_pattern] == '?')) {
        quantifier = pattern[next_pattern];
        next_pattern += 1;
    }
    if (quantifier == null) {
        if (text_index >= text.len or !atomMatches(atom, text[text_index], ignore_case)) return null;
        return matchFrom(pattern, text, next_pattern, text_index + 1, ignore_case);
    }
    if (quantifier == '?') {
        if (matchFrom(pattern, text, next_pattern, text_index, ignore_case)) |end| return end;
        if (text_index < text.len and atomMatches(atom, text[text_index], ignore_case)) {
            return matchFrom(pattern, text, next_pattern, text_index + 1, ignore_case);
        }
        return null;
    }
    const minimum: usize = if (quantifier == '+') 1 else 0;
    var matched: usize = 0;
    while (text_index + matched < text.len and atomMatches(atom, text[text_index + matched], ignore_case)) : (matched += 1) {}
    if (matched < minimum) return null;
    var count = matched;
    while (true) {
        if (matchFrom(pattern, text, next_pattern, text_index + count, ignore_case)) |end| return end;
        if (count == minimum) break;
        count -= 1;
    }
    return null;
}

fn atomMatches(atom: Atom, input: u8, ignore_case: bool) bool {
    return switch (atom) {
        .any => true,
        .literal => |pattern| if (ignore_case) std.ascii.toLower(pattern) == std.ascii.toLower(input) else pattern == input,
        .character_class => |pattern| characterClassMatches(pattern, input, ignore_case),
    };
}

fn characterClassMatches(pattern: []const u8, input: u8, ignore_case: bool) bool {
    const negated = pattern.len > 0 and pattern[0] == '^';
    const members = if (negated) pattern[1..] else pattern;
    const candidate = if (ignore_case) std.ascii.toLower(input) else input;
    var included = false;
    var index: usize = 0;
    while (index < members.len) {
        const escaped = members[index] == '\\' and index + 1 < members.len;
        const raw = if (escaped) members[index + 1] else members[index];
        if (escaped and raw == 's') {
            included = included or std.ascii.isWhitespace(input);
            index += 2;
            continue;
        }
        const start_raw = if (!escaped) raw else switch (raw) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '0' => 0,
            else => raw,
        };
        const start = if (ignore_case) std.ascii.toLower(start_raw) else start_raw;
        const token_width: usize = if (escaped) 2 else 1;
        const range_index = index + token_width;
        if (!escaped and range_index + 1 < members.len and members[range_index] == '-') {
            const end = if (ignore_case) std.ascii.toLower(members[range_index + 1]) else members[range_index + 1];
            included = included or (candidate >= start and candidate <= end);
            index = range_index + 2;
        } else {
            included = included or candidate == start;
            index += token_width;
        }
    }
    return if (negated) !included else included;
}
