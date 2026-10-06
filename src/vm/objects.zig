const std = @import("std");
const Value = @import("../value.zig").Value;

pub const ArrayObject = struct {
    items: SmallList(Value, 4) = .{},
    logical_length: usize = 0,
    byte_storage: ?[]u8 = null,
    is_buffer: bool = false,

	pub fn len(self: *const ArrayObject) usize {
		return if (self.byte_storage) |bytes| bytes.len else @max(self.logical_length, self.items.items.len);
	}

	pub fn get(self: *const ArrayObject, index: usize) Value {
		if (self.byte_storage) |bytes| return Value.fromInt(bytes[index]).?;
		return if (index < self.items.items.len) self.items.items[index] else Value.undefined_value;
	}

    pub fn set(self: *ArrayObject, allocator: std.mem.Allocator, index: usize, value: Value) !void {
		if (self.byte_storage) |bytes| {
			const number = value.asInt() orelse return error.TypeError;
			bytes[index] = @truncate(@as(u32, @bitCast(number)));
			return;
		}
        if (index >= self.items.items.len) {
            try self.items.ensureTotalCapacity(allocator, index + 1);
            while (self.items.items.len <= index) self.items.appendAssumeCapacity(Value.undefined_value);
        }
        self.items.items[index] = value;
        self.logical_length = @max(self.logical_length, index + 1);
    }

    pub fn materialize(self: *ArrayObject, allocator: std.mem.Allocator) !void {
        if (self.byte_storage != null or self.items.items.len >= self.len()) return;
        const length = self.len();
        try self.items.ensureTotalCapacity(allocator, length);
        while (self.items.items.len < length) self.items.appendAssumeCapacity(Value.undefined_value);
    }

    pub fn markBuffer(self: *ArrayObject, allocator: std.mem.Allocator) !void {
        if (self.byte_storage == null) {
            try self.materialize(allocator);
            const bytes = try allocator.alloc(u8, self.items.items.len);
            errdefer allocator.free(bytes);
            for (self.items.items, 0..) |value, index| {
                const integer = value.asInt() orelse return error.InvalidByte;
                if (integer < 0 or integer > 255) return error.InvalidByte;
                bytes[index] = @intCast(integer);
            }
            self.items.deinit(allocator);
            self.byte_storage = bytes;
        }
        self.is_buffer = true;
    }

    fn init(self: *ArrayObject) void {
        self.items.init();
    }
};

pub const ObjectField = struct {
    name: []const u8,
    value: Value,
};

pub const ObjectObject = struct {
    fields: SmallList(ObjectField, 4) = .{},
    prototype: Value = Value.undefined_value,

    fn init(self: *ObjectObject) void {
        self.fields.init();
    }
};

fn PointerCache(comptime T: type) type {
    return struct {
        entries: [8]?*T = @splat(null),
        next: usize = 0,
        last: ?*T = null,

        fn get(self: *@This(), pointer: *anyopaque) ?*T {
            if (self.last) |item| {
                if (@intFromPtr(item) == @intFromPtr(pointer)) return item;
            }
            for (self.entries) |entry| {
                if (entry) |item| {
                    if (@intFromPtr(item) == @intFromPtr(pointer)) return item;
                }
            }
            return null;
        }

        fn put(self: *@This(), item: *T) void {
            self.last = item;
            self.entries[self.next] = item;
            self.next = (self.next + 1) % self.entries.len;
        }
    };
}

