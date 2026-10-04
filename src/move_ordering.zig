const std = @import("std");
const Move = @import("movegen.zig").Move;
const MoveList = @import("movegen.zig").MoveList;
const PieceKind = @import("piece.zig").PieceKind;
const Piece = @import("piece.zig").Piece;
const GameState = @import("gamestate.zig").GameState;
const eval = @import("eval.zig");

const MVV_LVA_TABLE = blk: {
    var table: [6][6]i32 = undefined;
    const values = [6]i32{ 1, 3, 3, 5, 9, 0 };

    var victim = 0;
    while (victim < 6) : (victim += 1) {
        var attacker = 0;
        while (attacker < 6) : (attacker += 1) {
            table[victim][attacker] = values[victim] * 10 - values[attacker];
        }
    }

    break :blk table;
};

pub const KillerMoves = struct {
    moves: [2][128]?Move,

    pub fn init() KillerMoves {
        return KillerMoves{
            .moves = [_][128]?Move{[_]?Move{null} ** 128} ** 2,
        };
    }

    pub fn store(self: *KillerMoves, move: Move, ply: usize) void {
        if (ply >= 128) return;

        if (self.moves[0][ply]) |first| {
            if (first.from == move.from and first.to == move.to) return;
        }

        self.moves[1][ply] = self.moves[0][ply];
        self.moves[0][ply] = move;
    }

    pub fn isKiller(self: *const KillerMoves, move: Move, ply: usize) bool {
        if (ply >= 128) return false;

        for (self.moves) |slot| {
            if (slot[ply]) |killer| {
                if (killer.from == move.from and killer.to == move.to) {
                    return true;
                }
            }
        }
        return false;
    }

    pub fn clear(self: *KillerMoves) void {
        for (&self.moves) |*slot| {
            for (slot) |*move| {
                move.* = null;
            }
        }
    }
};

pub const HistoryTable = struct {
    scores: [64][64]i32,

    pub fn init() HistoryTable {
        return HistoryTable{
            .scores = [_][64]i32{[_]i32{0} ** 64} ** 64,
        };
    }

    pub fn update(self: *HistoryTable, move: Move, depth: i32) void {
        self.scores[move.from][move.to] += depth * depth;

        if (self.scores[move.from][move.to] > 10000) {
            self.scores[move.from][move.to] = 10000;
        }
    }

    pub fn getScore(self: *const HistoryTable, move: Move) i32 {
        return self.scores[move.from][move.to];
    }

    pub fn clear(self: *HistoryTable) void {
        for (&self.scores) |*row| {
            for (row) |*score| {
                score.* = 0;
            }
        }
    }

    pub fn age(self: *HistoryTable) void {
        for (&self.scores) |*row| {
            for (row) |*score| {
                score.* /= 2;
            }
        }
    }
};

pub const ScoredMove = struct {
    move: Move,
    score: i32,
};

pub const MoveOrderer = struct {
    killers: KillerMoves,
    history: HistoryTable,

    pub fn init() MoveOrderer {
        return MoveOrderer{
            .killers = KillerMoves.init(),
            .history = HistoryTable.init(),
        };
    }

    pub fn clear(self: *MoveOrderer) void {
        self.killers.clear();
        self.history.clear();
    }

    pub fn ageHistory(self: *MoveOrderer) void {
        self.history.age();
    }

    pub fn scoreMove(
        self: *const MoveOrderer,
        state: *const GameState,
        move: Move,
        ply: usize,
        hash_move: ?Move,
    ) i32 {
        if (hash_move) |hm| {
            if (move.from == hm.from and move.to == hm.to and
                move.promotion == hm.promotion)
            {
                return 1000000;
            }
        }

        if (move.is_capture) {
            const victim = if (move.is_en_passant)
                PieceKind.Pawn
            else
                state.board.squares[move.to].piece.?.kind;

            const attacker = state.board.squares[move.from].piece.?.kind;

            const mvv_lva = MVV_LVA_TABLE[@intFromEnum(victim)][@intFromEnum(attacker)];
            return 900000 + mvv_lva * 100;
        }

        if (move.promotion) |promo| {
            const promo_value = eval.getPieceValue(promo);
            return 800000 + promo_value;
        }

        if (self.killers.isKiller(move, ply)) {
            return 700000;
        }

        return self.history.getScore(move);
    }

    pub fn orderMoves(
        self: *const MoveOrderer,
        state: *const GameState,
        moves: *MoveList,
        ply: usize,
        hash_move: ?Move,
    ) void {
        if (moves.count <= 1) return;

        var scored: [256]ScoredMove = undefined;
        for (moves.moves[0..moves.count], 0..) |move, i| {
            scored[i] = ScoredMove{
                .move = move,
                .score = self.scoreMove(state, move, ply, hash_move),
            };
        }

        const slice = scored[0..moves.count];
        std.sort.pdq(ScoredMove, slice, {}, compareScoredMoves);

        for (slice, 0..) |sm, i| {
            moves.moves[i] = sm.move;
        }
    }

    pub fn pickNextMove(
        self: *const MoveOrderer,
        state: *const GameState,
        moves: *MoveList,
        start_index: usize,
        ply: usize,
        hash_move: ?Move,
    ) usize {
        if (start_index >= moves.count) return start_index;

        var best_index = start_index;
        var best_score = self.scoreMove(state, moves.moves[start_index], ply, hash_move);

        var i = start_index + 1;
        while (i < moves.count) : (i += 1) {
            const score = self.scoreMove(state, moves.moves[i], ply, hash_move);
            if (score > best_score) {
                best_score = score;
                best_index = i;
            }
        }

        if (best_index != start_index) {
            const temp = moves.moves[start_index];
            moves.moves[start_index] = moves.moves[best_index];
            moves.moves[best_index] = temp;
        }

        return start_index;
    }
};

fn compareScoredMoves(_: void, a: ScoredMove, b: ScoredMove) bool {
    return a.score > b.score;
}
