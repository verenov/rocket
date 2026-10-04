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

    var moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&state, &moves);

    std.debug.print("Perft divide depth 1 from startpos:\n", .{});
    var total: u64 = 0;
    for (moves.moves[0..moves.count]) |move| {
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };
        movegen.makeMove(&state, move, &undo);
        const nodes = perft(&state, 1);
        movegen.unmakeMove(&state, move, &undo);
        var buf: [6]u8 = undefined;
        std.debug.print("  {s}: {d}\n", .{ move.toUci(&buf), nodes });
        total += nodes;
    }
    std.debug.print("Total: {d} (expected 400)\n", .{total});

    // En passant position
    const ep_fen = "rnbqkbnr/ppp1pppp/8/3pP3/8/8/PPPP1PPP/RNBQKBNR w KQkq d6 0 1";
    var ep_state = try GameState.fromFen(ep_fen);
    const ep_total = perft(&ep_state, 1);
    std.debug.print("\nEn passant position d1 moves: {d} (expected 29)\n", .{ep_total});

    // Castling rights test after e4
    var castle_state = GameState.init();
    try castle_state.loadStart();
    const e4 = movegen.Move.fromUci("e2e4") catch unreachable;
    var undo = movegen.UndoInfo{
        .captured_piece = null,
        .castling_rights = castle_state.castling_rights,
        .en_passant_square = castle_state.en_passant_square,
        .halfmove_clock = castle_state.halfmove_clock,
    };
    movegen.makeMove(&castle_state, e4, &undo);
    const after_e4 = perft(&castle_state, 1);
    std.debug.print("After e2e4 (no castle flags): d1={d} (expected 20)\n", .{after_e4});

    // With proper move from legal list
    var castle_state2 = GameState.init();
    try castle_state2.loadStart();
    var legal = movegen.MoveList.init();
    movegen.generateLegalMoves(&castle_state2, &legal);
    var e4move: movegen.Move = undefined;
    for (legal.moves[0..legal.count]) |m| {
        var buf: [6]u8 = undefined;
        if (std.mem.eql(u8, m.toUci(&buf), "e2e4")) e4move = m;
    }
    var undo2 = movegen.UndoInfo{
        .captured_piece = null,
        .castling_rights = castle_state2.castling_rights,
        .en_passant_square = castle_state2.en_passant_square,
        .halfmove_clock = castle_state2.halfmove_clock,
    };
    movegen.makeMove(&castle_state2, e4move, &undo2);
    const after_e4_proper = perft(&castle_state2, 1);
    std.debug.print("After e2e4 (from legal list): d1={d} (expected 20)\n", .{after_e4_proper});
}