fn SmallList(comptime T: type, comptime inline_capacity: usize) type {
    return struct {
        items: []T = &.{},
        inline_storage: [inline_capacity]T = undefined,
        heap_storage: ?[]T = null,
        capacity: usize = inline_capacity,
        using_inline: bool = true,

        fn init(self: *@This()) void {
            self.items = self.inline_storage[0..0];
            self.heap_storage = null;
            self.capacity = inline_capacity;
            self.using_inline = true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.heap_storage) |storage| allocator.free(storage);
            self.items = &.{};
            self.heap_storage = null;
            self.capacity = inline_capacity;
            self.using_inline = true;
        }

        pub fn ensureTotalCapacity(self: *@This(), allocator: std.mem.Allocator, requested: usize) !void {
            if (requested <= self.capacity) return;
            const next_capacity = @max(requested, self.capacity * 2);
            if (self.heap_storage) |storage| {
                self.heap_storage = try allocator.realloc(storage, next_capacity);
            } else {
                self.heap_storage = try allocator.alloc(T, next_capacity);
                @memcpy(self.heap_storage.?[0..self.items.len], self.items);
            }
            self.capacity = next_capacity;
            self.using_inline = false;
            self.items = self.heap_storage.?[0..self.items.len];
        }

        pub fn append(self: *@This(), allocator: std.mem.Allocator, item: T) !void {
            try self.ensureTotalCapacity(allocator, self.items.len + 1);
            self.appendAssumeCapacity(item);
        }

        pub fn appendSlice(self: *@This(), allocator: std.mem.Allocator, values: []const T) !void {
            const start = self.items.len;
            try self.ensureTotalCapacity(allocator, start + values.len);
            const end = start + values.len;
            const storage = self.heap_storage orelse self.inline_storage[0..];
            @memcpy(storage[start..end], values);
            self.items = storage[0..end];
        }

        pub fn appendAssumeCapacity(self: *@This(), item: T) void {
            const storage = self.heap_storage orelse self.inline_storage[0..];
            storage[self.items.len] = item;
            self.items = storage[0 .. self.items.len + 1];
        }
    };
}

pub const ClosureObject = struct {
    function: *anyopaque,
    captures: []*Cell,
    prototype: Value = Value.undefined_value,
    properties: SmallList(ObjectField, 2) = .{},
};
pub const BoundFunctionObject = struct {
    target: Value,
    this_value: Value = Value.undefined_value,
    arguments: std.ArrayList(Value) = .empty,
};
pub const CollectionKind = enum { map, set, weak_map };
pub const CollectionEntry = struct { key: Value, value: Value };
pub const CollectionObject = struct {
    kind: CollectionKind,
    entries: std.ArrayList(CollectionEntry) = .empty,
};
pub const IteratorObject = struct {
    values: std.ArrayList(Value) = .empty,
    index: usize = 0,
};
pub const ExternalTaskPromiseObject = struct { task_id: u64 };
pub const ExternalTaskEntry = union(enum) { value: Value, task_id: u64 };
pub const ExternalTaskGroupObject = struct { entries: std.ArrayList(ExternalTaskEntry) = .empty };
pub const RegexObject = struct { pattern: []u8, ignore_case: bool, global: bool };
pub const BigIntObject = struct { value: std.math.big.int.Managed };

pub const StringObject = struct {
    bytes: []const u8 = "",
    left: ?*StringObject = null,
    right: ?*StringObject = null,
    length: usize = 0,
    flat: bool = true,
};
pub const StringEntry = struct { value: Value, bytes: []const u8 };
pub const Cell = struct { value: Value = Value.undefined_value };

