const std = @import("std");
const Board = @import("board.zig").Board;
const Piece = @import("piece.zig").Piece;
const PieceKind = @import("piece.zig").PieceKind;
const Square = @import("square.zig").Square;
const GameState = @import("gamestate.zig").GameState;
const CastlingRights = @import("gamestate.zig").CastlingRights;
const bb = @import("bitboard.zig");

pub const Move = struct {
    from: u8,
    to: u8,
    promotion: ?PieceKind = null,
    is_capture: bool = false,
    is_en_passant: bool = false,
    is_castle: bool = false,

    pub fn format(self: Move, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        const from_file = @as(u8, 'a') + (self.from % 8);
        const from_rank = @as(u8, '1') + (7 - self.from / 8);
        const to_file = @as(u8, 'a') + (self.to % 8);
        const to_rank = @as(u8, '1') + (7 - self.to / 8);

        try writer.print("{c}{c}{c}{c}", .{ from_file, from_rank, to_file, to_rank });

        if (self.promotion) |promo| {
            const promo_char = switch (promo) {
                .Queen => 'q',
                .Rook => 'r',
                .Bishop => 'b',
                .Knight => 'n',
                else => unreachable,
            };
            try writer.print("{c}", .{promo_char});
        }
    }

    pub fn fromUci(uci: []const u8) !Move {
        if (uci.len < 4 or uci.len > 5) return error.InvalidMove;

        const from_file = uci[0] - 'a';
        const from_rank = '8' - uci[1];
        const to_file = uci[2] - 'a';
        const to_rank = '8' - uci[3];

        if (from_file >= 8 or from_rank >= 8 or to_file >= 8 or to_rank >= 8) {
            return error.InvalidMove;
        }

        const from = from_rank * 8 + from_file;
        const to = to_rank * 8 + to_file;

        var move = Move{ .from = from, .to = to };

        if (uci.len == 5) {
            move.promotion = switch (uci[4]) {
                'q' => .Queen,
                'r' => .Rook,
                'b' => .Bishop,
                'n' => .Knight,
                else => return error.InvalidPromotion,
            };
        }

        return move;
    }

    pub fn toUci(self: Move, buf: []u8) []const u8 {
        const from_file = @as(u8, 'a') + (self.from % 8);
        const from_rank = @as(u8, '1') + (7 - self.from / 8);
        const to_file = @as(u8, 'a') + (self.to % 8);
        const to_rank = @as(u8, '1') + (7 - self.to / 8);

        buf[0] = from_file;
        buf[1] = from_rank;
        buf[2] = to_file;
        buf[3] = to_rank;

        var len: usize = 4;

        if (self.promotion) |promo| {
            buf[4] = switch (promo) {
                .Queen => 'q',
                .Rook => 'r',
                .Bishop => 'b',
                .Knight => 'n',
                else => unreachable,
            };
            len = 5;
        }

        return buf[0..len];
    }

    pub fn equals(self: Move, other: Move) bool {
        return self.from == other.from and
            self.to == other.to and
            self.promotion == other.promotion;
    }
};

pub const MoveList = struct {
    moves: [256]Move,
    count: usize,

    pub fn init() MoveList {
        return MoveList{
            .moves = undefined,
            .count = 0,
        };
    }

    pub fn add(self: *MoveList, move: Move) void {
        self.moves[self.count] = move;
        self.count += 1;
    }

    pub fn clear(self: *MoveList) void {
        self.count = 0;
    }

    pub fn getSlice(self: *const MoveList) []const Move {
        return self.moves[0..self.count];
    }
};

pub fn resolveLegalMove(state: *const GameState, uci_move: Move) ?Move {
    var legal_moves = MoveList.init();
    generateLegalMoves(state, &legal_moves);
    for (legal_moves.moves[0..legal_moves.count]) |move| {
        if (move.equals(uci_move)) return move;
    }
    return null;
}

pub const UndoInfo = struct {
    captured_piece: ?Piece,
    castling_rights: CastlingRights,
    en_passant_square: ?u8,
    halfmove_clock: u16,
};

inline fn squareIndex(rank: u8, file: u8) u8 {
    return rank * 8 + file;
}

inline fn isValidSquare(rank: i16, file: i16) bool {
    return rank >= 0 and rank < 8 and file >= 0 and file < 8;
}

