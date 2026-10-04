const std = @import("std");
const Board = @import("board.zig").Board;
const Piece = @import("piece.zig").Piece;
const PieceKind = @import("piece.zig").PieceKind;
const loadFen = @import("board.zig").loadFen;

pub const CastlingRights = struct {
    white_kingside: bool = false,
    white_queenside: bool = false,
    black_kingside: bool = false,
    black_queenside: bool = false,

    pub fn fromFen(fen: []const u8) CastlingRights {
        var rights = CastlingRights{};
        for (fen) |c| {
            switch (c) {
                'K' => rights.white_kingside = true,
                'Q' => rights.white_queenside = true,
                'k' => rights.black_kingside = true,
                'q' => rights.black_queenside = true,
                '-' => break,
                else => break,
            }
        }
        return rights;
    }

    pub fn toFen(self: CastlingRights, buf: []u8) []const u8 {
        if (!self.white_kingside and !self.white_queenside and
            !self.black_kingside and !self.black_queenside)
        {
            buf[0] = '-';
            return buf[0..1];
        }

        var len: usize = 0;
        if (self.white_kingside) {
            buf[len] = 'K';
            len += 1;
        }
        if (self.white_queenside) {
            buf[len] = 'Q';
            len += 1;
        }
        if (self.black_kingside) {
            buf[len] = 'k';
            len += 1;
        }
        if (self.black_queenside) {
            buf[len] = 'q';
            len += 1;
        }
        return buf[0..len];
    }
};

pub const GameState = struct {
    board: Board,
    side_to_move: i8,
    castling_rights: CastlingRights,
    en_passant_square: ?u8,
    halfmove_clock: u16,
    fullmove_number: u16,
    king_squares: [2]u8,

    pub fn init() GameState {
        return GameState{
            .board = Board.init(),
            .side_to_move = 1,
            .castling_rights = CastlingRights{},
            .en_passant_square = null,
            .halfmove_clock = 0,
            .fullmove_number = 1,
            .king_squares = .{ 60, 4 },
        };
    }

    pub fn fromFen(fen: []const u8) !GameState {
        var state = GameState.init();

        var parts = std.mem.splitScalar(u8, fen, ' ');

        const board_fen = parts.next() orelse return error.InvalidFen;
        try loadFen(&state.board, board_fen);
        for (state.board.squares, 0..) |square, idx| {
            if (square.piece) |piece| {
                if (piece.kind == .King) {
                    state.king_squares[if (piece.color == 1) 0 else 1] = @intCast(idx);
                }
            }
        }

        const side_str = parts.next() orelse return error.InvalidFen;
        state.side_to_move = if (side_str[0] == 'w') @as(i8, 1) else @as(i8, 0);

        const castling_str = parts.next() orelse return error.InvalidFen;
        state.castling_rights = CastlingRights.fromFen(castling_str);

        const ep_str = parts.next() orelse return error.InvalidFen;
        if (ep_str[0] != '-') {
            state.en_passant_square = try parseSquare(ep_str);
        }

        if (parts.next()) |halfmove_str| {
            state.halfmove_clock = try std.fmt.parseInt(u16, halfmove_str, 10);
        }

        if (parts.next()) |fullmove_str| {
            state.fullmove_number = try std.fmt.parseInt(u16, fullmove_str, 10);
        }

        return state;
    }

    pub fn toFen(self: *const GameState, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);

        var rank: i8 = 0;
        while (rank < 8) : (rank += 1) {
            if (rank > 0) try result.append('/');

            var empty: u8 = 0;
            var file: u8 = 0;
            while (file < 8) : (file += 1) {
                const idx = @as(usize, @intCast(rank)) * 8 + file;
                if (self.board.squares[idx].piece) |p| {
                    if (empty > 0) {
                        try result.append('0' + empty);
                        empty = 0;
                    }
                    try result.append(p.print());
                } else {
                    empty += 1;
                }
            }
            if (empty > 0) {
                try result.append('0' + empty);
            }
        }

        try result.append(' ');
        try result.append(if (self.side_to_move == 1) 'w' else 'b');

        var castling_buf: [4]u8 = undefined;
        const castling = self.castling_rights.toFen(&castling_buf);
        try result.append(' ');
        try result.appendSlice(castling);

        if (self.en_passant_square) |ep| {
            const file = @as(u8, 'a') + (ep % 8);
            const rank_ = @as(u8, '1') + (7 - ep / 8);
            try result.append(' ');
            try result.append(file);
            try result.append(rank_);
        } else {
            try result.appendSlice(" -");
        }

        try result.append(' ');
        const halfmove_str = try std.fmt.allocPrint(allocator, "{d}", .{self.halfmove_clock});
        defer allocator.free(halfmove_str);
        try result.appendSlice(halfmove_str);

        try result.append(' ');
        const fullmove_str = try std.fmt.allocPrint(allocator, "{d}", .{self.fullmove_number});
        defer allocator.free(fullmove_str);
        try result.appendSlice(fullmove_str);

        return result.toOwnedSlice();
    }

    pub fn loadStart(self: *GameState) !void {
        const start_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        const loaded = try GameState.fromFen(start_fen);
        self.* = loaded;
    }
};

fn parseSquare(str: []const u8) !u8 {
    if (str.len < 2) return error.InvalidSquare;

    const file = str[0] - 'a';
    const rank = '8' - str[1];

    if (file >= 8 or rank >= 8) return error.InvalidSquare;

    return rank * 8 + file;
}

pub fn squareToAlgebraic(square: u8) [2]u8 {
    const file = @as(u8, 'a') + (square % 8);
    const rank = @as(u8, '1') + (7 - square / 8);
    return .{ file, rank };
}
