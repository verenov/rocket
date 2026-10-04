const std = @import("std");
const GameState = @import("gamestate.zig").GameState;
const movegen = @import("movegen.zig");
const bb = @import("bitboard.zig");

fn perft(state: *GameState, depth: u32) u64 {
    if (depth == 0) return 1;
    var moves = movegen.MoveList.init();
    movegen.generateLegalMoves(state, &moves);
    if (depth == 1) return moves.count;
    var nodes: u64 = 0;
    for (moves.moves[0..moves.count]) |move| {
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };
        movegen.makeMove(state, move, &undo);
        nodes += perft(state, depth - 1);
        movegen.unmakeMove(state, move, &undo);
    }
    return nodes;
}

fn expectSynchronized(state: *const GameState) !void {
    var pieces = [_][6]u64{[_]u64{0} ** 6} ** 2;
    var colors = [_]u64{ 0, 0 };
    var occupied: u64 = 0;
    for (state.board.squares, 0..) |square, index| {
        if (square.piece) |piece| {
            const mask = bb.bit(@intCast(index));
            const color_idx: usize = if (piece.color == 1) 0 else 1;
            pieces[color_idx][@intFromEnum(piece.kind)] |= mask;
            colors[color_idx] |= mask;
            occupied |= mask;
        }
    }
    try std.testing.expectEqualDeep(pieces, state.board.pieces);
    try std.testing.expectEqual(colors, state.board.colors);
    try std.testing.expectEqual(occupied, state.board.occupied);
}

test "bitboards stay synchronized across make and unmake" {
    bb.initMagics();
    var state = try GameState.fromFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
    try expectSynchronized(&state);
    var moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&state, &moves);
    for (moves.moves[0..moves.count]) |move| {
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };
        movegen.makeMove(&state, move, &undo);
        try expectSynchronized(&state);
        movegen.unmakeMove(&state, move, &undo);
        try expectSynchronized(&state);
    }
}

test "canonical bitboard perft positions" {
    bb.initMagics();
    const cases = [_]struct { fen: []const u8, depth: u32, nodes: u64 }{
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .depth = 4, .nodes = 197281 },
        .{ .fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1", .depth = 3, .nodes = 97862 },
        .{ .fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", .depth = 4, .nodes = 43238 },
        .{ .fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1", .depth = 3, .nodes = 9467 },
        .{ .fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8", .depth = 3, .nodes = 62379 },
    };
    for (cases) |case| {
        var state = try GameState.fromFen(case.fen);
        try std.testing.expectEqual(case.nodes, perft(&state, case.depth));
        try expectSynchronized(&state);
    }
}
