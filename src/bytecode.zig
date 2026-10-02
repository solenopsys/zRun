const std = @import("std");
const Value = @import("value.zig").Value;
const FunctionBytecode = @import("vm.zig").FunctionBytecode;
const ExternalKind = @import("vm.zig").ExternalKind;
const ExternalVariable = @import("vm.zig").ExternalVariable;
const StringEntry = @import("vm/objects.zig").StringEntry;

pub const magic: u16 = 0xacfb;
pub const version_64: u16 = 0x8001;
pub const header_size: usize = 32;
const word_size: usize = 8;
const pointer_tag: u64 = 1;
const ascii_table = makeAsciiTable();

pub const Error = error{
    TruncatedHeader,
    InvalidMagic,
    UnsupportedVersion,
    UnsupportedHostWordSize,
    MisalignedImage,
    TruncatedBlock,
    InvalidBlockSize,
    UnsupportedMemoryTag,
    InvalidPointer,
    AddressOverflow,
    ForeignRelocationBase,
    InvalidFunctionData,
    UnsupportedConstant,
    OutOfMemory,
};

const MemoryTag = enum(u3) {
    free = 0,
    object = 1,
    float64 = 2,
    string = 3,
    function_bytecode = 4,
    value_array = 5,
    byte_array = 6,
    var_ref = 7,
};

