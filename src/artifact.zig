const std = @import("std");
const FunctionBytecode = @import("vm.zig").FunctionBytecode;
const StringValue = @import("vm.zig").StringValue;
const Value = @import("value.zig").Value;

const magic = "ZRUNBC01";
const max_depth = 128;
const legacy_version: u16 = 1;
const metadata_version: u16 = 2;
const metadata_flag: u16 = 1;
const metadata_header_size: usize = magic.len + 2 + 2 + 4 + 4;

pub const MetadataDocument = std.json.Value;

pub const DecodedArtifact = struct {
    root: FunctionBytecode,
    metadata_json: ?[]const u8 = null,
    metadata: ?MetadataDocument = null,
    function_metadata: []?std.json.Value,
};

pub const Constant = union(enum) {
    value: u64,
    string: []const u8,
};

pub const Unit = struct {
    name: []const u8 = "",
    code: []const u8,
    local_count: u32,
    argument_count: u16 = 0,
    capture_count: u16 = 0,
    capture_sources: []const u16 = &.{},
    capture_local_indices: []const u16 = &.{},
    constants: []const Constant = &.{},
    children: []const Unit = &.{},
};

pub const Buffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn write(self: *Buffer, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }

    fn writeU8(self: *Buffer, value: u8) !void {
        try self.bytes.append(self.allocator, value);
    }

    fn writeU16(self: *Buffer, value: u16) !void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        try self.write(&bytes);
    }

    fn writeU32(self: *Buffer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.write(&bytes);
    }

    fn writeU64(self: *Buffer, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.write(&bytes);
    }

    fn blob(self: *Buffer, value: []const u8) !void {
        try self.writeU32(@intCast(value.len));
        try self.write(value);
    }

    fn owned(self: *Buffer) ![]u8 {
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

pub fn encode(allocator: std.mem.Allocator, unit: Unit) ![]u8 {
    return encodeWithMetadata(allocator, unit, null);
}

/// Encode version 2 artifacts, placing a compact UTF-8 JSON metadata document
/// after the bytecode tree. Version 1 artifacts remain readable by `decode`.
pub fn encodeWithMetadata(allocator: std.mem.Allocator, unit: Unit, metadata_json: ?[]const u8) ![]u8 {
    var buffer = Buffer{ .allocator = allocator };
    try buffer.write(magic);
    try buffer.writeU16(metadata_version);
    try buffer.writeU16(if (metadata_json == null) 0 else metadata_flag);
    try buffer.writeU32(0); // absolute metadata offset; patched after bytecode
    try buffer.writeU32(0); // metadata length; patched after bytecode
    var next_function_id: u32 = 0;
    try writeUnit(&buffer, unit, 0, &next_function_id);
    if (metadata_json) |json| {
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{ .allocate = .alloc_always });
        if (parsed != .object) return error.InvalidMetadataDocument;
        const format = parsed.object.get("format") orelse return error.MissingMetadataFormat;
        if (format != .string or !std.mem.eql(u8, format.string, "zrun.metadata/1")) return error.UnsupportedMetadataFormat;
        _ = try indexFunctionMetadata(allocator, parsed, countUnitFunctions(unit));
        const compact = try std.json.Stringify.valueAlloc(allocator, parsed, .{});
        defer allocator.free(compact);
        if (buffer.bytes.items.len > std.math.maxInt(u32) or compact.len > std.math.maxInt(u32)) return error.ArtifactTooLarge;
        if (compact.len > std.math.maxInt(u32) - buffer.bytes.items.len) return error.ArtifactTooLarge;
        const metadata_offset: u32 = @intCast(buffer.bytes.items.len);
        const metadata_length: u32 = @intCast(compact.len);
        std.mem.writeInt(u32, buffer.bytes.items[12..16], metadata_offset, .little);
        std.mem.writeInt(u32, buffer.bytes.items[16..20], metadata_length, .little);
        try buffer.write(compact);
    }
    return buffer.owned();
}

fn countUnitFunctions(unit: Unit) usize {
    var count: usize = 1;
    for (unit.children) |child| count += countUnitFunctions(child);
    return count;
}

