const std = @import("std");
const Opcode = @import("opcode.zig").Opcode;
const VM = @import("vm.zig").VM;
const FunctionBytecode = @import("vm.zig").FunctionBytecode;
const Value = @import("value.zig").Value;

pub const StringLiteral = struct { bytes: []const u8 };

pub const Program = struct {
    name: []const u8 = "",
    code: []const u8,
    local_count: usize,
    argument_count: usize = 0,
    capture_count: usize = 0,
    capture_sources: []const u16 = &.{},
    capture_local_indices: []const u16 = &.{},
    constants: []const Value = &.{},
    string_values: []const @import("vm.zig").StringValue = &.{},
    functions: []const FunctionBytecode = &.{},
    children: []Program = &.{},
    strings: []*StringLiteral = &.{},

    pub fn bytecode(self: Program) FunctionBytecode {
        return .{
            .name = self.name,
            .code = self.code,
            .constants = self.constants,
            .string_values = self.string_values,
            .local_count = self.local_count,
            .argument_count = self.argument_count,
            .capture_count = self.capture_count,
            .capture_sources = self.capture_sources,
            .capture_local_indices = self.capture_local_indices,
            .functions = self.functions,
        };
    }

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.string_values);
        allocator.free(self.capture_sources);
        allocator.free(self.capture_local_indices);
        allocator.free(self.functions);
        for (self.strings) |string| {
            allocator.free(string.bytes);
            allocator.destroy(string);
        }
        allocator.free(self.strings);
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
    }

    pub fn stringBytes(self: Program, value: Value) ?[]const u8 {
        const pointer = value.asPointer() orelse return null;
        for (self.strings) |string| {
            if (@intFromPtr(string) == @intFromPtr(pointer)) return string.bytes;
        }
        for (self.children) |child| {
            if (child.stringBytes(value)) |bytes| return bytes;
        }
        return null;
    }
};

pub const Error = error{
    ExpectedExpression,
    ExpectedIdentifier,
    ExpectedSemicolon,
    InvalidInteger,
    LocalLimitExceeded,
    InvalidToken,
    UnterminatedString,
    UnsupportedEscape,
    IntegerOutOfRange,
    LoopControlOutsideLoop,
    LoopNestingExceeded,
    TooManyLoopJumps,
    FunctionLimitExceeded,
    OutOfMemory,
    UnknownIdentifier,
    UnexpectedToken,
};

pub fn compile(allocator: std.mem.Allocator, source: []const u8) Error!Program {
    return compileUnit(allocator, source, &.{}, false, null, null, false);
}

const CaptureDefinition = struct { name: []const u8, source: u16 };

fn compileUnit(allocator: std.mem.Allocator, source: []const u8, parameters: []const []const u8, is_function: bool, self_name: ?[]const u8, parent_locals: ?*const std.StringHashMapUnmanaged(u16), is_async: bool) Error!Program {
    var captures: std.ArrayList(CaptureDefinition) = .empty;
    defer captures.deinit(allocator);
    var referenced_names = try collectReferencedNames(allocator, source);
    defer referenced_names.deinit(allocator);
    if (parent_locals) |locals| {
        var iterator = locals.iterator();
        while (iterator.next()) |entry| {
            const name = entry.key_ptr.*;
            var shadowed = if (self_name) |self| std.mem.eql(u8, name, self) else false;
            for (parameters) |parameter| shadowed = shadowed or std.mem.eql(u8, name, parameter);
            shadowed = shadowed or sourceDeclaresName(source, name);
            if (!shadowed and referenced_names.contains(name)) captures.append(allocator, .{ .name = name, .source = entry.value_ptr.* }) catch return error.OutOfMemory;
        }
    }
    if (captures.items.len > std.math.maxInt(u16)) return error.LocalLimitExceeded;
    const capture_sources = allocator.alloc(u16, captures.items.len) catch return error.OutOfMemory;
    for (captures.items, 0..) |capture, index| capture_sources[index] = capture.source;
    const capture_local_indices = allocator.alloc(u16, captures.items.len) catch {
        allocator.free(capture_sources);
        return error.OutOfMemory;
    };
    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .argument_count = parameters.len,
        .capture_count = captures.items.len,
        .capture_sources = capture_sources,
        .capture_local_indices = capture_local_indices,
        .is_function = is_function,
        .is_async = is_async,
    };
    errdefer parser.deinit();
    parser.loops = allocator.alloc(Parser.LoopContext, 64) catch return error.OutOfMemory;
    parser.advance() catch |err| {
        std.debug.print("compile error {s} at byte {d} near `{s}`\n", .{ @errorName(err), parser.current.start, source[parser.current.start..@min(source.len, parser.current.start + 32)] });
        return err;
    };
    for (captures.items, 0..) |capture, index| {
        const local = try parser.declareLocal(capture.name);
        parser.capture_local_indices[index] = local;
    }
    for (parameters, 0..) |parameter, index| {
        const local = try parser.declareLocal(parameter);
        try parser.emitArgumentGet(@intCast(index));
        try parser.emitLocalPut(local);
    }
    if (self_name) |name| {
        if (referenced_names.contains(name)) {
            const local = try parser.declareLocal(name);
            try parser.emit(.fclosure8);
            try parser.emitByte(0);
            try parser.emitLocalPut(local);
        }
    }
    try parser.hoistFunctionDeclarations();
    while (parser.current.kind != .end) {
        parser.statement() catch |err| {
            std.debug.print("compile error {s} at byte {d} near `{s}`\n", .{ @errorName(err), parser.current.start, source[parser.current.start..@min(source.len, parser.current.start + 32)] });
            return err;
        };
    }
    try parser.emitLocalGet(0);
    try parser.emit(.return_value);

    const code = parser.code.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const children = parser.children.toOwnedSlice(allocator) catch {
        allocator.free(code);
        return error.OutOfMemory;
    };
    const constants = parser.constants.toOwnedSlice(allocator) catch {
        allocator.free(code);
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
        return error.OutOfMemory;
    };
    const strings = parser.strings.toOwnedSlice(allocator) catch {
        allocator.free(code);
        allocator.free(constants);
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
        return error.OutOfMemory;
    };
    var string_count = strings.len;
    for (children) |child| string_count += child.string_values.len;
    const string_values = allocator.alloc(@import("vm.zig").StringValue, string_count) catch {
        allocator.free(code);
        allocator.free(constants);
        for (strings) |string| {
            allocator.free(string.bytes);
            allocator.destroy(string);
        }
        allocator.free(strings);
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
        return error.OutOfMemory;
    };
    var string_index: usize = 0;
    for (strings) |string| {
        string_values[string_index] = .{ .value = Value.fromPointer(string), .bytes = string.bytes };
        string_index += 1;
    }
    for (children) |child| {
        @memcpy(string_values[string_index .. string_index + child.string_values.len], child.string_values);
        string_index += child.string_values.len;
    }
    const function_offset: usize = if (is_function) 1 else 0;
    const functions = allocator.alloc(FunctionBytecode, children.len + function_offset) catch {
        allocator.free(code);
        allocator.free(constants);
        allocator.free(string_values);
        for (strings) |string| {
            allocator.free(string.bytes);
            allocator.destroy(string);
        }
        allocator.free(strings);
        for (children) |*child| child.deinit(allocator);
        allocator.free(children);
        return error.OutOfMemory;
    };
    if (is_function) {
        functions[0] = .{
            .name = self_name orelse "",
            .code = code,
            .constants = constants,
            .string_values = string_values,
            .local_count = parser.next_local,
            .argument_count = parameters.len,
            .capture_count = captures.items.len,
            .capture_sources = capture_sources,
            .capture_local_indices = capture_local_indices,
            .functions = functions,
        };
    }
    for (children, 0..) |child, index| functions[index + function_offset] = child.bytecode();
    parser.locals.deinit(allocator);
    allocator.free(parser.loops);
    return .{
        .name = self_name orelse "",
        .code = code,
        .constants = constants,
        .string_values = string_values,
        .local_count = parser.next_local,
        .argument_count = if (is_function) parameters.len else 0,
        .capture_count = if (is_function) captures.items.len else 0,
        .capture_sources = capture_sources,
        .capture_local_indices = capture_local_indices,
        .functions = functions,
        .children = children,
        .strings = strings,
    };
}

const TokenKind = enum {
    end,
    identifier,
    number,
    bigint,
    string,
    template,
    semicolon,
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    dot,
    assign,
    plus,
    minus,
    star,
    slash,
    percent,
    bang,
    less,
    less_equal,
    greater,
    greater_equal,
    equal,
    not_equal,
    strict_equal,
    strict_not_equal,
    logical_and,
    logical_or,
    increment,
    decrement,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    xor,
    xor_assign,
    and_assign,
    or_assign,
    bit_and,
    bit_or,
    shift_left,
    shift_right,
    unsigned_shift_right,
    optional_dot,
    nullish,
    nullish_assign,
    arrow,
    ellipsis,
    comma,
    question,
    colon,
    let_kw,
    const_kw,
    var_kw,
    if_kw,
    while_kw,
    do_kw,
    for_kw,
    switch_kw,
    case_kw,
    default_kw,
    in_kw,
    instanceof_kw,
    typeof_kw,
    class_kw,
    of_kw,
    break_kw,
    continue_kw,
    function_kw,
    return_kw,
    try_kw,
    catch_kw,
    finally_kw,
    throw_kw,
    else_kw,
    true_kw,
    false_kw,
    null_kw,
    undefined_kw,
    void_kw,
    this_kw,
    new_kw,
};

const Token = struct {
    kind: TokenKind,
    start: usize,
    end: usize,
};

fn isIdentifierName(kind: TokenKind) bool {
    return switch (kind) {
        .identifier, .let_kw, .const_kw, .var_kw, .if_kw, .while_kw, .do_kw, .for_kw, .switch_kw, .case_kw, .default_kw, .in_kw, .instanceof_kw, .typeof_kw, .void_kw, .class_kw, .of_kw, .break_kw, .continue_kw, .function_kw, .return_kw, .try_kw, .catch_kw, .finally_kw, .throw_kw, .else_kw, .true_kw, .false_kw, .null_kw, .undefined_kw, .this_kw, .new_kw => true,
        else => false,
    };
}

fn blockBodyEnd(source: []const u8, open_brace: usize) Error!usize {
    var cursor = open_brace + 1;
    var depth: usize = 1;
    var quote: ?u8 = null;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (quote) |delimiter| {
            if (byte == '\\') {
                cursor = @min(cursor + 2, source.len);
                continue;
            }
            if (byte == delimiter) quote = null;
            cursor += 1;
            continue;
        }
        if (byte == '\'' or byte == '"' or byte == '`') {
            quote = byte;
            cursor += 1;
            continue;
        }
        if (byte == '/' and cursor + 1 < source.len) {
            if (source[cursor + 1] == '/') {
                cursor += 2;
                while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {}
                continue;
            }
            if (source[cursor + 1] == '*') {
                cursor += 2;
                while (cursor + 1 < source.len and !(source[cursor] == '*' and source[cursor + 1] == '/')) : (cursor += 1) {}
                if (cursor + 1 >= source.len) return error.UnexpectedToken;
                cursor += 2;
                continue;
            }
        }
        if (byte == '/' and canStartRegex(source, cursor)) {
            if (skipRegexLiteral(source, cursor)) |end| {
                cursor = end;
                continue;
            }
            return error.UnexpectedToken;
        }
        switch (byte) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return cursor;
            },
            else => {},
        }
        cursor += 1;
    }
    return error.UnexpectedToken;
}

fn skipRegexLiteral(source: []const u8, start: usize) ?usize {
    var cursor = start + 1;
    var escaped = false;
    var in_character_class = false;
    while (cursor < source.len) : (cursor += 1) {
        const byte = source[cursor];
        if (escaped) {
            escaped = false;
        } else if (byte == '\\') {
            escaped = true;
        } else if (byte == '[') {
            in_character_class = true;
        } else if (byte == ']') {
            in_character_class = false;
        } else if (byte == '/' and !in_character_class) {
            cursor += 1;
            while (cursor < source.len and std.ascii.isAlphabetic(source[cursor])) : (cursor += 1) {}
            return cursor;
        }
    }
    return null;
}

fn canStartRegex(source: []const u8, offset: usize) bool {
    var cursor = offset;
    while (cursor > 0 and std.ascii.isWhitespace(source[cursor - 1])) cursor -= 1;
    if (cursor == 0) return true;
    const previous = source[cursor - 1];
    if (std.mem.indexOfScalar(u8, "=(:,[!&|?;{}", previous) != null) return true;
    for ([_][]const u8{ "return", "throw", "case", "delete", "void", "typeof", "instanceof", "in" }) |keyword| {
        if (cursor >= keyword.len and std.mem.eql(u8, source[cursor - keyword.len .. cursor], keyword)) return true;
    }
    return false;
}

fn collectReferencedNames(allocator: std.mem.Allocator, source: []const u8) Error!std.StringHashMapUnmanaged(void) {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    errdefer names.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$') {
            const start = cursor;
            cursor += 1;
            while (cursor < source.len and (std.ascii.isAlphanumeric(source[cursor]) or source[cursor] == '_' or source[cursor] == '$')) : (cursor += 1) {}
            names.put(allocator, source[start..cursor], {}) catch return error.OutOfMemory;
        } else {
            cursor += 1;
        }
    }
    return names;
}