pub const Image = struct {
    bytes: []u8,

    pub const FunctionRecord = struct {
        name: u64,
        bytecode: u64,
        constants: u64,
        locals: u64,
        external_variables: u64,
        stack_size: u16,
        external_variable_count: u16,
        filename: u64,
        pc_to_line: u64,
        argument_count: u16,
    };

    pub const LoadedFunction = struct {
        allocator: std.mem.Allocator,
        bytecode: FunctionBytecode,
        constants: []Value,
        string_values: []StringEntry,
        external_variables: []ExternalVariable,
        functions: []FunctionBytecode,
        children: []LoadedFunction,

        pub fn deinit(self: *LoadedFunction) void {
            for (self.children) |*child| child.deinit();
            self.allocator.free(self.children);
            self.allocator.free(self.functions);
            self.allocator.free(self.constants);
            self.allocator.free(self.string_values);
            self.allocator.free(self.external_variables);
        }

        fn countStringValues(self: *const LoadedFunction) usize {
            var count = self.string_values.len;
            for (self.children) |child| count += child.countStringValues();
            return count;
        }

        fn copyStringValues(self: *const LoadedFunction, destination: []StringEntry, offset: usize) usize {
            @memcpy(destination[offset .. offset + self.string_values.len], self.string_values);
            var next = offset + self.string_values.len;
            for (self.children) |child| next = child.copyStringValues(destination, next);
            return next;
        }
    };

    pub fn init(bytes: []u8) Error!Image {
        var image = try initForRelocation(bytes);
        _ = try image.walk(null);
        return image;
    }

    /// Initialize an image that will be validated and rebased by `relocate`.
    pub fn initForRelocation(bytes: []u8) Error!Image {
        if (@sizeOf(usize) != word_size) return error.UnsupportedHostWordSize;
        if (bytes.len < header_size) return error.TruncatedHeader;
        if (readU16(bytes, 0) != magic) return error.InvalidMagic;
        if (readU16(bytes, 2) != version_64) return error.UnsupportedVersion;
        return .{ .bytes = bytes };
    }

    pub fn baseAddress(self: *const Image) u64 {
        return readU64(self.bytes, 8);
    }

    pub fn uniqueStrings(self: *const Image) u64 {
        return readU64(self.bytes, 16);
    }

    pub fn mainFunction(self: *const Image) u64 {
        return readU64(self.bytes, 24);
    }

    pub fn function(self: *const Image, value: u64) Error!FunctionRecord {
        const offset = try self.heapOffset(value);
        if (try blockTag(self.bytes, offset) != .function_bytecode) return error.UnsupportedMemoryTag;
        return .{
            .name = readU64(self.bytes, offset + 8),
            .bytecode = readU64(self.bytes, offset + 16),
            .constants = readU64(self.bytes, offset + 24),
            .locals = readU64(self.bytes, offset + 32),
            .external_variables = readU64(self.bytes, offset + 40),
            .stack_size = readU16(self.bytes, offset + 48),
            .external_variable_count = readU16(self.bytes, offset + 50),
            .filename = readU64(self.bytes, offset + 56),
            .pc_to_line = readU64(self.bytes, offset + 64),
            .argument_count = @truncate(readU64(self.bytes, offset) >> 7),
        };
    }

    /// Build the current VM function view for flat functions with immediate/string constants.
    pub fn loadMain(self: *const Image, allocator: std.mem.Allocator) Error!LoadedFunction {
        return self.loadFunction(allocator, self.mainFunction(), 0);
    }

    fn loadFunction(self: *const Image, allocator: std.mem.Allocator, function_value: u64, depth: usize) Error!LoadedFunction {
        if (depth >= 8) return error.InvalidFunctionData;
        const function_record = try self.function(function_value);
        if (!isPointer(function_record.bytecode)) return error.InvalidFunctionData;
        const code = try self.byteArray(function_record.bytecode);

        var local_count: usize = 0;
        if (isPointer(function_record.locals)) {
            local_count = try self.valueArrayCount(function_record.locals);
        }
        if (local_count < function_record.argument_count) return error.InvalidFunctionData;

        var constants: std.ArrayList(Value) = .empty;
        errdefer constants.deinit(allocator);
        var strings: std.ArrayList(StringEntry) = .empty;
        errdefer strings.deinit(allocator);
        var external_variables: std.ArrayList(ExternalVariable) = .empty;
        errdefer external_variables.deinit(allocator);
        var children: std.ArrayList(LoadedFunction) = .empty;
        errdefer {
            for (children.items) |*child| child.deinit();
            children.deinit(allocator);
        }
        var function_indices: std.ArrayList(?usize) = .empty;
        defer function_indices.deinit(allocator);
        if (isPointer(function_record.constants)) {
            const constant_count = try self.valueArrayCount(function_record.constants);
            constants.ensureTotalCapacity(allocator, constant_count) catch return error.OutOfMemory;
            function_indices.resize(allocator, constant_count) catch return error.OutOfMemory;
            @memset(function_indices.items, null);
            for (0..constant_count) |index| {
                const raw = try self.valueArrayItem(function_record.constants, index);
                const value = Value{ .bits = @intCast(raw) };
                if (isPointer(raw)) {
                    switch (try self.valueTag(raw)) {
                        .string => {
                            const bytes = self.string(raw) catch return error.UnsupportedConstant;
                            strings.append(allocator, .{ .value = value, .bytes = bytes }) catch return error.OutOfMemory;
                        },
                        .function_bytecode => {
                            var child = try self.loadFunction(allocator, raw, depth + 1);
                            const child_index = children.items.len;
                            children.append(allocator, child) catch {
                                child.deinit();
                                return error.OutOfMemory;
                            };
                            function_indices.items[index] = child_index;
                        },
                        else => return error.UnsupportedConstant,
                    }
                } else if (isStringCharacter(raw)) {
                    const bytes = self.stringValue(raw) catch return error.UnsupportedConstant;
                    strings.append(allocator, .{ .value = value, .bytes = bytes }) catch return error.OutOfMemory;
                }
                constants.append(allocator, value) catch return error.OutOfMemory;
            }
        }

        if (isPointer(function_record.external_variables)) {
            const ext_value_count = try self.valueArrayCount(function_record.external_variables);
            if (ext_value_count % 2 != 0) return error.InvalidFunctionData;
            const global_count = ext_value_count / 2;
            external_variables.ensureTotalCapacity(allocator, global_count) catch return error.OutOfMemory;
            for (0..global_count) |index| {
                const name_value = try self.valueArrayItem(function_record.external_variables, index * 2);
                const name = self.stringValue(name_value) catch return error.InvalidFunctionData;
                const declaration = try self.valueArrayItem(function_record.external_variables, index * 2 + 1);
                const declaration_int = (Value{ .bits = @intCast(declaration) }).asInt() orelse return error.InvalidFunctionData;
                const declaration_bits: u32 = @bitCast(declaration_int);
                const kind: ExternalKind = switch (declaration_bits >> 16) {
                    0 => .argument,
                    1 => .local,
                    2 => .outer,
                    3 => .global,
                    else => return error.InvalidFunctionData,
                };
                const source_index: u16 = @truncate(declaration_bits);
                external_variables.append(allocator, .{
                    .name = name,
                    .kind = kind,
                    .index = source_index,
                    .declared = (declaration_int & 0xffff) != 0,
                }) catch return error.OutOfMemory;
            }
        }

        const owned_constants = constants.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(owned_constants);
        const local_strings = strings.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(local_strings);
        const owned_external_variables = external_variables.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer allocator.free(owned_external_variables);
        const owned_children = children.toOwnedSlice(allocator) catch return error.OutOfMemory;
        errdefer {
            for (owned_children) |*child| child.deinit();
            allocator.free(owned_children);
        }
        const owned_functions = allocator.alloc(FunctionBytecode, owned_constants.len) catch return error.OutOfMemory;
        errdefer allocator.free(owned_functions);
        @memset(owned_functions, .{ .code = &.{} });
        for (function_indices.items, 0..) |child_index, constant_index| {
            if (child_index) |child| owned_functions[constant_index] = owned_children[child].bytecode;
        }
        var string_count = local_strings.len;
        for (owned_children) |child| string_count += child.countStringValues();
        const owned_strings = allocator.alloc(StringEntry, string_count) catch return error.OutOfMemory;
        errdefer allocator.free(owned_strings);
        var string_offset: usize = 0;
        @memcpy(owned_strings[0..local_strings.len], local_strings);
        string_offset += local_strings.len;
        for (owned_children) |child| string_offset = child.copyStringValues(owned_strings, string_offset);
        allocator.free(local_strings);
        return .{
            .allocator = allocator,
            .constants = owned_constants,
            .string_values = owned_strings,
            .external_variables = owned_external_variables,
            .functions = owned_functions,
            .children = owned_children,
            .bytecode = .{
                .code = code,
                .constants = owned_constants,
                .string_values = owned_strings,
                .max_stack = @max(function_record.stack_size, 1),
                .local_count = local_count - function_record.argument_count,
                .argument_count = function_record.argument_count,
                .external_variables = owned_external_variables,
                .functions = owned_functions,
                .capture_count = owned_external_variables.len,
            },
        };
    }

    pub fn byteArray(self: *const Image, value: u64) Error![]const u8 {
        const offset = try self.heapOffset(value);
        if (try blockTag(self.bytes, offset) != .byte_array) return error.UnsupportedMemoryTag;
        const size: usize = @intCast(readU64(self.bytes, offset) >> 4);
        return self.bytes[offset + word_size ..][0..size];
    }

    pub fn valueArrayCount(self: *const Image, value: u64) Error!usize {
        const offset = try self.heapOffset(value);
        if (try blockTag(self.bytes, offset) != .value_array) return error.UnsupportedMemoryTag;
        return @intCast(readU64(self.bytes, offset) >> 4);
    }

    pub fn valueArrayItem(self: *const Image, value: u64, index: usize) Error!u64 {
        const offset = try self.heapOffset(value);
        if (try blockTag(self.bytes, offset) != .value_array) return error.UnsupportedMemoryTag;
        const count: usize = @intCast(readU64(self.bytes, offset) >> 4);
        if (index >= count) return error.InvalidPointer;
        return readU64(self.bytes, offset + word_size + index * word_size);
    }

    pub fn string(self: *const Image, value: u64) Error![]const u8 {
        const offset = try self.heapOffset(value);
        if (try blockTag(self.bytes, offset) != .string) return error.UnsupportedMemoryTag;
        const len: usize = @intCast(readU64(self.bytes, offset) >> 7);
        return self.bytes[offset + word_size ..][0..len];
    }

    fn stringValue(self: *const Image, value: u64) Error![]const u8 {
        if (isPointer(value)) return self.string(value);
        if (!isStringCharacter(value)) return error.UnsupportedConstant;
        const codepoint = value >> 5;
        if (codepoint >= ascii_table.len) return error.UnsupportedConstant;
        return ascii_table[@intCast(codepoint)..][0..1];
    }

    fn heapOffset(self: *const Image, value: u64) Error!usize {
        if ((value & (word_size - 1)) != pointer_tag) return error.InvalidPointer;
        const address = value - pointer_tag;
        const base = self.baseAddress();
        if (address < base) return error.InvalidPointer;
        const relative = address - base;
        if (relative >= self.bytes.len - header_size or (relative & (word_size - 1)) != 0) return error.InvalidPointer;
        return header_size + @as(usize, @intCast(relative));
    }

    fn valueTag(self: *const Image, value: u64) Error!MemoryTag {
        return blockTag(self.bytes, try self.heapOffset(value));
    }

    pub fn blockCount(self: *const Image) Error!usize {
        var cursor = header_size;
        var count: usize = 0;
        while (cursor < self.bytes.len) : (count += 1) {
            const tag = try blockTag(self.bytes, cursor);
            cursor += try blockSize(self.bytes, cursor, tag);
        }
        return count;
    }

    /// Rebase relative pointer values to the heap immediately after the header.
    /// Validation runs first, so malformed pointer data cannot leave a half-relocated image.
    pub fn relocate(self: *Image) Error!void {
        const data = self.bytes[header_size..];
        const new_base = @intFromPtr(data.ptr);
        if ((new_base & (word_size - 1)) != 0) return error.MisalignedImage;

        const old_base = self.baseAddress();
        if (old_base == new_base) {
            try self.validatePointers(old_base, old_base);
            return;
        }
        if (old_base != 0) return error.ForeignRelocationBase;

        try self.validatePointers(old_base, new_base);
        const delta = new_base;
        _ = try self.walk(struct {
            fn apply(image: *Image, offset: usize, _: MemoryTag) Error!void {
                try image.relocateBlockValues(offset, @intFromPtr(image.bytes[header_size..].ptr));
            }
        }.apply);
        try relocateValue(self.bytes, 16, delta, data.len);
        try relocateValue(self.bytes, 24, delta, data.len);
        writeU64(self.bytes, 8, new_base);
    }

    fn validatePointers(self: *const Image, stored_base: u64, new_base: u64) Error!void {
        try validateValue(self.bytes, 16, stored_base, new_base, self.bytes.len - header_size);
        try validateValue(self.bytes, 24, stored_base, new_base, self.bytes.len - header_size);
        var cursor: usize = header_size;
        while (cursor < self.bytes.len) {
            const tag = try blockTag(self.bytes, cursor);
            const size = try blockSize(self.bytes, cursor, tag);
            switch (tag) {
                .function_bytecode => {
                    inline for (.{ 8, 16, 24, 32, 40, 56, 64 }) |field| {
                        try validateValue(self.bytes, cursor + field, stored_base, new_base, self.bytes.len - header_size);
                    }
                },
                .value_array => {
                    const count = readU64(self.bytes, cursor) >> 4;
                    var index: usize = 0;
                    while (index < count) : (index += 1) {
                        try validateValue(self.bytes, cursor + word_size + index * word_size, stored_base, new_base, self.bytes.len - header_size);
                    }
                },
                else => {},
            }
            cursor += size;
        }
    }

    fn relocateBlockValues(self: *Image, offset: usize, new_base: u64) Error!void {
        const tag = try blockTag(self.bytes, offset);
        switch (tag) {
            .function_bytecode => inline for (.{ 8, 16, 24, 32, 40, 56, 64 }) |field| {
                try relocateValue(self.bytes, offset + field, new_base, self.bytes.len - header_size);
            },
            .value_array => {
                const count = readU64(self.bytes, offset) >> 4;
                var index: usize = 0;
                while (index < count) : (index += 1) {
                    try relocateValue(self.bytes, offset + word_size + index * word_size, new_base, self.bytes.len - header_size);
                }
            },
            else => {},
        }
    }

    const Visitor = *const fn (*Image, usize, MemoryTag) Error!void;

    fn walk(self: *Image, visitor: ?Visitor) Error!usize {
        var cursor = header_size;
        var count: usize = 0;
        while (cursor < self.bytes.len) : (count += 1) {
            const tag = try blockTag(self.bytes, cursor);
            const size = try blockSize(self.bytes, cursor, tag);
            if (visitor) |visit| try visit(self, cursor, tag);
            cursor += size;
        }
        if (cursor != self.bytes.len) return error.TruncatedBlock;
        return count;
    }
};

