const std = @import("std");
const Engine = @import("engine.zig").Engine;
const EngineConfig = @import("engine.zig").EngineConfig;
const GoParams = @import("engine.zig").GoParams;
const GameState = @import("gamestate.zig").GameState;
const testing = std.testing;

test "engine basic initialization" {
    const allocator = testing.allocator;

    var engine = try Engine.init(allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();

    try testing.expect(true);
}

test "time calculation is reasonable" {
    const allocator = testing.allocator;

    var engine = try Engine.init(allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();

    var state = GameState.init();
    try state.loadStart();

    const params1 = GoParams{ .wtime = 5000, .btime = 5000 };
    const time_limits1 = engine.calculateTimeLimits(state, params1);

    if (time_limits1) |limits| {
        std.debug.print("\nTime limits for 5000ms: optimum={d}ms, maximum={d}ms\n", .{ limits.optimum, limits.maximum });

        try testing.expect(limits.optimum > 10);
        try testing.expect(limits.optimum < 2000);
        try testing.expect(limits.maximum > limits.optimum);
        try testing.expect(limits.maximum < 5000);
    } else {
        try testing.expect(false);
    }

    const params2 = GoParams{ .wtime = 10000, .btime = 10000, .winc = 100, .binc = 100 };
    const time_limits2 = engine.calculateTimeLimits(state, params2);

    if (time_limits2) |limits| {
        std.debug.print("Time limits for 10000ms + 100ms inc: optimum={d}ms, maximum={d}ms\n", .{ limits.optimum, limits.maximum });

        try testing.expect(limits.optimum > time_limits1.?.optimum);
    } else {
        try testing.expect(false);
    }

    const params3 = GoParams{ .wtime = 50, .btime = 50 };
    const time_limits3 = engine.calculateTimeLimits(state, params3);

    if (time_limits3) |limits| {
        std.debug.print("Time limits for 50ms: optimum={d}ms, maximum={d}ms\n", .{ limits.optimum, limits.maximum });

        try testing.expect(limits.optimum >= 1);
        try testing.expect(limits.maximum < 50);
    } else {
        try testing.expect(false);
    }
}

test "increment time manager stays bounded as the clock changes" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();
    var state = GameState.init();
    try state.loadStart();

    const first = engine.calculateAdaptiveTime(state, .{ .wtime = 10000, .winc = 500 });
    const stable = engine.calculateAdaptiveTime(state, .{ .wtime = 10020, .winc = 500 });
    try testing.expect(stable > first);
    try testing.expect(first < 1000);

    const falling = engine.calculateAdaptiveTime(state, .{ .wtime = 9000, .winc = 500 });
    try testing.expect(falling < stable);
    try testing.expect(falling < 900);
}

test "time manager preserves clock across a full increment game" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();
    var state = GameState.init();
    try state.loadStart();

    var clock: u64 = 60_000;
    const increment: u64 = 1_000;
    for (0..60) |turn| {
        const budget = engine.calculateAdaptiveTime(state, .{ .wtime = clock, .winc = increment });
        if (turn == 0) try testing.expect(budget <= 6_000);

        try testing.expect(budget + 5 < clock);
        clock = clock - budget - 5 + increment;
        if (turn == 19) try testing.expect(clock >= 12_000);
    }
    try testing.expect(clock >= 5_000);
}

test "time manager preserves sudden-death and sub-second reserves" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();
    var state = GameState.init();
    try state.loadStart();

    var clock: u64 = 60_000;
    for (0..80) |turn| {
        const budget = engine.calculateAdaptiveTime(state, .{ .wtime = clock });
        try testing.expect(budget + 5 < clock);
        clock -= budget + 5;
        if (turn == 59) try testing.expect(clock >= 3_000);
    }
    try testing.expect(clock >= 500);

    engine.newGame();
    clock = 800;
    for (0..20) |_| {
        const budget = engine.calculateAdaptiveTime(state, .{ .wtime = clock });
        try testing.expect(budget + 2 < clock);
        clock -= budget + 2;
    }
    try testing.expect(clock >= 10);
}

test "inferred increment cannot cause an allocation spike" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();
    var state = GameState.init();
    try state.loadStart();

    var clock: u64 = 10_000;
    const actual_increment: u64 = 500;
    for (0..40) |turn| {
        const budget = engine.calculateAdaptiveTime(state, .{ .wtime = clock });
        try testing.expect(budget + 2 < clock);
        try testing.expect(budget <= clock / 4);

        engine.last_search_ms[0] = budget;
        clock = clock - budget - 2 + actual_increment;

        if (turn == 1) {
            try testing.expect(engine.estimated_increment_ms[0] >= 450);
            try testing.expect(engine.estimated_increment_ms[0] <= 550);
        }
        if (turn == 9) try testing.expect(clock >= 5_000);
    }
    try testing.expect(clock > 1_000);
}

test "moves-to-go refill is not mistaken for Fischer increment" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();
    var state = GameState.init();
    try state.loadStart();

    const first = engine.calculateAdaptiveTime(state, .{ .wtime = 3_000, .movestogo = 1 });
    engine.last_search_ms[0] = first;
    _ = engine.calculateAdaptiveTime(state, .{ .wtime = 3_000 - first + 3_000, .movestogo = 20 });
    try testing.expectEqual(@as(u64, 0), engine.estimated_increment_ms[0]);
}

test "engine makes move with fixed depth" {
    const allocator = testing.allocator;

    var engine = try Engine.init(allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();

    var state = GameState.init();
    try state.loadStart();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{
        .depth = 3,
    };

    std.debug.print("\nStarting fixed depth search...\n", .{});
    const start_time = std.time.milliTimestamp();
    try engine.go(state, params, output.writer());
    const elapsed = std.time.milliTimestamp() - start_time;

    std.debug.print("Search completed in {d}ms\n", .{elapsed});
    std.debug.print("Output: {s}\n", .{output.items});

    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "bestmove") != null);
}

test "terminal root positions emit UCI no-move" {
    var engine = try Engine.init(testing.allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();

    const positions = [_][]const u8{
        "7k/5K2/6Q1/8/8/8/8/8 b - - 0 1",
        "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1",
    };
    for (positions) |fen| {
        const state = try GameState.fromFen(fen);
        var output = std.ArrayList(u8).init(testing.allocator);
        defer output.deinit();
        try engine.go(state, .{ .depth = 2 }, output.writer());
        try testing.expect(std.mem.indexOf(u8, output.items, "bestmove 0000\n") != null);
    }
}

test "engine makes move within time limit" {
    const allocator = testing.allocator;

    std.debug.print("\n=== TEST START ===\n", .{});

    var engine = try Engine.init(allocator, EngineConfig{ .hash_size_mb = 1, .use_nnue = false });
    defer engine.deinit();

    std.debug.print("Engine initialized\n", .{});

    var state = GameState.init();
    try state.loadStart();

    std.debug.print("State loaded\n", .{});

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{
        .movetime = 100,
    };

    std.debug.print("\nStarting timed search (100ms)...\n", .{});
    const start_time = std.time.milliTimestamp();

    std.debug.print("About to call engine.go()...\n", .{});
    try engine.go(state, params, output.writer());

    const elapsed = std.time.milliTimestamp() - start_time;

    std.debug.print("Search completed in {d}ms\n", .{elapsed});
    std.debug.print("Output: {s}\n", .{output.items});

    try testing.expect(elapsed < 500);

    const output_str = output.items;
    try testing.expect(std.mem.indexOf(u8, output_str, "bestmove") != null);

    std.debug.print("=== TEST END ===\n", .{});
}
