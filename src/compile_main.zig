const std = @import("std");
const compiler = @import("compiler.zig");
const artifact = @import("artifact.zig");

pub fn main(init: std.process.Init) !void {
	var args = std.process.Args.Iterator.init(init.minimal.args);
	_ = args.next() orelse return error.MissingExecutableName;
	const source_path = args.next() orelse return error.MissingSourcePath;
	if (args.next() != null) return error.UnexpectedArgument;

	const allocator = init.arena.allocator();
	const source = try std.Io.Dir.cwd().readFileAlloc(init.io, source_path, allocator, .limited(64 * 1024 * 1024));
	var program = try compiler.compile(allocator, source);
	defer program.deinit(allocator);
	const unit = try artifact.unitFromProgram(allocator, program);
	const bytes = try artifact.encode(allocator, unit);

	var stdout_buffer: [4096]u8 = undefined;
	var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
	try stdout.interface.writeAll(bytes);
	try stdout.interface.flush();
}
