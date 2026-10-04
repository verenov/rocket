const std = @import("std");
const GameState = @import("gamestate.zig").GameState;
const Move = @import("movegen.zig").Move;
const TranspositionTable = @import("transposition.zig").TranspositionTable;
const zobrist = @import("zobrist.zig");
const search = @import("search.zig");
const SearchLimits = search.SearchLimits;
const MATE_SCORE: i32 = 30000;
const eval = @import("eval.zig");
const nnue = @import("nnue.zig");

pub const GoParams = struct {
    wtime: ?u64 = null,
    btime: ?u64 = null,
    winc: ?u64 = null,
    binc: ?u64 = null,
    movestogo: ?u32 = null,
    depth: ?i32 = null,
    nodes: ?u64 = null,
    movetime: ?u64 = null,
    infinite: bool = false,
    ponder: bool = false,
};

pub const TimeLimits = struct {
    optimum: u64,
    maximum: u64,
};

pub const EngineConfig = struct {
    hash_size_mb: usize = 64,
    threads: u32 = 1,
    use_nnue: bool = true,
    nnue_file: ?[]const u8 = null,
    ponder_enabled: bool = false,
};

const LockedStdout = struct {
    const Writer = std.io.GenericWriter(*std.Thread.Mutex, std.fs.File.WriteError, write);

    fn write(mutex: *std.Thread.Mutex, bytes: []const u8) std.fs.File.WriteError!usize {
        mutex.lock();
        defer mutex.unlock();
        return std.io.getStdOut().write(bytes);
    }
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    config: EngineConfig,
    tt: TranspositionTable,
    nnue_network: ?nnue.Network,
    stop_flag: std.atomic.Value(bool),
    search_thread: ?std.Thread = null,
    output_mutex: std.Thread.Mutex = .{},
    ponder_mutex: std.Thread.Mutex = .{},
    ponder_condition: std.Thread.Condition = .{},
    pondering: std.atomic.Value(bool),
    ponder_hit_time_ms: std.atomic.Value(i64),
    last_clock_ms: [2]?u64 = .{ null, null },
    last_search_ms: [2]u64 = .{ 0, 0 },
    estimated_increment_ms: [2]u64 = .{ 0, 0 },

    pub fn init(allocator: std.mem.Allocator, config: EngineConfig) !Engine {
        zobrist.init();

        var network: ?nnue.Network = null;
        if (config.use_nnue) {
            var net = try nnue.Network.init(allocator);

            if (config.nnue_file) |path| {
                if (nnue.loadNetwork(&net, path)) {
                    std.debug.print("NNUE network loaded successfully from: {s}\n", .{path});
                    network = net;
                } else {
                    std.debug.print("NNUE disabled - network file not loaded\n", .{});
                    net.deinit();
                }
            } else {
                const default_paths = [_][]const u8{
                    "nnue/nn-1c0c37333daf.nnue",
                    "nnue/koivisto.bin",
                    "network.nnue",
                    "nn.nnue",
                    "koivisto.nnue",
                };

                var loaded = false;
                for (default_paths) |path| {
                    if (nnue.loadNetwork(&net, path)) {
                        std.debug.print("NNUE network loaded from: {s}\n", .{path});
                        network = net;
                        loaded = true;
                        break;
                    }
                }

                if (!loaded) {
                    std.debug.print("NNUE disabled - no network file found\n", .{});
                    net.deinit();
                }
            }
        }

        return Engine{
            .allocator = allocator,
            .config = config,
            .tt = try TranspositionTable.init(allocator, config.hash_size_mb),
            .nnue_network = network,
            .stop_flag = std.atomic.Value(bool).init(false),
            .search_thread = null,
            .output_mutex = .{},
            .ponder_mutex = .{},
            .ponder_condition = .{},
            .pondering = std.atomic.Value(bool).init(false),
            .ponder_hit_time_ms = std.atomic.Value(i64).init(0),
            .last_clock_ms = .{ null, null },
            .last_search_ms = .{ 0, 0 },
            .estimated_increment_ms = .{ 0, 0 },
        };
    }

    pub fn deinit(self: *Engine) void {
        self.stop();
        self.tt.deinit();
        if (self.nnue_network) |*net| {
            net.deinit();
        }
    }

    pub fn newGame(self: *Engine) void {
        self.stop();
        self.tt.clear();
        self.last_clock_ms = .{ null, null };
        self.last_search_ms = .{ 0, 0 };
        self.estimated_increment_ms = .{ 0, 0 };
    }

    pub fn setHashSize(self: *Engine, size_mb: usize) !void {
        self.stop();
        self.tt.deinit();
        self.tt = try TranspositionTable.init(self.allocator, size_mb);
        self.config.hash_size_mb = size_mb;
    }

    pub fn clearHash(self: *Engine) void {
        self.tt.clear();
    }

    pub fn stop(self: *Engine) void {
        self.stop_flag.store(true, .monotonic);

        self.ponder_mutex.lock();
        self.pondering.store(false, .release);
        self.ponder_condition.broadcast();
        self.ponder_mutex.unlock();

        if (self.search_thread) |thread| {
            thread.join();
            self.search_thread = null;
        }

        self.ponder_hit_time_ms.store(0, .release);
        self.stop_flag.store(false, .monotonic);
    }

    pub fn uciWriter(self: *Engine) LockedStdout.Writer {
        return .{ .context = &self.output_mutex };
    }

    pub fn ponderHit(self: *Engine) void {
        self.ponder_mutex.lock();
        defer self.ponder_mutex.unlock();
        if (!self.pondering.load(.acquire)) return;

        self.ponder_hit_time_ms.store(std.time.milliTimestamp(), .release);
        self.pondering.store(false, .release);
        self.ponder_condition.broadcast();
    }

    pub fn startUciSearch(self: *Engine, state: GameState, params: GoParams) !void {
        self.stop();
        self.ponder_hit_time_ms.store(0, .release);
        self.pondering.store(params.ponder, .release);

        self.search_thread = std.Thread.spawn(.{}, uciSearchWorker, .{ self, state, params }) catch |err| {
            self.pondering.store(false, .release);
            return err;
        };
    }

    fn uciSearchWorker(self: *Engine, state: GameState, params: GoParams) void {
        const writer = self.uciWriter();
        self.runSearch(state, params, writer) catch |err| {
            writer.print("info string search error: {s}\n", .{@errorName(err)}) catch {};
        };
    }

    pub fn go(self: *Engine, state: GameState, params: GoParams, writer: anytype) !void {
        self.stop();
        self.pondering.store(false, .release);
        self.ponder_hit_time_ms.store(0, .release);
        try self.runSearch(state, params, writer);
    }

    fn runSearch(self: *Engine, state: GameState, params: GoParams, writer: anytype) !void {
        const start_time = std.time.milliTimestamp();

        const time_ms = self.calculateAdaptiveTime(state, params);
        const search_threads = selectSearchThreads(self.config.threads, time_ms, params);

        if (params.depth == null and params.nodes == null and params.movetime == null and
            !params.infinite and !params.ponder and (params.wtime != null or params.btime != null))
        {
            if (try self.findBookMove(&state)) |book_move| {
                const side: usize = if (state.side_to_move == 1) 0 else 1;
                self.last_search_ms[side] = 0;
                try writer.writeAll("info string book move\n");
                try writeBestMove(writer, book_move, null);
                return;
            }
        }

        const limits = SearchLimits{
            .max_time_ms = time_ms,
            .start_time = start_time,
            .max_depth = if (params.depth) |d| d else search.MAX_DEPTH,
            .infinite = params.infinite,
            .max_nodes = params.nodes orelse std.math.maxInt(u64),
            .pondering = if (params.ponder) &self.pondering else null,
            .ponder_hit_time_ms = if (params.ponder) &self.ponder_hit_time_ms else null,
        };

        var nnue_ptr: ?*nnue.Network = null;
        if (self.config.use_nnue) {
            if (self.nnue_network) |*net| {
                net.initPosition(&state);
                nnue_ptr = net;
            }
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const search_allocator = arena.allocator();

        const result = if (search_threads > 1)
            search.parallelSearch(
                search_allocator,
                state,
                limits,
                &self.tt,
                &self.stop_flag,
                nnue_ptr,
                search_threads,
                writer,
            ) catch |err| {
                try writer.print("info string Error: {any}\n", .{err});
                var moves = @import("movegen.zig").MoveList.init();
                @import("movegen.zig").generateLegalMoves(&state, &moves);
                if (moves.count > 0) {
                    try writeBestMove(writer, moves.moves[0], null);
                } else {
                    try writer.writeAll("bestmove 0000\n");
                }
                return;
            }
        else
            search.search(
                search_allocator,
                state,
                limits,
                &self.tt,
                &self.stop_flag,
                nnue_ptr,
                writer,
            ) catch |err| {
                try writer.print("info string Error: {any}\n", .{err});
                var moves = @import("movegen.zig").MoveList.init();
                @import("movegen.zig").generateLegalMoves(&state, &moves);
                if (moves.count > 0) {
                    try writeBestMove(writer, moves.moves[0], null);
                } else {
                    try writer.writeAll("bestmove 0000\n");
                }
                return;
            };

        if (params.ponder) {
            self.ponder_mutex.lock();
            while (self.pondering.load(.acquire) and !self.stop_flag.load(.monotonic)) {
                self.ponder_condition.wait(&self.ponder_mutex);
            }
            self.ponder_mutex.unlock();
        }

        const searched_side: usize = if (state.side_to_move == 1) 0 else 1;
        if (params.ponder) {
            const hit_time = self.ponder_hit_time_ms.load(.acquire);
            self.last_search_ms[searched_side] = if (hit_time > 0)
                @intCast(@max(0, std.time.milliTimestamp() - hit_time))
            else
                0;
        } else {
            self.last_search_ms[searched_side] = result.time_ms;
        }

        const final_nps = if (result.time_ms > 0)
            result.nodes * 1000 / result.time_ms
        else
            0;
        var info_buf: [256]u8 = undefined;
        var info_stream = std.io.fixedBufferStream(&info_buf);
        const info_writer = info_stream.writer();
        if (eval.isMateScore(result.score)) {
            try info_writer.print("info depth {d} seldepth {d} score mate {d} nodes {d} time {d} nps {d}\n", .{
                result.depth,
                result.seldepth,
                eval.movesToMate(result.score),
                result.nodes,
                result.time_ms,
                final_nps,
            });
        } else {
            try info_writer.print("info depth {d} seldepth {d} score cp {d} nodes {d} time {d} nps {d}\n", .{
                result.depth,
                result.seldepth,
                result.score,
                result.nodes,
                result.time_ms,
                final_nps,
            });
        }
        try writer.writeAll(info_stream.getWritten());

        if (result.pv.length == 0) {
            try writer.writeAll("bestmove 0000\n");
            return;
        }
        if (self.config.ponder_enabled) {
            if (self.findPonderMove(state, result.best_move)) |ponder_move| {
                try writeBestMove(writer, result.best_move, ponder_move);
                return;
            }
        }
        try writeBestMove(writer, result.best_move, null);
    }

    fn findPonderMove(self: *Engine, state: GameState, best_move: Move) ?Move {
        const movegen = @import("movegen.zig");
        var child = state;
        const legal_best = movegen.resolveLegalMove(&child, best_move) orelse return null;
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = child.castling_rights,
            .en_passant_square = child.en_passant_square,
            .halfmove_clock = child.halfmove_clock,
        };
        movegen.makeMove(&child, legal_best, &undo);

        const entry = self.tt.probe(@import("transposition.zig").computeHash(&child)) orelse return null;
        return movegen.resolveLegalMove(&child, entry.best_move);
    }

    fn findBookMove(self: *Engine, state: *const GameState) !?Move {
        const movegen = @import("movegen.zig");
        const entries = [_]struct { fen: []const u8, move: []const u8 }{
            .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .move = "e2e4" },
            .{ .fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2", .move = "g1f3" },
            .{ .fen = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 2", .move = "g1f3" },
            .{ .fen = "rnbqkbnr/pppp1ppp/4p3/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2", .move = "d2d4" },
            .{ .fen = "rnbqkbnr/pp1p1ppp/4p3/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq c6 0 3", .move = "d2d4" },
            .{ .fen = "rnbqkbnr/ppp2ppp/8/3pp3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq d6 0 3", .move = "e4d5" },
            .{ .fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1", .move = "c7c5" },
            .{ .fen = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1", .move = "g8f6" },
        };

        const fen = try state.toFen(self.allocator);
        defer self.allocator.free(fen);
        for (entries) |entry| {
            if (!std.mem.eql(u8, fen, entry.fen)) continue;
            const parsed = try Move.fromUci(entry.move);
            return movegen.resolveLegalMove(state, parsed);
        }
        return null;
    }

    pub fn calculateTimeLimits(self: *const Engine, state: GameState, params: GoParams) ?TimeLimits {
        _ = self;
        if (params.movetime == null and !params.infinite) {
            const our_time = if (state.side_to_move == 1) params.wtime else params.btime;
            if (our_time == null) return null;
        }

        const optimum = calculateTime(state, params);
        if (params.infinite) return .{ .optimum = optimum, .maximum = optimum };

        const clock = if (state.side_to_move == 1) params.wtime else params.btime;
        const hard_cap = if (params.movetime) |mt| mt else clock.?;
        const safe_cap = if (hard_cap > 1) hard_cap - 1 else @as(u64, 1);
        return .{
            .optimum = @min(optimum, safe_cap),
            .maximum = @min(@max(optimum +| 1, optimum *| 4), safe_cap),
        };
    }

    pub fn calculateAdaptiveTime(self: *Engine, state: GameState, params: GoParams) u64 {
        if (params.movetime != null or params.infinite) return calculateTime(state, params);

        const side: usize = if (state.side_to_move == 1) 0 else 1;
        const clock = if (side == 0) params.wtime else params.btime;
        const explicit_increment = if (side == 0) params.winc else params.binc;

        if (clock) |now| {
            if (explicit_increment == null and params.movestogo == null) {
                if (self.last_clock_ms[side]) |previous| {
                    const replenished = now +| self.last_search_ms[side];
                    if (replenished > previous) {
                        const observed = replenished - previous;
                        if (observed <= 10_000) {
                            const old = self.estimated_increment_ms[side];
                            self.estimated_increment_ms[side] = if (old == 0)
                                observed
                            else
                                (old * 3 + observed) / 4;
                        }
                    }
                }
            }

            const inferred = if (params.movestogo == null) self.estimated_increment_ms[side] else 0;
            const increment: ?u64 = explicit_increment orelse if (inferred > 0) inferred else null;
            self.last_clock_ms[side] = now;

            if (increment) |inc| {
                var effective = params;
                if (side == 0) effective.winc = inc else effective.binc = inc;
                return calculateTime(state, effective);
            }
        }

        return calculateTime(state, params);
    }

    fn calculateTime(state: GameState, params: GoParams) u64 {
        if (params.movetime) |mt| {
            if (mt <= 1) return 1;
            return mt - clockReserve(mt);
        }

        if (params.infinite) {
            return 3600000;
        }

        const our_time = if (state.side_to_move == 1) params.wtime else params.btime;
        const our_inc = if (state.side_to_move == 1) params.winc else params.binc;

        if (our_time) |time| {
            if (time <= 1) return 1;

            const available = time - clockReserve(time);
            const increment = our_inc orelse 0;
            const has_increment = increment > 0;
            const horizon: u64 = if (params.movestogo) |moves|
                @max(@as(u64, 1), @as(u64, moves) + 1)
            else if (has_increment)
                30
            else
                40;

            const base = available / horizon;

            const increment_credit = @min(increment - increment / 4, available / 20);
            const requested = @max(@as(u64, 1), base +| increment_credit);

            const cap_divisor: u64 = if (time <= 1000)
                10
            else if (params.movestogo != null)
                2
            else if (has_increment)
                10
            else
                20;
            const cap = @max(@as(u64, 1), available / cap_divisor);
            const result = @min(requested, cap);

            return result;
        }

        return 3600000;
    }

    pub fn analyze(self: *Engine, state: GameState, writer: anytype) !void {
        try self.go(state, .{ .infinite = true }, writer);
    }

    pub fn perft(state: *GameState, depth: u32, writer: anytype) !void {
        const movegen = @import("movegen.zig");
        const MoveList = movegen.MoveList;
        const UndoInfo = movegen.UndoInfo;

        if (depth == 0) {
            try writer.print("Nodes: 1\n", .{});
            return;
        }

        var moves = MoveList.init();
        movegen.generateLegalMoves(state, &moves);

        var total: u64 = 0;

        for (moves.moves[0..moves.count]) |move| {
            var undo = UndoInfo{
                .captured_piece = null,
                .castling_rights = state.castling_rights,
                .en_passant_square = state.en_passant_square,
                .halfmove_clock = state.halfmove_clock,
            };

            movegen.makeMove(state, move, &undo);
            const nodes = perftInner(state, depth - 1);
            movegen.unmakeMove(state, move, &undo);

            var buf: [6]u8 = undefined;
            const move_str = move.toUci(&buf);
            try writer.print("{s}: {d}\n", .{ move_str, nodes });

            total += nodes;
        }

        try writer.print("\nNodes: {d}\n", .{total});
    }
};

fn selectSearchThreads(configured: u32, time_ms: u64, params: GoParams) u32 {
    if (configured <= 1 or params.infinite or params.ponder or params.depth != null or params.nodes != null) {
        return configured;
    }
    if (time_ms < 50) return 1;
    if (time_ms < 100) return @min(configured, 2);
    return configured;
}

fn clockReserve(time_ms: u64) u64 {
    if (time_ms <= 1) return 0;
    const target = @max(@as(u64, 5), @min(@as(u64, 50), time_ms / 50));
    return @min(time_ms - 1, target);
}

test "short clock budgets shed worker overhead" {
    try std.testing.expectEqual(@as(u32, 1), selectSearchThreads(8, 40, .{ .wtime = 1000 }));
    try std.testing.expectEqual(@as(u32, 2), selectSearchThreads(8, 75, .{ .wtime = 2000 }));
    try std.testing.expectEqual(@as(u32, 8), selectSearchThreads(8, 150, .{ .wtime = 5000 }));
    try std.testing.expectEqual(@as(u32, 8), selectSearchThreads(8, 40, .{ .nodes = 1000 }));
    try std.testing.expectEqual(@as(u32, 8), selectSearchThreads(8, 40, .{ .ponder = true }));
}

fn writeBestMove(writer: anytype, best_move: Move, ponder_move: ?Move) !void {
    var line_buf: [64]u8 = undefined;
    var line_stream = std.io.fixedBufferStream(&line_buf);
    const line = line_stream.writer();
    var best_buf: [6]u8 = undefined;

    try line.print("bestmove {s}", .{best_move.toUci(&best_buf)});
    if (ponder_move) |ponder| {
        var ponder_buf: [6]u8 = undefined;
        try line.print(" ponder {s}", .{ponder.toUci(&ponder_buf)});
    }
    try line.writeByte('\n');
    try writer.writeAll(line_stream.getWritten());
}

fn perftInner(state: *GameState, depth: u32) u64 {
    const movegen = @import("movegen.zig");
    const MoveList = movegen.MoveList;
    const UndoInfo = movegen.UndoInfo;

    if (depth == 0) return 1;

    var moves = MoveList.init();
    movegen.generateLegalMoves(state, &moves);

    if (depth == 1) return moves.count;

    var nodes: u64 = 0;

    for (moves.moves[0..moves.count]) |move| {
        var undo = UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };

        movegen.makeMove(state, move, &undo);
        nodes += perftInner(state, depth - 1);
        movegen.unmakeMove(state, move, &undo);
    }

    return nodes;
}
