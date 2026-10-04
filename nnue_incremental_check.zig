const std = @import("std");
const GameState = @import("src/gamestate.zig").GameState;
const movegen = @import("src/movegen.zig");
const Network = @import("src/nnue/network.zig").Network;
const loader = @import("src/nnue/loader.zig");
const tt = @import("src/transposition.zig");

pub fn main() !void {
    var net = try Network.init(std.heap.page_allocator);
    defer net.deinit();
    try loader.loadFromFile(&net, "nnue/koivisto.bin");

    var state = GameState.init();
    try state.loadStart();
    var hash = tt.computeHash(&state);
    var ply: usize = 0;
    while (ply < 80) : (ply += 1) {
        net.initPosition(&state);
        var moves = movegen.MoveList.init();
        movegen.generateLegalMoves(&state, &moves);
        if (moves.count == 0) break;
        const move = moves.moves[(ply * 17 + 3) % moves.count];
        var undo = movegen.UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };
        const moving_piece = state.board.squares[move.from].piece.?;
        movegen.makeMove(&state, move, &undo);
        hash = tt.hashAfterMove(hash, &state, move, &undo, moving_piece);
        if (hash != tt.computeHash(&state)) return error.IncrementalHashMismatch;
        const captured = if (undo.captured_piece) |piece| piece.kind else null;
        net.pushAndUpdateForMove(&state, move, captured);
        const incremental = net.evaluate(&state);
        net.initPosition(&state);
        const refreshed = net.evaluate(&state);
        if (incremental != refreshed) {
            var buf: [6]u8 = undefined;
            std.debug.print("Mismatch ply {d} move {s}: incremental={d} refresh={d}\n", .{
                ply, move.toUci(&buf), incremental, refreshed,
            });
            return error.IncrementalMismatch;
        }
    }
    std.debug.print("NNUE incremental/full refresh matched for {d} plies\n", .{ply});
}
