const std = @import("std");

pub const max_bytecode_size = 16 * 1024 * 1024;
pub const max_worker_count = 64;

pub const WorkerUrls = struct {
    allocator: std.mem.Allocator,
    items: [][]const u8,

    pub fn deinit(self: *WorkerUrls) void {
        for (self.items) |url| self.allocator.free(url);
        self.allocator.free(self.items);
    }
};

pub fn fetchBytecode(allocator: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &response_body.writer,
    });
    if (response.status != .ok) return error.BytecodeEndpointFailed;

    const bytes = response_body.written();
    if (bytes.len == 0) return error.EmptyBytecodeResponse;
    if (bytes.len > max_bytecode_size) return error.BytecodeResponseTooLarge;
    return allocator.dupe(u8, bytes);
}

pub fn parseWorkerUrls(allocator: std.mem.Allocator, encoded: []const u8) !WorkerUrls {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), encoded, .{
        .allocate = .alloc_always,
    });
    const entries = switch (parsed) {
        .array => |array| array.items,
        else => return error.InvalidWorkerConfiguration,
    };
    if (entries.len == 0 or entries.len > max_worker_count) return error.InvalidWorkerCount;

    var urls: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (urls.items) |url| allocator.free(url);
        urls.deinit(allocator);
    }
    try urls.ensureTotalCapacity(allocator, entries.len);
    for (entries) |entry| {
        const url = switch (entry) {
            .string => |value| value,
            else => return error.InvalidWorkerAddress,
        };
        if (url.len == 0) return error.InvalidWorkerAddress;
        urls.appendAssumeCapacity(try allocator.dupe(u8, url));
    }
    return .{ .allocator = allocator, .items = try urls.toOwnedSlice(allocator) };
}

pub fn spawnWorkers(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_environment: *const std.process.Environ.Map,
    executable: []const u8,
    urls: []const []const u8,
) !void {
    var children: std.ArrayList(std.process.Child) = .empty;
    defer {
        for (children.items) |*child| {
            if (child.id != null) child.kill(io);
        }
        children.deinit(allocator);
    }
    try children.ensureTotalCapacity(allocator, urls.len);

    for (urls) |url| {
        var environment = try parent_environment.clone(allocator);
        defer environment.deinit();
        try environment.put("ZRUN_BYTECODE_URL", url);

        const child = try std.process.spawn(io, .{
            .argv = &.{ executable, "--bytecode-env" },
            .environ_map = &environment,
        });
        children.appendAssumeCapacity(child);
    }

    var failed = false;
    for (children.items) |*child| {
        switch (try child.wait(io)) {
            .exited => |code| if (code != 0) {
                failed = true;
            },
            else => failed = true,
        }
    }
    if (failed) return error.WorkerFailed;
}

test "worker address environment is a bounded JSON string array" {
    var urls = try parseWorkerUrls(std.testing.allocator, "[\"http://one/a.bin\",\"http://two/b.bin\"]");
    defer urls.deinit();
    try std.testing.expectEqual(@as(usize, 2), urls.items.len);
    try std.testing.expectEqualStrings("http://one/a.bin", urls.items[0]);
    try std.testing.expectEqualStrings("http://two/b.bin", urls.items[1]);
}

test "worker address environment rejects malformed and empty configurations" {
    try std.testing.expectError(error.InvalidWorkerCount, parseWorkerUrls(std.testing.allocator, "[]"));
    try std.testing.expectError(error.InvalidWorkerConfiguration, parseWorkerUrls(std.testing.allocator, "{}"));
    try std.testing.expectError(error.InvalidWorkerAddress, parseWorkerUrls(std.testing.allocator, "[42]"));
    try std.testing.expectError(error.InvalidWorkerAddress, parseWorkerUrls(std.testing.allocator, "[\"\"]"));
}
