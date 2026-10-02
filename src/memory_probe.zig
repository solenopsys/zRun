const std = @import("std");
const compiler = @import("compiler.zig");
const VM = @import("vm.zig").VM;
const Value = @import("value.zig").Value;
const ObjectStore = @import("vm/objects.zig").Store;

const context_count = 100;
const source_size = 10 * 1024;

const Context = struct {
    source: []u8,
    program: compiler.Program,
    objects: ObjectStore,
    vm: VM,
    result: Value,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const baseline_kb = try currentRssKb(init.io);
    const contexts = try allocator.alloc(Context, context_count);
    var retained_bytecode: usize = 0;

    for (contexts) |*context| {
        const source = try makeSource(allocator);
        const program = try compiler.compile(allocator, source);
        var objects = ObjectStore.init(allocator);
        const vm = VM{ .allocator = allocator, .objects = &objects };
        const result = try vm.execute(program.bytecode());

        context.* = .{
            .source = source,
            .program = program,
            .objects = objects,
            .vm = vm,
            .result = result,
        };
        retained_bytecode += program.code.len;
    }

    std.mem.doNotOptimizeAway(contexts);
    const after_kb = try currentRssKb(init.io);
    const delta_kb = after_kb -| baseline_kb;

    std.debug.print(
        "contexts: {d}\nsource per context: {d} bytes\nretained bytecode total: {d} bytes\nRSS before: {d} KiB\nRSS after: {d} KiB\nRSS delta: {d} KiB\nRSS delta per context: {d}.{d} KiB\n",
        .{
            context_count,
            source_size,
            retained_bytecode,
            baseline_kb,
            after_kb,
            delta_kb,
            delta_kb / context_count,
            (delta_kb % context_count) * 10 / context_count,
        },
    );
}

fn makeSource(allocator: std.mem.Allocator) ![]u8 {
    const prefix = "var payload = \"";
    const suffix = "\";";
    const source = try allocator.alloc(u8, source_size);
    @memcpy(source[0..prefix.len], prefix);
    @memset(source[prefix.len .. source_size - suffix.len], 'x');
    @memcpy(source[source_size - suffix.len ..], suffix);
    return source;
}

fn currentRssKb(io: std.Io) !usize {
    var file = try std.Io.Dir.openFileAbsolute(io, "/proc/self/status", .{});
    defer file.close(io);
    var buffer: [2048]u8 = undefined;
    var reader = file.reader(io, &buffer);
    const length = try reader.interface.readSliceShort(&buffer);
    const status = buffer[0..length];

    const start = std.mem.indexOf(u8, status, "VmRSS:") orelse return error.MissingVmRss;
    var fields = std.mem.tokenizeAny(u8, status[start..], " \t\r\n");
    _ = fields.next();
    const value = fields.next() orelse return error.MissingVmRssValue;
    return try std.fmt.parseInt(usize, value, 10);
}