fn blockTag(bytes: []const u8, offset: usize) Error!MemoryTag {
    if (offset > bytes.len or bytes.len - offset < word_size) return error.TruncatedBlock;
    const raw: u3 = @truncate((readU64(bytes, offset) >> 1) & 7);
    return switch (raw) {
        0 => .free,
        1 => .object,
        2 => .float64,
        3 => .string,
        4 => .function_bytecode,
        5 => .value_array,
        6 => .byte_array,
        7 => .var_ref,
    };
}

fn isPointer(value: u64) bool {
    return (value & (word_size - 1)) == pointer_tag;
}

fn isStringCharacter(value: u64) bool {
    return (value & 0x1f) == 27;
}

fn makeAsciiTable() [128]u8 {
    var bytes: [128]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    return bytes;
}

fn blockSize(bytes: []const u8, offset: usize, tag: MemoryTag) Error!usize {
    const header = readU64(bytes, offset);
    const payload_words = header >> 4;
    const size: u64 = switch (tag) {
        .free => checkedWordsSize(payload_words) orelse return error.InvalidBlockSize,
        .float64 => 16,
        .string => 8 + alignForward((header >> 7) + 1, word_size),
        .function_bytecode => 80,
        .value_array => checkedWordsSize(payload_words) orelse return error.InvalidBlockSize,
        .byte_array => 8 + alignForward(payload_words, word_size),
        .object, .var_ref => return error.UnsupportedMemoryTag,
    };
    if (size < word_size or size > std.math.maxInt(usize)) return error.InvalidBlockSize;
    const block_len: usize = @intCast(size);
    if (block_len % word_size != 0) return error.InvalidBlockSize;
    if (offset > bytes.len or block_len > bytes.len - offset) return error.TruncatedBlock;
    return block_len;
}

