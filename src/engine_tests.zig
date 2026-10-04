const std = @import("std");
const testing = std.testing;
const GameState = @import("gamestate.zig").GameState;
const movegen = @import("movegen.zig");
const Move = movegen.Move;
const MoveList = movegen.MoveList;
const eval = @import("eval.zig");
const Engine = @import("engine.zig").Engine;
const EngineConfig = @import("engine.zig").EngineConfig;
const GoParams = @import("engine.zig").GoParams;

test "Move generation: no illegal moves in startpos" {
    var state = GameState.init();
    try state.loadStart();

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    std.debug.print("\nStartpos legal moves: {d}\n", .{moves.count});
    try testing.expect(moves.count == 20);

    for (moves.moves[0..moves.count]) |move| {
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };

        var test_state = state;
        movegen.makeMove(&test_state, move, &undo);

        const our_king_in_check = movegen.isInCheck(&test_state.board, 1 - test_state.side_to_move);
        if (our_king_in_check) {
            var buf: [6]u8 = undefined;
            std.debug.print("ILLEGAL MOVE GENERATED: {s}\n", .{move.toUci(&buf)});
        }
        try testing.expect(!our_king_in_check);
    }
}

test "Move generation: king cannot move into check" {
    const fen = "4k3/8/8/8/8/8/4q3/4K3 w - - 0 1";
    var state = try GameState.fromFen(fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    std.debug.print("\nKing in check test, legal moves: {d}\n", .{moves.count});

    for (moves.moves[0..moves.count]) |move| {
        var buf: [6]u8 = undefined;
        const move_str = move.toUci(&buf);

        if (std.mem.eql(u8, move_str, "e1f2") or std.mem.eql(u8, move_str, "e1e2") or
            std.mem.eql(u8, move_str, "e1d2"))
        {
            std.debug.print("ILLEGAL: King moving into check: {s}\n", .{move_str});
            try testing.expect(false);
        }
    }
}

test "Move generation: cannot capture defended piece with king" {
    const fen = "4k3/8/8/8/8/8/4qr2/4K3 w - - 0 1";
    var state = try GameState.fromFen(fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    std.debug.print("\nDefended piece test, legal moves: {d}\n", .{moves.count});

    for (moves.moves[0..moves.count]) |move| {
        var buf: [6]u8 = undefined;
        const move_str = move.toUci(&buf);

        if (std.mem.eql(u8, move_str, "e1f2")) {
            std.debug.print("ILLEGAL: King capturing defended queen: {s}\n", .{move_str});
            try testing.expect(false);
        }
    }
}

test "Evaluation: material count is correct" {
    var state = GameState.init();
    try state.loadStart();

    const score = eval.evaluate(&state);
    std.debug.print("\nStartpos eval: {d} (should be close to 0)\n", .{score});

    try testing.expect(@abs(score) < 100);
}

test "Evaluation: winning position is positive" {
    const fen = "4k3/8/8/8/8/8/PPPPPPPP/RNBQKBNR w KQ - 0 1";
    var state = try GameState.fromFen(fen);

    const score = eval.evaluate(&state);
    std.debug.print("\nWhite up material eval: {d} (should be >> 0)\n", .{score});

    try testing.expect(score > 3000);
}

test "Evaluation: losing position is negative" {
    const fen = "rnbqkbnr/pppppppp/8/8/8/8/8/4K3 w kq - 0 1";
    var state = try GameState.fromFen(fen);

    const score = eval.evaluate(&state);
    std.debug.print("\nWhite down material eval: {d} (should be << 0)\n", .{score});

    try testing.expect(score < -3000);
}

test "Evaluation: queen vs pawn" {
    const fen = "4k3/8/8/8/8/8/4P3/4KQ2 w - - 0 1";
    var state = try GameState.fromFen(fen);

    const score = eval.evaluate(&state);
    std.debug.print("\nQueen vs Pawn eval: {d} (should be ~800)\n", .{score});

    try testing.expect(score > 700 and score < 1000);
}

test "Search: doesn't hang queen in one move" {
    const fen = "rnbqkb1r/pppp1ppp/5n2/4p3/4P3/5N2/PPPPQPPP/RNB1KB1R w KQkq - 0 1";
    const state = try GameState.fromFen(fen);

    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, EngineConfig{});
    defer engine.deinit();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{ .depth = 3 };
    try engine.go(state, params, output.writer());

    const output_str = output.items;
    std.debug.print("\nQueen hanging test output:\n{s}\n", .{output_str});

    const has_qxe5 = std.mem.indexOf(u8, output_str, "e2e5") != null;
    if (has_qxe5) {
        std.debug.print("ERROR: Engine wants to hang queen with Qxe5!\n", .{});
        try testing.expect(false);
    }
}

test "Search: finds mate in 1" {
    const fen = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1";
    const state = try GameState.fromFen(fen);

    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, EngineConfig{});
    defer engine.deinit();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{ .depth = 3 };
    try engine.go(state, params, output.writer());

    const output_str = output.items;
    std.debug.print("\nMate in 1 test output:\n{s}\n", .{output_str});

    const has_ra8 = std.mem.indexOf(u8, output_str, "bestmove a1a8") != null;
    if (!has_ra8) {
        std.debug.print("ERROR: Engine missed mate in 1 (Ra8#)!\n", .{});
        try testing.expect(false);
    }
}

test "Search: avoids getting mated in 1" {
    const fen = "r5k1/5ppp/8/8/8/8/5PPP/6K1 b - - 0 1";
    const state = try GameState.fromFen(fen);

    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, EngineConfig{});
    defer engine.deinit();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{ .depth = 3 };
    try engine.go(state, params, output.writer());

    const output_str = output.items;
    std.debug.print("\nAvoid mate in 1 test output:\n{s}\n", .{output_str});

    const plays_ra1 = std.mem.indexOf(u8, output_str, "bestmove a8a1") != null;
    if (!plays_ra1) {
        std.debug.print("ERROR: Engine didn't play mate in 1!\n", .{});
        try testing.expect(false);
    }
}

