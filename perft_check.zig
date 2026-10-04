const std = @import("std");
const GameState = @import("src/gamestate.zig").GameState;
const movegen = @import("src/movegen.zig");

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

pub fn main() !void {
    var state = GameState.init();
    try state.loadStart();

    const d1 = perft(&state, 1);
    const d2 = perft(&state, 2);
    const d3 = perft(&state, 3);

    std.debug.print("Perft startpos: d1={d} d2={d} d3={d}\n", .{ d1, d2, d3 });
    std.debug.print("Expected:       d1=20 d2=400 d3=8902\n", .{});

    // Correct king-in-check FEN (queen on e7)
    const fen = "4k3/8/4q3/8/8/8/8/4K3 w - - 0 1";
    var state2 = try GameState.fromFen(fen);
    var moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&state2, &moves);
    std.debug.print("\nCorrect queen e7 FEN, legal moves: {d}\n", .{moves.count});
    for (moves.moves[0..moves.count]) |move| {
        var buf: [6]u8 = undefined;
        std.debug.print("  {s}\n", .{move.toUci(&buf)});
    }

    const fen_out = try state2.toFen(std.heap.page_allocator);
    defer std.heap.page_allocator.free(fen_out);
    std.debug.print("Roundtrip FEN: {s}\n", .{fen_out});
}
