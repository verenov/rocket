const std = @import("std");
const GameState = @import("../gamestate.zig").GameState;
const Piece = @import("../piece.zig").Piece;
const PieceKind = @import("../piece.zig").PieceKind;

pub const N_PIECE_TYPES: usize = 12;
pub const N_SQUARES: usize = 64;
pub const N_COLORS: usize = 2;
pub const N_KING_BUCKETS: usize = 32;
pub const INPUT_SIZE: usize = N_PIECE_TYPES * N_SQUARES * N_KING_BUCKETS;

pub const KING_BUCKETS = [64]i8{
    -1, -1, -1, -1, 31, 30, 29, 28,
    -1, -1, -1, -1, 27, 26, 25, 24,
    -1, -1, -1, -1, 23, 22, 21, 20,
    -1, -1, -1, -1, 19, 18, 17, 16,
    -1, -1, -1, -1, 15, 14, 13, 12,
    -1, -1, -1, -1, 11, 10, 9,  8,
    -1, -1, -1, -1, 7,  6,  5,  4,
    -1, -1, -1, -1, 3,  2,  1,  0,
};

pub const Feature = struct {
    index_white: usize,
    index_black: usize,
};

pub fn orient(is_white_pov: bool, sq: u8, ksq: u8) u8 {
    const kfile = ksq % 8;
    const mirror_file: u8 = if (kfile < 4) 7 else 0;
    const mirror_rank: u8 = if (!is_white_pov) 56 else 0;
    return mirror_file ^ mirror_rank ^ sq;
}

pub fn getKingBucket(ksq: u8) u8 {
    return @intCast(KING_BUCKETS[ksq]);
}

pub fn getPieceTypeIndex(piece_kind: PieceKind, piece_color: i8, is_white_pov: bool) u8 {
    const pt: u8 = @intFromEnum(piece_kind);
    const own_color: i8 = if (is_white_pov) 1 else 0;
    const color_bit: u8 = if (piece_color != own_color) 1 else 0;
    return pt * 2 + color_bit;
}

pub fn getFeatureIndex(
    piece_kind: PieceKind,
    piece_color: i8,
    square: u8,
    view: i8,
    king_square: u8,
) usize {
    const is_white_pov = view == 1;
    const oriented_sq = orient(is_white_pov, square, king_square);
    const oriented_ksq = orient(is_white_pov, king_square, king_square);
    const king_bucket = getKingBucket(oriented_ksq);
    const pt_idx = getPieceTypeIndex(piece_kind, piece_color, is_white_pov);

    return @as(usize, oriented_sq) +
        @as(usize, pt_idx) * 64 +
        @as(usize, king_bucket) * 768;
}

pub fn getFeature(
    state: *const GameState,
    piece_kind: PieceKind,
    piece_color: i8,
    square: u8,
) Feature {
    const white_king = findKing(state, 1) orelse return Feature{ .index_white = 0, .index_black = 0 };
    const black_king = findKing(state, 0) orelse return Feature{ .index_white = 0, .index_black = 0 };

    return Feature{
        .index_white = getFeatureIndex(piece_kind, piece_color, square, 1, white_king),
        .index_black = getFeatureIndex(piece_kind, piece_color, square, 0, black_king),
    };
}

pub fn getFeatureWithKings(
    piece_kind: PieceKind,
    piece_color: i8,
    square: u8,
    white_king: u8,
    black_king: u8,
) Feature {
    return Feature{
        .index_white = getFeatureIndex(piece_kind, piece_color, square, 1, white_king),
        .index_black = getFeatureIndex(piece_kind, piece_color, square, 0, black_king),
    };
}

pub fn findKing(state: *const GameState, color: i8) ?u8 {
    for (state.board.squares, 0..) |square, idx| {
        if (square.piece) |piece| {
            if (piece.kind == .King and piece.color == color) {
                return @intCast(idx);
            }
        }
    }
    return null;
}

pub fn getActiveFeatures(state: *const GameState, allocator: std.mem.Allocator) ![]Feature {
    var features_list = std.ArrayList(Feature).init(allocator);

    for (state.board.squares, 0..) |square, idx| {
        if (square.piece) |piece| {
            const feature = getFeature(state, piece.kind, piece.color, @intCast(idx));
            try features_list.append(feature);
        }
    }

    return features_list.toOwnedSlice();
}
