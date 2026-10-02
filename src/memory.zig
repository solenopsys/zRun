// Heap allocator for the zRun runtime.
// Copyright (c) 2017-2025 Fabrice Bellard
// Copyright (c) 2017-2025 Charlie Gordon
// SPDX-License-Identifier: MIT

const std = @import("std");
const Word = @import("value.zig").Word;
const HeaderPayload = if (@bitSizeOf(Word) == 64) u60 else u28;

pub const MemoryTag = enum(u3) {
    free = 0,
    object = 1,
    float64 = 2,
    string = 3,
    function_bytecode = 4,
    value_array = 5,
    byte_array = 6,
    var_ref = 7,
};

pub const BlockHeader = packed struct(Word) {
    gc_mark: u1,
    mtag: MemoryTag,
    reserved: HeaderPayload,
};

pub const FreeBlockHeader = packed struct(Word) {
    gc_mark: u1,
    mtag: MemoryTag,
    size_words: HeaderPayload,
};

pub const Heap = struct {
    memory: []align(@alignOf(Word)) u8,
    heap_base: usize,
    heap_free: usize,
    stack_bottom: usize,
    min_free_size: usize = 512,
    collector: ?Collector = null,

    pub const Collector = struct {
        context: *anyopaque,
        collect_fn: *const fn (*anyopaque) void,

        fn collect(self: Collector) void {
            self.collect_fn(self.context);
        }
    };

    pub const Error = error{
        InvalidMemoryRegion,
        InvalidBlockSize,
        BlockTooLarge,
        OutOfMemory,
    };

    pub fn init(memory: []align(@alignOf(Word)) u8, heap_base: usize) Error!Heap {
        if (heap_base > memory.len or heap_base % @alignOf(Word) != 0) return error.InvalidMemoryRegion;
        return .{
            .memory = memory,
            .heap_base = heap_base,
            .heap_free = heap_base,
            .stack_bottom = memory.len,
        };
    }

    pub fn allocate(self: *Heap, requested_size: usize, tag: MemoryTag) Error!?[]u8 {
        if (requested_size == 0) return null;
        const size = try alignSize(requested_size);
        try self.checkFreeMemory(size);
        if (size > self.memory.len - self.heap_free) return error.OutOfMemory;

        const start = self.heap_free;
        self.heap_free += size;
        self.writeHeader(start, tag);
        return self.memory[start .. start + size];
    }

    pub fn allocateZeroed(self: *Heap, requested_size: usize, tag: MemoryTag) Error!?[]u8 {
        const block = try self.allocate(requested_size, tag) orelse return null;
        if (requested_size > @sizeOf(u32)) {
            @memset(block[@sizeOf(u32)..requested_size], 0);
        }
        return block;
    }

    pub fn checkFreeMemory(self: *Heap, needed: usize) Error!void {
        if (self.available() >= needed + self.min_free_size) return;
        if (self.collector) |collector| collector.collect();
        if (self.available() < needed + self.min_free_size) return error.OutOfMemory;
    }

    pub fn stackCheck(self: *Heap, stack_pointer: usize, value_count: usize, slack: usize) Error!usize {
        const count = std.math.add(usize, value_count, slack) catch return error.BlockTooLarge;
        const stack_bytes = std.math.mul(usize, count, @sizeOf(Word)) catch return error.BlockTooLarge;
        if (stack_pointer < stack_bytes) return error.OutOfMemory;
        const new_bottom = stack_pointer - stack_bytes;
        try self.checkFreeMemory(stack_bytes);
        self.stack_bottom = new_bottom;
        return new_bottom;
    }

    pub fn freeTail(self: *Heap, block_offset: usize, block_size: usize) Error!void {
        if (block_offset < self.heap_base or block_offset > self.heap_free) return error.InvalidMemoryRegion;
        const end = std.math.add(usize, block_offset, block_size) catch return error.BlockTooLarge;
        if (end == self.heap_free) self.heap_free = block_offset;
    }

    pub fn shrink(self: *Heap, block_offset: usize, old_size: usize, requested_new_size: usize) Error!usize {
        const new_size = try alignSize(requested_new_size);
        if (new_size == 0) {
            try self.freeTail(block_offset, old_size);
            return 0;
        }
        if (new_size > old_size or block_offset + old_size > self.heap_free) return error.InvalidBlockSize;
        const difference = old_size - new_size;
        if (difference == 0) return new_size;
        try self.setFreeBlock(block_offset + new_size, difference);
        return new_size;
    }

    pub fn setFreeBlock(self: *Heap, block_offset: usize, block_size: usize) Error!void {
        if (block_size < @sizeOf(Word) or block_size % @sizeOf(Word) != 0) return error.InvalidBlockSize;
        if (block_offset + block_size > self.memory.len) return error.InvalidMemoryRegion;
        const payload_words = (block_size - @sizeOf(Word)) / @sizeOf(Word);
        const max_words = std.math.maxInt(@TypeOf(@as(FreeBlockHeader, undefined).size_words));
        if (payload_words > max_words) return error.BlockTooLarge;
        const header: FreeBlockHeader = .{ .gc_mark = 0, .mtag = .free, .size_words = @intCast(payload_words) };
        self.writeWord(block_offset, @bitCast(header));
    }

    pub fn headerAt(self: *const Heap, block_offset: usize) Error!BlockHeader {
        if (block_offset < self.heap_base or block_offset + @sizeOf(Word) > self.heap_free) return error.InvalidMemoryRegion;
        return @bitCast(self.readWord(block_offset));
    }

    pub fn available(self: *const Heap) usize {
        return self.stack_bottom - self.heap_free;
    }

    fn writeHeader(self: *Heap, block_offset: usize, tag: MemoryTag) void {
        const header: BlockHeader = .{ .gc_mark = 0, .mtag = tag, .reserved = 0 };
        self.writeWord(block_offset, @bitCast(header));
    }

    fn writeWord(self: *Heap, offset: usize, value: Word) void {
        const ptr: *align(1) Word = @ptrCast(&self.memory[offset]);
        ptr.* = value;
    }

    fn readWord(self: *const Heap, offset: usize) Word {
        const ptr: *align(1) const Word = @ptrCast(&self.memory[offset]);
        return ptr.*;
    }
};