pub fn generateLegalMoves(state: *const GameState, moves: *MoveList) void {
    generatePseudoLegalMoves(state, moves);

    var write_idx: usize = 0;
    var read_idx: usize = 0;

    var temp_state = state.*;

    while (read_idx < moves.count) : (read_idx += 1) {
        const move = moves.moves[read_idx];

        var undo = UndoInfo{
            .captured_piece = null,
            .castling_rights = temp_state.castling_rights,
            .en_passant_square = temp_state.en_passant_square,
            .halfmove_clock = temp_state.halfmove_clock,
        };

        makeMove(&temp_state, move, &undo);
        const legal = !isInCheckState(&temp_state, 1 - temp_state.side_to_move);
        unmakeMove(&temp_state, move, &undo);

        if (legal) {
            if (write_idx != read_idx) {
                moves.moves[write_idx] = move;
            }
            write_idx += 1;
        }
    }

    moves.count = write_idx;
}

pub fn generatePseudoLegalMoves(state: *const GameState, moves: *MoveList) void {
    generateMoves(state, state.side_to_move, moves, false);
}

pub fn generateNoisyMoves(state: *const GameState, moves: *MoveList) void {
    generateMoves(state, state.side_to_move, moves, true);
}

fn generateMoves(state: *const GameState, color: i8, moves: *MoveList, noisy_only: bool) void {
    moves.clear();

    var pieces = state.board.colors[Board.colorIndex(color)];
    while (pieces != 0) {
        const from = bb.popLsb(&pieces);
        switch (state.board.squares[from].piece.?.kind) {
            .Pawn => generatePawnMoves(state, from, color, moves, noisy_only),
            .Knight => generateKnightMoves(&state.board, from, color, moves, noisy_only),
            .Bishop => generateBishopMoves(&state.board, from, color, moves, noisy_only),
            .Rook => generateRookMoves(&state.board, from, color, moves, noisy_only),
            .Queen => generateQueenMoves(&state.board, from, color, moves, noisy_only),
            .King => generateKingMoves(state, from, color, moves, noisy_only),
        }
    }
}

fn generatePawnMoves(state: *const GameState, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    const rank = from / 8;
    const file = from % 8;
    const enemy = state.board.colors[Board.colorIndex(1 - color)];

    const direction: i16 = if (color == 1) -1 else 1;
    const start_rank: u8 = if (color == 1) 6 else 1;
    const promotion_rank: u8 = if (color == 1) 0 else 7;

    const new_rank: i16 = @as(i16, rank) + direction;
    if (isValidSquare(new_rank, file)) {
        const to = squareIndex(@intCast(new_rank), file);
        if (state.board.occupied & bb.bit(to) == 0 and (!noisy_only or new_rank == promotion_rank)) {
            if (new_rank == promotion_rank) {
                moves.add(.{ .from = from, .to = to, .promotion = .Queen });
                moves.add(.{ .from = from, .to = to, .promotion = .Rook });
                moves.add(.{ .from = from, .to = to, .promotion = .Bishop });
                moves.add(.{ .from = from, .to = to, .promotion = .Knight });
            } else {
                moves.add(.{ .from = from, .to = to });
            }

            if (!noisy_only and rank == start_rank) {
                const double_rank: i16 = new_rank + direction;
                const double_to = squareIndex(@intCast(double_rank), file);
                if (state.board.occupied & bb.bit(double_to) == 0) {
                    moves.add(.{ .from = from, .to = double_to });
                }
            }
        }
    }

    var captures = bb.PAWN_ATTACKS[@intCast(color)][from];
    if (state.en_passant_square) |ep| captures &= enemy | bb.bit(ep) else captures &= enemy;
    while (captures != 0) {
        const to = bb.popLsb(&captures);
        const is_ep = state.en_passant_square != null and to == state.en_passant_square.? and enemy & bb.bit(to) == 0;
        if (new_rank == promotion_rank) {
            moves.add(.{ .from = from, .to = to, .promotion = .Queen, .is_capture = true });
            moves.add(.{ .from = from, .to = to, .promotion = .Rook, .is_capture = true });
            moves.add(.{ .from = from, .to = to, .promotion = .Bishop, .is_capture = true });
            moves.add(.{ .from = from, .to = to, .promotion = .Knight, .is_capture = true });
        } else {
            moves.add(.{ .from = from, .to = to, .is_capture = true, .is_en_passant = is_ep });
        }
    }
}

fn generateKnightMoves(board: *const Board, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    emitTargets(board, from, color, bb.KNIGHT_ATTACKS[from], moves, noisy_only);
}

inline fn emitTargets(board: *const Board, from: u8, color: i8, attacks: bb.Bitboard, moves: *MoveList, noisy_only: bool) void {
    const own = board.colors[Board.colorIndex(color)];
    const enemy = board.colors[Board.colorIndex(1 - color)];
    var targets = attacks & ~own;
    if (noisy_only) targets &= enemy;
    while (targets != 0) {
        const to = bb.popLsb(&targets);
        moves.add(.{ .from = from, .to = to, .is_capture = enemy & bb.bit(to) != 0 });
    }
}

