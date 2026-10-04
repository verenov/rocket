const std = @import("std");
const uci = @import("uci.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var engine = try uci.UciEngine.init(allocator);
    defer engine.deinit();
    try engine.run();
}
