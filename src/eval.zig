const std = @import("std");
const GameState = @import("gamestate.zig").GameState;
const Board = @import("board.zig").Board;
const Piece = @import("piece.zig").Piece;
const PieceKind = @import("piece.zig").PieceKind;

const nnue_network = @import("nnue/network.zig");
pub const NNUENetwork = nnue_network.Network;

pub const MATE_SCORE: i32 = 30000;
pub const DRAW_SCORE: i32 = 0;
pub const CHECKMATE: i32 = MATE_SCORE;
pub const STALEMATE: i32 = DRAW_SCORE;

const PIECE_VALUES = [_]i32{
    100,
    320,
    330,
    500,
    900,
    20000,
};

const PAWN_TABLE = [64]i32{
    0,  0,  0,   0,   0,   0,   0,  0,
    50, 50, 50,  50,  50,  50,  50, 50,
    10, 10, 20,  30,  30,  20,  10, 10,
    5,  5,  10,  25,  25,  10,  5,  5,
    0,  0,  0,   20,  20,  0,   0,  0,
    5,  -5, -10, 0,   0,   -10, -5, 5,
    5,  10, 10,  -20, -20, 10,  10, 5,
    0,  0,  0,   0,   0,   0,   0,  0,
};

const KNIGHT_TABLE = [64]i32{
    -50, -40, -30, -30, -30, -30, -40, -50,
    -40, -20, 0,   0,   0,   0,   -20, -40,
    -30, 0,   10,  15,  15,  10,  0,   -30,
    -30, 5,   15,  20,  20,  15,  5,   -30,
    -30, 0,   15,  20,  20,  15,  0,   -30,
    -30, 5,   10,  15,  15,  10,  5,   -30,
    -40, -20, 0,   5,   5,   0,   -20, -40,
    -50, -40, -30, -30, -30, -30, -40, -50,
};

const BISHOP_TABLE = [64]i32{
    -20, -10, -10, -10, -10, -10, -10, -20,
    -10, 0,   0,   0,   0,   0,   0,   -10,
    -10, 0,   5,   10,  10,  5,   0,   -10,
    -10, 5,   5,   10,  10,  5,   5,   -10,
    -10, 0,   10,  10,  10,  10,  0,   -10,
    -10, 10,  10,  10,  10,  10,  10,  -10,
    -10, 5,   0,   0,   0,   0,   5,   -10,
    -20, -10, -10, -10, -10, -10, -10, -20,
};

const ROOK_TABLE = [64]i32{
    0,  0,  0,  0,  0,  0,  0,  0,
    5,  10, 10, 10, 10, 10, 10, 5,
    -5, 0,  0,  0,  0,  0,  0,  -5,
    -5, 0,  0,  0,  0,  0,  0,  -5,
    -5, 0,  0,  0,  0,  0,  0,  -5,
    -5, 0,  0,  0,  0,  0,  0,  -5,
    -5, 0,  0,  0,  0,  0,  0,  -5,
    0,  0,  0,  5,  5,  0,  0,  0,
};

const QUEEN_TABLE = [64]i32{
    -20, -10, -10, -5, -5, -10, -10, -20,
    -10, 0,   0,   0,  0,  0,   0,   -10,
    -10, 0,   5,   5,  5,  5,   0,   -10,
    -5,  0,   5,   5,  5,  5,   0,   -5,
    0,   0,   5,   5,  5,  5,   0,   -5,
    -10, 5,   5,   5,  5,  5,   0,   -10,
    -10, 0,   5,   0,  0,  0,   0,   -10,
    -20, -10, -10, -5, -5, -10, -10, -20,
};

const KING_MIDDLE_GAME_TABLE = [64]i32{
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -30, -40, -40, -50, -50, -40, -40, -30,
    -20, -30, -30, -40, -40, -30, -30, -20,
    -10, -20, -20, -20, -20, -20, -20, -10,
    20,  20,  0,   0,   0,   0,   20,  20,
    20,  30,  10,  0,   0,   10,  30,  20,
};

const KING_END_GAME_TABLE = [64]i32{
    -50, -40, -30, -20, -20, -30, -40, -50,
    -30, -20, -10, 0,   0,   -10, -20, -30,
    -30, -10, 20,  30,  30,  20,  -10, -30,
    -30, -10, 30,  40,  40,  30,  -10, -30,
    -30, -10, 30,  40,  40,  30,  -10, -30,
    -30, -10, 20,  30,  30,  20,  -10, -30,
    -30, -30, 0,   0,   0,   0,   -30, -30,
    -50, -30, -30, -30, -30, -30, -30, -50,
};

fn getPieceSquareValue(piece: Piece, square: u8, is_endgame: bool) i32 {
    const sq = if (piece.color == 1) square else mirrorSquare(square);

    const value = switch (piece.kind) {
        .Pawn => PAWN_TABLE[sq],
        .Knight => KNIGHT_TABLE[sq],
        .Bishop => BISHOP_TABLE[sq],
        .Rook => ROOK_TABLE[sq],
        .Queen => QUEEN_TABLE[sq],
        .King => if (is_endgame) KING_END_GAME_TABLE[sq] else KING_MIDDLE_GAME_TABLE[sq],
    };

    return value;
}

inline fn mirrorSquare(square: u8) u8 {
    return square ^ 56;
}

pub fn getPieceValue(kind: PieceKind) i32 {
    return PIECE_VALUES[@intFromEnum(kind)];
}

fn isEndgame(state: *const GameState) bool {
    var queens: u8 = 0;
    var minors: u8 = 0;
    var rooks: u8 = 0;

    for (state.board.squares) |square| {
        if (square.piece) |p| {
            switch (p.kind) {
                .Queen => queens += 1,
                .Rook => rooks += 1,
                .Bishop, .Knight => minors += 1,
                else => {},
            }
        }
    }

    return queens == 0 or (queens <= 2 and minors <= 2);
}