fn sourceDeclaresName(source: []const u8, name: []const u8) bool {
    var cursor: usize = 0;
    var in_declaration = false;
    var expect_binding = false;
    var parens: usize = 0;
    var brackets: usize = 0;
    var braces: usize = 0;
    while (cursor < source.len) {
        const byte = source[cursor];
        if (std.ascii.isWhitespace(byte)) {
            cursor += 1;
            continue;
        }
        if (byte == '\'' or byte == '"' or byte == '`') {
            const quote = byte;
            cursor += 1;
            while (cursor < source.len) : (cursor += 1) {
                if (source[cursor] == '\\') {
                    cursor = @min(cursor + 1, source.len - 1);
                } else if (source[cursor] == quote) {
                    cursor += 1;
                    break;
                }
            }
            continue;
        }
        if (byte == '/' and cursor + 1 < source.len and source[cursor + 1] == '/') {
            cursor += 2;
            while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (byte == '/' and cursor + 1 < source.len and source[cursor + 1] == '*') {
            cursor += 2;
            while (cursor + 1 < source.len and !(source[cursor] == '*' and source[cursor + 1] == '/')) : (cursor += 1) {}
            cursor = @min(cursor + 2, source.len);
            continue;
        }
        if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$') {
            const start = cursor;
            cursor += 1;
            while (cursor < source.len and (std.ascii.isAlphanumeric(source[cursor]) or source[cursor] == '_' or source[cursor] == '$')) : (cursor += 1) {}
            const word = source[start..cursor];
            if (std.mem.eql(u8, word, "var") or std.mem.eql(u8, word, "let") or std.mem.eql(u8, word, "const")) {
                var next = cursor;
                while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                if (next < source.len and source[next] == '{') {
                    next += 1;
                    while (next < source.len and source[next] != '}') {
                        while (next < source.len and (std.ascii.isWhitespace(source[next]) or source[next] == ',')) : (next += 1) {}
                        if (next >= source.len or source[next] == '}') break;
                        if (!(std.ascii.isAlphabetic(source[next]) or source[next] == '_' or source[next] == '$')) break;
                        const key_start = next;
                        next += 1;
                        while (next < source.len and (std.ascii.isAlphanumeric(source[next]) or source[next] == '_' or source[next] == '$')) : (next += 1) {}
                        const key = source[key_start..next];
                        while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                        var binding = key;
                        if (next < source.len and source[next] == ':') {
                            next += 1;
                            while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                            const binding_start = next;
                            if (next >= source.len or !(std.ascii.isAlphabetic(source[next]) or source[next] == '_' or source[next] == '$')) break;
                            next += 1;
                            while (next < source.len and (std.ascii.isAlphanumeric(source[next]) or source[next] == '_' or source[next] == '$')) : (next += 1) {}
                            binding = source[binding_start..next];
                        }
                        if (std.mem.eql(u8, binding, name)) return true;
                        while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                        if (next < source.len and source[next] == ',') next += 1 else break;
                    }
                }
                in_declaration = true;
                expect_binding = true;
                continue;
            }
            if (std.mem.eql(u8, word, "function")) {
                var next = cursor;
                while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                if (next < source.len and (std.ascii.isAlphabetic(source[next]) or source[next] == '_' or source[next] == '$')) {
                    const binding_start = next;
                    next += 1;
                    while (next < source.len and (std.ascii.isAlphanumeric(source[next]) or source[next] == '_' or source[next] == '$')) : (next += 1) {}
                    if (std.mem.eql(u8, source[binding_start..next], name)) return true;
                }
            }
            if (std.mem.eql(u8, word, "catch")) {
                var next = cursor;
                while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                if (next < source.len and source[next] == '(') {
                    next += 1;
                    while (next < source.len and std.ascii.isWhitespace(source[next])) : (next += 1) {}
                    if (next < source.len and (std.ascii.isAlphabetic(source[next]) or source[next] == '_' or source[next] == '$')) {
                        const binding_start = next;
                        next += 1;
                        while (next < source.len and (std.ascii.isAlphanumeric(source[next]) or source[next] == '_' or source[next] == '$')) : (next += 1) {}
                        if (std.mem.eql(u8, source[binding_start..next], name)) return true;
                    }
                }
            }
            if (in_declaration and expect_binding) {
                if (std.mem.eql(u8, word, name)) return true;
                expect_binding = false;
            }
            continue;
        }
        switch (byte) {
            '(' => parens += 1,
            ')' => parens -|= 1,
            '[' => brackets += 1,
            ']' => brackets -|= 1,
            '{' => braces += 1,
            '}' => {
                braces -|= 1;
                if (in_declaration and parens == 0 and brackets == 0 and braces == 0) in_declaration = false;
            },
            ',' => if (in_declaration and parens == 0 and brackets == 0 and braces == 0) {
                expect_binding = true;
            },
            ';' => if (parens == 0 and brackets == 0 and braces == 0) {
                in_declaration = false;
                expect_binding = false;
            },
            else => {},
        }
        cursor += 1;
    }
    return false;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    offset: usize = 0,
    current: Token = .{ .kind = .end, .start = 0, .end = 0 },
    code: std.ArrayList(u8) = .empty,
    locals: std.StringHashMapUnmanaged(u16) = .empty,
    next_local: usize = 1,
    argument_count: usize = 0,
    capture_count: usize = 0,
    capture_sources: []u16,
    capture_local_indices: []u16,
    children: std.ArrayList(Program) = .empty,
    constants: std.ArrayList(Value) = .empty,
    strings: std.ArrayList(*StringLiteral) = .empty,
    is_function: bool = false,
    is_async: bool = false,
    loops: []LoopContext = &.{},
    loop_depth: usize = 0,

    const LoopContext = struct {
        continue_target: ?usize,
        accepts_continue: bool = true,
        label: ?[]const u8 = null,
        break_operands: [256]usize = undefined,
        break_count: usize = 0,
        continue_operands: [256]usize = undefined,
        continue_count: usize = 0,
    };

    const ObjectBinding = struct { key: []const u8, local: u16 };

    fn deinit(self: *Parser) void {
        self.code.deinit(self.allocator);
        self.locals.deinit(self.allocator);
        for (self.children.items) |*child| child.deinit(self.allocator);
        self.children.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        for (self.strings.items) |string| {
            self.allocator.free(string.bytes);
            self.allocator.destroy(string);
        }
        self.strings.deinit(self.allocator);
        self.allocator.free(self.capture_sources);
        self.allocator.free(self.capture_local_indices);
        if (self.loops.len > 0) self.allocator.free(self.loops);
    }

    fn advance(self: *Parser) Error!void {
        while (self.offset < self.source.len) {
            const byte = self.source[self.offset];
            if (std.ascii.isWhitespace(byte)) {
                self.offset += 1;
                continue;
            }
            if (byte == '/' and self.offset + 1 < self.source.len and self.source[self.offset + 1] == '/') {
                self.offset += 2;
                while (self.offset < self.source.len and self.source[self.offset] != '\n') self.offset += 1;
                continue;
            }
            if (byte == '/' and self.offset + 1 < self.source.len and self.source[self.offset + 1] == '*') {
                self.offset += 2;
                while (self.offset + 1 < self.source.len and !(self.source[self.offset] == '*' and self.source[self.offset + 1] == '/')) : (self.offset += 1) {}
                if (self.offset + 1 >= self.source.len) return error.UnexpectedToken;
                self.offset += 2;
                continue;
            }
            break;
        }

        if (self.offset == self.source.len) {
            self.current = .{ .kind = .end, .start = self.offset, .end = self.offset };
            return;
        }

        const start = self.offset;
        const byte = self.source[self.offset];
        if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$') {
            self.offset += 1;
            while (self.offset < self.source.len) {
                const next = self.source[self.offset];
                if (!std.ascii.isAlphanumeric(next) and next != '_' and next != '$') break;
                self.offset += 1;
            }
            const word = self.source[start..self.offset];
            const kind: TokenKind = if (std.mem.eql(u8, word, "let")) .let_kw else if (std.mem.eql(u8, word, "const")) .const_kw else if (std.mem.eql(u8, word, "var")) .var_kw else if (std.mem.eql(u8, word, "if")) .if_kw else if (std.mem.eql(u8, word, "while")) .while_kw else if (std.mem.eql(u8, word, "do")) .do_kw else if (std.mem.eql(u8, word, "for")) .for_kw else if (std.mem.eql(u8, word, "switch")) .switch_kw else if (std.mem.eql(u8, word, "case")) .case_kw else if (std.mem.eql(u8, word, "default")) .default_kw else if (std.mem.eql(u8, word, "in")) .in_kw else if (std.mem.eql(u8, word, "of")) .of_kw else if (std.mem.eql(u8, word, "instanceof")) .instanceof_kw else if (std.mem.eql(u8, word, "typeof")) .typeof_kw else if (std.mem.eql(u8, word, "void")) .void_kw else if (std.mem.eql(u8, word, "class")) .class_kw else if (std.mem.eql(u8, word, "break")) .break_kw else if (std.mem.eql(u8, word, "continue")) .continue_kw else if (std.mem.eql(u8, word, "function")) .function_kw else if (std.mem.eql(u8, word, "return")) .return_kw else if (std.mem.eql(u8, word, "try")) .try_kw else if (std.mem.eql(u8, word, "catch")) .catch_kw else if (std.mem.eql(u8, word, "finally")) .finally_kw else if (std.mem.eql(u8, word, "throw")) .throw_kw else if (std.mem.eql(u8, word, "else")) .else_kw else if (std.mem.eql(u8, word, "true")) .true_kw else if (std.mem.eql(u8, word, "false")) .false_kw else if (std.mem.eql(u8, word, "null")) .null_kw else if (std.mem.eql(u8, word, "undefined")) .undefined_kw else if (std.mem.eql(u8, word, "this")) .this_kw else if (std.mem.eql(u8, word, "new")) .new_kw else .identifier;
            self.current = .{ .kind = kind, .start = start, .end = self.offset };
            return;
        }
        if (std.ascii.isDigit(byte)) {
            self.offset += 1;
            if (byte == '0' and self.offset < self.source.len and (self.source[self.offset] == 'x' or self.source[self.offset] == 'X')) {
                self.offset += 1;
                while (self.offset < self.source.len and std.ascii.isHex(self.source[self.offset])) self.offset += 1;
            } else {
                while (self.offset < self.source.len and std.ascii.isDigit(self.source[self.offset])) self.offset += 1;
                if (self.offset < self.source.len and self.source[self.offset] == '.' and
                    self.offset + 1 < self.source.len and std.ascii.isDigit(self.source[self.offset + 1]))
                {
                    self.offset += 1;
                    while (self.offset < self.source.len and std.ascii.isDigit(self.source[self.offset])) self.offset += 1;
                }
                if (self.offset < self.source.len and (self.source[self.offset] == 'e' or self.source[self.offset] == 'E')) {
                    self.offset += 1;
                    if (self.offset < self.source.len and (self.source[self.offset] == '+' or self.source[self.offset] == '-')) self.offset += 1;
                    const exponent_start = self.offset;
                    while (self.offset < self.source.len and std.ascii.isDigit(self.source[self.offset])) self.offset += 1;
                    if (self.offset == exponent_start) return error.InvalidInteger;
                }
            }
            const kind: TokenKind = if (self.take('n')) .bigint else .number;
            self.current = .{ .kind = kind, .start = start, .end = self.offset };
            return;
        }
        if (byte == '`') {
            self.offset += 1;
            while (self.offset < self.source.len and self.source[self.offset] != '`') {
                if (self.source[self.offset] == '\\' and self.offset + 1 < self.source.len) self.offset += 1;
                self.offset += 1;
            }
            if (self.offset == self.source.len) return error.UnterminatedString;
            self.offset += 1;
            self.current = .{ .kind = .template, .start = start, .end = self.offset };
            return;
        }
        if (byte == '\'' or byte == '"') {
            self.offset += 1;
            while (self.offset < self.source.len and self.source[self.offset] != byte) {
                if (self.source[self.offset] == '\\') {
                    self.offset += 1;
                    if (self.offset == self.source.len) return error.UnterminatedString;
                } else if (self.source[self.offset] == '\n' or self.source[self.offset] == '\r') {
                    return error.UnterminatedString;
                }
                self.offset += 1;
            }
            if (self.offset == self.source.len) return error.UnterminatedString;
            self.offset += 1;
            self.current = .{ .kind = .string, .start = start, .end = self.offset };
            return;
        }

        self.offset += 1;
        const kind: TokenKind = switch (byte) {
            ',' => .comma,
            '?' => if (self.take('?')) (if (self.take('=')) .nullish_assign else .nullish) else if (self.take('.')) .optional_dot else .question,
            ':' => .colon,
            ';' => .semicolon,
            '(' => .left_paren,
            ')' => .right_paren,
            '{' => .left_brace,
            '}' => .right_brace,
            '[' => .left_bracket,
            ']' => .right_bracket,
            '.' => if (self.take('.')) blk: {
                if (!self.take('.')) return error.InvalidToken;
                break :blk .ellipsis;
            } else .dot,
            '+' => if (self.take('+')) .increment else if (self.take('=')) .plus_assign else .plus,
            '-' => if (self.take('-')) .decrement else if (self.take('=')) .minus_assign else .minus,
            '*' => if (self.take('=')) .star_assign else .star,
            '^' => if (self.take('=')) .xor_assign else .xor,
            '/' => if (self.take('=')) .slash_assign else .slash,
            '%' => .percent,
            '!' => if (self.take('=')) blk: {
                break :blk if (self.take('=')) .strict_not_equal else .not_equal;
            } else .bang,
            '=' => if (self.take('=')) blk: {
                break :blk if (self.take('=')) .strict_equal else .equal;
            } else if (self.take('>')) .arrow else .assign,
            '<' => if (self.take('<')) .shift_left else if (self.take('=')) .less_equal else .less,
            '>' => if (self.take('>')) blk: {
                break :blk if (self.take('>')) .unsigned_shift_right else .shift_right;
            } else if (self.take('=')) .greater_equal else .greater,
            '&' => if (self.take('&')) .logical_and else if (self.take('=')) .and_assign else .bit_and,
            '|' => if (self.take('|')) .logical_or else if (self.take('=')) .or_assign else .bit_or,
            else => return error.InvalidToken,
        };
        self.current = .{ .kind = kind, .start = start, .end = self.offset };
    }

    fn take(self: *Parser, expected: u8) bool {
        if (self.offset >= self.source.len or self.source[self.offset] != expected) return false;
        self.offset += 1;
        return true;
    }

    fn nextIsLeftParen(self: *Parser) bool {
        var cursor = self.offset;
        while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) cursor += 1;
        return cursor < self.source.len and self.source[cursor] == '(';
    }

    fn nextIsDot(self: *Parser) bool {
        var cursor = self.offset;
        while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) cursor += 1;
        return cursor < self.source.len and self.source[cursor] == '.';
    }

    fn statement(self: *Parser) Error!void {
        switch (self.current.kind) {
            .semicolon => try self.advance(),
            .let_kw, .const_kw, .var_kw => try self.variableDeclaration(),
            .if_kw => try self.ifStatement(),
            .while_kw => try self.whileStatement(),
            .do_kw => try self.doWhileStatement(),
            .for_kw => try self.forStatement(),
            .switch_kw => try self.switchStatement(),
            .function_kw => try self.functionDeclaration(false),
            .class_kw => try self.classDeclaration(),
            .return_kw => try self.returnStatement(),
            .throw_kw => try self.throwStatement(),
            .try_kw => try self.tryStatement(),
            .break_kw => try self.loopControl(false),
            .continue_kw => try self.loopControl(true),
            .left_brace => try self.blockStatement(),
            .identifier => {
                const first_identifier = self.current;
                const name = self.lexeme();
                if (std.mem.eql(u8, name, "async")) {
                    try self.advance();
                    if (self.current.kind != .function_kw) return error.UnexpectedToken;
                    try self.functionDeclaration(true);
                    return;
                }
                try self.advance();
                if (self.current.kind == .colon) {
                    try self.advance();
                    if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
                    const context_index = self.loop_depth;
                    self.loops[context_index] = .{ .continue_target = null, .accepts_continue = false, .label = name };
                    self.loop_depth += 1;
                    try self.statement();
                    const label_end = self.code.items.len;
                    for (self.loops[context_index].break_operands[0..self.loops[context_index].break_count]) |operand| try self.patchBranch(operand, label_end);
                    self.loop_depth -= 1;
                    return;
                }
                self.offset = first_identifier.start;
                try self.advance();
                if (std.mem.eql(u8, name, "globalThis")) {
                    try self.globalThisStatement();
                } else if (self.locals.contains(name) or std.mem.eql(u8, name, "print")) {
                    try self.identifierStatement();
                } else {
                    try self.expressionSequence();
                    try self.expect(.semicolon);
                    try self.emitLocalPut(0);
                }
            },
            else => {
                try self.expressionSequence();
                try self.expect(.semicolon);
                try self.emitLocalPut(0);
            },
        }
    }

    fn globalThisStatement(self: *Parser) Error!void {
        try self.emit(.push_global_this);
        try self.advance();
        if (self.current.kind == .dot) {
            try self.advance();
            if (!isIdentifierName(self.current.kind)) return error.ExpectedIdentifier;
            const property_index = try self.addStringConstant(self.lexeme());
            try self.advance();
            if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
                try self.emit(.put_field);
                try self.emitU16(@intCast(property_index));
                try self.emit(.drop);
                try self.expect(.semicolon);
                return;
            }
            if (self.current.kind == .left_paren) {
                try self.emit(.get_field2);
                try self.emitU16(@intCast(property_index));
                try self.callSuffixWithReceiver(0, true);
            } else {
                try self.emit(.get_field);
                try self.emitU16(@intCast(property_index));
                try self.callSuffixWithReceiver(0, false);
            }
        } else {
            try self.expect(.left_bracket);
            try self.expression(1);
            try self.expect(.right_bracket);
            if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
                try self.emit(.put_array_el);
                try self.expect(.semicolon);
                return;
            }
            if (self.current.kind == .left_paren) {
                try self.emit(.get_array_el2);
                try self.callSuffixWithReceiver(0, true);
            } else {
                try self.emit(.get_array_el);
                try self.callSuffixWithReceiver(0, false);
            }
        }
        try self.expressionTail(1);
        try self.expressionSequenceTail();
        try self.expect(.semicolon);
        try self.emit(.drop);
    }

    fn variableDeclaration(self: *Parser) Error!void {
        try self.advance();
        while (true) {
            if (self.current.kind == .left_brace) {
                const PropertyBinding = struct { key: []const u8, local: u16 };
                var bindings: std.ArrayList(PropertyBinding) = .empty;
                defer bindings.deinit(self.allocator);
                try self.advance();
                while (self.current.kind != .right_brace) {
                    if (self.current.kind != .identifier and self.current.kind != .string) return error.ExpectedIdentifier;
                    const key = if (self.current.kind == .identifier)
                        self.lexeme()
                    else
                        self.source[self.current.start + 1 .. self.current.end - 1];
                    try self.advance();
                    const binding_name = if (self.current.kind == .colon) blk: {
                        try self.advance();
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const alias = self.lexeme();
                        try self.advance();
                        break :blk alias;
                    } else key;
                    const local = self.locals.get(binding_name) orelse try self.declareLocal(binding_name);
                    bindings.append(self.allocator, .{ .key = key, .local = local }) catch return error.OutOfMemory;
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_brace);
                try self.expect(.assign);
                try self.expression(1);
                const source_local = try self.declareTempLocal("object_destructure");
                try self.emitLocalPut(source_local);
                for (bindings.items) |binding| {
                    const property_index = try self.addStringConstant(binding.key);
                    try self.emitLocalGet(source_local);
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                    try self.emitLocalPut(binding.local);
                }
                if (self.current.kind != .comma) break;
                try self.advance();
                continue;
            }
            if (self.current.kind == .left_bracket) {
                try self.advance();
                var slots: std.ArrayList(?u16) = .empty;
                defer slots.deinit(self.allocator);
                while (self.current.kind != .right_bracket) {
                    if (self.current.kind == .comma) {
                        slots.append(self.allocator, null) catch return error.OutOfMemory;
                    } else {
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const local = try self.declareLocal(self.lexeme());
                        slots.append(self.allocator, local) catch return error.OutOfMemory;
                        try self.advance();
                    }
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_bracket);
                try self.expect(.assign);
                try self.expression(1);
                const source_local = try self.declareTempLocal("destructure");
                try self.emitLocalPut(source_local);
                for (slots.items, 0..) |slot, position| {
                    if (slot) |local| {
                        try self.emitLocalGet(source_local);
                        try self.emitInteger(@intCast(position));
                        try self.emit(.get_array_el);
                        try self.emitLocalPut(local);
                    }
                }
                if (self.current.kind != .comma) break;
                try self.advance();
                continue;
            }
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const name = self.lexeme();
            const index = self.locals.get(name) orelse try self.declareLocal(name);
            try self.advance();
            if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
            } else {
                try self.emit(.undefined_value);
            }
            try self.emitLocalPut(index);
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        try self.expect(.semicolon);
    }

    fn functionDeclaration(self: *Parser, is_async: bool) Error!void {
        try self.advance();
        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
        const name = self.lexeme();
        const local = self.locals.get(name) orelse try self.declareLocal(name);
        try self.advance();
        try self.expect(.left_paren);

        var parameters: std.ArrayList([]const u8) = .empty;
        defer parameters.deinit(self.allocator);
        var prologue: std.ArrayList(u8) = .empty;
        defer prologue.deinit(self.allocator);
        var parameter_index: usize = 0;
        while (self.current.kind != .right_paren) {
            if (self.current.kind == .left_brace) {
                const synthetic = try self.syntheticParameterName(parameter_index);
                parameter_index += 1;
                parameters.append(self.allocator, synthetic) catch return error.OutOfMemory;
                try self.advance();
                while (self.current.kind != .right_brace) {
                    if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                    const property = self.lexeme();
                    try self.advance();
                    const binding = if (self.current.kind == .colon) blk: {
                        try self.advance();
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const alias = self.lexeme();
                        try self.advance();
                        break :blk alias;
                    } else property;
                    const declaration = try std.fmt.allocPrint(self.allocator, "var {s} = {s}.{s};\n", .{ binding, synthetic, property });
                    defer self.allocator.free(declaration);
                    prologue.appendSlice(self.allocator, declaration) catch return error.OutOfMemory;
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_brace);
            } else {
                if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                const parameter = self.lexeme();
                parameters.append(self.allocator, parameter) catch return error.OutOfMemory;
                try self.advance();
                try self.appendDefaultParameter(parameter, &prologue);
            }
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        try self.expect(.right_paren);
        if (self.current.kind != .left_brace) return error.UnexpectedToken;
        const body_open = self.current.start;
        const body_start = body_open + 1;
        const body_end = try blockBodyEnd(self.source, body_open);
        self.offset = body_end + 1;
        try self.advance();

        const body = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prologue.items, self.source[body_start..body_end] });
        defer self.allocator.free(body);
        const child = compileUnit(self.allocator, body, parameters.items, true, name, &self.locals, is_async) catch |err| {
            std.debug.print("failed function body {s}: {s}\n", .{ name, body });
            return err;
        };
        var owns_child = true;
        errdefer if (owns_child) {
            var owned_child = child;
            owned_child.deinit(self.allocator);
        };
        const function_offset: usize = if (self.is_function) 1 else 0;
        if (self.children.items.len + function_offset > std.math.maxInt(u16)) return error.FunctionLimitExceeded;
        const function_index: u16 = @intCast(self.children.items.len + function_offset);
        self.children.append(self.allocator, child) catch return error.OutOfMemory;
        owns_child = false;
        if (function_index <= std.math.maxInt(u8)) {
            try self.emit(.fclosure8);
            try self.emitByte(@intCast(function_index));
        } else {
            try self.emit(.fclosure);
            try self.emitU16(function_index);
        }
        try self.emitLocalPut(local);
    }

    fn classDeclaration(self: *Parser) Error!void {
        try self.advance();
        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
        const name = self.lexeme();
        const local = try self.declareLocal(name);
        try self.advance();
        var extends_error = false;
        if (self.current.kind == .identifier and std.mem.eql(u8, self.lexeme(), "extends")) {
            try self.advance();
            if (self.current.kind != .identifier or !std.mem.eql(u8, self.lexeme(), "Error")) return error.UnexpectedToken;
            extends_error = true;
            try self.advance();
        }
        try self.expect(.left_brace);
        var parameters: std.ArrayList([]const u8) = .empty;
        defer parameters.deinit(self.allocator);
        var prologue: std.ArrayList(u8) = .empty;
        defer prologue.deinit(self.allocator);
        var body_source: []const u8 = undefined;
        if (self.current.kind == .right_brace and extends_error) {
            parameters.append(self.allocator, "message") catch return error.OutOfMemory;
            body_source = "this.message = message;";
            try self.expect(.right_brace);
        } else {
            if (self.current.kind != .identifier or !std.mem.eql(u8, self.lexeme(), "constructor")) return error.UnexpectedToken;
            try self.advance();
            try self.expect(.left_paren);
            while (self.current.kind != .right_paren) {
                if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                const parameter = self.lexeme();
                parameters.append(self.allocator, parameter) catch return error.OutOfMemory;
                try self.advance();
                try self.appendDefaultParameter(parameter, &prologue);
                if (self.current.kind != .comma) break;
                try self.advance();
            }
            try self.expect(.right_paren);
            if (self.current.kind != .left_brace) return error.UnexpectedToken;
            const body_open = self.current.start;
            const body_start = body_open + 1;
            const body_end = try blockBodyEnd(self.source, body_open);
            self.offset = body_end + 1;
            try self.advance();
            try self.expect(.right_brace);
            body_source = self.source[body_start..body_end];
        }
        const body = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prologue.items, body_source });
        defer self.allocator.free(body);
        const child = try compileUnit(self.allocator, body, parameters.items, true, null, &self.locals, false);
        var owns_child = true;
        errdefer if (owns_child) {
            var owned_child = child;
            owned_child.deinit(self.allocator);
        };
        const function_offset: usize = if (self.is_function) 1 else 0;
        if (self.children.items.len + function_offset > std.math.maxInt(u16)) return error.FunctionLimitExceeded;
        const function_index: u16 = @intCast(self.children.items.len + function_offset);
        self.children.append(self.allocator, child) catch return error.OutOfMemory;
        owns_child = false;
        if (function_index <= std.math.maxInt(u8)) {
            try self.emit(.fclosure8);
            try self.emitByte(@intCast(function_index));
        } else {
            try self.emit(.fclosure);
            try self.emitU16(function_index);
        }
        try self.emitLocalPut(local);
    }

    fn returnStatement(self: *Parser) Error!void {
        try self.advance();
        if (self.current.kind == .semicolon) {
            try self.emit(.undefined_value);
        } else {
            try self.expressionSequence();
        }
        try self.expect(.semicolon);
        try self.emit(.return_value);
    }

    fn throwStatement(self: *Parser) Error!void {
        try self.advance();
        try self.expressionSequence();
        try self.expect(.semicolon);
        try self.emit(.throw);
    }

    fn tryStatement(self: *Parser) Error!void {
        try self.advance();
        const outer_handler = try self.emitBranch(.catch_value);
        const handler_branch = try self.emitBranch(.catch_value);
        try self.statement();
        try self.emit(.drop);
        const normal_after_try = try self.emitBranch(.goto);
        try self.patchBranch(handler_branch, self.code.items.len);

        const has_catch = self.current.kind == .catch_kw;
        if (has_catch) {
            try self.advance();
            if (self.current.kind == .left_paren) {
                try self.advance();
                if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                const catch_local = self.locals.get(self.lexeme()) orelse try self.declareLocal(self.lexeme());
                try self.advance();
                try self.expect(.right_paren);
                try self.emitLocalPut(catch_local);
            } else {
                try self.emit(.drop);
            }
            try self.statement();
            const catch_end = try self.emitBranch(.goto);
            const successful_body = self.code.items.len;
            try self.patchBranch(normal_after_try, successful_body);
            try self.patchBranch(catch_end, successful_body);
            try self.emit(.drop);
            if (self.current.kind == .finally_kw) {
                try self.advance();
                const finally_start = self.current.start;
                try self.statement();
                const after_finally = self.offset;
                const after_finally_token = self.current;
                const normal_exit = try self.emitBranch(.goto);

                try self.patchBranch(outer_handler, self.code.items.len);
                const thrown_value = try self.declareTempLocal("finally_error");
                try self.emitLocalPut(thrown_value);
                self.offset = finally_start;
                try self.advance();
                try self.statement();
                try self.emitLocalGet(thrown_value);
                try self.emit(.throw);

                self.offset = after_finally;
                self.current = after_finally_token;
                try self.patchBranch(normal_exit, self.code.items.len);
            } else {
                const normal_exit = try self.emitBranch(.goto);
                try self.patchBranch(outer_handler, self.code.items.len);
                try self.emit(.throw);
                try self.patchBranch(normal_exit, self.code.items.len);
            }
            return;
        }

        if (self.current.kind == .finally_kw) {
            try self.emit(.swap);
            try self.emit(.drop);
            const thrown_value = try self.declareTempLocal("finally_error");
            try self.emitLocalPut(thrown_value);
            try self.advance();
            const finally_start = self.current.start;
            try self.statement();
            try self.emitLocalGet(thrown_value);
            try self.emit(.throw);
            const final_error_end = self.offset;
            const final_error_token = self.current;

            try self.patchBranch(outer_handler, self.code.items.len);
            try self.emit(.throw);

            try self.patchBranch(normal_after_try, self.code.items.len);
            try self.emit(.drop);
            self.offset = finally_start;
            try self.advance();
            try self.statement();
            self.offset = final_error_end;
            self.current = final_error_token;
            return;
        }

        return error.UnexpectedToken;
    }

    fn identifierStatement(self: *Parser) Error!void {
        const name = self.lexeme();
        const maybe_index = self.locals.get(name);
        try self.advance();
        if (maybe_index == null and std.mem.eql(u8, name, "print") and self.current.kind == .left_paren) {
            _ = try self.emitConstant(Value.shortFunction(0));
            try self.callSuffix();
            try self.expressionTail(1);
            try self.expressionSequenceTail();
            try self.expect(.semicolon);
            try self.emitLocalPut(0);
            return;
        }
        const index = maybe_index orelse return error.UnknownIdentifier;
        if (self.current.kind == .left_bracket) {
            try self.emitLocalGet(index);
            try self.advance();
            try self.expression(1);
            try self.expect(.right_bracket);
            if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
                try self.emit(.put_array_el);
                try self.discardedExpressionSequenceTail();
            } else {
                try self.emit(.get_array_el);
                try self.callSuffix();
                try self.expressionTail(1);
                try self.expressionSequenceTail();
                try self.expect(.semicolon);
                try self.emitLocalPut(0);
                return;
            }
            try self.expect(.semicolon);
            return;
        }
        if (self.current.kind == .dot) {
            try self.emitLocalGet(index);
            try self.advance();
            if (self.current.kind != .identifier) return error.UnknownIdentifier;
            const property = self.lexeme();
            try self.advance();
            if (self.current.kind == .assign) {
                const property_index = try self.addStringConstant(property);
                try self.advance();
                try self.expression(1);
                try self.emit(.put_field);
                try self.emitU16(@intCast(property_index));
                try self.expressionSequenceTail();
                try self.emit(.drop);
                try self.expect(.semicolon);
                return;
            }
            if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .xor_assign or self.current.kind == .and_assign or self.current.kind == .or_assign) {
                const operator = self.current.kind;
                const property_index = try self.addStringConstant(property);
                try self.emit(.dup);
                try self.emit(.get_field);
                try self.emitU16(@intCast(property_index));
                try self.advance();
                try self.expression(1);
                try self.emit(switch (operator) {
                    .plus_assign => .add,
                    .minus_assign => .sub,
                    .star_assign => .mul,
                    .xor_assign => .xor,
                    .and_assign => .and_op,
                    .or_assign => .or_op,
                    else => unreachable,
                });
                try self.emit(.put_field);
                try self.emitU16(@intCast(property_index));
                try self.expressionSequenceTail();
                try self.emit(.drop);
                try self.expect(.semicolon);
                return;
            }
            if (std.mem.eql(u8, property, "length")) {
                try self.emit(.get_length);
            } else if (self.current.kind == .left_paren) {
                const property_index = try self.addStringConstant(property);
                try self.emit(.get_field2);
                try self.emitU16(@intCast(property_index));
                try self.callSuffixWithReceiver(0, true);
                try self.expressionTail(1);
                try self.expressionSequenceTail();
                try self.expect(.semicolon);
                try self.emitLocalPut(0);
                return;
            } else {
                const property_index = try self.addStringConstant(property);
                try self.emit(.get_field);
                try self.emitU16(@intCast(property_index));
            }
            try self.callSuffixWithReceiver(0, false);
            try self.expressionTail(1);
            try self.expressionSequenceTail();
            try self.expect(.semicolon);
            try self.emitLocalPut(0);
            return;
        }
        if (self.current.kind == .assign) {
            try self.advance();
            if (try self.localSelfUpdateOperator(name)) |opcode| {
                try self.advance();
                try self.advance();
                try self.expression(1);
                try self.emit(opcode);
                try self.emitU16(index);
                try self.expect(.semicolon);
                return;
            }
            try self.expression(1);
            try self.emit(.dup);
            try self.emitLocalPut(index);
            try self.expressionSequenceTail();
            try self.emit(.drop);
            try self.expect(.semicolon);
            return;
        }
        if (self.current.kind == .increment) {
            try self.advance();
            try self.emitLocalGet(index);
            try self.emit(.inc);
            try self.emitLocalPut(index);
            try self.expect(.semicolon);
            return;
        }
        if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .slash_assign or self.current.kind == .xor_assign or self.current.kind == .and_assign or self.current.kind == .or_assign) {
            const operator = self.current.kind;
            try self.advance();
            if (operator == .plus_assign or operator == .minus_assign) {
                try self.expression(1);
                try self.emit(if (operator == .plus_assign) .add_loc else .sub_loc);
                try self.emitU16(index);
                try self.expect(.semicolon);
                return;
            }
            try self.emitLocalGet(index);
            try self.expression(1);
            try self.emit(switch (operator) {
                .plus_assign => .add,
                .minus_assign => .sub,
                .star_assign => .mul,
                .slash_assign => .div,
                .xor_assign => .xor,
                .and_assign => .and_op,
                .or_assign => .or_op,
                else => unreachable,
            });
            try self.emitLocalPut(index);
            try self.expect(.semicolon);
            return;
        }
        if (self.current.kind == .nullish_assign) {
            try self.advance();
            try self.emitLocalGet(index);
            try self.emit(.dup);
            try self.emit(.null_value);
            try self.emit(.strict_eq);
            const use_rhs_from_null = try self.emitBranch(.if_true);
            try self.emit(.dup);
            try self.emit(.undefined_value);
            try self.emit(.strict_eq);
            const use_rhs_from_undefined = try self.emitBranch(.if_true);
            const done = try self.emitBranch(.goto);
            const rhs = self.code.items.len;
            try self.patchBranch(use_rhs_from_null, rhs);
            try self.patchBranch(use_rhs_from_undefined, rhs);
            try self.emit(.drop);
            try self.expression(1);
            try self.emit(.dup);
            try self.emitLocalPut(index);
            try self.emit(.drop);
            try self.patchBranch(done, self.code.items.len);
            try self.expect(.semicolon);
            return;
        }
        try self.emitLocalGet(index);
        try self.callSuffix();
        try self.expressionTail(1);
        try self.expressionSequenceTail();
        try self.expect(.semicolon);
        try self.emitLocalPut(0);
    }

    fn localSelfUpdateOperator(self: *Parser, name: []const u8) Error!?Opcode {
        if (self.current.kind != .identifier or !std.mem.eql(u8, self.lexeme(), name)) return null;
        var lookahead = self.*;
        try lookahead.advance();
        const opcode: Opcode = switch (lookahead.current.kind) {
            .plus => .add_loc,
            .minus => .sub_loc,
            else => return null,
        };
        try lookahead.advance();
        if (lookahead.current.kind != .number) return null;
        try lookahead.advance();
        if (lookahead.current.kind != .semicolon) return null;
        return opcode;
    }

    fn blockStatement(self: *Parser) Error!void {
        try self.advance();
        while (self.current.kind != .right_brace) {
            if (self.current.kind == .end) return error.UnexpectedToken;
            try self.statement();
        }
        try self.advance();
    }

    fn ifStatement(self: *Parser) Error!void {
        try self.advance();
        try self.expect(.left_paren);
        try self.expressionSequence();
        try self.expect(.right_paren);
        const false_branch = try self.emitBranch(.if_false);
        try self.statement();
        if (self.current.kind == .else_kw) {
            const end_branch = try self.emitBranch(.goto);
            try self.patchBranch(false_branch, self.code.items.len);
            try self.advance();
            try self.statement();
            try self.patchBranch(end_branch, self.code.items.len);
        } else {
            try self.patchBranch(false_branch, self.code.items.len);
        }
    }

    fn whileStatement(self: *Parser) Error!void {
        try self.advance();
        const loop_start = self.code.items.len;
        try self.expect(.left_paren);
        try self.expressionSequence();
        try self.expect(.right_paren);
        const exit_branch = try self.emitBranch(.if_false);
        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = loop_start };
        self.loop_depth += 1;
        try self.statement();
        const repeat_branch = try self.emitBranch(.goto);
        try self.patchBranch(repeat_branch, loop_start);
        const loop_end = self.code.items.len;
        try self.patchBranch(exit_branch, loop_end);
        const context = self.loops[context_index];
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, loop_end);
        self.loop_depth -= 1;
    }

    fn doWhileStatement(self: *Parser) Error!void {
        try self.advance();
        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = null };
        self.loop_depth += 1;
        const body_start = self.code.items.len;
        try self.statement();
        const condition_start = self.code.items.len;
        const context = &self.loops[context_index];
        context.continue_target = condition_start;
        for (context.continue_operands[0..context.continue_count]) |operand| try self.patchBranch(operand, condition_start);
        try self.expect(.while_kw);
        try self.expect(.left_paren);
        try self.expressionSequence();
        try self.expect(.right_paren);
        if (self.current.kind == .semicolon) try self.advance();
        const repeat_branch = try self.emitBranch(.if_true);
        try self.patchBranch(repeat_branch, body_start);
        const loop_end = self.code.items.len;
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, loop_end);
        self.loop_depth -= 1;
    }

    fn forStatement(self: *Parser) Error!void {
        try self.advance();
        try self.expect(.left_paren);
        if (self.current.kind == .let_kw or self.current.kind == .const_kw or self.current.kind == .var_kw) {
            try self.advance();
            if (self.current.kind == .left_brace) {
                var bindings: std.ArrayList(ObjectBinding) = .empty;
                defer bindings.deinit(self.allocator);
                try self.advance();
                while (self.current.kind != .right_brace) {
                    if (self.current.kind != .identifier and self.current.kind != .string) return error.ExpectedIdentifier;
                    const key = if (self.current.kind == .identifier) self.lexeme() else self.source[self.current.start + 1 .. self.current.end - 1];
                    try self.advance();
                    const binding = if (self.current.kind == .colon) blk: {
                        try self.advance();
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const alias = self.lexeme();
                        try self.advance();
                        break :blk alias;
                    } else key;
                    const local = self.locals.get(binding) orelse try self.declareLocal(binding);
                    bindings.append(self.allocator, .{ .key = key, .local = local }) catch return error.OutOfMemory;
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_brace);
                if (self.current.kind != .in_kw and self.current.kind != .of_kw) return error.UnexpectedToken;
                const is_in = self.current.kind == .in_kw;
                try self.advance();
                const target = try self.declareTempLocal("for_object_target");
                return self.forEachObjectStatement(target, is_in, bindings.items);
            } else if (self.current.kind == .left_bracket) {
                try self.advance();
                var slots: std.ArrayList(?u16) = .empty;
                defer slots.deinit(self.allocator);
                while (self.current.kind != .right_bracket) {
                    if (self.current.kind == .comma) {
                        slots.append(self.allocator, null) catch return error.OutOfMemory;
                    } else {
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const local = self.locals.get(self.lexeme()) orelse try self.declareLocal(self.lexeme());
                        slots.append(self.allocator, local) catch return error.OutOfMemory;
                        try self.advance();
                    }
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_bracket);
                if (self.current.kind != .in_kw and self.current.kind != .of_kw) return error.UnexpectedToken;
                const is_in = self.current.kind == .in_kw;
                try self.advance();
                const target = try self.declareTempLocal("for_target");
                return self.forEachStatement(target, is_in, slots.items);
            }
            if (self.current.kind != .identifier) return error.ExpectedIdentifier;
            const target = self.locals.get(self.lexeme()) orelse try self.declareLocal(self.lexeme());
            try self.advance();
            if (self.current.kind == .in_kw or self.current.kind == .of_kw) {
                const is_in = self.current.kind == .in_kw;
                try self.advance();
                return self.forEachStatement(target, is_in, &.{});
            }
            if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
            } else {
                try self.emit(.undefined_value);
            }
            try self.emitLocalPut(target);
            while (self.current.kind == .comma) {
                try self.advance();
                if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                const next_target = self.locals.get(self.lexeme()) orelse try self.declareLocal(self.lexeme());
                try self.advance();
                if (self.current.kind == .assign) {
                    try self.advance();
                    try self.expression(1);
                } else {
                    try self.emit(.undefined_value);
                }
                try self.emitLocalPut(next_target);
            }
            try self.expect(.semicolon);
        } else if (self.current.kind == .identifier) {
            const first_identifier = self.current;
            const name = self.lexeme();
            try self.advance();
            if (self.current.kind == .in_kw or self.current.kind == .of_kw) {
                const target = self.locals.get(name) orelse return error.UnknownIdentifier;
                const is_in = self.current.kind == .in_kw;
                try self.advance();
                return self.forEachStatement(target, is_in, &.{});
            }
            self.offset = first_identifier.start;
            try self.advance();
            try self.expressionSequence();
            try self.emit(.drop);
            try self.expect(.semicolon);
        } else if (self.current.kind == .semicolon) {
            try self.advance();
        } else {
            try self.expressionSequence();
            try self.emit(.drop);
            try self.expect(.semicolon);
        }

        const loop_start = self.code.items.len;
        if (self.current.kind == .semicolon) {
            try self.emit(.push_true);
        } else {
            try self.expressionSequence();
        }
        try self.expect(.semicolon);
        const exit_branch = try self.emitBranch(.if_false);
        const update_code = try self.captureForUpdate();
        defer self.allocator.free(update_code);
        try self.expect(.right_paren);

        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = null };
        self.loop_depth += 1;
        try self.statement();

        const update_start = self.code.items.len;
        var context = &self.loops[context_index];
        context.continue_target = update_start;
        for (context.continue_operands[0..context.continue_count]) |operand| try self.patchBranch(operand, update_start);
        self.code.appendSlice(self.allocator, update_code) catch return error.OutOfMemory;
        const repeat_branch = try self.emitBranch(.goto);
        try self.patchBranch(repeat_branch, loop_start);
        const loop_end = self.code.items.len;
        try self.patchBranch(exit_branch, loop_end);
        context = &self.loops[context_index];
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, loop_end);
        self.loop_depth -= 1;
    }

    fn forEachStatement(self: *Parser, target: u16, is_in: bool, destructured: []const ?u16) Error!void {
        // A for-in/of RHS is an Expression, so a comma expression such as
        // `for (key in target = {}, source)` must be consumed as one value.
        try self.forEachRightHandSide(is_in);
        const iterable = try self.declareTempLocal("iterator");
        try self.emitLocalPut(iterable);
        const index = try self.declareTempLocal("index");
        try self.emitInteger(0);
        try self.emitLocalPut(index);
        const loop_start = self.code.items.len;
        try self.emitLocalGet(index);
        try self.emitLocalGet(iterable);
        try self.emit(.get_length);
        try self.emit(.lt);
        const exit_branch = try self.emitBranch(.if_false);
        try self.emitLocalGet(iterable);
        try self.emitLocalGet(index);
        try self.emit(.get_array_el);
        try self.emitLocalPut(target);
        for (destructured, 0..) |slot, position| {
            if (slot) |local| {
                try self.emitLocalGet(target);
                try self.emitInteger(@intCast(position));
                try self.emit(.get_array_el);
                try self.emitLocalPut(local);
            }
        }
        try self.expect(.right_paren);
        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = null };
        self.loop_depth += 1;
        try self.statement();
        const continue_target = self.code.items.len;
        const context = &self.loops[context_index];
        for (context.continue_operands[0..context.continue_count]) |operand| try self.patchBranch(operand, continue_target);
        try self.emitLocalGet(index);
        try self.emit(.inc);
        try self.emitLocalPut(index);
        const repeat = try self.emitBranch(.goto);
        try self.patchBranch(repeat, loop_start);
        const end = self.code.items.len;
        try self.patchBranch(exit_branch, end);
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, end);
        self.loop_depth -= 1;
    }

    fn forEachObjectStatement(self: *Parser, target: u16, is_in: bool, bindings: []const ObjectBinding) Error!void {
        try self.forEachRightHandSide(is_in);
        const iterable = try self.declareTempLocal("object_iterator");
        try self.emitLocalPut(iterable);
        const index = try self.declareTempLocal("object_index");
        try self.emitInteger(0);
        try self.emitLocalPut(index);
        const loop_start = self.code.items.len;
        try self.emitLocalGet(index);
        try self.emitLocalGet(iterable);
        try self.emit(.get_length);
        try self.emit(.lt);
        const exit_branch = try self.emitBranch(.if_false);
        try self.emitLocalGet(iterable);
        try self.emitLocalGet(index);
        try self.emit(.get_array_el);
        try self.emitLocalPut(target);
        for (bindings) |binding| {
            const key = try self.addStringConstant(binding.key);
            try self.emitLocalGet(target);
            try self.emit(.get_field);
            try self.emitU16(@intCast(key));
            try self.emitLocalPut(binding.local);
        }
        try self.expect(.right_paren);
        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = null };
        self.loop_depth += 1;
        try self.statement();
        const continue_target = self.code.items.len;
        const context = &self.loops[context_index];
        for (context.continue_operands[0..context.continue_count]) |operand| try self.patchBranch(operand, continue_target);
        try self.emitLocalGet(index);
        try self.emit(.inc);
        try self.emitLocalPut(index);
        const repeat = try self.emitBranch(.goto);
        try self.patchBranch(repeat, loop_start);
        const end = self.code.items.len;
        try self.patchBranch(exit_branch, end);
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, end);
        self.loop_depth -= 1;
    }

    fn forEachRightHandSide(self: *Parser, is_in: bool) Error!void {
        try self.expressionSequence();
        if (is_in) try self.emit(.object_keys);
    }

    fn switchStatement(self: *Parser) Error!void {
        try self.advance();
        try self.expect(.left_paren);
        try self.expressionSequence();
        try self.expect(.right_paren);
        const discriminant = try self.declareTempLocal("switch");
        try self.emitLocalPut(discriminant);
        try self.expect(.left_brace);
        if (self.loop_depth == self.loops.len) return error.LoopNestingExceeded;
        const context_index = self.loop_depth;
        self.loops[context_index] = .{ .continue_target = null, .accepts_continue = false };
        self.loop_depth += 1;
        var miss_branches: std.ArrayList(usize) = .empty;
        defer miss_branches.deinit(self.allocator);
        var fallthrough_branch: ?usize = null;
        var default_body: ?usize = null;
        while (self.current.kind == .case_kw or self.current.kind == .default_kw) {
            const is_default = self.current.kind == .default_kw;
            if (!is_default) {
                const test_start = self.code.items.len;
                for (miss_branches.items) |branch| try self.patchBranch(branch, test_start);
                miss_branches.clearRetainingCapacity();
                try self.advance();
                try self.emitLocalGet(discriminant);
                try self.expression(1);
                try self.emit(.strict_eq);
                miss_branches.append(self.allocator, try self.emitBranch(.if_false)) catch return error.OutOfMemory;
            } else {
                try self.advance();
            }
            try self.expect(.colon);
            const body_start = self.code.items.len;
            if (is_default and default_body == null) default_body = body_start;
            if (self.current.kind == .case_kw or self.current.kind == .default_kw) {
                if (fallthrough_branch) |branch| try self.patchBranch(branch, body_start);
                fallthrough_branch = null;
                fallthrough_branch = try self.emitBranch(.goto);
                continue;
            }
            if (fallthrough_branch) |branch| try self.patchBranch(branch, body_start);
            fallthrough_branch = null;
            while (self.current.kind != .case_kw and self.current.kind != .default_kw and self.current.kind != .right_brace) {
                try self.statement();
            }
            fallthrough_branch = try self.emitBranch(.goto);
        }
        try self.expect(.right_brace);
        const end = self.code.items.len;
        if (fallthrough_branch) |branch| try self.patchBranch(branch, end);
        const miss_target = default_body orelse end;
        for (miss_branches.items) |branch| try self.patchBranch(branch, miss_target);
        const context = self.loops[context_index];
        for (context.break_operands[0..context.break_count]) |operand| try self.patchBranch(operand, end);
        self.loop_depth -= 1;
    }

    fn captureForUpdate(self: *Parser) Error![]u8 {
        if (self.current.kind == .right_paren) return self.allocator.alloc(u8, 0) catch return error.OutOfMemory;

        const main_code = self.code;
        self.code = .empty;
        errdefer {
            self.code.deinit(self.allocator);
            self.code = main_code;
        }

        while (true) {
            if (self.current.kind != .identifier) return error.UnexpectedToken;
            const name = self.lexeme();
            const index = self.locals.get(name) orelse return error.UnknownIdentifier;
            try self.advance();
            if (self.current.kind == .increment or self.current.kind == .decrement) {
                const operator = self.current.kind;
                try self.advance();
                try self.emitLocalGet(index);
                try self.emit(if (operator == .increment) .inc else .dec);
            } else if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .xor_assign) {
                const operator = self.current.kind;
                try self.advance();
                try self.emitLocalGet(index);
                try self.expression(1);
                try self.emit(switch (operator) {
                    .plus_assign => .add,
                    .minus_assign => .sub,
                    .star_assign => .mul,
                    .xor_assign => .xor,
                    else => unreachable,
                });
            } else if (self.current.kind == .assign) {
                try self.advance();
                try self.expression(1);
            } else {
                return error.UnexpectedToken;
            }
            try self.emitLocalPut(index);
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        const update = self.code.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        self.code = main_code;
        return update;
    }

    fn loopControl(self: *Parser, is_continue: bool) Error!void {
        try self.advance();
        var context_index: ?usize = null;
        if (self.current.kind == .identifier) {
            if (is_continue) return error.LoopControlOutsideLoop;
            const label = self.lexeme();
            var depth = self.loop_depth;
            while (depth > 0) {
                depth -= 1;
                if (self.loops[depth].label) |candidate| {
                    if (std.mem.eql(u8, label, candidate)) {
                        context_index = depth;
                        break;
                    }
                }
            }
            if (context_index == null) return error.LoopControlOutsideLoop;
            try self.advance();
        } else {
            var depth = self.loop_depth;
            while (depth > 0) {
                depth -= 1;
                if (!is_continue or self.loops[depth].accepts_continue) {
                    context_index = depth;
                    break;
                }
            }
            if (context_index == null) return error.LoopControlOutsideLoop;
        }
        try self.expect(.semicolon);
        const operand = try self.emitBranch(.goto);
        const context = &self.loops[context_index.?];
        if (is_continue) {
            if (context.continue_target) |target| {
                try self.patchBranch(operand, target);
            } else {
                if (context.continue_count == context.continue_operands.len) return error.TooManyLoopJumps;
                context.continue_operands[context.continue_count] = operand;
                context.continue_count += 1;
            }
        } else {
            if (context.break_count == context.break_operands.len) return error.TooManyLoopJumps;
            context.break_operands[context.break_count] = operand;
            context.break_count += 1;
        }
    }

    fn expression(self: *Parser, minimum_precedence: u8) Error!void {
        try self.prefix();
        try self.expressionTail(minimum_precedence);
    }

    fn expressionSequence(self: *Parser) Error!void {
        try self.expression(1);
        try self.expressionSequenceTail();
    }

    fn expressionSequenceTail(self: *Parser) Error!void {
        while (self.current.kind == .comma) {
            try self.advance();
            try self.emit(.drop);
            try self.expression(1);
        }
    }

    fn discardedExpressionSequenceTail(self: *Parser) Error!void {
        while (self.current.kind == .comma) {
            try self.advance();
            try self.expression(1);
            try self.expressionSequenceTail();
            try self.emit(.drop);
        }
    }

    fn expressionTail(self: *Parser, minimum_precedence: u8) Error!void {
        while (true) {
            if (self.current.kind == .dot) {
                try self.advance();
                if (!isIdentifierName(self.current.kind)) return error.ExpectedIdentifier;
                const property = self.lexeme();
                try self.advance();
                if (self.current.kind == .assign) {
                    const property_index = try self.addStringConstant(property);
                    try self.advance();
                    try self.expression(1);
                    try self.emit(.put_field);
                    try self.emitU16(@intCast(property_index));
                } else if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .xor_assign or self.current.kind == .and_assign or self.current.kind == .or_assign) {
                    const operator = self.current.kind;
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.dup);
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                    try self.advance();
                    try self.expression(1);
                    try self.emit(switch (operator) {
                        .plus_assign => .add,
                        .minus_assign => .sub,
                        .star_assign => .mul,
                        .xor_assign => .xor,
                        .and_assign => .and_op,
                        .or_assign => .or_op,
                        else => unreachable,
                    });
                    try self.emit(.put_field);
                    try self.emitU16(@intCast(property_index));
                } else if (self.current.kind == .left_paren) {
                    if (std.mem.eql(u8, property, "call") or std.mem.eql(u8, property, "bind")) {
                        const is_bind = std.mem.eql(u8, property, "bind");
                        try self.advance();
                        var argument_count: usize = 0;
                        if (self.current.kind != .right_paren) {
                            try self.expression(1);
                            if (!is_bind) try self.emit(.swap);
                            if (self.current.kind == .comma) {
                                try self.advance();
                            } else if (self.current.kind != .right_paren) {
                                return error.UnexpectedToken;
                            }
                            while (self.current.kind != .right_paren) {
                                try self.expression(1);
                                argument_count += 1;
                                if (self.current.kind != .comma) break;
                                try self.advance();
                            }
                        } else {
                            try self.emit(.undefined_value);
                            if (!is_bind) try self.emit(.swap);
                        }
                        try self.expect(.right_paren);
                        if (is_bind) {
                            if (argument_count > std.math.maxInt(u16)) return error.LocalLimitExceeded;
                            try self.emit(.function_bind);
                            try self.emitU16(@intCast(argument_count));
                        } else {
                            if (argument_count > std.math.maxInt(u16)) return error.LocalLimitExceeded;
                            try self.emit(.call_method);
                            try self.emitU16(@intCast(argument_count));
                        }
                        continue;
                    }
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.get_field2);
                    try self.emitU16(@intCast(property_index));
                    try self.callSuffixWithReceiver(0, true);
                } else if (std.mem.eql(u8, property, "length")) {
                    try self.emit(.get_length);
                } else {
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                }
                continue;
            }
            if (self.current.kind == .optional_dot) {
                try self.advance();
                if (self.current.kind == .left_paren) {
                    // Optional call (`value?.(args)`). Keep the callable on
                    // the stack while checking nullishness so arguments are
                    // evaluated only on the call path.
                    try self.emit(.dup);
                    try self.emit(.null_value);
                    try self.emit(.strict_eq);
                    const null_call = try self.emitBranch(.if_true);
                    try self.emit(.dup);
                    try self.emit(.undefined_value);
                    try self.emit(.strict_eq);
                    const undefined_call = try self.emitBranch(.if_true);
                    try self.callSuffix();
                    const call_done = try self.emitBranch(.goto);
                    const null_target = self.code.items.len;
                    try self.patchBranch(null_call, null_target);
                    try self.patchBranch(undefined_call, null_target);
                    try self.emit(.drop);
                    try self.emit(.undefined_value);
                    try self.patchBranch(call_done, self.code.items.len);
                    continue;
                }
                try self.emit(.dup);
                try self.emit(.null_value);
                try self.emit(.strict_eq);
                const null_branch = try self.emitBranch(.if_true);
                try self.emit(.dup);
                try self.emit(.undefined_value);
                try self.emit(.strict_eq);
                const undefined_branch = try self.emitBranch(.if_true);
                if (self.current.kind == .left_bracket) {
                    try self.advance();
                    try self.expression(1);
                    try self.expect(.right_bracket);
                    try self.emit(.get_array_el);
                } else {
                    if (!isIdentifierName(self.current.kind)) return error.ExpectedIdentifier;
                    const property_index = try self.addStringConstant(self.lexeme());
                    try self.advance();
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                }
                const done = try self.emitBranch(.goto);
                const null_target = self.code.items.len;
                try self.patchBranch(null_branch, null_target);
                try self.patchBranch(undefined_branch, null_target);
                try self.emit(.drop);
                try self.emit(.undefined_value);
                try self.patchBranch(done, self.code.items.len);
                continue;
            }
            if (self.current.kind == .left_bracket) {
                try self.advance();
                try self.expression(1);
                try self.expect(.right_bracket);
                if (self.current.kind == .assign) {
                    try self.advance();
                    try self.expression(1);
                    try self.emit(.insert3);
                    try self.emit(.put_array_el);
                    continue;
                }
                try self.emit(.get_array_el);
                continue;
            }
            if (self.current.kind == .question and minimum_precedence <= 1) {
                try self.advance();
                const false_branch = try self.emitBranch(.if_false);
                try self.expression(1);
                try self.expect(.colon);
                const end_branch = try self.emitBranch(.goto);
                try self.patchBranch(false_branch, self.code.items.len);
                try self.expression(1);
                try self.patchBranch(end_branch, self.code.items.len);
                continue;
            }
            if (self.current.kind == .nullish and minimum_precedence <= 1) {
                try self.emit(.dup);
                try self.emit(.null_value);
                try self.emit(.strict_eq);
                const use_rhs_from_null = try self.emitBranch(.if_true);
                try self.emit(.dup);
                try self.emit(.undefined_value);
                try self.emit(.strict_eq);
                const use_rhs_from_undefined = try self.emitBranch(.if_true);
                const done = try self.emitBranch(.goto);
                const rhs = self.code.items.len;
                try self.patchBranch(use_rhs_from_null, rhs);
                try self.patchBranch(use_rhs_from_undefined, rhs);
                try self.emit(.drop);
                try self.advance();
                try self.expression(1);
                try self.patchBranch(done, self.code.items.len);
                continue;
            }
            const level = precedence(self.current.kind) orelse break;
            if (level < minimum_precedence) break;
            const operator = self.current.kind;
            try self.advance();
            if (operator == .logical_and or operator == .logical_or) {
                try self.emit(.dup);
                const branch = try self.emitBranch(if (operator == .logical_and) .if_false else .if_true);
                try self.emit(.drop);
                try self.expression(level + 1);
                try self.patchBranch(branch, self.code.items.len);
                continue;
            }
            try self.expression(level + 1);
            try self.emit(binaryOpcode(operator) orelse return error.UnexpectedToken);
        }
    }

    fn prefix(self: *Parser) Error!void {
        const token = self.current;
        switch (token.kind) {
            .number => {
                const number_text = self.lexeme();
                if (std.mem.indexOfAny(u8, number_text, ".eE") != null) {
                    const value = std.fmt.parseFloat(f64, number_text) catch return error.InvalidInteger;
                    _ = try self.emitConstant(Value.fromFloat64(value));
                    try self.advance();
                    return;
                }
                const value: i64 = if (std.mem.startsWith(u8, number_text, "0x") or std.mem.startsWith(u8, number_text, "0X"))
                    std.fmt.parseInt(i64, number_text[2..], 16) catch return error.InvalidInteger
                else
                    std.fmt.parseInt(i64, number_text, 10) catch return error.InvalidInteger;
                if (std.math.cast(i32, value)) |small| {
                    try self.emitInteger(small);
                } else {
                    _ = try self.emitConstant(Value.fromFloat64(@floatFromInt(value)));
                }
                try self.advance();
            },
            .bigint => {
                const literal = self.lexeme();
                _ = try self.emitConstant(try self.addString(literal[0 .. literal.len - 1]));
                try self.emit(.to_bigint);
                try self.advance();
            },
            .string => try self.emitString(),
            .template => try self.templateExpression(),
            .slash => try self.regexpLiteral(),
            .true_kw => {
                try self.emit(.push_true);
                try self.advance();
            },
            .false_kw => {
                try self.emit(.push_false);
                try self.advance();
            },
            .null_kw => {
                try self.emit(.null_value);
                try self.advance();
            },
            .undefined_kw => {
                try self.emit(.undefined_value);
                try self.advance();
            },
            .void_kw => {
                try self.advance();
                try self.prefix();
                try self.emit(.drop);
                try self.emit(.undefined_value);
            },
            .identifier => {
                const name = self.lexeme();
                if (std.mem.eql(u8, name, "await")) {
                    if (!self.is_async) return error.UnexpectedToken;
                    try self.advance();
                    try self.prefix();
                    try self.emit(.await);
                    return;
                } else if (std.mem.eql(u8, name, "async")) {
                    const saved_token = self.current;
                    const saved_offset = self.offset;
                    try self.advance();
                    if (self.current.kind == .function_kw) {
                        try self.functionExpression(true);
                        return;
                    }
                    if (self.current.kind == .left_paren and self.looksLikeArrow(self.current.start)) {
                        try self.arrowFunctionExpression(true);
                        return;
                    }
                    self.current = saved_token;
                    self.offset = saved_offset;
                } else if (std.mem.eql(u8, name, "Object") and self.nextIsLeftParen()) {
                    try self.advance();
                    _ = try self.emitConstant(Value.shortFunction(56));
                    try self.callSuffix();
                    return;
                } else if (std.mem.eql(u8, name, "Object") and self.nextIsDot()) {
                    try self.advance();
                    try self.expect(.dot);
                    if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                    const property = self.lexeme();
                    if (std.mem.eql(u8, property, "prototype")) {
                        try self.emit(.push_global_this);
                        const object_key = try self.addStringConstant("Object");
                        try self.emit(.get_field);
                        try self.emitU16(@intCast(object_key));
                        const prototype_key = try self.addStringConstant("prototype");
                        try self.emit(.get_field);
                        try self.emitU16(@intCast(prototype_key));
                        try self.advance();
                        try self.callSuffix();
                        return;
                    }
                    const native_index = builtinFunction("Object", property) orelse return error.UnknownIdentifier;
                    _ = try self.emitConstant(Value.shortFunction(native_index));
                    try self.advance();
                    try self.callSuffix();
                    return;
                } else if (std.mem.eql(u8, name, "Object")) {
                    try self.emit(.push_global_this);
                    const property_index = try self.addStringConstant("Object");
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                    try self.advance();
                    try self.callSuffix();
                    return;
                } else if (std.mem.eql(u8, name, "Array") and self.nextIsLeftParen()) {
                    try self.advance();
                    _ = try self.emitConstant(Value.shortFunction(60));
                    try self.callSuffix();
                    return;
                } else if (std.mem.eql(u8, name, "BigInt")) {
                    try self.advance();
                    try self.expect(.left_paren);
                    if (self.current.kind == .right_paren) return error.ExpectedExpression;
                    try self.expression(1);
                    try self.expect(.right_paren);
                    try self.emit(.to_bigint);
                    try self.callSuffix();
                    return;
                } else if (isBuiltinNamespace(name)) {
                    try self.advance();
                    try self.expect(.dot);
                    if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                    const method = self.lexeme();
                    const native_index = builtinFunction(name, method) orelse return error.UnknownIdentifier;
                    _ = try self.emitConstant(Value.shortFunction(native_index));
                    try self.advance();
                    try self.callSuffix();
                    return;
                } else if (self.locals.get(name)) |index| {
                    try self.advance();
                    if (self.current.kind == .assign) {
                        try self.advance();
                        try self.expression(1);
                        try self.emit(.dup);
                        try self.emitLocalPut(index);
                        return;
                    }
                    if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .xor_assign or self.current.kind == .and_assign or self.current.kind == .or_assign) {
                        const operator = self.current.kind;
                        try self.emitLocalGet(index);
                        try self.advance();
                        try self.expression(1);
                        try self.emit(switch (operator) {
                            .plus_assign => .add,
                            .minus_assign => .sub,
                            .star_assign => .mul,
                            .xor_assign => .xor,
                            .and_assign => .and_op,
                            .or_assign => .or_op,
                            else => unreachable,
                        });
                        try self.emit(.dup);
                        try self.emitLocalPut(index);
                        return;
                    }
                    try self.emitLocalGet(index);
                    try self.callSuffix();
                    if (self.current.kind == .increment or self.current.kind == .decrement) {
                        const opcode: Opcode = if (self.current.kind == .increment) .post_inc else .post_dec;
                        try self.emit(opcode);
                        try self.emitLocalPut(index);
                        try self.advance();
                    }
                    return;
                } else if (std.mem.eql(u8, name, "arguments")) {
                    try self.emit(.arguments);
                } else if (std.mem.eql(u8, name, "print")) {
                    _ = try self.emitConstant(Value.shortFunction(0));
                } else if (isErrorConstructor(name)) {
                    _ = try self.emitConstant(Value.shortFunction(65535));
                } else if (std.mem.eql(u8, name, "Map")) {
                    _ = try self.emitConstant(Value.shortFunction(65534));
                } else if (std.mem.eql(u8, name, "Set")) {
                    _ = try self.emitConstant(Value.shortFunction(65533));
                } else if (std.mem.eql(u8, name, "WeakMap")) {
                    _ = try self.emitConstant(Value.shortFunction(65532));
                } else if (std.mem.eql(u8, name, "globalThis")) {
                    try self.emit(.push_global_this);
                } else if (std.mem.eql(u8, name, "__host")) {
                    _ = try self.emitConstant(Value.shortFunction(39));
                } else if (std.mem.eql(u8, name, "Boolean")) {
                    _ = try self.emitConstant(Value.shortFunction(41));
                } else if (std.mem.eql(u8, name, "String")) {
                    _ = try self.emitConstant(Value.shortFunction(42));
                } else if (std.mem.eql(u8, name, "Number")) {
                    _ = try self.emitConstant(Value.shortFunction(44));
                } else if (std.mem.eql(u8, name, "encodeURIComponent")) {
                    _ = try self.emitConstant(Value.shortFunction(45));
                } else if (std.mem.eql(u8, name, "parseInt")) {
                    _ = try self.emitConstant(Value.shortFunction(61));
                } else if (isUnavailableHostGlobal(name)) {
                    try self.emit(.undefined_value);
                } else {
                    std.debug.print("unknown source identifier `{s}` at {d}\n", .{ name, self.current.start });
                    return error.UnknownIdentifier;
                }
                try self.advance();
                try self.callSuffix();
            },
            .this_kw => {
                try self.emit(.push_this);
                try self.advance();
            },
            .new_kw => try self.newExpression(),
            .typeof_kw => {
                try self.advance();
                try self.prefix();
                try self.emit(.typeof_value);
            },
            .increment, .decrement => {
                try self.advance();
                if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                const index = self.locals.get(self.lexeme()) orelse return error.UnknownIdentifier;
                try self.emitLocalGet(index);
                try self.emit(if (token.kind == .increment) .inc else .dec);
                try self.emit(.dup);
                try self.emitLocalPut(index);
                try self.advance();
            },
            .minus, .plus, .bang => {
                try self.advance();
                try self.prefix();
                try self.expressionTail(7);
                try self.emit(switch (token.kind) {
                    .minus => .neg,
                    .plus => .plus,
                    .bang => .lnot,
                    else => unreachable,
                });
            },
            .left_paren => {
                if (self.looksLikeArrow(token.start)) {
                    try self.arrowFunctionExpression(false);
                    return;
                }
                try self.advance();
                try self.expressionSequence();
                try self.expect(.right_paren);
                try self.callSuffix();
            },
            .left_bracket => {
                try self.advance();
                try self.emit(.array_from);
                try self.emitU16(0);
                while (self.current.kind != .right_bracket) {
                    const is_spread = self.current.kind == .ellipsis;
                    if (is_spread) try self.advance();
                    try self.expression(1);
                    try self.emit(if (is_spread) .array_spread else .array_append);
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_bracket);
            },
            .left_brace => {
                try self.advance();
                try self.emit(.object);
                try self.emitU16(0);
                while (self.current.kind != .right_brace) {
                    if (self.current.kind == .ellipsis) {
                        try self.advance();
                        try self.expression(1);
                        try self.emit(.object_spread);
                        if (self.current.kind != .comma) break;
                        try self.advance();
                        continue;
                    }
                    if (self.current.kind == .left_bracket) {
                        try self.emit(.dup);
                        try self.advance();
                        try self.expression(1);
                        try self.expect(.right_bracket);
                        if (self.current.kind == .left_paren) {
                            try self.functionBody(null, false);
                        } else {
                            try self.expect(.colon);
                            try self.expression(1);
                        }
                        try self.emit(.put_array_el);
                        if (self.current.kind != .comma) break;
                        try self.advance();
                        if (self.current.kind == .right_brace) break;
                        continue;
                    }
                    if (!isIdentifierName(self.current.kind) and self.current.kind != .string) return error.ExpectedIdentifier;
                    const property = if (isIdentifierName(self.current.kind))
                        self.lexeme()
                    else
                        self.source[self.current.start + 1 .. self.current.end - 1];
                    const property_index = try self.addStringConstant(property);
                    try self.advance();
                    if (self.current.kind == .left_paren) {
                        try self.functionBody(null, false);
                    } else if (self.current.kind == .colon) {
                        try self.advance();
                        try self.expression(1);
                    } else {
                        const local = self.locals.get(property) orelse return error.UnknownIdentifier;
                        try self.emitLocalGet(local);
                    }
                    try self.emit(.define_field);
                    try self.emitU16(@intCast(property_index));
                    if (self.current.kind != .comma) break;
                    try self.advance();
                    if (self.current.kind == .right_brace) break;
                }
                try self.expect(.right_brace);
            },
            .function_kw => try self.functionExpression(false),
            else => return error.ExpectedExpression,
        }
    }

    fn functionExpression(self: *Parser, is_async: bool) Error!void {
        try self.advance();
        var self_name: ?[]const u8 = null;
        if (self.current.kind == .identifier) {
            self_name = self.lexeme();
            try self.advance();
        }
        try self.functionBody(self_name, is_async);
        try self.callSuffix();
    }

    fn functionBody(self: *Parser, self_name: ?[]const u8, is_async: bool) Error!void {
        try self.expect(.left_paren);
        var parameters: std.ArrayList([]const u8) = .empty;
        defer parameters.deinit(self.allocator);
        var prologue: std.ArrayList(u8) = .empty;
        defer prologue.deinit(self.allocator);
        while (self.current.kind != .right_paren) {
            if (self.current.kind != .identifier) return error.ExpectedIdentifier;
            const parameter = self.lexeme();
            parameters.append(self.allocator, parameter) catch return error.OutOfMemory;
            try self.advance();
            try self.appendDefaultParameter(parameter, &prologue);
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        try self.expect(.right_paren);
        if (self.current.kind != .left_brace) return error.UnexpectedToken;
        const body_open = self.current.start;
        const body_start = body_open + 1;
        const body_end = try blockBodyEnd(self.source, body_open);
        self.offset = body_end + 1;
        try self.advance();

        const body = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prologue.items, self.source[body_start..body_end] });
        defer self.allocator.free(body);
        const child = try compileUnit(self.allocator, body, parameters.items, true, self_name, &self.locals, is_async);
        var owns_child = true;
        errdefer if (owns_child) {
            var owned_child = child;
            owned_child.deinit(self.allocator);
        };
        const function_offset: usize = if (self.is_function) 1 else 0;
        if (self.children.items.len + function_offset > std.math.maxInt(u16)) return error.FunctionLimitExceeded;
        const function_index: u16 = @intCast(self.children.items.len + function_offset);
        self.children.append(self.allocator, child) catch return error.OutOfMemory;
        owns_child = false;
        if (function_index <= std.math.maxInt(u8)) {
            try self.emit(.fclosure8);
            try self.emitByte(@intCast(function_index));
        } else {
            try self.emit(.fclosure);
            try self.emitU16(function_index);
        }
    }

    fn looksLikeArrow(self: *Parser, start: usize) bool {
        var cursor = start + 1;
        var depth: usize = 1;
        while (cursor < self.source.len) : (cursor += 1) {
            switch (self.source[cursor]) {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) {
                        cursor += 1;
                        while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) cursor += 1;
                        return cursor + 1 < self.source.len and self.source[cursor] == '=' and self.source[cursor + 1] == '>';
                    }
                },
                '\'', '"' => {
                    const quote = self.source[cursor];
                    cursor += 1;
                    while (cursor < self.source.len and self.source[cursor] != quote) : (cursor += 1) {
                        if (self.source[cursor] == '\\') cursor += 1;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn arrowFunctionExpression(self: *Parser, is_async: bool) Error!void {
        try self.expect(.left_paren);
        var parameters: std.ArrayList([]const u8) = .empty;
        defer parameters.deinit(self.allocator);
        var prologue: std.ArrayList(u8) = .empty;
        defer prologue.deinit(self.allocator);
        var parameter_index: usize = 0;
        while (self.current.kind != .right_paren) {
            if (self.current.kind == .identifier) {
                const parameter = self.lexeme();
                parameters.append(self.allocator, parameter) catch return error.OutOfMemory;
                try self.advance();
                try self.appendDefaultParameter(parameter, &prologue);
            } else if (self.current.kind == .left_bracket) {
                const synthetic = try self.syntheticParameterName(parameter_index);
                parameter_index += 1;
                parameters.append(self.allocator, synthetic) catch return error.OutOfMemory;
                try self.advance();
                var element_index: usize = 0;
                while (self.current.kind != .right_bracket) {
                    if (self.current.kind == .comma) {
                        element_index += 1;
                    } else {
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const name = self.lexeme();
                        const declaration = try std.fmt.allocPrint(
                            self.allocator,
                            "var {s} = {s}[{d}];\n",
                            .{ name, synthetic, element_index },
                        );
                        defer self.allocator.free(declaration);
                        prologue.appendSlice(self.allocator, declaration) catch return error.OutOfMemory;
                        element_index += 1;
                        try self.advance();
                    }
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_bracket);
            } else if (self.current.kind == .left_brace) {
                const synthetic = try self.syntheticParameterName(parameter_index);
                parameter_index += 1;
                parameters.append(self.allocator, synthetic) catch return error.OutOfMemory;
                try self.advance();
                var excluded_keys: std.ArrayList([]const u8) = .empty;
                defer excluded_keys.deinit(self.allocator);
                var rest_name: ?[]const u8 = null;
                var rest_key_name: ?[]const u8 = null;
                while (self.current.kind != .right_brace) {
                    if (self.current.kind == .ellipsis) {
                        try self.advance();
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        rest_name = self.lexeme();
                        try self.advance();
                        rest_key_name = try std.fmt.allocPrint(self.allocator, "{s}_rest_key", .{synthetic});
                        break;
                    }
                    if (self.current.kind != .identifier and self.current.kind != .string) return error.ExpectedIdentifier;
                    const property = if (self.current.kind == .identifier)
                        self.lexeme()
                    else
                        self.source[self.current.start + 1 .. self.current.end - 1];
                    excluded_keys.append(self.allocator, property) catch return error.OutOfMemory;
                    try self.advance();
                    const binding = if (self.current.kind == .colon) blk: {
                        try self.advance();
                        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
                        const alias = self.lexeme();
                        try self.advance();
                        break :blk alias;
                    } else property;
                    const declaration = try std.fmt.allocPrint(
                        self.allocator,
                        "var {s} = {s}.{s};\n",
                        .{ binding, synthetic, property },
                    );
                    defer self.allocator.free(declaration);
                    prologue.appendSlice(self.allocator, declaration) catch return error.OutOfMemory;
                    try self.appendDefaultParameter(binding, &prologue);
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                try self.expect(.right_brace);
                if (rest_name) |rest| {
                    const key_name = rest_key_name.?;
                    const start = try std.fmt.allocPrint(self.allocator, "var {s} = {{}}; for (var {s} in {s}) {{ if (", .{ rest, key_name, synthetic });
                    defer self.allocator.free(start);
                    prologue.appendSlice(self.allocator, start) catch return error.OutOfMemory;
                    if (excluded_keys.items.len == 0) prologue.appendSlice(self.allocator, "true") catch return error.OutOfMemory;
                    for (excluded_keys.items, 0..) |key, index| {
                        if (index != 0) prologue.appendSlice(self.allocator, " && ") catch return error.OutOfMemory;
                        const condition = try std.fmt.allocPrint(self.allocator, "{s} !== \"{s}\"", .{ key_name, key });
                        defer self.allocator.free(condition);
                        prologue.appendSlice(self.allocator, condition) catch return error.OutOfMemory;
                    }
                    const finish = try std.fmt.allocPrint(self.allocator, ") {s}[{s}] = {s}[{s}]; }}\n", .{ rest, key_name, synthetic, key_name });
                    defer self.allocator.free(finish);
                    prologue.appendSlice(self.allocator, finish) catch return error.OutOfMemory;
                    self.allocator.free(key_name);
                }
            } else return error.ExpectedIdentifier;
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        try self.expect(.right_paren);
        try self.expect(.arrow);
        const body = if (self.current.kind == .left_brace) blk: {
            const body_open = self.current.start;
            const body_start = body_open + 1;
            const body_end = try blockBodyEnd(self.source, body_open);
            self.offset = body_end + 1;
            try self.advance();
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ prologue.items, self.source[body_start..body_end] },
            );
        } else blk: {
            const expression_start = self.current.start;
            var cursor = expression_start;
            var parens: usize = 0;
            var brackets: usize = 0;
            var braces: usize = 0;
            var quote: ?u8 = null;
            while (cursor < self.source.len) : (cursor += 1) {
                const byte = self.source[cursor];
                if (quote) |delimiter| {
                    if (byte == '\\') {
                        cursor += 1;
                    } else if (byte == delimiter) {
                        quote = null;
                    }
                    continue;
                }
                if (byte == '\'' or byte == '"' or byte == '`') {
                    quote = byte;
                    continue;
                }
                switch (byte) {
                    '(' => parens += 1,
                    ')' => {
                        if (parens == 0 and brackets == 0 and braces == 0) break;
                        parens -= 1;
                    },
                    '[' => brackets += 1,
                    ']' => {
                        if (brackets == 0 and parens == 0 and braces == 0) break;
                        brackets -= 1;
                    },
                    '{' => braces += 1,
                    '}' => {
                        if (braces == 0 and parens == 0 and brackets == 0) break;
                        braces -= 1;
                    },
                    ';', ',' => if (parens == 0 and brackets == 0 and braces == 0) break,
                    else => {},
                }
            }
            if (cursor == expression_start) return error.ExpectedExpression;
            const expression_text = std.mem.trim(u8, self.source[expression_start..cursor], " \t\r\n");
            self.offset = cursor;
            try self.advance();
            break :blk try std.fmt.allocPrint(self.allocator, "{s}return {s};", .{ prologue.items, expression_text });
        };
        defer self.allocator.free(body);
        const child = try compileUnit(self.allocator, body, parameters.items, true, null, &self.locals, is_async);
        var owns_child = true;
        errdefer if (owns_child) {
            var owned_child = child;
            owned_child.deinit(self.allocator);
        };
        const function_offset: usize = if (self.is_function) 1 else 0;
        if (self.children.items.len + function_offset > std.math.maxInt(u16)) return error.FunctionLimitExceeded;
        const function_index: u16 = @intCast(self.children.items.len + function_offset);
        self.children.append(self.allocator, child) catch return error.OutOfMemory;
        owns_child = false;
        if (function_index <= std.math.maxInt(u8)) {
            try self.emit(.fclosure8);
            try self.emitByte(@intCast(function_index));
        } else {
            try self.emit(.fclosure);
            try self.emitU16(function_index);
        }
        try self.callSuffix();
    }

    fn syntheticParameterName(self: *Parser, initial_index: usize) Error![]const u8 {
        var index = initial_index;
        while (true) : (index += 1) {
            const name = std.fmt.allocPrint(self.allocator, "__zmqjs_internal_arg_{d}", .{index}) catch return error.OutOfMemory;
            if (std.mem.indexOf(u8, self.source, name) == null) return name;
            self.allocator.free(name);
        }
    }

    fn appendDefaultParameter(self: *Parser, name: []const u8, prologue: *std.ArrayList(u8)) Error!void {
        if (self.current.kind != .assign) return;
        try self.advance();
        const start = self.current.start;
        var cursor = start;
        var parens: usize = 0;
        var brackets: usize = 0;
        var braces: usize = 0;
        var quote: ?u8 = null;
        while (cursor < self.source.len) : (cursor += 1) {
            const byte = self.source[cursor];
            if (quote) |delimiter| {
                if (byte == '\\') {
                    cursor += 1;
                } else if (byte == delimiter) {
                    quote = null;
                }
                continue;
            }
            if (byte == '\'' or byte == '"' or byte == '`') {
                quote = byte;
                continue;
            }
            switch (byte) {
                '(' => parens += 1,
                ')' => {
                    if (parens == 0 and brackets == 0 and braces == 0) break;
                    parens -= 1;
                },
                '[' => brackets += 1,
                ']' => brackets -= 1,
                '{' => braces += 1,
                '}' => braces -= 1,
                ',' => if (parens == 0 and brackets == 0 and braces == 0) break,
                else => {},
            }
        }
        if (cursor == start) return error.ExpectedExpression;
        const default_value = std.mem.trim(u8, self.source[start..cursor], " \t\r\n");
        const declaration = try std.fmt.allocPrint(
            self.allocator,
            "if ({s} === undefined) {s} = {s};\n",
            .{ name, name, default_value },
        );
        defer self.allocator.free(declaration);
        prologue.appendSlice(self.allocator, declaration) catch return error.OutOfMemory;
        self.offset = cursor;
        try self.advance();
    }

    fn hoistFunctionDeclarations(self: *Parser) Error!void {
        var cursor: usize = 0;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var statement_start = true;
        while (cursor < self.source.len) {
            const byte = self.source[cursor];
            if (quote) |delimiter| {
                if (byte == '\\') {
                    cursor = @min(cursor + 2, self.source.len);
                    continue;
                }
                if (byte == delimiter) quote = null;
                cursor += 1;
                continue;
            }
            if (byte == '\'' or byte == '"' or byte == '`') {
                quote = byte;
                statement_start = false;
                cursor += 1;
                continue;
            }
            if (byte == '/' and cursor + 1 < self.source.len) {
                if (self.source[cursor + 1] == '/') {
                    cursor += 2;
                    while (cursor < self.source.len and self.source[cursor] != '\n') : (cursor += 1) {}
                    continue;
                }
                if (self.source[cursor + 1] == '*') {
                    cursor += 2;
                    while (cursor + 1 < self.source.len and !(self.source[cursor] == '*' and self.source[cursor + 1] == '/')) : (cursor += 1) {}
                    if (cursor + 1 >= self.source.len) return error.UnexpectedToken;
                    cursor += 2;
                    continue;
                }
            }
            if (byte == '/' and canStartRegex(self.source, cursor)) {
                if (skipRegexLiteral(self.source, cursor)) |end| {
                    cursor = end;
                    statement_start = false;
                    continue;
                }
            }
            if (std.ascii.isWhitespace(byte)) {
                cursor += 1;
                continue;
            }
            if (std.ascii.isAlphabetic(byte) or byte == '_' or byte == '$') {
                const start = cursor;
                cursor += 1;
                while (cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) : (cursor += 1) {}
                if (depth == 0 and statement_start and std.mem.eql(u8, self.source[start..cursor], "function")) {
                    while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                    const name_start = cursor;
                    if (cursor < self.source.len and (std.ascii.isAlphabetic(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) {
                        cursor += 1;
                        while (cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) : (cursor += 1) {}
                        _ = try self.declareLocal(self.source[name_start..cursor]);
                    }
                }
                // Function-scoped `var` declarations also occur inside one
                // block layer (for example a top-level `if`). Keep nested
                // callback/function bodies out of this pass; they are hoisted
                // by their own compileUnit invocation.
                if (depth <= 1 and std.mem.eql(u8, self.source[start..cursor], "var")) {
                    while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                    if (cursor < self.source.len and (std.ascii.isAlphabetic(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) {
                        const name_start = cursor;
                        cursor += 1;
                        while (cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) : (cursor += 1) {}
                        const name = self.source[name_start..cursor];
                        if (!self.locals.contains(name)) _ = try self.declareLocal(name);
                    } else if (cursor < self.source.len and self.source[cursor] == '{') {
                        // The parser supports simple object binding patterns in
                        // variable declarations. Hoist their local names too:
                        // generated code can reference a binding before the
                        // destructuring declaration, as Preact's hooks runtime
                        // does for `var { shouldComponentUpdate: c } = ...`.
                        cursor += 1;
                        while (cursor < self.source.len) {
                            while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                            if (cursor >= self.source.len or self.source[cursor] == '}') break;
                            const key_start = cursor;
                            if (!(std.ascii.isAlphabetic(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) break;
                            cursor += 1;
                            while (cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) : (cursor += 1) {}
                            const key = self.source[key_start..cursor];
                            while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                            var binding_name = key;
                            if (cursor < self.source.len and self.source[cursor] == ':') {
                                cursor += 1;
                                while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                                const binding_start = cursor;
                                if (cursor >= self.source.len or !(std.ascii.isAlphabetic(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) break;
                                cursor += 1;
                                while (cursor < self.source.len and (std.ascii.isAlphanumeric(self.source[cursor]) or self.source[cursor] == '_' or self.source[cursor] == '$')) : (cursor += 1) {}
                                binding_name = self.source[binding_start..cursor];
                            }
                            if (!self.locals.contains(binding_name)) _ = try self.declareLocal(binding_name);
                            while (cursor < self.source.len and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
                            if (cursor < self.source.len and self.source[cursor] == ',') {
                                cursor += 1;
                                continue;
                            }
                            break;
                        }
                    }
                }
                statement_start = false;
                continue;
            }
            switch (byte) {
                '{' => {
                    depth += 1;
                    statement_start = true;
                },
                '}' => {
                    depth -|= 1;
                    statement_start = depth == 0;
                },
                ';' => statement_start = true,
                else => statement_start = false,
            }
            cursor += 1;
        }
    }

    fn newExpression(self: *Parser) Error!void {
        try self.advance();
        if (self.current.kind != .identifier) return error.ExpectedIdentifier;
        const name = self.lexeme();
        if (std.mem.eql(u8, name, "Array")) {
            try self.advance();
            try self.expect(.left_paren);
            if (self.current.kind == .right_paren) {
                try self.emit(.array_from);
                try self.emitU16(0);
            } else {
                try self.expression(1);
                if (self.current.kind != .right_paren) return error.UnexpectedToken;
                try self.emit(.array_new);
            }
            try self.expect(.right_paren);
            return;
        }
        const callee = self.locals.get(name);
        const is_error_constructor = callee == null and std.mem.eql(u8, name, "Error");
        const collection_kind: ?u8 = if (std.mem.eql(u8, name, "Map")) 0 else if (std.mem.eql(u8, name, "Set")) 1 else if (std.mem.eql(u8, name, "WeakMap")) 2 else null;
        if (callee == null and !is_error_constructor and collection_kind == null) return error.UnknownIdentifier;
        if (collection_kind) |kind| {
            try self.advance();
            if (self.current.kind != .left_paren) {
                try self.emit(.collection_new);
                try self.emitByte(kind);
                return;
            }
            try self.expect(.left_paren);
            var has_iterable = false;
            if (self.current.kind != .right_paren) {
                try self.expression(1);
                has_iterable = true;
                while (self.current.kind == .comma) {
                    try self.advance();
                    try self.expression(1);
                    try self.emit(.drop);
                }
            }
            try self.expect(.right_paren);
            try self.emit(.collection_new);
            try self.emitByte(kind | (@as(u8, @intFromBool(has_iterable)) << 7));
            return;
        }
        try self.emit(.object);
        try self.emitU16(0);
        try self.advance();
        try self.expect(.left_paren);
        if (is_error_constructor) {
            while (self.current.kind != .right_paren) {
                try self.expression(1);
                try self.emit(.drop);
                if (self.current.kind != .comma) break;
                try self.advance();
            }
            try self.expect(.right_paren);
            return;
        }
        const prototype_property = try self.addStringConstant("prototype");
        const prototype_link = try self.addStringConstant("__proto__");
        try self.emit(.dup);
        try self.emitLocalGet(callee.?);
        try self.emit(.get_field);
        try self.emitU16(@intCast(prototype_property));
        try self.emit(.put_field);
        try self.emitU16(@intCast(prototype_link));
        try self.emit(.drop);
        try self.emit(.dup);
        try self.emitLocalGet(callee.?);
        var argument_count: usize = 0;
        while (self.current.kind != .right_paren) {
            try self.expression(1);
            argument_count += 1;
            if (self.current.kind != .comma) break;
            try self.advance();
        }
        if (argument_count > std.math.maxInt(u16)) return error.LocalLimitExceeded;
        try self.expect(.right_paren);
        try self.emit(.call_method);
        try self.emitU16(@intCast(argument_count));
        try self.emit(.drop);
    }

    fn callSuffix(self: *Parser) Error!void {
        try self.callSuffixWithReceiver(0, false);
    }

    fn callSuffixWithReceiver(self: *Parser, initial_receiver_arguments: usize, initial_method_call: bool) Error!void {
        var pending_receiver_arguments = initial_receiver_arguments;
        var pending_method_call = initial_method_call;
        while (true) {
            if (self.current.kind == .left_paren) {
                try self.advance();
                var argument_count: usize = 0;
                var has_spread = false;
                var spread_mode = false;
                while (self.current.kind != .right_paren) {
                    var spread_argument = false;
                    if (self.current.kind == .ellipsis) {
                        if (pending_receiver_arguments != 0) return error.UnexpectedToken;
                        if (!spread_mode) {
                            if (argument_count != 0) return error.UnexpectedToken;
                            spread_mode = true;
                            try self.emit(.array_from);
                            try self.emitU16(0);
                        }
                        spread_argument = true;
                        has_spread = true;
                        try self.advance();
                    }
                    try self.expression(1);
                    if (spread_mode) try self.emit(if (spread_argument) .array_spread else .array_append);
                    argument_count += 1;
                    if (self.current.kind != .comma) break;
                    try self.advance();
                }
                const total_arguments = argument_count + pending_receiver_arguments;
                if (total_arguments > std.math.maxInt(u16)) return error.LocalLimitExceeded;
                try self.expect(.right_paren);
                if (has_spread) {
                    try self.emit(if (pending_method_call) .call_method_spread else .call_spread);
                } else {
                    try self.emit(if (pending_method_call) .call_method else .call);
                    try self.emitU16(@intCast(total_arguments));
                }
                pending_receiver_arguments = 0;
                pending_method_call = false;
            } else if (self.current.kind == .left_bracket) {
                try self.advance();
                try self.expression(1);
                try self.expect(.right_bracket);
                if (self.current.kind == .assign) {
                    try self.advance();
                    try self.expression(1);
                    try self.emit(.insert3);
                    try self.emit(.put_array_el);
                } else if (self.current.kind == .left_paren) {
                    try self.emit(.get_array_el2);
                    pending_method_call = true;
                } else {
                    try self.emit(.get_array_el);
                }
            } else if (self.current.kind == .dot) {
                try self.advance();
                if (!isIdentifierName(self.current.kind)) return error.UnknownIdentifier;
                const property = self.lexeme();
                try self.advance();
                if (self.current.kind == .assign) {
                    const property_index = try self.addStringConstant(property);
                    try self.advance();
                    try self.expression(1);
                    try self.emit(.put_field);
                    try self.emitU16(@intCast(property_index));
                } else if (self.current.kind == .plus_assign or self.current.kind == .minus_assign or self.current.kind == .star_assign or self.current.kind == .xor_assign or self.current.kind == .and_assign or self.current.kind == .or_assign) {
                    const operator = self.current.kind;
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.dup);
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                    try self.advance();
                    try self.expression(1);
                    try self.emit(switch (operator) {
                        .plus_assign => .add,
                        .minus_assign => .sub,
                        .star_assign => .mul,
                        .xor_assign => .xor,
                        .and_assign => .and_op,
                        .or_assign => .or_op,
                        else => unreachable,
                    });
                    try self.emit(.put_field);
                    try self.emitU16(@intCast(property_index));
                } else if (std.mem.eql(u8, property, "apply") and self.current.kind == .left_paren) {
                    // Lower Function.prototype.apply to the existing method-spread
                    // instruction. The callee is already on the stack; preserve it
                    // while parsing thisArg and the optional argument array.
                    const callee = try self.declareTempLocal("apply_callee");
                    const receiver = try self.declareTempLocal("apply_receiver");
                    const arguments = try self.declareTempLocal("apply_arguments");
                    try self.emitLocalPut(callee);
                    try self.advance();
                    if (self.current.kind == .right_paren) {
                        try self.emit(.undefined_value);
                        try self.emitLocalPut(receiver);
                        try self.emit(.array_from);
                        try self.emitU16(0);
                        try self.emitLocalPut(arguments);
                    } else {
                        try self.expression(1);
                        try self.emitLocalPut(receiver);
                        if (self.current.kind == .comma) {
                            try self.advance();
                            try self.expression(1);
                            try self.emitLocalPut(arguments);
                            while (self.current.kind == .comma) {
                                try self.advance();
                                try self.expression(1);
                            }
                        } else {
                            try self.emit(.array_from);
                            try self.emitU16(0);
                            try self.emitLocalPut(arguments);
                        }
                    }
                    try self.expect(.right_paren);
                    try self.emitLocalGet(receiver);
                    try self.emitLocalGet(callee);
                    try self.emitLocalGet(arguments);
                    try self.emit(.call_method_spread);
                    pending_method_call = false;
                    pending_receiver_arguments = 0;
                } else if ((std.mem.eql(u8, property, "call") or std.mem.eql(u8, property, "bind")) and self.current.kind == .left_paren) {
                    const is_bind = std.mem.eql(u8, property, "bind");
                    try self.advance();
                    var argument_count: usize = 0;
                    if (self.current.kind != .right_paren) {
                        try self.expression(1);
                        if (!is_bind) try self.emit(.swap);
                        if (self.current.kind == .comma) {
                            try self.advance();
                        } else if (self.current.kind != .right_paren) {
                            return error.UnexpectedToken;
                        }
                        while (self.current.kind != .right_paren) {
                            try self.expression(1);
                            argument_count += 1;
                            if (self.current.kind != .comma) break;
                            try self.advance();
                        }
                    } else {
                        try self.emit(.undefined_value);
                        if (!is_bind) try self.emit(.swap);
                    }
                    try self.expect(.right_paren);
                    if (argument_count > std.math.maxInt(u16)) return error.LocalLimitExceeded;
                    if (is_bind) {
                        try self.emit(.function_bind);
                        try self.emitU16(@intCast(argument_count));
                    } else {
                        try self.emit(.call_method);
                        try self.emitU16(@intCast(argument_count));
                    }
                } else if (std.mem.eql(u8, property, "length")) {
                    try self.emit(.get_length);
                } else if (self.current.kind == .left_paren) {
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.get_field2);
                    try self.emitU16(@intCast(property_index));
                    pending_method_call = true;
                } else {
                    const property_index = try self.addStringConstant(property);
                    try self.emit(.get_field);
                    try self.emitU16(@intCast(property_index));
                }
            } else {
                break;
            }
        }
    }

    fn emitString(self: *Parser) Error!void {
        const source_bytes = self.source[self.current.start + 1 .. self.current.end - 1];
        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(self.allocator);
        var index: usize = 0;
        while (index < source_bytes.len) : (index += 1) {
            if (source_bytes[index] != '\\') {
                decoded.append(self.allocator, source_bytes[index]) catch return error.OutOfMemory;
                continue;
            }
            index += 1;
            if (index >= source_bytes.len) return error.UnterminatedString;
            if (source_bytes[index] == 'x') {
                if (index + 2 >= source_bytes.len) return error.UnsupportedEscape;
                const high = hexDigit(source_bytes[index + 1]) orelse return error.UnsupportedEscape;
                const low = hexDigit(source_bytes[index + 2]) orelse return error.UnsupportedEscape;
                index += 2;
                var encoded: [4]u8 = undefined;
                const encoded_len = std.unicode.utf8Encode(@as(u21, high * 16 + low), &encoded) catch return error.UnsupportedEscape;
                decoded.appendSlice(self.allocator, encoded[0..encoded_len]) catch return error.OutOfMemory;
                continue;
            }
            const escaped: u8 = switch (source_bytes[index]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                else => return error.UnsupportedEscape,
            };
            decoded.append(self.allocator, escaped) catch return error.OutOfMemory;
        }
        const value = try self.addString(decoded.items);
        _ = try self.emitConstant(value);
        try self.advance();
    }

    fn templateExpression(self: *Parser) Error!void {
        const contents = self.source[self.current.start + 1 .. self.current.end - 1];
        var cursor: usize = 0;
        var emitted = false;
        while (cursor < contents.len) {
            const interpolation = std.mem.indexOfPos(u8, contents, cursor, "${");
            const literal_end = interpolation orelse contents.len;
            if (literal_end > cursor or !emitted) {
                const value = try self.addString(contents[cursor..literal_end]);
                _ = try self.emitConstant(value);
                if (emitted) try self.emit(.add);
                emitted = true;
            }
            if (interpolation) |start| {
                var end = start + 2;
                var depth: usize = 1;
                var quote: ?u8 = null;
                while (end < contents.len and depth > 0) : (end += 1) {
                    const byte = contents[end];
                    if (quote) |delimiter| {
                        if (byte == '\\') {
                            end += 1;
                        } else if (byte == delimiter) {
                            quote = null;
                        }
                    } else if (byte == '\'' or byte == '"') {
                        quote = byte;
                    } else if (byte == '{') {
                        depth += 1;
                    } else if (byte == '}') {
                        depth -= 1;
                    }
                }
                if (depth != 0) return error.UnexpectedToken;
                const expression_source = contents[start + 2 .. end - 1];
                const child_source = std.fmt.allocPrint(self.allocator, "{s};", .{expression_source}) catch return error.OutOfMemory;
                defer self.allocator.free(child_source);
                const child = try compileUnit(self.allocator, child_source, &.{}, true, null, &self.locals, false);
                var owns_child = true;
                errdefer if (owns_child) {
                    var owned_child = child;
                    owned_child.deinit(self.allocator);
                };
                const function_offset: usize = if (self.is_function) 1 else 0;
                if (self.children.items.len + function_offset > std.math.maxInt(u16)) return error.FunctionLimitExceeded;
                const function_index: u16 = @intCast(self.children.items.len + function_offset);
                self.children.append(self.allocator, child) catch return error.OutOfMemory;
                owns_child = false;
                if (function_index <= std.math.maxInt(u8)) {
                    try self.emit(.fclosure8);
                    try self.emitByte(@intCast(function_index));
                } else {
                    try self.emit(.fclosure);
                    try self.emitU16(function_index);
                }
                try self.emit(.call);
                try self.emitU16(0);
                if (emitted) try self.emit(.add);
                emitted = true;
                cursor = end;
            } else {
                cursor = contents.len;
            }
        }
        try self.advance();
    }

    fn regexpLiteral(self: *Parser) Error!void {
        const start = self.current.start;
        var cursor = start + 1;
        var escaped = false;
        var in_character_class = false;
        while (cursor < self.source.len) : (cursor += 1) {
            const byte = self.source[cursor];
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '[') {
                in_character_class = true;
            } else if (byte == ']') {
                in_character_class = false;
            } else if (byte == '/' and !in_character_class) {
                break;
            }
        }
        if (cursor >= self.source.len) return error.UnexpectedToken;
        const pattern = self.source[start + 1 .. cursor];
        cursor += 1;
        var flags: u8 = 0;
        while (cursor < self.source.len and std.ascii.isAlphabetic(self.source[cursor])) : (cursor += 1) {
            const flag: u8 = switch (self.source[cursor]) {
                'i' => 1,
                'g' => 2,
                else => return error.InvalidToken,
            };
            if (flags & flag != 0) return error.InvalidToken;
            flags |= flag;
        }
        const pattern_value = try self.addString(pattern);
        _ = try self.emitConstant(pattern_value);
        try self.emit(.regexp_new);
        try self.emitByte(flags);
        self.offset = cursor;
        try self.advance();
        try self.callSuffix();
    }

    fn addString(self: *Parser, bytes: []const u8) Error!Value {
        const owned_bytes = self.allocator.dupe(u8, bytes) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned_bytes);
        const literal = self.allocator.create(StringLiteral) catch return error.OutOfMemory;
        errdefer self.allocator.destroy(literal);
        literal.* = .{ .bytes = owned_bytes };
        self.strings.append(self.allocator, literal) catch return error.OutOfMemory;
        return Value.fromPointer(literal);
    }

    fn emitConstant(self: *Parser, value: Value) Error!usize {
        const index = try self.addConstant(value);
        if (index <= std.math.maxInt(u8)) {
            try self.emit(.push_const8);
            try self.emitByte(@intCast(index));
        } else {
            try self.emit(.push_const);
            try self.emitU16(@intCast(index));
        }
        return index;
    }

    fn addStringConstant(self: *Parser, bytes: []const u8) Error!usize {
        return self.addConstant(try self.addString(bytes));
    }

    fn addConstant(self: *Parser, value: Value) Error!usize {
        if (self.constants.items.len > std.math.maxInt(u16)) return error.LocalLimitExceeded;
        const index = self.constants.items.len;
        self.constants.append(self.allocator, value) catch return error.OutOfMemory;
        return index;
    }

    fn declareLocal(self: *Parser, name: []const u8) Error!u16 {
        if (self.locals.contains(name)) return error.UnexpectedToken;
        if (self.next_local > std.math.maxInt(u16)) return error.LocalLimitExceeded;
        const index: u16 = @intCast(self.next_local);
        self.next_local += 1;
        self.locals.put(self.allocator, name, index) catch return error.OutOfMemory;
        return index;
    }

    fn declareTempLocal(self: *Parser, label: []const u8) Error!u16 {
        const name = std.fmt.allocPrint(self.allocator, "${s}{d}", .{ label, self.next_local }) catch return error.OutOfMemory;
        return self.declareLocal(name);
    }

    fn emitLocalGet(self: *Parser, index: u16) Error!void {
        if (index < 4) {
            try self.emit(@enumFromInt(@intFromEnum(Opcode.get_loc0) + @as(u8, @intCast(index))));
        } else if (index <= std.math.maxInt(u8)) {
            try self.emit(.get_loc8);
            try self.emitByte(@intCast(index));
        } else {
            try self.emit(.get_loc);
            try self.emitU16(index);
        }
    }

    fn emitArgumentGet(self: *Parser, index: u16) Error!void {
        if (index < 4) {
            try self.emit(@enumFromInt(@intFromEnum(Opcode.get_arg0) + @as(u8, @intCast(index))));
        } else {
            try self.emit(.get_arg);
            try self.emitU16(index);
        }
    }

    fn emitLocalPut(self: *Parser, index: u16) Error!void {
        if (index < 4) {
            try self.emit(@enumFromInt(@intFromEnum(Opcode.put_loc0) + @as(u8, @intCast(index))));
        } else if (index <= std.math.maxInt(u8)) {
            try self.emit(.put_loc8);
            try self.emitByte(@intCast(index));
        } else {
            try self.emit(.put_loc);
            try self.emitU16(index);
        }
    }

    fn emitInteger(self: *Parser, value: i32) Error!void {
        const encoded = Value.fromInt(value) orelse {
            _ = try self.emitConstant(Value.fromFloat64(@floatFromInt(value)));
            return;
        };
        if (value >= -1 and value <= 7) {
            const opcode = @as(i32, @intFromEnum(Opcode.push_0)) + value;
            try self.emit(@enumFromInt(@as(u8, @intCast(opcode))));
        } else if (std.math.cast(i8, value)) |small| {
            try self.emit(.push_i8);
            try self.emitByte(@bitCast(small));
        } else if (std.math.cast(i16, value)) |small| {
            try self.emit(.push_i16);
            try self.emitU16(@bitCast(small));
        } else {
            try self.emit(.push_value);
            try self.emitU32(@truncate(encoded.raw()));
        }
    }

    fn emitBranch(self: *Parser, opcode: Opcode) Error!usize {
        try self.emit(opcode);
        const operand = self.code.items.len;
        try self.emitU32(0);
        return operand;
    }

    fn patchBranch(self: *Parser, operand: usize, target: usize) Error!void {
        const relative = std.math.cast(i32, @as(i64, @intCast(target)) - @as(i64, @intCast(operand))) orelse return error.IntegerOutOfRange;
        const bits: u32 = @bitCast(relative);
        for (0..4) |index| self.code.items[operand + index] = @truncate(bits >> @intCast(index * 8));
    }

    fn emit(self: *Parser, opcode: Opcode) Error!void {
        try self.emitByte(@intFromEnum(opcode));
    }

    fn emitByte(self: *Parser, byte: u8) Error!void {
        self.code.append(self.allocator, byte) catch return error.OutOfMemory;
    }

    fn emitU16(self: *Parser, value: u16) Error!void {
        try self.emitByte(@truncate(value));
        try self.emitByte(@truncate(value >> 8));
    }

    fn emitU32(self: *Parser, value: u32) Error!void {
        try self.emitU16(@truncate(value));
        try self.emitU16(@truncate(value >> 16));
    }

    fn expect(self: *Parser, kind: TokenKind) Error!void {
        if (kind == .semicolon and (self.current.kind == .right_brace or self.current.kind == .end)) return;
        if (self.current.kind != kind) {
            std.debug.print("expected token {s}, found {s} at {d}\n", .{ @tagName(kind), @tagName(self.current.kind), self.current.start });
            return error.UnexpectedToken;
        }
        try self.advance();
    }

    fn lexeme(self: *Parser) []const u8 {
        return self.source[self.current.start..self.current.end];
    }
};

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn precedence(kind: TokenKind) ?u8 {
    return switch (kind) {
        .logical_or => 1,
        .nullish => 1,
        .logical_and => 2,
        .equal, .not_equal, .strict_equal, .strict_not_equal => 3,
        .in_kw, .instanceof_kw => 4,
        .less, .less_equal, .greater, .greater_equal => 4,
        .shift_left, .shift_right => 5,
        .plus, .minus => 6,
        .xor => 4,
        .bit_and => 4,
        .bit_or => 3,
        .unsigned_shift_right => 5,
        .star, .slash, .percent => 7,
        else => null,
    };
}

fn isBuiltinNamespace(name: []const u8) bool {
    return std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "Object") or std.mem.eql(u8, name, "JSON") or std.mem.eql(u8, name, "Math") or std.mem.eql(u8, name, "Promise");
}

fn isErrorConstructor(name: []const u8) bool {
    for ([_][]const u8{ "Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError" }) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

fn isUnavailableHostGlobal(name: []const u8) bool {
    const names = [_][]const u8{
        "document", "window",           "self",    "navigator",  "localStorage", "sessionStorage",       "Node",                 "Element",     "Text", "HTMLElement", "SVGElement",
        "Event",    "MutationObserver", "setTimeout", "clearTimeout", "requestAnimationFrame", "cancelAnimationFrame",
    };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn builtinFunction(namespace: []const u8, method: []const u8) ?usize {
    if (std.mem.eql(u8, namespace, "Promise") and std.mem.eql(u8, method, "all")) return 67;
    if (std.mem.eql(u8, namespace, "Array") and std.mem.eql(u8, method, "isArray")) return 2;
    if (std.mem.eql(u8, namespace, "Array") and std.mem.eql(u8, method, "from")) return 64;
        if (std.mem.eql(u8, namespace, "Object")) {
        if (std.mem.eql(u8, method, "create")) return 53;
        if (std.mem.eql(u8, method, "defineProperty")) return 54;
        if (std.mem.eql(u8, method, "getOwnPropertyDescriptor")) return 55;
        if (std.mem.eql(u8, method, "assign")) return 3;
        if (std.mem.eql(u8, method, "entries")) return 4;
        if (std.mem.eql(u8, method, "fromEntries")) return 5;
        if (std.mem.eql(u8, method, "keys")) return 6;
        if (std.mem.eql(u8, method, "values")) return 7;
        if (std.mem.eql(u8, method, "getPrototypeOf")) return 57;
        if (std.mem.eql(u8, method, "getOwnPropertyNames")) return 58;
    }
    if (std.mem.eql(u8, namespace, "JSON")) {
        if (std.mem.eql(u8, method, "parse")) return 8;
        if (std.mem.eql(u8, method, "stringify")) return 9;
    }
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "imul")) return 10;
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "random")) return 46;
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "round")) return 62;
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "pow")) return 63;
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "max")) return 65;
    if (std.mem.eql(u8, namespace, "Math") and std.mem.eql(u8, method, "min")) return 66;
    return null;
}

