const ascii = @import("std").ascii;

pub const PieceKind = enum {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,

    fn print(self: PieceKind) u8 {
        return switch (self) {
            .Pawn => 'P',
            .Knight => 'N',
            .Bishop => 'B',
            .Rook => 'R',
            .Queen => 'Q',
            .King => 'K',
        };
    }
};

pub const Piece = struct {
    kind: PieceKind,
    color: i8,

    pub fn print(self: Piece) u8 {
        const kindChar = self.kind.print();
        return if (self.color == 1) kindChar else ascii.toLower(kindChar);
    }
};

pub fn makePiece(c: u8) Piece {
    const color = if (ascii.isLower(c)) @as(i8, 0) else @as(i8, 1);
    const kind = switch (ascii.toUpper(c)) {
        'P' => PieceKind.Pawn,
        'N' => PieceKind.Knight,
        'B' => PieceKind.Bishop,
        'R' => PieceKind.Rook,
        'Q' => PieceKind.Queen,
        'K' => PieceKind.King,
        else => @panic("unknown piece kind"),
    };
    return Piece{ .kind = kind, .color = color };
}