fn writeUnit(buffer: *Buffer, unit: Unit, depth: usize, next_function_id: *u32) !void {
    if (depth >= max_depth) return error.NestingTooDeep;
    if (next_function_id.* == std.math.maxInt(u32)) return error.TooManyFunctions;
    try buffer.writeU32(next_function_id.*);
    next_function_id.* += 1;
    try buffer.blob(unit.name);
    try buffer.blob(unit.code);
    try buffer.writeU32(unit.local_count);
    try buffer.writeU16(unit.argument_count);
    try buffer.writeU16(unit.capture_count);
    try buffer.writeU16(@intCast(unit.capture_sources.len));
    for (unit.capture_sources) |value| try buffer.writeU16(value);
    try buffer.writeU16(@intCast(unit.capture_local_indices.len));
    for (unit.capture_local_indices) |value| try buffer.writeU16(value);
    try buffer.writeU32(@intCast(unit.constants.len));
    for (unit.constants) |constant| switch (constant) {
        .value => |value| {
            try buffer.writeU8(0);
            try buffer.writeU64(value);
        },
        .string => |value| {
            try buffer.writeU8(1);
            try buffer.blob(value);
        },
    };
    try buffer.writeU32(@intCast(unit.children.len));
    for (unit.children) |child| try writeUnit(buffer, child, depth + 1, next_function_id);
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn read(self: *Reader, count: usize) ![]const u8 {
        if (count > self.bytes.len -| self.offset) return error.TruncatedArtifact;
        const slice = self.bytes[self.offset .. self.offset + count];
        self.offset += count;
        return slice;
    }

    fn readU8(self: *Reader) !u8 {
        return (try self.read(1))[0];
    }

    fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.read(2))[0..2], .little);
    }

    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.read(4))[0..4], .little);
    }

    fn readU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.read(8))[0..8], .little);
    }

    fn blob(self: *Reader) ![]const u8 {
        return self.read(try self.readU32());
    }
};

const StringLiteral = struct { bytes: []const u8 };

const LoadedUnit = struct {
    function: FunctionBytecode,
    strings: []StringValue,
    children: []LoadedUnit,
};

pub const LoadedModule = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    root: FunctionBytecode,
    metadata_json: ?[]const u8 = null,
    metadata: ?MetadataDocument = null,
    function_metadata: []?std.json.Value = &.{},

    pub fn init(parent_allocator: std.mem.Allocator, bytes: []const u8) !LoadedModule {
        const arena = try parent_allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer {
            arena.deinit();
            parent_allocator.destroy(arena);
        }
        const allocator = arena.allocator();
        const owned_bytes = try allocator.dupe(u8, bytes);
        const decoded = try decode(allocator, owned_bytes);
        return .{
            .parent_allocator = parent_allocator,
            .arena = arena,
            .root = decoded.root,
            .metadata_json = decoded.metadata_json,
            .metadata = decoded.metadata,
            .function_metadata = decoded.function_metadata,
        };
    }

    pub fn deinit(self: *LoadedModule) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn findFunction(self: *const LoadedModule, name: []const u8) ?*const FunctionBytecode {
        return findFunctionIn(&self.root, name);
    }

    /// Returns a function's full extensible metadata record by its artifact-local ID.
    pub fn metadataForFunction(self: *const LoadedModule, function_id: u32) ?std.json.Value {
        const index: usize = function_id;
        if (index >= self.function_metadata.len) return null;
        return self.function_metadata[index];
    }
};

fn countFunctions(function: *const FunctionBytecode) usize {
    var count: usize = 1;
    for (function.functions) |*child| {
        if (child.artifact_id == function.artifact_id) continue;
        count += countFunctions(child);
    }
    return count;
}

fn indexFunctionMetadata(allocator: std.mem.Allocator, metadata: ?MetadataDocument, function_count: usize) ![]?std.json.Value {
    const index = try allocator.alloc(?std.json.Value, function_count);
    @memset(index, null);
    const document = metadata orelse return index;
    const records_value = document.object.get("functions") orelse return index;
    const records = switch (records_value) {
        .array => |array| array.items,
        else => return error.InvalidFunctionMetadata,
    };
    for (records) |record| {
        const object = switch (record) {
            .object => |value| value,
            else => return error.InvalidFunctionMetadata,
        };
        const id_value = object.get("id") orelse return error.MissingFunctionId;
        const id_number = switch (id_value) {
            .integer => |value| value,
            else => return error.InvalidFunctionId,
        };
        if (id_number < 0 or id_number >= @as(i64, @intCast(function_count))) return error.InvalidFunctionId;
        const id: usize = @intCast(id_number);
        if (index[id] != null) return error.DuplicateFunctionMetadata;
        index[id] = record;
    }
    return index;
}

