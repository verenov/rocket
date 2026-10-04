const std = @import("std");
const GameState = @import("src/gamestate.zig").GameState;
const movegen = @import("src/movegen.zig");

pub fn main() !void {
    const fen = "4k3/8/8/8/8/8/4q3/4K3 w - - 0 1";
    var state = try GameState.fromFen(fen);

    std.debug.print("White in check at start: {}\n", .{movegen.isInCheck(&state.board, 1)});

    const squares = [_]struct { name: []const u8, sq: u8 }{
        .{ .name = "d1", .sq = 59 },
        .{ .name = "d2", .sq = 51 },
        .{ .name = "e2", .sq = 52 },
        .{ .name = "f1", .sq = 61 },
        .{ .name = "f2", .sq = 62 },
    };

    for (squares) |s| {
        std.debug.print("Square {s} ({d}) attacked by black: {}\n", .{ s.name, s.sq, movegen.isSquareAttacked(&state.board, s.sq, 0) });
    }

    std.debug.print("\nE-file pieces:\n", .{});
    for (0..8) |rank| {
        const sq: u8 = @intCast(rank * 8 + 4);
        if (state.board.squares[sq].piece) |p| {
            std.debug.print("  rank {d} sq {d}: {s} {s}\n", .{ rank, sq, if (p.color == 1) "white" else "black", @tagName(p.kind) });
        }
    }

    // Manual ray trace from e2 along dir=-8
    var sq: i16 = 52 - 8;
    var dist: u8 = 1;
    std.debug.print("\nRay from e2 along -8:\n", .{});
    while (sq >= 0 and sq < 64 and dist < 8) : ({ sq -= 8; dist += 1; }) {
        const piece = state.board.squares[@intCast(sq)].piece;
        std.debug.print("  sq={d} dist={d} piece={?}\n", .{ sq, dist, piece });
        if (piece != null) break;
    }

    // f-file for castling
    std.debug.print("\nF-file pieces (castling position):\n", .{});
    const state2prep = try GameState.fromFen("rnbqkbnr/pppppppp/8/8/8/5r2/PPPPPPPP/RNBQK2R w KQkq - 0 1");
    for (0..8) |rank| {
        const f_sq: u8 = @intCast(rank * 8 + 5);
        if (state2prep.board.squares[f_sq].piece) |p| {
            std.debug.print("  rank {d} sq {d}: {s} {s}\n", .{ rank, f_sq, if (p.color == 1) "white" else "black", @tagName(p.kind) });
        }
    }
    sq = 61 - 8;
    dist = 1;
    std.debug.print("\nRay from f1 along -8:\n", .{});
    while (sq >= 0 and sq < 64 and dist < 8) : ({ sq -= 8; dist += 1; }) {
        const piece = state2prep.board.squares[@intCast(sq)].piece;
        std.debug.print("  sq={d} dist={d} piece={?}\n", .{ sq, dist, piece });
        if (piece != null) break;
    }

    // Simulate Ke2
    var moves = movegen.MoveList.init();
    movegen.generateLegalMoves(&state, &moves);
    std.debug.print("\nLegal moves ({d}):\n", .{moves.count});
    for (moves.moves[0..moves.count]) |move| {
        var buf: [6]u8 = undefined;
        std.debug.print("  {s}\n", .{move.toUci(&buf)});
    }

    // Castling test
    const fen2 = "rnbqkbnr/pppppppp/8/8/8/5r2/PPPPPPPP/RNBQK2R w KQkq - 0 1";
    var state2 = try GameState.fromFen(fen2);
    std.debug.print("\nCastling test - f1 attacked by black: {}\n", .{movegen.isSquareAttacked(&state2.board, 61, 0)});
    std.debug.print("e1 attacked: {}\n", .{movegen.isSquareAttacked(&state2.board, 60, 0)});
    std.debug.print("g1 attacked: {}\n", .{movegen.isSquareAttacked(&state2.board, 62, 0)});

    var moves2 = movegen.MoveList.init();
    movegen.generateLegalMoves(&state2, &moves2);
    for (moves2.moves[0..moves2.count]) |move| {
        if (move.is_castle) {
            std.debug.print("CASTLING MOVE GENERATED!\n", .{});
        }
    }
}