fn binaryOpcode(kind: TokenKind) ?Opcode {
    return switch (kind) {
        .equal => .eq,
        .not_equal => .neq,
        .strict_equal => .strict_eq,
        .strict_not_equal => .strict_neq,
        .in_kw => .in_operator,
        .instanceof_kw => .instanceof,
        .less => .lt,
        .less_equal => .lte,
        .greater => .gt,
        .greater_equal => .gte,
        .shift_left => .shl,
        .shift_right => .sar,
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .percent => .mod,
        .xor => .xor,
        .bit_and => .and_op,
        .bit_or => .or_op,
        .unsigned_shift_right => .shr,
        else => null,
    };
}

test "source compiler lowers loose equality to VM equality opcodes" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator,
        \\var same_string = "key" == "key";
        \\var nullish = null == undefined;
        \\var boolean_number = true == 1 && false != 1;
        \\var different_numbers = 2 != 3;
        \\same_string && nullish && boolean_number && different_numbers;
    );
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(Value.true_value.raw(), result.raw());
}

test "source compiler emits bytecode that executes on the Zig VM" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let answer = 7; answer * 6;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 42), result.asInt().?);
}

test "source compiler finds arrow body end when regex contains quotes" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "(()=>{var single=/'/g,mixed=/['\"]/g;return true;})();");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(Value.true_value.raw(), result.raw());
}