fn findFunctionIn(function: *const FunctionBytecode, name: []const u8) ?*const FunctionBytecode {
    if (std.mem.eql(u8, function.name, name)) return function;
    for (function.functions) |*child| {
        if (child.code.ptr == function.code.ptr and child.code.len == function.code.len) continue;
        if (findFunctionIn(child, name)) |found| return found;
    }
    return null;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !FunctionBytecode {
    return (try decode(allocator, bytes)).root;
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !DecodedArtifact {
    if (@sizeOf(usize) != 8) return error.UnsupportedHostWordSize;
    var reader = Reader{ .bytes = bytes };
    if (!std.mem.eql(u8, try reader.read(magic.len), magic)) return error.InvalidArtifactMagic;
    const version = try reader.readU16();
    if (version == legacy_version) {
        if (try reader.readU16() != 0) return error.InvalidArtifactHeader;
        var next_function_id: u32 = 0;
        const loaded = try readUnit(allocator, &reader, false, 0, false, &next_function_id);
        if (reader.offset != bytes.len) return error.TrailingArtifactData;
        const function_metadata = try indexFunctionMetadata(allocator, null, countFunctions(&loaded.function));
        return .{ .root = loaded.function, .function_metadata = function_metadata };
    }
    if (version != metadata_version) return error.UnsupportedArtifactVersion;
    const flags = try reader.readU16();
    if (flags & ~metadata_flag != 0) return error.InvalidArtifactHeader;
    const metadata_offset = try reader.readU32();
    const metadata_length = try reader.readU32();
    const has_metadata = flags & metadata_flag != 0;
    if (has_metadata) {
        if (metadata_offset < metadata_header_size or metadata_offset > bytes.len) return error.InvalidMetadataRange;
        const offset: usize = metadata_offset;
        const length: usize = metadata_length;
        if (length == 0 or length > bytes.len - offset) return error.InvalidMetadataRange;
        if (offset + length != bytes.len) return error.InvalidMetadataRange;
    } else if (metadata_offset != 0 or metadata_length != 0) return error.InvalidArtifactHeader;
    const bytecode_end: usize = if (has_metadata) metadata_offset else bytes.len;
    reader.bytes = bytes[0..bytecode_end];
    var next_function_id: u32 = 0;
    const loaded = try readUnit(allocator, &reader, false, 0, true, &next_function_id);
    if (reader.offset != bytecode_end) return error.TrailingArtifactData;
    if (!has_metadata) {
        const function_metadata = try indexFunctionMetadata(allocator, null, countFunctions(&loaded.function));
        return .{ .root = loaded.function, .function_metadata = function_metadata };
    }
    const offset: usize = metadata_offset;
    const length: usize = metadata_length;
    const metadata_json = bytes[offset .. offset + length];
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, metadata_json, .{ .allocate = .alloc_always });
    if (parsed != .object) return error.InvalidMetadataDocument;
    const format = parsed.object.get("format") orelse return error.MissingMetadataFormat;
    if (format != .string or !std.mem.eql(u8, format.string, "zrun.metadata/1")) return error.UnsupportedMetadataFormat;
    const function_metadata = try indexFunctionMetadata(allocator, parsed, countFunctions(&loaded.function));
    return .{ .root = loaded.function, .metadata_json = metadata_json, .metadata = parsed, .function_metadata = function_metadata };
}

test "loaded module owns decoded functions and resolves named entries" {
    const allocator = std.testing.allocator;
    const children = [_]Unit{
        .{ .name = "lookupUser", .code = &.{ 1, 2, 3 }, .local_count = 0 },
        .{ .name = "writeUser", .code = &.{ 4, 5 }, .local_count = 0 },
    };
    const image = try encode(allocator, .{ .name = "users", .code = &.{}, .local_count = 0, .children = &children });
    defer allocator.free(image);
    var module = try LoadedModule.init(allocator, image);
    defer module.deinit();

    const lookup = module.findFunction("lookupUser") orelse return error.MissingFunction;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, lookup.code);
    try std.testing.expect(module.findFunction("missing") == null);
}

