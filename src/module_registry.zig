const std = @import("std");
const artifact = @import("artifact.zig");
const FunctionBytecode = @import("vm.zig").FunctionBytecode;

/// Owns decoded bytecode modules until the host explicitly removes them.
/// Module names are host-defined keys, such as "users" or "billing".
pub const ModuleRegistry = struct {
	allocator: std.mem.Allocator,
	modules: std.StringHashMapUnmanaged(artifact.LoadedModule) = .empty,

	pub fn init(allocator: std.mem.Allocator) ModuleRegistry {
		return .{ .allocator = allocator };
	}

	pub fn deinit(self: *ModuleRegistry) void {
		var iterator = self.modules.iterator();
		while (iterator.next()) |entry| {
			self.allocator.free(entry.key_ptr.*);
			entry.value_ptr.deinit();
		}
		self.modules.deinit(self.allocator);
		self.* = undefined;
	}

	/// Decodes an artifact once and keeps its owned bytes and functions resident.
	/// Loading an existing name fails; remove it first to replace its bytecode.
	pub fn load(self: *ModuleRegistry, name: []const u8, bytes: []const u8) !void {
		if (name.len == 0) return error.EmptyModuleName;
		if (self.modules.contains(name)) return error.ModuleAlreadyLoaded;

		const owned_name = try self.allocator.dupe(u8, name);
		errdefer self.allocator.free(owned_name);
		var module = try artifact.LoadedModule.init(self.allocator, bytes);
		errdefer module.deinit();
		try self.modules.put(self.allocator, owned_name, module);
	}

	/// Drops a module's retained bytecode and decoded functions immediately.
	/// Call only after no active execution still refers to this module.
	pub fn remove(self: *ModuleRegistry, name: []const u8) bool {
		const removed = self.modules.fetchRemove(name) orelse return false;
		self.allocator.free(removed.key);
		var module = removed.value;
		module.deinit();
		return true;
	}

	pub fn contains(self: *const ModuleRegistry, name: []const u8) bool {
		return self.modules.contains(name);
	}

	pub fn getModule(self: *ModuleRegistry, name: []const u8) ?*artifact.LoadedModule {
		return self.modules.getPtr(name);
	}

	/// Resolves `module_name.function_name` while keeping names as separate keys.
	pub fn findFunction(
		self: *ModuleRegistry,
		module_name: []const u8,
		function_name: []const u8,
	) error{ ModuleNotLoaded, FunctionNotFound }!*const FunctionBytecode {
		const module = self.getModule(module_name) orelse return error.ModuleNotLoaded;
		return module.findFunction(function_name) orelse error.FunctionNotFound;
	}
};
