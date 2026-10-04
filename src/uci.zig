const std = @import("std");
const GameState = @import("gamestate.zig").GameState;
const movegen = @import("movegen.zig");
const Move = movegen.Move;
const MoveList = movegen.MoveList;
const UndoInfo = movegen.UndoInfo;
const Engine = @import("engine.zig").Engine;
const EngineConfig = @import("engine.zig").EngineConfig;
const GoParams = @import("engine.zig").GoParams;

pub const UciEngine = struct {
    state: GameState,
    engine: Engine,
    allocator: std.mem.Allocator,
    debug: bool = false,

    pub fn init(allocator: std.mem.Allocator) !UciEngine {
        return UciEngine{
            .state = GameState.init(),
            .engine = try Engine.init(allocator, EngineConfig{}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UciEngine) void {
        self.engine.deinit();
    }

    pub fn run(self: *UciEngine) !void {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();

        var buffered_reader = std.io.bufferedReader(stdin.reader());

        var reader = buffered_reader.reader();

        while (true) {
            var line_buf: [4096]u8 = undefined;
            const line = reader.readUntilDelimiterOrEof(&line_buf, '\n') catch |err| {
                return err;
            } orelse break;

            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;

            _ = stdout;
            const writer = self.engine.uciWriter();
            self.handleCommand(trimmed, writer) catch |err| {
                try writer.print("info string command error: {s}\n", .{@errorName(err)});
            };
            try writer.writeAll("");
        }
    }

    fn handleCommand(self: *UciEngine, cmd: []const u8, writer: anytype) !void {
        var iter = std.mem.tokenizeScalar(u8, cmd, ' ');
        const command = iter.next() orelse return;

        if (std.mem.eql(u8, command, "uci")) {
            try self.cmdUci(writer);
        } else if (std.mem.eql(u8, command, "isready")) {
            try writer.writeAll("readyok\n");
        } else if (std.mem.eql(u8, command, "ucinewgame")) {
            try self.cmdNewGame();
        } else if (std.mem.eql(u8, command, "position")) {
            try self.cmdPosition(&iter);
        } else if (std.mem.eql(u8, command, "go")) {
            try self.cmdGo(&iter);
        } else if (std.mem.eql(u8, command, "stop")) {
            self.engine.stop();
        } else if (std.mem.eql(u8, command, "ponderhit")) {
            self.engine.ponderHit();
        } else if (std.mem.eql(u8, command, "setoption")) {
            try self.cmdSetOption(&iter, writer);
        } else if (std.mem.eql(u8, command, "d")) {
            try self.cmdDisplay(writer);
        } else if (std.mem.eql(u8, command, "perft")) {
            try self.cmdPerft(&iter, writer);
        } else if (std.mem.eql(u8, command, "quit")) {
            self.engine.stop();
            std.process.exit(0);
        } else if (self.debug) {
            try writer.print("Unknown command: {s}\n", .{command});
        }
    }

    fn cmdUci(self: *UciEngine, writer: anytype) !void {
        try writer.writeAll("id name Rocket\n");
        try writer.writeAll("id author Rocket Team\n");
        try writer.writeAll("option name Hash type spin default 64 min 1 max 4096\n");
        try writer.writeAll("option name Threads type spin default 1 min 1 max 256\n");
        try writer.writeAll("option name Use NNUE type check default true\n");
        try writer.writeAll("option name Ponder type check default false\n");
        try writer.writeAll("uciok\n");
        _ = self;
    }

    fn cmdNewGame(self: *UciEngine) !void {
        try self.state.loadStart();
        self.engine.newGame();
    }

    fn cmdPosition(self: *UciEngine, iter: *std.mem.TokenIterator(u8, .scalar)) !void {
        self.engine.stop();
        const pos_type = iter.next() orelse return;
        var moves_token: ?[]const u8 = null;
        var new_state = GameState.init();

        if (std.mem.eql(u8, pos_type, "startpos")) {
            try new_state.loadStart();
            moves_token = iter.next();
        } else if (std.mem.eql(u8, pos_type, "fen")) {
            var fen_parts = std.ArrayList(u8).init(self.allocator);
            defer fen_parts.deinit();

            for (0..6) |count| {
                const part = iter.next() orelse return error.InvalidFen;
                if (count > 0) try fen_parts.append(' ');
                try fen_parts.appendSlice(part);
            }

            new_state = try GameState.fromFen(fen_parts.items);
            moves_token = iter.next();
        } else {
            return error.InvalidPosition;
        }

        if (moves_token) |token| {
            if (std.mem.eql(u8, token, "moves")) {
                while (iter.next()) |move_str| {
                    const parsed = try Move.fromUci(move_str);
                    const move = movegen.resolveLegalMove(&new_state, parsed) orelse
                        return error.IllegalMove;
                    var undo = UndoInfo{
                        .captured_piece = null,
                        .castling_rights = new_state.castling_rights,
                        .en_passant_square = new_state.en_passant_square,
                        .halfmove_clock = new_state.halfmove_clock,
                    };
                    movegen.makeMove(&new_state, move, &undo);
                }
            }
        }
        self.state = new_state;
    }

    fn cmdGo(self: *UciEngine, iter: *std.mem.TokenIterator(u8, .scalar)) !void {
        var params = GoParams{};

        while (iter.next()) |token| {
            if (std.mem.eql(u8, token, "wtime")) {
                if (iter.next()) |val| {
                    params.wtime = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "btime")) {
                if (iter.next()) |val| {
                    params.btime = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "winc")) {
                if (iter.next()) |val| {
                    params.winc = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "binc")) {
                if (iter.next()) |val| {
                    params.binc = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "movestogo")) {
                if (iter.next()) |val| {
                    params.movestogo = try std.fmt.parseInt(u32, val, 10);
                }
            } else if (std.mem.eql(u8, token, "depth")) {
                if (iter.next()) |val| {
                    params.depth = try std.fmt.parseInt(i32, val, 10);
                }
            } else if (std.mem.eql(u8, token, "nodes")) {
                if (iter.next()) |val| {
                    params.nodes = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "movetime")) {
                if (iter.next()) |val| {
                    params.movetime = try std.fmt.parseInt(u64, val, 10);
                }
            } else if (std.mem.eql(u8, token, "infinite")) {
                params.infinite = true;
            } else if (std.mem.eql(u8, token, "ponder")) {
                params.ponder = true;
            }
        }

        try self.engine.startUciSearch(self.state, params);
    }

    fn cmdDisplay(self: *UciEngine, writer: anytype) !void {
        try writer.writeAll("\n");

        var rank: i8 = 0;
        while (rank < 8) : (rank += 1) {
            try writer.print("{d} ", .{8 - rank});

            var file: u8 = 0;
            while (file < 8) : (file += 1) {
                const idx = @as(usize, @intCast(rank)) * 8 + file;
                const square = self.state.board.squares[idx];

                if (square.piece) |p| {
                    try writer.print(" {c}", .{p.print()});
                } else {
                    try writer.writeAll(" .");
                }
            }
            try writer.writeAll("\n");
        }

        try writer.writeAll("   a b c d e f g h\n\n");

        const fen = try self.state.toFen(self.allocator);
        defer self.allocator.free(fen);
        try writer.print("FEN: {s}\n", .{fen});

        try writer.print("Side to move: {s}\n", .{if (self.state.side_to_move == 1) "White" else "Black"});

        var moves = MoveList.init();
        movegen.generateLegalMoves(&self.state, &moves);
        try writer.print("Legal moves: {d}\n\n", .{moves.count});
    }

    fn cmdSetOption(self: *UciEngine, iter: *std.mem.TokenIterator(u8, .scalar), writer: anytype) !void {
        _ = writer;

        const name_token = iter.next();
        if (name_token == null or !std.mem.eql(u8, name_token.?, "name")) return;

        const option_name = iter.next() orelse return;

        const value_token = iter.next();
        if (std.mem.eql(u8, option_name, "Use") and value_token != null and
            std.mem.eql(u8, value_token.?, "NNUE"))
        {
            const marker = iter.next() orelse return;
            if (!std.mem.eql(u8, marker, "value")) return;
            const enabled = iter.next() orelse return;
            const use_nnue = std.ascii.eqlIgnoreCase(enabled, "true") or
                std.mem.eql(u8, enabled, "1") or std.ascii.eqlIgnoreCase(enabled, "on");
            self.engine.stop();
            if (use_nnue != self.engine.config.use_nnue) self.engine.clearHash();
            self.engine.config.use_nnue = use_nnue;
            return;
        }
        if (value_token == null or !std.mem.eql(u8, value_token.?, "value")) return;

        const value_str = iter.next() orelse return;

        if (std.mem.eql(u8, option_name, "Hash")) {
            const hash_mb = try std.fmt.parseInt(usize, value_str, 10);
            try self.engine.setHashSize(hash_mb);
        } else if (std.mem.eql(u8, option_name, "Threads")) {
            const threads = try std.fmt.parseInt(u32, value_str, 10);
            self.engine.stop();
            self.engine.config.threads = @min(threads, 256);
        } else if (std.mem.eql(u8, option_name, "Ponder")) {
            self.engine.stop();
            self.engine.config.ponder_enabled = std.ascii.eqlIgnoreCase(value_str, "true") or
                std.mem.eql(u8, value_str, "1") or std.ascii.eqlIgnoreCase(value_str, "on");
        }
    }

    fn cmdPerft(self: *UciEngine, iter: *std.mem.TokenIterator(u8, .scalar), writer: anytype) !void {
        self.engine.stop();
        const depth_str = iter.next() orelse "5";
        const depth = try std.fmt.parseInt(u32, depth_str, 10);
        try Engine.perft(&self.state, depth, writer);
    }
};
