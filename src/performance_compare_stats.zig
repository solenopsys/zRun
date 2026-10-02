const compare = @import("performance_compare.zig");

pub fn main(init: @import("std").process.Init) !void {
    try compare.runStats(init);
}
