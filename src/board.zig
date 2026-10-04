const std = @import("std");
const piece = @import("piece.zig");
const ascii = std.ascii;

const Piece = piece.Piece;
const PieceKind = piece.PieceKind;
const Square = @import("square.zig").Square;
const Bitboard = @import("bitboard.zig").Bitboard;
const bb = @import("bitboard.zig");

pub const Board = struct {
    squares: [64]Square,
    pieces: [2][6]Bitboard,
    colors: [2]Bitboard,
    occupied: Bitboard,

    pub inline fn init() Board {
        return Board{
            .squares = undefined,
            .pieces = [_][6]Bitboard{[_]Bitboard{0} ** 6} ** 2,
            .colors = .{ 0, 0 },
            .occupied = 0,
        };
    }

    pub inline fn colorIndex(color: i8) usize {
        return if (color == 1) 0 else 1;
    }

    pub inline fn pieceBits(self: *const Board, kind: PieceKind, color: i8) Bitboard {
        return self.pieces[colorIndex(color)][@intFromEnum(kind)];
    }

    fn addBits(self: *Board, square: u8, p: Piece) void {
        const mask = bb.bit(square);
        const color_idx = colorIndex(p.color);
        self.pieces[color_idx][@intFromEnum(p.kind)] |= mask;
        self.colors[color_idx] |= mask;
        self.occupied |= mask;
    }

    fn removeBits(self: *Board, square: u8, p: Piece) void {
        const mask = ~bb.bit(square);
        const color_idx = colorIndex(p.color);
        self.pieces[color_idx][@intFromEnum(p.kind)] &= mask;
        self.colors[color_idx] &= mask;
        self.occupied &= mask;
    }

    pub fn takePiece(self: *Board, square: u8) ?Piece {
        const p = self.squares[square].piece orelse return null;
        self.removeBits(square, p);
        self.squares[square].piece = null;
        return p;
    }

    pub fn putPiece(self: *Board, square: u8, p: Piece) void {
        if (self.squares[square].piece) |old| self.removeBits(square, old);
        self.squares[square].piece = p;
        self.addBits(square, p);
    }
};

const START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";

pub fn loadFen(self: *Board, fen: []const u8) !void {
    self.pieces = [_][6]Bitboard{[_]Bitboard{0} ** 6} ** 2;
    self.colors = .{ 0, 0 };
    self.occupied = 0;
    var rank: u8 = 0;
    var file: u8 = 0;

    for (fen) |c| {
        if (c == ' ') break;
        switch (c) {
            '/' => {
                rank += 1;
                file = 0;
            },
            '1'...'8' => {
                const empty = c - '0';
                for (0..empty) |_| {
                    const index = @as(usize, rank) * 8 + file;

                    self.squares[index] = Square{
                        .rank = rank,
                        .file = file,
                        .piece = null,
                    };

                    file += 1;
                }
            },
            else => {
                const index: usize = @as(usize, rank) * 8 + file;
                const p = piece.makePiece(c);
                self.squares[index] = Square{ .rank = rank, .file = file, .piece = p };
                self.addBits(@intCast(index), p);
                file += 1;
            },
        }
    }
}

pub inline fn loadStart(self: *Board) !void {
    try loadFen(self, START_FEN);
}

pub fn print(self: *Board, flipped: bool) void {
    if (!flipped) {
        for (0..8) |rank| {
            std.debug.print("\n", .{});

            for (0..8) |file| {
                const sq = self.squares[rank * 8 + file];

                if (sq.piece) |p| {
                    std.debug.print(" {c} ", .{p.print()});
                } else {
                    std.debug.print(" . ", .{});
                }
            }
        }
    } else {
        var rank: i8 = 7;
        while (rank >= 0) : (rank -= 1) {
            std.debug.print("\n", .{});

            var file: i8 = 7;
            while (file >= 0) : (file -= 1) {
                const index: usize = @intCast(rank * 8 + file);
                const sq = self.squares[index];

                if (sq.piece) |p| {
                    std.debug.print(" {c} ", .{p.print()});
                } else {
                    std.debug.print(" . ", .{});
                }
            }
        }
    }

    std.debug.print("\n", .{});
}
