const Piece = @import("piece.zig").Piece;

pub const Square = struct {
    rank: u8,
    file: u8,
    piece: ?Piece = null,

    pub fn print(self: Square) [2]u8 {
        return .{ self.rank, self.file };
    }
};