fn readUnit(allocator: std.mem.Allocator, reader: *Reader, is_function: bool, depth: usize, has_function_ids: bool, next_function_id: *u32) anyerror!LoadedUnit {
    if (depth >= max_depth) return error.NestingTooDeep;
    const function_id = if (has_function_ids) try reader.readU32() else next_function_id.*;
    if (function_id != next_function_id.*) return error.InvalidFunctionId;
    if (next_function_id.* == std.math.maxInt(u32)) return error.TooManyFunctions;
    next_function_id.* += 1;
    const name = try reader.blob();
    const code = try reader.blob();
    const local_count = try reader.readU32();
    const argument_count = try reader.readU16();
    const capture_count = try reader.readU16();
    const source_count = try reader.readU16();
    if (source_count != capture_count) return error.InvalidArtifactData;
    const capture_sources = try allocator.alloc(u16, source_count);
    for (capture_sources) |*value| value.* = try reader.readU16();
    const local_index_count = try reader.readU16();
    if (local_index_count != capture_count) return error.InvalidArtifactData;
    const capture_local_indices = try allocator.alloc(u16, local_index_count);
    for (capture_local_indices) |*value| value.* = try reader.readU16();
    const constant_count = try reader.readU32();
    const constants = try allocator.alloc(Value, constant_count);
    var own_strings: std.ArrayList(StringValue) = .empty;
    for (constants) |*value| {
        switch (try reader.readU8()) {
            0 => value.* = .{ .bits = @intCast(try reader.readU64()) },
            1 => {
                const string = try reader.blob();
                const literal = try allocator.create(StringLiteral);
                literal.* = .{ .bytes = string };
                value.* = Value.fromPointer(literal);
                try own_strings.append(allocator, .{ .value = value.*, .bytes = string });
            },
            else => return error.InvalidArtifactData,
        }
    }
    const child_count = try reader.readU32();
    const children = try allocator.alloc(LoadedUnit, child_count);
    for (children) |*child| child.* = try readUnit(allocator, reader, true, depth + 1, has_function_ids, next_function_id);

    var string_count = own_strings.items.len;
    for (children) |child| string_count += child.strings.len;
    const strings = try allocator.alloc(StringValue, string_count);
    @memcpy(strings[0..own_strings.items.len], own_strings.items);
    var string_offset = own_strings.items.len;
    for (children) |child| {
        @memcpy(strings[string_offset .. string_offset + child.strings.len], child.strings);
        string_offset += child.strings.len;
    }
    const functions = try allocator.alloc(FunctionBytecode, child_count + @intFromBool(is_function));
    const child_offset: usize = @intFromBool(is_function);
    for (children, 0..) |child, index| functions[child_offset + index] = child.function;
    var function = FunctionBytecode{
        .artifact_id = function_id,
        .name = name,
        .code = code,
        // Compiler-generated bytecode cannot need more stack slots than there
        // are instruction bytes. Keep the legacy limit for large functions,
        // while avoiding a 256-slot allocation for every small call frame.
        .max_stack = @max(@min(code.len, 256), 1),
        .constants = constants,
        .string_values = strings,
        .local_count = local_count,
        .argument_count = argument_count,
        .capture_count = capture_count,
        .capture_sources = capture_sources,
        .capture_local_indices = capture_local_indices,
        .functions = functions,
    };
    if (is_function) {
        functions[0] = function;
        functions[0].functions = functions;
        function = functions[0];
    }
    return .{ .function = function, .strings = strings, .children = children };
}

pub fn unitFromProgram(allocator: std.mem.Allocator, program: anytype) anyerror!Unit {
    const constants = try allocator.alloc(Constant, program.constants.len);
    for (program.constants, 0..) |value, index| {
        if (value.asPointer() != null) {
            constants[index] = .{ .string = program.stringBytes(value) orelse return error.UnsupportedConstant };
        } else {
            constants[index] = .{ .value = @intCast(value.raw()) };
        }
    }
    const children = try allocator.alloc(Unit, program.children.len);
    for (program.children, 0..) |child, index| children[index] = try unitFromProgram(allocator, child);
    return .{
        .name = program.name,
        .code = program.code,
        .local_count = @intCast(program.local_count),
        .argument_count = @intCast(program.argument_count),
        .capture_count = @intCast(program.capture_count),
        .capture_sources = program.capture_sources,
        .capture_local_indices = program.capture_local_indices,
        .constants = constants,
        .children = children,
    };
}