test "source compiler applies semicolon insertion at function end" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "(()=>{if(false){throw TypeError(\"x\")}return true})()");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(Value.true_value.raw(), result.raw());
}

test "source compiler lowers conditional arithmetic into VM branches" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let value = 0; if (2 < 3) { value = 40 + 2; } value;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 42), result.asInt().?);
}

test "source compiler preserves short-circuit behavior for logical operators" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "false && (1 / 0) || (2 && 5);");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 5), result.asInt().?);
}

test "source compiler lowers conditional expressions into branches" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "true ? 42 : 0;");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 42), result.asInt());
}

test "source compiler emits executable loop branches" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let i = 0; let sum = 0; while (i < 5) { sum = sum + i; i = i + 1; } sum;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 10), result.asInt().?);
}

test "source compiler fuses local self-updates without changing addition semantics" {
    const allocator = std.testing.allocator;
    var number_program = try compile(allocator, "var value = 4; value = value + 3; value += 2; value;");
    defer number_program.deinit(allocator);
    try std.testing.expect(std.mem.indexOfScalar(
        u8,
        number_program.code,
        @intFromEnum(Opcode.add_loc),
    ) != null);
    const number = try (VM{ .allocator = allocator }).execute(number_program.bytecode());
    try std.testing.expectEqual(@as(?i32, 9), number.asInt());

    var string_program = try compile(allocator, "var value = \"a\"; value = value + \"b\"; value;");
    defer string_program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const string = try (VM{ .allocator = allocator, .objects = &objects }).execute(string_program.bytecode());
    try std.testing.expectEqualStrings("ab", objects.findString(string).?);
}

