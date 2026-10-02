pub const value = @import("value.zig");
pub const opcode = @import("opcode.zig");
pub const memory = @import("memory.zig");
pub const bytecode = @import("bytecode.zig");
pub const artifact = @import("artifact.zig");
pub const module_registry = @import("module_registry.zig");
pub const execution = @import("execution.zig");
pub const vm = @import("vm.zig");
pub const stack = @import("vm/stack.zig");
pub const compiler = @import("compiler.zig");
pub const worker_runtime = @import("worker_runtime.zig");

test {
    _ = value.Value;
    _ = opcode.Opcode;
    _ = memory.Heap;
    _ = bytecode.Image;
    _ = artifact.Unit;
    _ = module_registry.ModuleRegistry;
    _ = execution;
    _ = vm.VM;
    _ = stack.Stack;
    _ = compiler.Program;
    _ = worker_runtime;
}