pub const Store = struct {
    allocator: std.mem.Allocator,
    default_object_prototype: Value = Value.undefined_value,
    arrays: std.ArrayList(*ArrayObject) = .empty,
    array_index: std.AutoHashMapUnmanaged(usize, *ArrayObject) = .empty,
    array_cache: PointerCache(ArrayObject) = .{},
    objects: std.ArrayList(*ObjectObject) = .empty,
    object_index: std.AutoHashMapUnmanaged(usize, *ObjectObject) = .empty,
    object_cache: PointerCache(ObjectObject) = .{},
    closures: std.ArrayList(*ClosureObject) = .empty,
    closure_index: std.AutoHashMapUnmanaged(usize, *ClosureObject) = .empty,
    bound_functions: std.ArrayList(*BoundFunctionObject) = .empty,
    bound_function_index: std.AutoHashMapUnmanaged(usize, *BoundFunctionObject) = .empty,
    collections: std.ArrayList(*CollectionObject) = .empty,
    collection_index: std.AutoHashMapUnmanaged(usize, *CollectionObject) = .empty,
    iterators: std.ArrayList(*IteratorObject) = .empty,
    iterator_index: std.AutoHashMapUnmanaged(usize, *IteratorObject) = .empty,
    external_task_promises: std.ArrayList(*ExternalTaskPromiseObject) = .empty,
    external_task_promise_index: std.AutoHashMapUnmanaged(usize, *ExternalTaskPromiseObject) = .empty,
    external_task_groups: std.ArrayList(*ExternalTaskGroupObject) = .empty,
    external_task_group_index: std.AutoHashMapUnmanaged(usize, *ExternalTaskGroupObject) = .empty,
    regexes: std.ArrayList(*RegexObject) = .empty,
    regex_index: std.AutoHashMapUnmanaged(usize, *RegexObject) = .empty,
    bigints: std.ArrayList(*BigIntObject) = .empty,
    bigint_index: std.AutoHashMapUnmanaged(usize, *BigIntObject) = .empty,
    strings: std.ArrayList(*StringObject) = .empty,
    string_index: std.AutoHashMapUnmanaged(usize, *StringObject) = .empty,
    string_cache: PointerCache(StringObject) = .{},
    cells: std.ArrayList(*Cell) = .empty,
    static_strings: []const StringEntry = &.{},

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store) void {
        for (self.arrays.items) |array| {
            array.items.deinit(self.allocator);
			if (array.byte_storage) |bytes| self.allocator.free(bytes);
            self.allocator.destroy(array);
        }
        self.arrays.deinit(self.allocator);
        self.array_index.deinit(self.allocator);
        for (self.objects.items) |object| {
            object.fields.deinit(self.allocator);
            self.allocator.destroy(object);
        }
        self.objects.deinit(self.allocator);
        self.object_index.deinit(self.allocator);
        for (self.closures.items) |closure| {
            self.allocator.free(closure.captures);
            closure.properties.deinit(self.allocator);
            self.allocator.destroy(closure);
        }
        self.closures.deinit(self.allocator);
        self.closure_index.deinit(self.allocator);
        for (self.bound_functions.items) |bound| {
            bound.arguments.deinit(self.allocator);
            self.allocator.destroy(bound);
        }
        self.bound_functions.deinit(self.allocator);
        self.bound_function_index.deinit(self.allocator);
        for (self.collections.items) |collection| {
            collection.entries.deinit(self.allocator);
            self.allocator.destroy(collection);
        }
        self.collections.deinit(self.allocator);
        self.collection_index.deinit(self.allocator);
        for (self.iterators.items) |iterator| {
            iterator.values.deinit(self.allocator);
            self.allocator.destroy(iterator);
        }
        self.iterators.deinit(self.allocator);
        self.iterator_index.deinit(self.allocator);
        for (self.external_task_groups.items) |group| {
            group.entries.deinit(self.allocator);
            self.allocator.destroy(group);
        }
        self.external_task_groups.deinit(self.allocator);
        self.external_task_group_index.deinit(self.allocator);
        for (self.external_task_promises.items) |promise| self.allocator.destroy(promise);
        self.external_task_promises.deinit(self.allocator);
        self.external_task_promise_index.deinit(self.allocator);
        for (self.regexes.items) |regex| {
            self.allocator.free(regex.pattern);
            self.allocator.destroy(regex);
        }
        self.regexes.deinit(self.allocator);
        self.regex_index.deinit(self.allocator);
        for (self.bigints.items) |bigint| {
            bigint.value.deinit();
            self.allocator.destroy(bigint);
        }
        self.bigints.deinit(self.allocator);
        self.bigint_index.deinit(self.allocator);
        for (self.strings.items) |string| {
            self.allocator.free(string.bytes);
            self.allocator.destroy(string);
        }
        self.strings.deinit(self.allocator);
        self.string_index.deinit(self.allocator);
        for (self.cells.items) |cell| self.allocator.destroy(cell);
        self.cells.deinit(self.allocator);
    }

    pub fn createArray(self: *Store, values: []const Value) !Value {
        const array = try self.allocator.create(ArrayObject);
        errdefer self.allocator.destroy(array);
        array.* = .{};
        array.init();
        errdefer array.items.deinit(self.allocator);
        try array.items.appendSlice(self.allocator, values);
        try self.arrays.append(self.allocator, array);
        try self.array_index.put(self.allocator, @intFromPtr(array), array);
        self.array_cache.put(array);
        return Value.fromPointer(array);
    }

    pub fn createArrayWithCapacity(self: *Store, capacity: usize) !Value {
        const array = try self.allocator.create(ArrayObject);
        errdefer self.allocator.destroy(array);
        array.* = .{};
        array.init();
        errdefer array.items.deinit(self.allocator);
        try array.items.ensureTotalCapacity(self.allocator, capacity);
        try self.arrays.append(self.allocator, array);
        self.array_index.put(self.allocator, @intFromPtr(array), array) catch |err| {
            _ = self.arrays.pop();
            return err;
        };
        self.array_cache.put(array);
        return Value.fromPointer(array);
    }

	pub fn createByteArray(self: *Store, length: usize) !Value {
		const array = try self.allocator.create(ArrayObject);
		errdefer self.allocator.destroy(array);
		array.* = .{};
		array.items.init();
		array.byte_storage = try self.allocator.alloc(u8, length);
		errdefer self.allocator.free(array.byte_storage.?);
		@memset(array.byte_storage.?, 0);
		try self.arrays.append(self.allocator, array);
		errdefer _ = self.arrays.pop();
		try self.array_index.put(self.allocator, @intFromPtr(array), array);
		self.array_cache.put(array);
		return Value.fromPointer(array);
	}

    pub fn createExternalTaskPromise(self: *Store, task_id: u64) !Value {
        const promise = try self.allocator.create(ExternalTaskPromiseObject);
        errdefer self.allocator.destroy(promise);
        promise.* = .{ .task_id = task_id };
        try self.external_task_promises.append(self.allocator, promise);
        errdefer _ = self.external_task_promises.pop();
        try self.external_task_promise_index.put(self.allocator, @intFromPtr(promise), promise);
        return Value.fromPointer(promise);
    }

    pub fn findExternalTaskPromise(self: *Store, value: Value) ?*ExternalTaskPromiseObject {
        const pointer = value.asPointer() orelse return null;
        return self.external_task_promise_index.get(@intFromPtr(pointer));
    }

    pub fn createExternalTaskGroup(self: *Store, entries: []const ExternalTaskEntry) !Value {
        const group = try self.allocator.create(ExternalTaskGroupObject);
        errdefer self.allocator.destroy(group);
        group.* = .{};
        errdefer group.entries.deinit(self.allocator);
        try group.entries.appendSlice(self.allocator, entries);
        try self.external_task_groups.append(self.allocator, group);
        errdefer _ = self.external_task_groups.pop();
        try self.external_task_group_index.put(self.allocator, @intFromPtr(group), group);
        return Value.fromPointer(group);
    }

    pub fn findExternalTaskGroup(self: *Store, value: Value) ?*ExternalTaskGroupObject {
        const pointer = value.asPointer() orelse return null;
        return self.external_task_group_index.get(@intFromPtr(pointer));
    }

    pub fn setArrayLength(self: *Store, value: Value, length: usize) !void {
        const array = self.findArray(value) orelse return error.InvalidArray;
        if (length < array.items.items.len) array.items.items = array.items.items[0..length];
        array.logical_length = length;
    }

    pub fn createObject(self: *Store) !Value {
        return self.createObjectWithCapacity(0);
    }

    pub fn createObjectWithCapacity(self: *Store, capacity: usize) !Value {
        const object = try self.allocator.create(ObjectObject);
        errdefer self.allocator.destroy(object);
        object.* = .{ .prototype = self.default_object_prototype };
        object.init();
        errdefer object.fields.deinit(self.allocator);
        try object.fields.ensureTotalCapacity(self.allocator, capacity);
        try self.objects.append(self.allocator, object);
        self.object_index.put(self.allocator, @intFromPtr(object), object) catch |err| {
            _ = self.objects.pop();
            return err;
        };
        self.object_cache.put(object);
        return Value.fromPointer(object);
    }

    pub fn createCell(self: *Store, value: Value) !*Cell {
        const cell = try self.allocator.create(Cell);
        cell.* = .{ .value = value };
        errdefer self.allocator.destroy(cell);
        try self.cells.append(self.allocator, cell);
        return cell;
    }

    pub fn createClosure(self: *Store, function: *anyopaque, captures: []*Cell) !Value {
        const closure = try self.allocator.create(ClosureObject);
        errdefer self.allocator.destroy(closure);
        const owned_captures = try self.allocator.dupe(*Cell, captures);
        errdefer self.allocator.free(owned_captures);
        closure.* = .{ .function = function, .captures = owned_captures };
        closure.properties.init();
        try self.closures.append(self.allocator, closure);
        self.closure_index.put(self.allocator, @intFromPtr(closure), closure) catch |err| {
            _ = self.closures.pop();
            return err;
        };
        return Value.fromPointer(closure);
    }

    pub fn ensureFunctionPrototype(self: *Store, value: Value) !Value {
        const closure = self.findClosure(value) orelse return error.NotCallable;
        if (!closure.prototype.isUndefined()) return closure.prototype;
        const prototype = try self.createObject();
        closure.prototype = prototype;
        try self.putProperty(prototype, "constructor", value);
        return prototype;
    }

    pub fn createBoundFunction(self: *Store, target: Value, this_value: Value, arguments: []const Value) !Value {
        const bound = try self.allocator.create(BoundFunctionObject);
        errdefer self.allocator.destroy(bound);
        bound.* = .{ .target = target, .this_value = this_value };
        errdefer bound.arguments.deinit(self.allocator);
        try bound.arguments.appendSlice(self.allocator, arguments);
        try self.bound_functions.append(self.allocator, bound);
        try self.bound_function_index.put(self.allocator, @intFromPtr(bound), bound);
        return Value.fromPointer(bound);
    }

    pub fn createString(self: *Store, bytes: []const u8) !Value {
        const owned_bytes = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned_bytes);
        return self.createStringOwned(owned_bytes);
    }

    pub fn createStringOwned(self: *Store, bytes: []u8) !Value {
        const string = try self.allocator.create(StringObject);
        errdefer self.allocator.destroy(string);
        string.* = .{ .bytes = bytes, .length = bytes.len };
        try self.strings.append(self.allocator, string);
        self.string_index.put(self.allocator, @intFromPtr(string), string) catch |err| {
            _ = self.strings.pop();
            return err;
        };
        return Value.fromPointer(string);
    }

    pub fn createConcat(self: *Store, left: *StringObject, right: *StringObject) !Value {
        const node = try self.allocator.create(StringObject);
        errdefer self.allocator.destroy(node);
        const length = try std.math.add(usize, left.length, right.length);
        node.* = .{
            .left = left,
            .right = right,
            .length = length,
            .flat = false,
        };
        try self.strings.append(self.allocator, node);
        self.string_index.put(self.allocator, @intFromPtr(node), node) catch |err| {
            _ = self.strings.pop();
            return err;
        };
        return Value.fromPointer(node);
    }

    fn flattenString(self: *Store, root: *StringObject) void {
        if (root.flat) return;
        var stack = std.ArrayList(*StringObject).empty;
        defer stack.deinit(self.allocator);
        var order = std.ArrayList(*StringObject).empty;
        defer order.deinit(self.allocator);
        stack.append(self.allocator, root) catch @panic("out of memory flattening string");
        while (stack.pop()) |object| {
            if (object.flat) continue;
            order.append(self.allocator, object) catch @panic("out of memory flattening string");
            stack.append(self.allocator, object.left.?) catch @panic("out of memory flattening string");
            stack.append(self.allocator, object.right.?) catch @panic("out of memory flattening string");
        }
        var index = order.items.len;
        while (index > 0) {
            index -= 1;
            const object = order.items[index];
            const left = object.left.?;
            const right = object.right.?;
            const bytes = self.allocator.alloc(u8, object.length) catch @panic("out of memory flattening string");
            @memcpy(bytes[0..left.length], left.bytes[0..left.length]);
            @memcpy(bytes[left.length..], right.bytes[0..right.length]);
            object.bytes = bytes;
            object.left = null;
            object.right = null;
            object.flat = true;
        }
    }

    pub fn stringLength(self: *Store, function: anytype, value: Value) ?usize {
        if (value.asStringCharacter()) |codepoint| {
            if (codepoint >= 128) return null;
            return 1;
        }
        for (function.string_values) |entry| {
            if (entry.value.raw() == value.raw()) return entry.bytes.len;
        }
        if (self.findString(value)) |bytes| return bytes.len;
        const pointer = value.asPointer() orelse return null;
        const object = self.string_index.get(@intFromPtr(pointer)) orelse return null;
        return object.length;
    }

    pub fn stringObject(self: *Store, function: anytype, value: Value) !?*StringObject {
        if (value.asStringCharacter() != null) return null;
        for (function.string_values) |entry| {
            if (entry.value.raw() == value.raw()) {
                const wrapped = try self.createString(entry.bytes);
                return @ptrCast(@alignCast(wrapped.asPointer().?));
            }
        }
        const pointer = value.asPointer() orelse return null;
        return self.string_index.get(@intFromPtr(pointer));
    }

    pub fn findArray(self: *Store, value: Value) ?*ArrayObject {
        const pointer = value.asPointer() orelse return null;
        if (self.array_cache.get(pointer)) |array| return array;
        const array = self.array_index.get(@intFromPtr(pointer)) orelse return null;
        self.array_cache.put(array);
        return array;
    }

    pub fn markBuffer(self: *Store, value: Value) !bool {
        const array = self.findArray(value) orelse return false;
        try array.markBuffer(self.allocator);
        return true;
    }

    pub fn findObject(self: *Store, value: Value) ?*ObjectObject {
        const pointer = value.asPointer() orelse return null;
        if (self.object_cache.get(pointer)) |object| return object;
        const object = self.object_index.get(@intFromPtr(pointer)) orelse return null;
        self.object_cache.put(object);
        return object;
    }

    pub fn findClosure(self: *Store, value: Value) ?*ClosureObject {
        const pointer = value.asPointer() orelse return null;
        return self.closure_index.get(@intFromPtr(pointer));
    }

    pub fn findBoundFunction(self: *Store, value: Value) ?*BoundFunctionObject {
        const pointer = value.asPointer() orelse return null;
        return self.bound_function_index.get(@intFromPtr(pointer));
    }

    pub fn createCollection(self: *Store, kind: CollectionKind) !Value {
        const collection = try self.allocator.create(CollectionObject);
        errdefer self.allocator.destroy(collection);
        collection.* = .{ .kind = kind };
        try self.collections.append(self.allocator, collection);
        try self.collection_index.put(self.allocator, @intFromPtr(collection), collection);
        return Value.fromPointer(collection);
    }

    pub fn findCollection(self: *Store, value: Value) ?*CollectionObject {
        const pointer = value.asPointer() orelse return null;
        return self.collection_index.get(@intFromPtr(pointer));
    }

    pub fn createIterator(self: *Store, values: []const Value) !Value {
        const iterator = try self.allocator.create(IteratorObject);
        errdefer self.allocator.destroy(iterator);
        iterator.* = .{};
        errdefer iterator.values.deinit(self.allocator);
        try iterator.values.appendSlice(self.allocator, values);
        try self.iterators.append(self.allocator, iterator);
        try self.iterator_index.put(self.allocator, @intFromPtr(iterator), iterator);
        return Value.fromPointer(iterator);
    }

    pub fn findIterator(self: *Store, value: Value) ?*IteratorObject {
        const pointer = value.asPointer() orelse return null;
        return self.iterator_index.get(@intFromPtr(pointer));
    }

    pub fn createRegex(self: *Store, pattern: []const u8, ignore_case: bool, global: bool) !Value {
        const regex = try self.allocator.create(RegexObject);
        errdefer self.allocator.destroy(regex);
        const owned_pattern = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(owned_pattern);
        regex.* = .{ .pattern = owned_pattern, .ignore_case = ignore_case, .global = global };
        try self.regexes.append(self.allocator, regex);
        try self.regex_index.put(self.allocator, @intFromPtr(regex), regex);
        return Value.fromPointer(regex);
    }

    pub fn findRegex(self: *Store, value: Value) ?*RegexObject {
        const pointer = value.asPointer() orelse return null;
        return self.regex_index.get(@intFromPtr(pointer));
    }

    pub fn findString(self: *Store, value: Value) ?[]const u8 {
        for (self.static_strings) |string| {
            if (string.value.raw() == value.raw()) return string.bytes;
        }
        const pointer = value.asPointer() orelse return null;
        if (self.string_cache.get(pointer)) |object| {
            self.flattenString(object);
            return object.bytes;
        }
        const object = self.string_index.get(@intFromPtr(pointer)) orelse return null;
        self.string_cache.put(object);
        self.flattenString(object);
        return object.bytes;
    }

    pub fn createBigInt(self: *Store) !Value {
        const object = try self.allocator.create(BigIntObject);
        errdefer self.allocator.destroy(object);
        object.value = try std.math.big.int.Managed.init(self.allocator);
        errdefer object.value.deinit();
        try self.bigints.append(self.allocator, object);
        errdefer _ = self.bigints.pop();
        try self.bigint_index.put(self.allocator, @intFromPtr(object), object);
        return Value.fromPointer(object);
    }

    pub fn createBigIntFromString(self: *Store, text: []const u8) !Value {
        const value = try self.createBigInt();
        const bigint = self.findBigInt(value).?;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidCharacter;

        var digits = trimmed;
        var base: u8 = 10;
        if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) {
            if (digits[0] == '+') {
                digits = digits[1..];
            } else if (digits.len > 1 and (std.mem.startsWith(u8, digits[1..], "0x") or std.mem.startsWith(u8, digits[1..], "0X") or std.mem.startsWith(u8, digits[1..], "0b") or std.mem.startsWith(u8, digits[1..], "0B") or std.mem.startsWith(u8, digits[1..], "0o") or std.mem.startsWith(u8, digits[1..], "0O"))) {
                return error.InvalidCharacter;
            }
        }
        if (std.mem.startsWith(u8, digits, "0x") or std.mem.startsWith(u8, digits, "0X")) {
            base = 16;
            digits = digits[2..];
        } else if (std.mem.startsWith(u8, digits, "0b") or std.mem.startsWith(u8, digits, "0B")) {
            base = 2;
            digits = digits[2..];
        } else if (std.mem.startsWith(u8, digits, "0o") or std.mem.startsWith(u8, digits, "0O")) {
            base = 8;
            digits = digits[2..];
        }
        try bigint.value.setString(base, digits);
        return value;
    }

    pub fn createBigIntFromInt(self: *Store, number: i64) !Value {
        const value = try self.createBigInt();
        try self.findBigInt(value).?.value.set(number);
        return value;
    }

    pub fn findBigInt(self: *Store, value: Value) ?*BigIntObject {
        const pointer = value.asPointer() orelse return null;
        return self.bigint_index.get(@intFromPtr(pointer));
    }

    pub fn getProperty(self: *Store, value: Value, name: []const u8) ?Value {
        if (self.findClosure(value)) |closure| {
            if (std.mem.eql(u8, name, "prototype")) return closure.prototype;
            for (closure.properties.items) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.value;
            }
            return Value.undefined_value;
        }
        var current = value;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const object = self.findObject(current) orelse return null;
            for (object.fields.items) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.value;
            }
            if (std.mem.eql(u8, name, "__proto__")) return object.prototype;
            if (object.prototype.isUndefined() or object.prototype.isNull()) break;
            current = object.prototype;
        }
        return Value.undefined_value;
    }

    pub fn getOwnProperty(self: *Store, value: Value, name: []const u8) ?Value {
        if (self.findClosure(value)) |closure| {
            if (std.mem.eql(u8, name, "prototype")) return closure.prototype;
            for (closure.properties.items) |field| {
                if (std.mem.eql(u8, field.name, name)) return field.value;
            }
            return null;
        }
        const object = self.findObject(value) orelse return null;
        for (object.fields.items) |field| {
            if (std.mem.eql(u8, field.name, name)) return field.value;
        }
        if (std.mem.eql(u8, name, "__proto__")) return object.prototype;
        return null;
    }

    pub fn hasProperty(self: *Store, value: Value, name: []const u8) bool {
        if (self.findClosure(value)) |closure| {
            if (std.mem.eql(u8, name, "prototype") and !closure.prototype.isUndefined()) return true;
            for (closure.properties.items) |field| {
                if (std.mem.eql(u8, field.name, name)) return true;
            }
            return false;
        }
        var current = value;
        var depth: usize = 0;
        while (depth < 32) : (depth += 1) {
            const object = self.findObject(current) orelse return false;
            for (object.fields.items) |field| {
                if (std.mem.eql(u8, field.name, name)) return true;
            }
            if (object.prototype.isUndefined() or object.prototype.isNull()) return false;
            current = object.prototype;
        }
        return false;
    }

    pub fn putProperty(self: *Store, value: Value, name: []const u8, property_value: Value) !void {
        if (self.findClosure(value)) |closure| {
            if (std.mem.eql(u8, name, "prototype")) {
                closure.prototype = property_value;
                return;
            }
            for (closure.properties.items) |*field| {
                if (std.mem.eql(u8, field.name, name)) {
                    field.value = property_value;
                    return;
                }
            }
            try closure.properties.append(self.allocator, .{ .name = name, .value = property_value });
            return;
        }
        const object = self.findObject(value) orelse return error.InvalidObject;
        if (std.mem.eql(u8, name, "__proto__")) {
            if (!property_value.isNull() and self.findObject(property_value) == null) return error.InvalidPrototype;
            object.prototype = property_value;
            return;
        }
        for (object.fields.items) |*field| {
            if (std.mem.eql(u8, field.name, name)) {
                field.value = property_value;
                return;
            }
        }
        try object.fields.append(self.allocator, .{ .name = name, .value = property_value });
    }
};