fn generateBishopMoves(board: *const Board, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    emitTargets(board, from, color, bb.bishopAttacks(from, board.occupied), moves, noisy_only);
}

fn generateRookMoves(board: *const Board, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    emitTargets(board, from, color, bb.rookAttacks(from, board.occupied), moves, noisy_only);
}

fn generateQueenMoves(board: *const Board, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    emitTargets(board, from, color, bb.queenAttacks(from, board.occupied), moves, noisy_only);
}

fn generateKingMoves(state: *const GameState, from: u8, color: i8, moves: *MoveList, noisy_only: bool) void {
    emitTargets(&state.board, from, color, bb.KING_ATTACKS[from], moves, noisy_only);

    if (noisy_only) return;

    if (color == 1) {
        if (state.castling_rights.white_kingside) {
            if (hasPiece(&state.board, 60, .King, 1) and
                hasPiece(&state.board, 63, .Rook, 1) and
                state.board.squares[61].piece == null and
                state.board.squares[62].piece == null and
                !isSquareAttacked(&state.board, 60, 0) and
                !isSquareAttacked(&state.board, 61, 0) and
                !isSquareAttacked(&state.board, 62, 0))
            {
                moves.add(.{ .from = 60, .to = 62, .is_castle = true });
            }
        }
        if (state.castling_rights.white_queenside) {
            if (hasPiece(&state.board, 60, .King, 1) and
                hasPiece(&state.board, 56, .Rook, 1) and
                state.board.squares[59].piece == null and
                state.board.squares[58].piece == null and
                state.board.squares[57].piece == null and
                !isSquareAttacked(&state.board, 60, 0) and
                !isSquareAttacked(&state.board, 59, 0) and
                !isSquareAttacked(&state.board, 58, 0))
            {
                moves.add(.{ .from = 60, .to = 58, .is_castle = true });
            }
        }
    } else {
        if (state.castling_rights.black_kingside) {
            if (hasPiece(&state.board, 4, .King, 0) and
                hasPiece(&state.board, 7, .Rook, 0) and
                state.board.squares[5].piece == null and
                state.board.squares[6].piece == null and
                !isSquareAttacked(&state.board, 4, 1) and
                !isSquareAttacked(&state.board, 5, 1) and
                !isSquareAttacked(&state.board, 6, 1))
            {
                moves.add(.{ .from = 4, .to = 6, .is_castle = true });
            }
        }
        if (state.castling_rights.black_queenside) {
            if (hasPiece(&state.board, 4, .King, 0) and
                hasPiece(&state.board, 0, .Rook, 0) and
                state.board.squares[3].piece == null and
                state.board.squares[2].piece == null and
                state.board.squares[1].piece == null and
                !isSquareAttacked(&state.board, 4, 1) and
                !isSquareAttacked(&state.board, 3, 1) and
                !isSquareAttacked(&state.board, 2, 1))
            {
                moves.add(.{ .from = 4, .to = 2, .is_castle = true });
            }
        }
    }
}

fn hasPiece(board: *const Board, square: u8, kind: PieceKind, color: i8) bool {
    const piece = board.squares[square].piece orelse return false;
    return piece.kind == kind and piece.color == color;
}

