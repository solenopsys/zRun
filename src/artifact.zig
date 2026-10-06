const std = @import("std");
const FunctionBytecode = @import("vm.zig").FunctionBytecode;
const StringValue = @import("vm.zig").StringValue;
const Value = @import("value.zig").Value;

const magic = "ZRUNBC01";
const max_depth = 128;

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
	var buffer = Buffer{ .allocator = allocator };
	try buffer.write(magic);
	try buffer.writeU16(1);
	try buffer.writeU16(0);
	try writeUnit(&buffer, unit, 0);
	return buffer.owned();
}

fn writeUnit(buffer: *Buffer, unit: Unit, depth: usize) !void {
	if (depth >= max_depth) return error.NestingTooDeep;
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
	for (unit.children) |child| try writeUnit(buffer, child, depth + 1);
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

	pub fn init(parent_allocator: std.mem.Allocator, bytes: []const u8) !LoadedModule {
		const arena = try parent_allocator.create(std.heap.ArenaAllocator);
		arena.* = std.heap.ArenaAllocator.init(parent_allocator);
		errdefer {
			arena.deinit();
			parent_allocator.destroy(arena);
		}
		const allocator = arena.allocator();
		const owned_bytes = try allocator.dupe(u8, bytes);
		return .{ .parent_allocator = parent_allocator, .arena = arena, .root = try load(allocator, owned_bytes) };
	}

	pub fn deinit(self: *LoadedModule) void {
		self.arena.deinit();
		self.parent_allocator.destroy(self.arena);
		self.* = undefined;
	}

	pub fn findFunction(self: *const LoadedModule, name: []const u8) ?*const FunctionBytecode {
		return findFunctionIn(&self.root, name);
	}
};

fn findFunctionIn(function: *const FunctionBytecode, name: []const u8) ?*const FunctionBytecode {
	if (std.mem.eql(u8, function.name, name)) return function;
	for (function.functions) |*child| {
		if (child.code.ptr == function.code.ptr and child.code.len == function.code.len) continue;
		if (findFunctionIn(child, name)) |found| return found;
	}
	return null;
}

pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !FunctionBytecode {
	if (@sizeOf(usize) != 8) return error.UnsupportedHostWordSize;
	var reader = Reader{ .bytes = bytes };
	if (!std.mem.eql(u8, try reader.read(magic.len), magic)) return error.InvalidArtifactMagic;
	if (try reader.readU16() != 1) return error.UnsupportedArtifactVersion;
	if (try reader.readU16() != 0) return error.InvalidArtifactHeader;
	const loaded = try readUnit(allocator, &reader, false, 0);
	if (reader.offset != bytes.len) return error.TrailingArtifactData;
	return loaded.function;
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

fn readUnit(allocator: std.mem.Allocator, reader: *Reader, is_function: bool, depth: usize) anyerror!LoadedUnit {
	if (depth >= max_depth) return error.NestingTooDeep;
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
	for (children) |*child| child.* = try readUnit(allocator, reader, true, depth + 1);

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