test "runtime object store owns and validates array values" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const initial = [_]Value{ Value.fromInt(3).?, Value.fromInt(5).? };
    const value = try store.createArray(&initial);
    const array = store.findArray(value).?;
    try std.testing.expectEqual(@as(usize, 2), array.items.items.len);
    try std.testing.expectEqual(@as(?i32, 5), array.items.items[1].asInt());
    try std.testing.expect(store.findArray(Value.fromPointer(@ptrFromInt(8))) == null);
}

test "new arrays keep virtual length without allocating undefined elements" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    const value = try store.createArrayWithCapacity(0);
    try store.setArrayLength(value, 1024);
    const array = store.findArray(value).?;
    try std.testing.expectEqual(@as(usize, 1024), array.len());
    try std.testing.expectEqual(@as(usize, 0), array.items.items.len);
    try std.testing.expect(array.get(0).isUndefined());
    try std.testing.expect(array.get(1023).isUndefined());

    try array.set(store.allocator, 1023, Value.fromInt(7).?);
    try std.testing.expectEqual(@as(usize, 1024), array.len());
    try std.testing.expectEqual(@as(?i32, 7), array.get(1023).asInt());
    try std.testing.expect(array.get(1000).isUndefined());
}

test "runtime object store frees byte array storage at store teardown" {
    var store = Store.init(std.testing.allocator);
    defer store.deinit();

    for (0..512) |index| {
        const value = try store.createByteArray(1024);
        const array = store.findArray(value).?;
        try std.testing.expectEqual(@as(usize, 1024), array.len());
        array.byte_storage.?[0] = @truncate(index);
        array.byte_storage.?[1023] = @truncate(index + 1);
    }
}