fn validateValue(bytes: []const u8, offset: usize, stored_base: u64, new_base: u64, data_len: usize) Error!void {
    const value = readU64(bytes, offset);
    if ((value & (word_size - 1)) != pointer_tag) return;
    const address = value - pointer_tag;
    if (address < stored_base) return error.InvalidPointer;
    const relative = address - stored_base;
    if (relative >= data_len or (relative & (word_size - 1)) != 0) return error.InvalidPointer;
    const relocated = std.math.add(u64, new_base, relative) catch return error.AddressOverflow;
    _ = std.math.add(u64, relocated, pointer_tag) catch return error.AddressOverflow;
}

fn relocateValue(bytes: []u8, offset: usize, new_base: u64, data_len: usize) Error!void {
    const value = readU64(bytes, offset);
    if ((value & (word_size - 1)) != pointer_tag) return;
    const relative = value - pointer_tag;
    if (relative >= data_len or (relative & (word_size - 1)) != 0) return error.InvalidPointer;
    const relocated = std.math.add(u64, new_base, relative) catch return error.AddressOverflow;
    writeU64(bytes, offset, relocated + pointer_tag);
}

fn alignForward(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn checkedWordsSize(count: u64) ?u64 {
    const max = std.math.maxInt(u64);
    if (count > (max - word_size) / word_size) return null;
    return word_size + count * word_size;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, bytes[offset..][0..8], .little);
}