pub fn evaluate(state: *const GameState) i32 {
    return evaluateClassical(state);
}

pub fn evaluateWithNNUE(state: *const GameState, network: ?*nnue_network.Network) i32 {
    if (network) |net| {
        if (net.isLoaded()) {
            return net.evaluate(state);
        }
    }
    return evaluateClassical(state);
}

pub fn evaluateClassical(state: *const GameState) i32 {
    var score: i32 = 0;
    const endgame = isEndgame(state);
    var pawn_files = [_][8]u8{[_]u8{0} ** 8} ** 2;
    var bishops = [_]u8{ 0, 0 };
    var queens = [_]u8{ 0, 0 };
    var king_squares = [_]?u8{ null, null };

    for (state.board.squares, 0..) |square, idx| {
        if (square.piece) |piece| {
            const material = getPieceValue(piece.kind);
            const positional = getPieceSquareValue(piece, @intCast(idx), endgame);

            const piece_score = material + positional;

            if (piece.color == 1) {
                score += piece_score;
            } else {
                score -= piece_score;
            }

            const color_idx: usize = if (piece.color == 1) 0 else 1;
            switch (piece.kind) {
                .Pawn => pawn_files[color_idx][idx % 8] += 1,
                .Bishop => bishops[color_idx] += 1,
                .Queen => queens[color_idx] += 1,
                .King => king_squares[color_idx] = @intCast(idx),
                else => {},
            }
        }
    }

    if (bishops[0] >= 2) score += 35;
    if (bishops[1] >= 2) score -= 35;

    for (state.board.squares, 0..) |square, idx| {
        const piece = square.piece orelse continue;
        if (piece.kind != .Pawn) continue;
        const color_idx: usize = if (piece.color == 1) 0 else 1;
        const enemy_idx: usize = 1 - color_idx;
        const file = idx % 8;
        const rank = idx / 8;
        const sign: i32 = if (piece.color == 1) 1 else -1;

        if (pawn_files[color_idx][file] > 1) score -= sign * 14;
        const left_empty = file == 0 or pawn_files[color_idx][file - 1] == 0;
        const right_empty = file == 7 or pawn_files[color_idx][file + 1] == 0;
        if (left_empty and right_empty) score -= sign * 12;

        var passed = true;
        const first_file = if (file == 0) file else file - 1;
        const last_file = @min(file + 1, 7);
        var scan_file = first_file;
        while (scan_file <= last_file) : (scan_file += 1) {
            var scan_rank: usize = if (piece.color == 1) 0 else rank + 1;
            const end_rank: usize = if (piece.color == 1) rank else 8;
            while (scan_rank < end_rank) : (scan_rank += 1) {
                const target = state.board.squares[scan_rank * 8 + scan_file].piece;
                if (target != null and target.?.color != piece.color and target.?.kind == .Pawn) {
                    passed = false;
                    break;
                }
            }
            if (!passed) break;
        }
        _ = enemy_idx;
        if (passed) {
            const advancement: i32 = @intCast(if (piece.color == 1) 6 - rank else rank - 1);
            score += sign * (18 + advancement * advancement * 7);
        }
    }

    for (state.board.squares, 0..) |square, idx| {
        const piece = square.piece orelse continue;
        if (piece.kind != .Rook) continue;
        const color_idx: usize = if (piece.color == 1) 0 else 1;
        const enemy_idx: usize = 1 - color_idx;
        const file = idx % 8;
        const sign: i32 = if (piece.color == 1) 1 else -1;
        if (pawn_files[color_idx][file] == 0) {
            score += sign * (if (pawn_files[enemy_idx][file] == 0) @as(i32, 24) else 12);
        }
    }

    for (0..2) |color_idx| {
        if (queens[1 - color_idx] == 0) continue;
        const king_sq = king_squares[color_idx] orelse continue;
        const king_rank: i16 = @intCast(king_sq / 8);
        const king_file: i16 = @intCast(king_sq % 8);
        const home_rank: i16 = if (color_idx == 0) 7 else 0;
        var safety: i32 = -@as(i32, @intCast(@abs(king_rank - home_rank))) * 18;
        const shield_rank = king_rank + (if (color_idx == 0) @as(i16, -1) else 1);
        if (shield_rank >= 0 and shield_rank < 8) {
            var df: i16 = -1;
            while (df <= 1) : (df += 1) {
                const f = king_file + df;
                if (f < 0 or f >= 8) continue;
                const shield = state.board.squares[@as(usize, @intCast(shield_rank * 8 + f))].piece;
                if (shield != null and shield.?.kind == .Pawn and
                    shield.?.color == (if (color_idx == 0) @as(i8, 1) else 0)) safety += 12 else safety -= 10;
            }
        }
        score += if (color_idx == 0) safety else -safety;
    }

    const tempo: i32 = 10;
    return if (state.side_to_move == 1) score + tempo else -score + tempo;
}

pub fn isMateScore(score: i32) bool {
    return @abs(score) >= MATE_SCORE - 1000;
}

pub fn movesToMate(score: i32) i32 {
    if (score > 0) {
        return @divTrunc((MATE_SCORE - score + 1), 2);
    } else {
        return -@divTrunc((MATE_SCORE + score + 1), 2);
    }
}

pub fn adjustMateScore(score: i32, ply: i32) i32 {
    if (score > MATE_SCORE - 1000) {
        return score - ply;
    } else if (score < -MATE_SCORE + 1000) {
        return score + ply;
    }
    return score;
}