pub fn makeMove(state: *GameState, move: Move, undo: *UndoInfo) void {
    const moving_piece = state.board.takePiece(move.from).?;
    undo.captured_piece = state.board.takePiece(move.to);
    const placed_piece = if (move.promotion) |promo|
        Piece{ .kind = promo, .color = moving_piece.color }
    else
        moving_piece;
    state.board.putPiece(move.to, placed_piece);

    if (move.is_en_passant) {
        const captured_pawn_square = if (moving_piece.color == 1)
            move.to + 8
        else
            move.to - 8;
        undo.captured_piece = state.board.takePiece(captured_pawn_square);
    }

    if (move.is_castle) {
        if (move.to == 62) {
            state.board.putPiece(61, state.board.takePiece(63).?);
        } else if (move.to == 58) {
            state.board.putPiece(59, state.board.takePiece(56).?);
        } else if (move.to == 6) {
            state.board.putPiece(5, state.board.takePiece(7).?);
        } else if (move.to == 2) {
            state.board.putPiece(3, state.board.takePiece(0).?);
        }
    }

    state.en_passant_square = null;
    if (moving_piece.kind == .Pawn) {
        const from_rank = move.from / 8;
        const to_rank = move.to / 8;
        if (@abs(@as(i16, to_rank) - @as(i16, from_rank)) == 2) {
            state.en_passant_square = if (moving_piece.color == 1)
                move.from - 8
            else
                move.from + 8;
        }
    }

    if (moving_piece.kind == .King) {
        state.king_squares[if (moving_piece.color == 1) 0 else 1] = move.to;
        if (moving_piece.color == 1) {
            state.castling_rights.white_kingside = false;
            state.castling_rights.white_queenside = false;
        } else {
            state.castling_rights.black_kingside = false;
            state.castling_rights.black_queenside = false;
        }
    }

    if (moving_piece.kind == .Rook) {
        if (move.from == 63) state.castling_rights.white_kingside = false;
        if (move.from == 56) state.castling_rights.white_queenside = false;
        if (move.from == 7) state.castling_rights.black_kingside = false;
        if (move.from == 0) state.castling_rights.black_queenside = false;
    }

    if (move.to == 63) state.castling_rights.white_kingside = false;
    if (move.to == 56) state.castling_rights.white_queenside = false;
    if (move.to == 7) state.castling_rights.black_kingside = false;
    if (move.to == 0) state.castling_rights.black_queenside = false;

    if (move.is_capture or moving_piece.kind == .Pawn) {
        state.halfmove_clock = 0;
    } else {
        state.halfmove_clock += 1;
    }

    if (state.side_to_move == 0) {
        state.fullmove_number += 1;
    }

    state.side_to_move = 1 - state.side_to_move;
}

pub fn unmakeMove(state: *GameState, move: Move, undo: *const UndoInfo) void {
    state.side_to_move = 1 - state.side_to_move;

    if (state.side_to_move == 0) {
        state.fullmove_number -= 1;
    }

    state.castling_rights = undo.castling_rights;
    state.en_passant_square = undo.en_passant_square;
    state.halfmove_clock = undo.halfmove_clock;

    const moving_piece = state.board.takePiece(move.to).?;
    const restored_piece = if (move.promotion != null)
        Piece{ .kind = .Pawn, .color = moving_piece.color }
    else
        moving_piece;
    state.board.putPiece(move.from, restored_piece);

    if (moving_piece.kind == .King) {
        state.king_squares[if (moving_piece.color == 1) 0 else 1] = move.from;
    }

    if (move.is_en_passant) {
        const captured_pawn_square = if (moving_piece.color == 1)
            move.to + 8
        else
            move.to - 8;
        if (undo.captured_piece) |captured| state.board.putPiece(captured_pawn_square, captured);
    } else if (undo.captured_piece) |captured| {
        state.board.putPiece(move.to, captured);
    }

    if (move.is_castle) {
        if (move.to == 62) {
            state.board.putPiece(63, state.board.takePiece(61).?);
        } else if (move.to == 58) {
            state.board.putPiece(56, state.board.takePiece(59).?);
        } else if (move.to == 6) {
            state.board.putPiece(7, state.board.takePiece(5).?);
        } else if (move.to == 2) {
            state.board.putPiece(0, state.board.takePiece(3).?);
        }
    }
}

pub inline fn isSquareAttacked(board: *const Board, square: u8, by_color: i8) bool {
    const pawns = board.pieceBits(.Pawn, by_color);
    const knights = board.pieceBits(.Knight, by_color);
    const bishops_queens = board.pieceBits(.Bishop, by_color) | board.pieceBits(.Queen, by_color);
    const rooks_queens = board.pieceBits(.Rook, by_color) | board.pieceBits(.Queen, by_color);
    const king = board.pieceBits(.King, by_color);
    const color_idx: usize = if (by_color == 1) 1 else 0;

    if (bb.PAWN_ATTACKS[1 - color_idx][square] & pawns != 0) return true;
    if (bb.KNIGHT_ATTACKS[square] & knights != 0) return true;
    if (bb.KING_ATTACKS[square] & king != 0) return true;
    if (bb.bishopAttacks(square, board.occupied) & bishops_queens != 0) return true;
    if (bb.rookAttacks(square, board.occupied) & rooks_queens != 0) return true;
    return false;
}

pub inline fn isInCheck(board: *const Board, color: i8) bool {
    var king_square: u8 = 0;
    for (board.squares, 0..) |square, idx| {
        if (square.piece) |p| {
            if (p.color == color and p.kind == .King) {
                king_square = @intCast(idx);
                return isSquareAttacked(board, king_square, 1 - color);
            }
        }
    }
    return false;
}

pub inline fn isInCheckState(state: *const GameState, color: i8) bool {
    const king_square = state.king_squares[if (color == 1) 0 else 1];
    return isSquareAttacked(&state.board, king_square, 1 - color);
}