test "source compiler supports local division assignment" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "var value = 8192; value /= 8; value;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 1024), result.asInt());
}

test "source compiler lowers loop continue break and compound updates" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "var sum = 0; var i = 0; while (i < 5) { i++; if (i === 2) continue; if (i === 5) break; sum += i; } sum;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 8), result.asInt().?);
}

test "source compiler lowers for-loop initializer condition and update" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let product = 1; for (let i = 1; i <= 4; i++) { product *= i; } product;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 24), result.asInt().?);
}

test "source compiler emits callable functions with parameter frames" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "function add(a, b) { return a + b; } add(19, 23);");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 42), result.asInt().?);
}

test "source compiler suspends async functions at await and resumes through nested frames" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "async function load() { let answer = await 40; return answer + 2; } load();");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    var outcome = try vm.executeAsync(program.bytecode());
    const suspended = switch (outcome) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    try std.testing.expectEqual(@as(?i32, 40), suspended.awaited.asInt());
    outcome = try vm.resumeExecution(suspended.continuation, .{ .resolved = Value.fromInt(40).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "async function expressions and arrows suspend and resume" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let load = async function(value) { return await value + 1; }; let arrow = async (value) => await value + 2; load(40); arrow(41);");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    var outcome = try vm.executeAsync(program.bytecode());
    const first = switch (outcome) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    try std.testing.expectEqual(@as(?i32, 40), first.awaited.asInt());
    outcome = try vm.resumeExecution(first.continuation, .{ .resolved = Value.fromInt(40).? });
    const second = switch (outcome) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    try std.testing.expectEqual(@as(?i32, 41), second.awaited.asInt());
    outcome = try vm.resumeExecution(second.continuation, .{ .resolved = Value.fromInt(41).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 43), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "source compiler rejects await outside an async function" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnexpectedToken, compile(allocator, "function load() { return await 40; } load();"));
}

test "async continuation survives zRun artifact encode and load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var program = try compile(allocator, "async function load() { return await 40 + 2; } load();");
    defer program.deinit(allocator);
    const artifact = @import("artifact.zig");
    const unit = try artifact.unitFromProgram(allocator, program);
    const bytes = try artifact.encode(allocator, unit);
    const loaded = try artifact.load(allocator, bytes);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    const pending = try vm.executeAsync(loaded);
    const suspended = switch (pending) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    const outcome = try vm.resumeExecution(suspended.continuation, .{ .resolved = Value.fromInt(40).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "async await passes host task rejection through the function catch handler" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "async function load() { try { return await print(\"request\"); } catch (reason) { return reason + 2; } } load();");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const natives = [_]VM.NativeFunction{asyncHostRequest};
    const vm = VM{ .allocator = allocator, .objects = &objects, .native_functions = &natives };
    const pending = try vm.executeAsync(program.bytecode());
    const suspended = switch (pending) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    try std.testing.expectEqual(@as(?i32, 900), suspended.awaited.asInt());
    const outcome = try vm.resumeExecution(suspended.continuation, .{ .rejected = Value.fromInt(40).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "async await rejection unwinds nested frames into the caller catch handler" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "async function load() { return await print(\"request\"); } try { load(); } catch (reason) { reason + 2; }");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const natives = [_]VM.NativeFunction{asyncHostRequest};
    const vm = VM{ .allocator = allocator, .objects = &objects, .native_functions = &natives };
    const pending = try vm.executeAsync(program.bytecode());
    const suspended = switch (pending) {
        .suspended => |state| state,
        else => return error.ExpectedSuspension,
    };
    const outcome = try vm.resumeExecution(suspended.continuation, .{ .rejected = Value.fromInt(40).? });
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "async await continuation handles ten thousand host completions" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "async function run(limit) { let n = 0; while (n < limit) { await n; n++; } return n; } run(10000);");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    var outcome = try vm.executeAsync(program.bytecode());
    var resumes: usize = 0;
    while (outcome == .suspended) {
        const pending = outcome.suspended;
        outcome = try vm.resumeExecution(pending.continuation, .{ .resolved = pending.awaited });
        resumes += 1;
    }
    try std.testing.expectEqual(@as(usize, 10000), resumes);
    switch (outcome) {
        .value => |value| try std.testing.expectEqual(@as(?i32, 10000), value.asInt()),
        else => return error.ExpectedCompletion,
    }
}

test "async runtime keeps one thousand suspended scripts independent" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "async function run() { await 1; return 2; } run();");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    const continuations = try allocator.alloc(*VM.Continuation, 1000);
    defer allocator.free(continuations);
    for (continuations) |*continuation| {
        const pending = try vm.executeAsync(program.bytecode());
        continuation.* = switch (pending) {
            .suspended => |state| state.continuation,
            else => return error.ExpectedSuspension,
        };
    }
    for (0..continuations.len) |reverse_index| {
        const index = continuations.len - reverse_index - 1;
        const outcome = try vm.resumeExecution(continuations[index], .{ .resolved = Value.fromInt(1).? });
        switch (outcome) {
            .value => |value| try std.testing.expectEqual(@as(?i32, 2), value.asInt()),
            else => return error.ExpectedCompletion,
        }
    }
}