fn alignSize(size: usize) Heap.Error!usize {
    const mask = @sizeOf(Word) - 1;
    const aligned = std.math.add(usize, size, mask) catch return error.BlockTooLarge;
    return aligned & ~@as(usize, mask);
}

test "heap block headers retain tag bits and word alignment" {
    var storage: [256]u8 align(@alignOf(Word)) = undefined;
    var heap = try Heap.init(&storage, @sizeOf(Word));
    heap.min_free_size = 0;

    const block = (try heap.allocate(13, .string)).?;
    try std.testing.expectEqual(@as(usize, 16), block.len);
    try std.testing.expectEqual(MemoryTag.string, (try heap.headerAt(@sizeOf(Word))).mtag);
    try std.testing.expectEqual(@as(u1, 0), (try heap.headerAt(@sizeOf(Word))).gc_mark);
}

test "zeroed allocation preserves the header and clears its payload" {
    var storage: [256]u8 align(@alignOf(Word)) = undefined;
    var heap = try Heap.init(&storage, @sizeOf(Word));
    heap.min_free_size = 0;

    const block = (try heap.allocateZeroed(32, .object)).?;
    try std.testing.expectEqual(MemoryTag.object, (try heap.headerAt(@sizeOf(Word))).mtag);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, block[@sizeOf(BlockHeader)..][0..8]);
}

test "shrink writes a free-block header in the released tail" {
    var storage: [256]u8 align(@alignOf(Word)) = undefined;
    var heap = try Heap.init(&storage, @sizeOf(Word));
    heap.min_free_size = 0;
    _ = try heap.allocate(64, .byte_array);

    try std.testing.expectEqual(@as(usize, 32), try heap.shrink(@sizeOf(Word), 64, 32));
    const free_header: FreeBlockHeader = @bitCast(heap.readWord(@sizeOf(Word) + 32));
    try std.testing.expectEqual(MemoryTag.free, free_header.mtag);
    try std.testing.expectEqual(@as(usize, 3), free_header.size_words);
}

test "allocation retries through the collector before failing" {
    var storage: [128]u8 align(@alignOf(Word)) = undefined;
    var heap = try Heap.init(&storage, @sizeOf(Word));
    heap.min_free_size = 32;
    var state = CollectorState{ .heap = &heap };
    heap.collector = .{ .context = &state, .collect_fn = CollectorState.collect };

    _ = try heap.allocate(40, .byte_array);
    _ = try heap.allocate(72, .byte_array);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
}

const CollectorState = struct {
    heap: *Heap,
    calls: usize = 0,

    fn collect(raw: *anyopaque) void {
        const self: *CollectorState = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.heap.heap_free = self.heap.heap_base;
    }
};
