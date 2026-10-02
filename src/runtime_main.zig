const std = @import("std");
const artifact = @import("artifact.zig");
const execution = @import("execution.zig");

pub fn main(init: std.process.Init) !void {
	var args = std.process.Args.Iterator.init(init.minimal.args);
	_ = args.next() orelse return error.MissingExecutableName;
	const artifact_path = args.next() orelse return error.MissingArtifactPath;
	var host_json: []const u8 = "";
	if (args.next()) |option| {
		if (!std.mem.eql(u8, option, "--host-json")) return error.UnexpectedArgument;
		const host_path = args.next() orelse return error.MissingHostJsonPath;
		host_json = try std.Io.Dir.cwd().readFileAlloc(init.io, host_path, init.arena.allocator(), .limited(1024 * 1024));
	}
	if (args.next() != null) return error.UnexpectedArgument;

	const allocator = init.arena.allocator();
	const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, artifact_path, allocator, .limited(64 * 1024 * 1024));
	const function = try artifact.load(allocator, bytes);
	var stdout_buffer: [256]u8 = undefined;
	var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
	var stderr_buffer: [256]u8 = undefined;
	var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
	const uncaught = try execution.execute(allocator, function, &stdout.interface, &stderr.interface, host_json);
	try stdout.interface.flush();
	try stderr.interface.flush();
	if (uncaught) std.process.exit(1);
}