fn writeU64(bytes: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[offset..][0..8], value, .little);
}

test "relocates an upstream compiler image and is idempotent" {
    const fixture = @embedFile("testdata/values.bin");
    const bytes = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(bytes);

    var image = try Image.init(bytes);
    try std.testing.expectEqual(magic, readU16(bytes, 0));
    try std.testing.expect(try image.blockCount() > 0);
    try std.testing.expectEqual(@as(u64, 0x91), image.mainFunction());
    try std.testing.expectEqual(@as(u64, 0x39), image.uniqueStrings());

    try image.relocate();
    const data_address = @intFromPtr(bytes[header_size..].ptr);
    try std.testing.expectEqual(@as(u64, data_address), image.baseAddress());
    try std.testing.expectEqual(@as(u64, data_address + 0x90 + pointer_tag), image.mainFunction());
    try std.testing.expectEqual(@as(u64, data_address + 0x38 + pointer_tag), image.uniqueStrings());
    const main = try image.function(image.mainFunction());
    try std.testing.expect(main.stack_size > 0);
    try std.testing.expect(main.bytecode != 0);
    try std.testing.expect(try image.valueArrayCount(main.constants) > 0);
    try std.testing.expectEqualStrings("<eval>", try image.string(try image.valueArrayItem(image.uniqueStrings(), 0)));
    try std.testing.expect((try image.byteArray(main.bytecode)).len > 0);
    try image.relocate();
    try std.testing.expectEqual(@as(u64, data_address + 0x90 + pointer_tag), image.mainFunction());
}