fn asyncHostRequest(_: *VM.NativeCallContext, _: []const Value) anyerror!Value {
    return Value.fromInt(900).?;
}

test "source compiler supports recursive named function calls" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "function factorial(n) { if (n <= 1) return 1; return n * factorial(n - 1); } factorial(5);");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 120), result.asInt().?);
}

test "non-escaping function bindings stay in frame storage" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "function addOne(value) { return value + 1; } addOne(41);");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();

    const vm = VM{ .allocator = allocator, .objects = &objects };
    const result = try vm.execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 42), result.asInt());
    try std.testing.expectEqual(@as(usize, 0), objects.cells.items.len);
}

test "source compiler lowers try catch into VM exception handlers" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "let answer = 0; try { throw 42; } catch (errorValue) { answer = errorValue; } answer;");
    defer program.deinit(allocator);

    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(i32, 42), result.asInt().?);
}

test "source compiler runs escaped strings through a native plugin call" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "print(\"a\\nb\"); 7;");
    defer program.deinit(allocator);
    const natives = [_]VM.NativeFunction{nativeStringLength};
    const vm = VM{ .allocator = allocator, .native_functions = &natives, .native_context = &program };
    const result = try vm.execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 7), result.asInt());
}

test "source compiler executes array literals indexing mutation and length" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "var values = [3, 5, 8]; values[1] = 7; values.length + values[1];");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 10), result.asInt());
}