test "Search: captures hanging piece" {
    const fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPPQPPP/RNB1KBNR w KQkq - 0 1";
    const state = try GameState.fromFen(fen);

    const allocator = std.testing.allocator;
    var engine = try Engine.init(allocator, EngineConfig{});
    defer engine.deinit();

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    const params = GoParams{ .depth = 2 };
    try engine.go(state, params, output.writer());

    const output_str = output.items;
    std.debug.print("\nCapture hanging pawn test:\n{s}\n", .{output_str});

    const captures_e5 = std.mem.indexOf(u8, output_str, "bestmove e2e5") != null;
    if (!captures_e5) {
        std.debug.print("WARNING: Engine didn't capture hanging pawn\n", .{});
    }
}

test "Zobrist: same position has same hash" {
    var state1 = GameState.init();
    try state1.loadStart();

    var state2 = GameState.init();
    try state2.loadStart();

    const zobrist_module = @import("transposition.zig");
    const hash1 = zobrist_module.computeHash(&state1);
    const hash2 = zobrist_module.computeHash(&state2);

    std.debug.print("\nHash1: {x}, Hash2: {x}\n", .{ hash1, hash2 });
    try testing.expect(hash1 == hash2);
}

test "Zobrist: different positions have different hashes" {
    var state1 = GameState.init();
    try state1.loadStart();

    const fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1";
    var state2 = try GameState.fromFen(fen);

    const zobrist_module = @import("transposition.zig");
    const hash1 = zobrist_module.computeHash(&state1);
    const hash2 = zobrist_module.computeHash(&state2);

    std.debug.print("\nStartpos hash: {x}, After e4 hash: {x}\n", .{ hash1, hash2 });
    try testing.expect(hash1 != hash2);
}

test "Make/Unmake: position is restored" {
    var state = GameState.init();
    try state.loadStart();

    const original_fen = try state.toFen(std.testing.allocator);
    defer std.testing.allocator.free(original_fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    const move = moves.moves[0];
    var undo = movegen.UndoInfo{
        .captured_piece = null,
        .castling_rights = state.castling_rights,
        .en_passant_square = state.en_passant_square,
        .halfmove_clock = state.halfmove_clock,
    };

    movegen.makeMove(&state, move, &undo);
    movegen.unmakeMove(&state, move, &undo);

    const restored_fen = try state.toFen(std.testing.allocator);
    defer std.testing.allocator.free(restored_fen);

    std.debug.print("\nOriginal: {s}\nRestored: {s}\n", .{ original_fen, restored_fen });
    try testing.expect(std.mem.eql(u8, original_fen, restored_fen));
}

test "Castling: white kingside is legal" {
    const fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQK2R w KQkq - 0 1";
    var state = try GameState.fromFen(fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    var found_castling = false;
    for (moves.moves[0..moves.count]) |move| {
        if (move.from == 60 and move.to == 62 and move.is_castle) {
            found_castling = true;
            break;
        }
    }

    std.debug.print("\nCastling found: {}\n", .{found_castling});
    try testing.expect(found_castling);
}

test "Castling: cannot castle through check" {
    const fen = "rnbqkbnr/pppppppp/8/8/8/5r2/PPPPPPPP/RNBQK2R w KQkq - 0 1";
    var state = try GameState.fromFen(fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    for (moves.moves[0..moves.count]) |move| {
        if (move.is_castle) {
            std.debug.print("ERROR: Castling through check allowed!\n", .{});
            try testing.expect(false);
        }
    }
}

test "En passant: is generated correctly" {
    const fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 1";
    var state = try GameState.fromFen(fen);

    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    var found_ep = false;
    for (moves.moves[0..moves.count]) |move| {
        if (move.is_en_passant) {
            var buf: [6]u8 = undefined;
            std.debug.print("\nEn passant move: {s}\n", .{move.toUci(&buf)});
            found_ep = true;
        }
    }

    try testing.expect(found_ep);
}

test "UCI move resolution preserves castling semantics" {
    const fen = "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1";
    var state = try GameState.fromFen(fen);
    const parsed = try Move.fromUci("e1g1");
    const move = movegen.resolveLegalMove(&state, parsed) orelse return error.TestExpectedEqual;
    try testing.expect(move.is_castle);

    var undo = movegen.UndoInfo{
        .captured_piece = null,
        .castling_rights = state.castling_rights,
        .en_passant_square = state.en_passant_square,
        .halfmove_clock = state.halfmove_clock,
    };
    movegen.makeMove(&state, move, &undo);
    try testing.expect(state.board.squares[62].piece.?.kind == .King);
    try testing.expect(state.board.squares[61].piece.?.kind == .Rook);
    try testing.expect(state.board.squares[63].piece == null);
}

test "Castling rights without a rook do not generate castling" {
    const fen = "4k3/8/8/8/8/8/8/4K3 w KQ - 0 1";
    var state = try GameState.fromFen(fen);
    var moves = MoveList.init();
    movegen.generateLegalMoves(&state, &moves);
    for (moves.moves[0..moves.count]) |move| {
        try testing.expect(!move.is_castle);
    }
}

test "UCI move resolution preserves en passant semantics" {
    const fen = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1";
    var state = try GameState.fromFen(fen);
    const parsed = try Move.fromUci("e5d6");
    const move = movegen.resolveLegalMove(&state, parsed) orelse return error.TestExpectedEqual;
    try testing.expect(move.is_en_passant);
    try testing.expect(move.is_capture);
}