test "rejects malformed headers and truncated block payloads" {
    const fixture = @embedFile("testdata/values.bin");
    const bytes = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(bytes);

    bytes[2] = 0;
    try std.testing.expectError(error.UnsupportedVersion, Image.init(bytes));
    bytes[2] = 1;
    bytes[3] = 0x80;

    const original_header = readU64(bytes, header_size);
    writeU64(bytes, header_size, (@as(u64, 1000) << 7) | (original_header & 0x7f));
    try std.testing.expectError(error.TruncatedBlock, Image.init(bytes));

    writeU64(bytes, header_size, 14);
    try std.testing.expectError(error.UnsupportedMemoryTag, Image.init(bytes));
}

test "invalid pointer relocations do not partially mutate the image" {
    const fixture = @embedFile("testdata/values.bin");
    const bytes = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(bytes);

    writeU64(bytes, 24, @as(u64, fixture.len + 1));
    var image = try Image.init(bytes);
    const original_header = readU64(bytes, 16);
    try std.testing.expectError(error.InvalidPointer, image.relocate());
    try std.testing.expectEqual(@as(u64, 0), image.baseAddress());
    try std.testing.expectEqual(original_header, image.uniqueStrings());
}

test "upstream image main function executes on the Zig VM" {
    const fixture = @embedFile("testdata/throw_42.bin");
    const allocator = std.testing.allocator;
    const bytes = try allocator.dupe(u8, fixture);
    defer allocator.free(bytes);

    var image = try Image.init(bytes);
    try image.relocate();
    var loaded = try image.loadMain(allocator);
    defer loaded.deinit();

    const VM = @import("vm.zig").VM;
    const outcome = try (VM{ .allocator = allocator }).executeOutcome(loaded.bytecode);
    switch (outcome) {
        .value => try std.testing.expect(false),
        .thrown => |value| try std.testing.expectEqual(@as(?i32, 42), value.asInt()),
        .suspended => |suspension| {
            suspension.continuation.deinit();
            return error.TestUnexpectedResult;
        },
    }
}