test "length access falls back for ordinary properties and primitive values" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "var objectLength = { length: 7 }.length; function primitiveLength(value) { return value.length; } objectLength + (primitiveLength(3) === undefined && (3 < primitiveLength(3)) === false ? 1 : 0);");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 8), result.asInt());
}

test "source compiler executes object literals static properties and computed keys" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "var item = {name: \"zed\", count: 3}; var key = \"count\"; item.name = \"ok\"; item[key] + 1;");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 4), result.asInt());
}

test "source compiler captures outer values in returned anonymous functions" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "function makeAdder(base) { return function (value) { return base + value; }; } let addFive = makeAdder(5); addFive(4);");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 9), result.asInt());
}

test "closures share captured mutable local bindings" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "function makeCounter() { var count = 0; return function () { count++; return count; }; } var next = makeCounter(); next() + next();");
    defer program.deinit(allocator);
    const result = try (VM{ .allocator = allocator }).execute(program.bytecode());
    try std.testing.expectEqual(@as(?i32, 3), result.asInt());
}

test "VM caller-owned object store keeps returned arrays alive after execution" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "[3, 9];");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    const result = try vm.execute(program.bytecode());
    const array = objects.findArray(result).?;
    try std.testing.expectEqual(@as(?i32, 9), array.items.items[1].asInt());
}

test "source compiler concatenates strings into runtime-owned values" {
    const allocator = std.testing.allocator;
    var program = try compile(allocator, "\"<p>\" + 42 + \"</p>\" + 7 + \"\";");
    defer program.deinit(allocator);
    var objects = @import("vm/objects.zig").Store.init(allocator);
    defer objects.deinit();
    const vm = VM{ .allocator = allocator, .objects = &objects };
    const result = try vm.execute(program.bytecode());
    try std.testing.expectEqualStrings("<p>42</p>7", objects.findString(result).?);
}

fn nativeStringLength(context: *VM.NativeCallContext, arguments: []const Value) anyerror!Value {
    const program: *Program = @ptrCast(@alignCast(context.host_context.?));
    const bytes = program.stringBytes(arguments[0]) orelse return error.ExpectedString;
    return Value.fromInt(@intCast(bytes.len)) orelse error.IntegerOverflow;
}