test "runtime object store updates properties by string content" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();
    const value = try store.createObject();
    try store.putProperty(value, "name", Value.fromInt(12).?);
    try store.putProperty(value, "name", Value.fromInt(13).?);
    try std.testing.expectEqual(@as(?i32, 13), store.getProperty(value, "name").?.asInt());
}

test "runtime heap indices preserve array, object, and string lookup through growth" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    var arrays: [256]Value = undefined;
    var objects: [256]Value = undefined;
    var strings: [256]Value = undefined;
    for (0..arrays.len) |index| {
        const number = Value.fromInt(@intCast(index)).?;
        arrays[index] = try store.createArray(&.{number});
        objects[index] = try store.createObject();
        try store.putProperty(objects[index], "index", number);
        strings[index] = try store.createString("heap-index-test");
    }

    for (0..arrays.len) |index| {
        try std.testing.expectEqual(@as(?i32, @intCast(index)), store.findArray(arrays[index]).?.items.items[0].asInt());
        try std.testing.expectEqual(@as(?i32, @intCast(index)), store.getProperty(objects[index], "index").?.asInt());
        try std.testing.expectEqualStrings("heap-index-test", store.findString(strings[index]).?);
    }
    try std.testing.expect(store.findArray(objects[0]) == null);
    try std.testing.expect(store.findObject(arrays[0]) == null);
}

test "closure index preserves identity through growth" {
    const allocator = std.testing.allocator;
    var store = Store.init(allocator);
    defer store.deinit();

    var closures: [256]Value = undefined;
    for (&closures) |*value| value.* = try store.createClosure(@ptrFromInt(8), &.{});

    for (closures, 0..) |value, index| {
        const closure = store.findClosure(value).?;
        try std.testing.expectEqual(@as(usize, 8), @intFromPtr(closure.function));
        try std.testing.expectEqual(@intFromPtr(closure), @intFromPtr(store.closures.items[index]));
    }
    try std.testing.expect(store.findClosure(Value.fromPointer(@ptrFromInt(8))) == null);
}
