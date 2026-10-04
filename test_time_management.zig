const std = @import("std");
const Engine = @import("src/engine.zig").Engine;
const EngineConfig = @import("src/engine.zig").EngineConfig;
const GoParams = @import("src/engine.zig").GoParams;
const GameState = @import("src/gamestate.zig").GameState;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n=== Time Management Test Suite ===\n\n", .{});
    
    var engine = try Engine.init(allocator, EngineConfig{ 
        .hash_size_mb = 64, 
        .use_nnue = false 
    });
    defer engine.deinit();
    
    var state = GameState.init();
    try state.loadStart();
    
    // Test scenarios
    const scenarios = [_]struct {
        name: []const u8,
        params: GoParams,
        expected_min_depth: i32,
    }{
        .{
            .name = "1 second sudden death",
            .params = .{ .wtime = 1000, .btime = 1000 },
            .expected_min_depth = 6,
        },
        .{
            .name = "5 seconds sudden death",
            .params = .{ .wtime = 5000, .btime = 5000 },
            .expected_min_depth = 9,
        },
        .{
            .name = "10 seconds sudden death",
            .params = .{ .wtime = 10000, .btime = 10000 },
            .expected_min_depth = 11,
        },
        .{
            .name = "1 minute sudden death",
            .params = .{ .wtime = 60000, .btime = 60000 },
            .expected_min_depth = 14,
        },
        .{
            .name = "1+1 increment (blitz)",
            .params = .{ .wtime = 60000, .btime = 60000, .winc = 1000, .binc = 1000 },
            .expected_min_depth = 16,
        },
        .{
            .name = "5+3 increment (rapid)",
            .params = .{ .wtime = 300000, .btime = 300000, .winc = 3000, .binc = 3000 },
            .expected_min_depth = 18,
        },
        .{
            .name = "40 moves in 5 minutes",
            .params = .{ .wtime = 300000, .btime = 300000, .movestogo = 40 },
            .expected_min_depth = 12,
        },
        .{
            .name = "500ms movetime",
            .params = .{ .movetime = 500 },
            .expected_min_depth = 8,
        },
    };
    
    var passed: usize = 0;
    var failed: usize = 0;
    
    for (scenarios) |scenario| {
        std.debug.print("Test: {s}\n", .{scenario.name});
        
        // Just show what time would be allocated
        std.debug.print("  Time params: wtime={?d} winc={?d} movestogo={?d} movetime={?d}\n", 
            .{scenario.params.wtime, scenario.params.winc, scenario.params.movestogo, scenario.params.movetime});
        
        // Run search
        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();
        
        const start = std.time.milliTimestamp();
        try engine.go(state, scenario.params, output.writer());
        const elapsed = std.time.milliTimestamp() - start;
        
        // Parse output to get depth (look for last completed depth)
        const output_str = output.items;
        var depth: i32 = 0;
        
        // Find last "depth X" line (from our debug output)
        var lines = std.mem.splitScalar(u8, output_str, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "depth ")) |idx| {
                // Extract number after "depth "
                var tokens = std.mem.tokenizeScalar(u8, line[idx..], ' ');
                _ = tokens.next(); // skip "depth"
                if (tokens.next()) |depth_str| {
                    depth = std.fmt.parseInt(i32, depth_str, 10) catch depth;
                }
            }
        }
        
        std.debug.print("  Result: depth={d}, time={d}ms", .{depth, elapsed});
        
        // Check depth expectation
        const depth_ok = depth >= scenario.expected_min_depth;
        
        // For now, just check depth (time management is simpler in v2)
        if (depth_ok) {
            std.debug.print(" ✓ PASS\n", .{});
            passed += 1;
        } else {
            std.debug.print(" ✗ FAIL (expected depth >= {d})", .{scenario.expected_min_depth});
            std.debug.print("\n", .{});
            failed += 1;
        }
        
        std.debug.print("\n", .{});
        
        // Reset engine between tests
        engine.clearHash();
    }
    
    std.debug.print("=== Results: {d} passed, {d} failed ===\n\n", .{passed, failed});
    
    if (failed > 0) {
        std.process.exit(1);
    }
}
