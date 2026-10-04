const std = @import("std");
const GameState = @import("src/gamestate.zig").GameState;
const movegen = @import("src/movegen.zig");

pub fn main() !void {
    var state = GameState.init();
    try state.loadStart();

    // Apply b2b4
    var legal = movegen.MoveList.init();
    movegen.generateLegalMoves(&state, &legal);
    for (legal.moves[0..legal.count]) |m| {
        var buf: [6]u8 = undefined;
        if (std.mem.eql(u8, m.toUci(&buf), "b2b4")) {
            var undo = movegen.UndoInfo{
                .captured_piece = null,
                .castling_rights = state.castling_rights,
                .en_passant_square = state.en_passant_square,
                .halfmove_clock = state.halfmove_clock,
            };
            movegen.makeMove(&state, m, &undo);
            break;
        }
    }

    std.debug.print("After b2b4, ep square: {?}\n", .{state.en_passant_square});
    const fen = try state.toFen(std.heap.page_allocator);
    defer std.heap.page_allocator.free(fen);
    std.debug.print("FEN: {s}\n\n", .{fen});

    var black_moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&state, &black_moves);
    std.debug.print("Black legal moves ({d}, expected 20):\n", .{black_moves.count});
    for (black_moves.moves[0..black_moves.count]) |move| {
        var buf: [6]u8 = undefined;
        const uci = move.toUci(&buf);

        var trial = state;
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = trial.castling_rights,
            .en_passant_square = trial.en_passant_square,
            .halfmove_clock = trial.halfmove_clock,
        };
        movegen.makeMove(&trial, move, &undo);
        const leaves_king_in_check = movegen.isInCheck(&trial.board, 1 - trial.side_to_move);
        std.debug.print("  {s}{s}{s}\n", .{ uci, if (move.is_en_passant) " [ep]" else "", if (leaves_king_in_check) " ILLEGAL!" else "" });
    }

    // Compare with known list - find missing/extra
    std.debug.print("\n--- En passant test position ---\n", .{});
    var ep = try GameState.fromFen("rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 1");
    var ep_moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&ep, &ep_moves);
    std.debug.print("White moves: {d} (expected 29)\n", .{ep_moves.count});
    for (ep_moves.moves[0..ep_moves.count]) |move| {
        var buf: [6]u8 = undefined;
        if (move.is_en_passant) std.debug.print("  EP: {s}\n", .{move.toUci(&buf)});
    }
}
