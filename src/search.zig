const std = @import("std");
const GameState = @import("gamestate.zig").GameState;
const Move = @import("movegen.zig").Move;
const MoveList = @import("movegen.zig").MoveList;
const UndoInfo = @import("movegen.zig").UndoInfo;
const movegen = @import("movegen.zig");
const eval = @import("eval.zig");
const TranspositionTable = @import("transposition.zig").TranspositionTable;
const TTEntry = @import("transposition.zig").TTEntry;
const EntryType = @import("transposition.zig").EntryType;
const zobrist = @import("zobrist.zig");
const computeHash = @import("transposition.zig").computeHash;
const hashAfterMove = @import("transposition.zig").hashAfterMove;
const hashAfterNull = @import("transposition.zig").hashAfterNull;
const nnue = @import("nnue.zig");

pub const MAX_DEPTH: i32 = 64;
pub const MAX_PLY: usize = 128;
pub const MATE_SCORE: i32 = 30000;
pub const INFINITY: i32 = 32000;
const ASPIRATION_WINDOW: i32 = 50;
const MAX_THREADS: usize = 256;

const NULL_MOVE_REDUCTION: i32 = 3;
const NULL_MOVE_MIN_DEPTH: i32 = 3;

const LMR_MIN_DEPTH: i32 = 2;
const LMR_MIN_MOVES: usize = 2;
const LMR_REDUCTIONS = makeLMRTable();

const FUTILITY_MARGINS = [_]i32{ 0, 250, 400, 600, 850, 1100, 1400, 1700, 2000 };
const FUTILITY_DEPTH: i32 = 2;

const RAZOR_MARGINS = [_]i32{ 0, 500, 700, 900 };
const RAZOR_DEPTH: i32 = 3;

const RFP_MARGIN: i32 = 110;
const RFP_MAX_DEPTH: i32 = 6;

const LATE_MOVE_PRUNING = [_]usize{ 0, 4, 8, 14, 24 };

const KillerMoves = struct {
    moves: [MAX_PLY][2]Move,

    pub fn init() KillerMoves {
        return KillerMoves{
            .moves = [_][2]Move{[_]Move{Move{ .from = 0, .to = 0 }} ** 2} ** MAX_PLY,
        };
    }

    pub fn store(self: *KillerMoves, ply: usize, move: Move) void {
        if (ply >= MAX_PLY) return;
        if (!move.equals(self.moves[ply][0])) {
            self.moves[ply][1] = self.moves[ply][0];
            self.moves[ply][0] = move;
        }
    }

    pub fn isKiller(self: *const KillerMoves, ply: usize, move: Move) bool {
        if (ply >= MAX_PLY) return false;
        return move.equals(self.moves[ply][0]) or move.equals(self.moves[ply][1]);
    }
};

const History = struct {
    scores: [2][64][64]i32,
    const MAX_SCORE: i32 = 16_384;

    pub fn init() History {
        return History{
            .scores = [_][64][64]i32{[_][64]i32{[_]i32{0} ** 64} ** 64} ** 2,
        };
    }

    pub fn update(self: *History, side: i8, move: Move, depth: i32) void {
        self.applyBonus(side, move, @min(depth * depth, 400));
    }

    pub fn penalize(self: *History, side: i8, move: Move, depth: i32) void {
        self.applyBonus(side, move, -@min(depth * depth, 400));
    }

    fn applyBonus(self: *History, side: i8, move: Move, bonus: i32) void {
        const color_idx: usize = if (side == 1) 0 else 1;
        const score = &self.scores[color_idx][move.from][move.to];
        const abs_bonus: i32 = @intCast(@abs(bonus));
        score.* += bonus - @divTrunc(score.* * abs_bonus, MAX_SCORE);
    }

    pub fn getScore(self: *const History, side: i8, move: Move) i32 {
        const color_idx: usize = if (side == 1) 0 else 1;
        return self.scores[color_idx][move.from][move.to];
    }

    pub fn age(self: *History) void {
        for (0..2) |c| {
            for (0..64) |f| {
                for (0..64) |t| {
                    self.scores[c][f][t] = @divTrunc(self.scores[c][f][t], 2);
                }
            }
        }
    }

    pub fn clear(self: *History) void {
        self.* = History.init();
    }
};

const CountermoveHistory = struct {
    table: [2][64][64]Move,

    pub fn init() CountermoveHistory {
        return CountermoveHistory{
            .table = [_][64][64]Move{[_][64]Move{[_]Move{Move{ .from = 0, .to = 0 }} ** 64} ** 64} ** 2,
        };
    }

    pub fn store(self: *CountermoveHistory, side: i8, prev_move: Move, counter_move: Move) void {
        const color_idx: usize = if (side == 1) 0 else 1;
        self.table[color_idx][prev_move.from][prev_move.to] = counter_move;
    }

    pub fn get(self: *const CountermoveHistory, side: i8, prev_move: Move) ?Move {
        const color_idx: usize = if (side == 1) 0 else 1;
        const move = self.table[color_idx][prev_move.from][prev_move.to];
        if (move.from == 0 and move.to == 0) return null;
        return move;
    }

    pub fn clear(self: *CountermoveHistory) void {
        self.* = CountermoveHistory.init();
    }
};

const ContinuationHistory = struct {
    table: [2][64][64]i32,

    pub fn init() ContinuationHistory {
        return ContinuationHistory{
            .table = [_][64][64]i32{[_][64]i32{[_]i32{0} ** 64} ** 64} ** 2,
        };
    }

    pub fn update(self: *ContinuationHistory, side: i8, move: Move, bonus: i32) void {
        const color_idx: usize = if (side == 1) 0 else 1;
        self.table[color_idx][move.from][move.to] += bonus;
    }

    pub fn get(self: *const ContinuationHistory, side: i8, move: Move) i32 {
        const color_idx: usize = if (side == 1) 0 else 1;
        return self.table[color_idx][move.from][move.to];
    }

    pub fn clear(self: *ContinuationHistory) void {
        self.* = ContinuationHistory.init();
    }
};

pub const SearchLimits = struct {
    max_time_ms: u64 = std.math.maxInt(u64),
    start_time: i64 = 0,
    max_depth: i32 = MAX_DEPTH,
    max_nodes: u64 = std.math.maxInt(u64),
    infinite: bool = false,

    pondering: ?*const std.atomic.Value(bool) = null,
    ponder_hit_time_ms: ?*const std.atomic.Value(i64) = null,
};

pub const SearchStats = struct {
    nodes: u64 = 0,
    qnodes: u64 = 0,
    tb_hits: u64 = 0,
    tt_hits: u64 = 0,
    nps: u64 = 0,
    seldepth: i32 = 0,
};

pub const PrincipalVariation = struct {
    moves: [MAX_PLY]Move,
    length: usize,

    pub fn init() PrincipalVariation {
        return PrincipalVariation{
            .moves = [_]Move{Move{ .from = 0, .to = 0 }} ** MAX_PLY,
            .length = 0,
        };
    }

    pub fn clear(self: *PrincipalVariation) void {
        self.length = 0;
    }

    pub fn update(self: *PrincipalVariation, move: Move, child_pv: *const PrincipalVariation) void {
        self.moves[0] = move;
        self.length = 1;

        if (child_pv.length > 0) {
            const copy_len = @min(child_pv.length, MAX_PLY - 1);
            @memcpy(self.moves[1 .. 1 + copy_len], child_pv.moves[0..copy_len]);
            self.length += copy_len;
        }
    }
};

pub const SearchThread = struct {
    id: usize,
    state: GameState,
    killers: KillerMoves,
    history: History,
    counter_moves: CountermoveHistory,
    prev_move: ?Move,
    pv: PrincipalVariation,
    stats: SearchStats,
    ply: usize,
    root_depth: i32,
    hash_stack: [MAX_PLY]u64,

    tt: *TranspositionTable,
    stop_flag: *std.atomic.Value(bool),
    nnue: ?*nnue.Network,

    node_counters: ?[]std.atomic.Value(u64),

    pub fn init(id: usize, state: GameState, tt: *TranspositionTable, stop_flag: *std.atomic.Value(bool)) SearchThread {
        var hashes = [_]u64{0} ** MAX_PLY;
        hashes[0] = computeHash(&state);
        return SearchThread{
            .id = id,
            .state = state,
            .killers = KillerMoves.init(),
            .history = History.init(),
            .counter_moves = CountermoveHistory.init(),
            .prev_move = null,
            .pv = PrincipalVariation.init(),
            .stats = SearchStats{},
            .ply = 0,
            .root_depth = 0,
            .hash_stack = hashes,
            .tt = tt,
            .stop_flag = stop_flag,
            .nnue = null,
            .node_counters = null,
        };
    }

    inline fn localNodes(self: *const SearchThread) u64 {
        return self.stats.nodes + self.stats.qnodes;
    }

    fn publishNodes(self: *SearchThread) void {
        if (self.node_counters) |counters| {
            counters[self.id].store(self.localNodes(), .release);
        }
    }

    fn reportedNodes(self: *const SearchThread) u64 {
        if (self.node_counters) |counters| {
            var total: u64 = 0;
            for (counters) |*counter| total += counter.load(.acquire);
            return total;
        }
        return self.localNodes();
    }
};

pub const SearchContext = struct {
    threads: std.ArrayList(SearchThread),
    limits: SearchLimits,
    best_move: Move,
    best_score: i32,
    allocator: std.mem.Allocator,
    tt: *TranspositionTable,
    stop_flag: *std.atomic.Value(bool),
    nnue: ?*nnue.Network,

    pub fn init(
        allocator: std.mem.Allocator,
        _: GameState,
        tt: *TranspositionTable,
        stop_flag: *std.atomic.Value(bool),
    ) SearchContext {
        return SearchContext{
            .threads = std.ArrayList(SearchThread).init(allocator),
            .limits = SearchLimits{},
            .best_move = Move{ .from = 0, .to = 0 },
            .best_score = -INFINITY,
            .allocator = allocator,
            .tt = tt,
            .stop_flag = stop_flag,
            .nnue = null,
        };
    }

    pub fn deinit(self: *SearchContext) void {
        self.threads.deinit();
    }
};

pub const SearchResult = struct {
    best_move: Move,
    score: i32,
    depth: i32,
    seldepth: i32,
    nodes: u64,
    time_ms: u64,
    pv: PrincipalVariation,
};

inline fn shouldStop(thread: *SearchThread, limits: *const SearchLimits) bool {
    if (thread.stop_flag.load(.monotonic)) return true;

    const total_nodes = thread.stats.nodes + thread.stats.qnodes;
    if (total_nodes & 2047 == 0) {
        thread.publishNodes();
        if (!limits.infinite) {
            var timing_active = true;
            var timing_start = limits.start_time;
            if (limits.pondering) |pondering| {
                if (pondering.load(.acquire)) {
                    timing_active = false;
                } else if (limits.ponder_hit_time_ms) |hit_time| {
                    const hit = hit_time.load(.acquire);

                    if (hit > 0) timing_start = hit else timing_active = false;
                }
            }
            if (timing_active) {
                const elapsed = std.time.milliTimestamp() - timing_start;
                if (elapsed >= limits.max_time_ms) return true;
            }
        }

        if (thread.reportedNodes() >= limits.max_nodes) return true;
    }
    if (thread.node_counters == null and total_nodes >= limits.max_nodes) {
        return true;
    }

    return false;
}

fn scoreMoveOrdering(thread: *SearchThread, move: Move, tt_move: ?Move, ply: usize) i32 {
    if (tt_move) |tt| {
        if (move.equals(tt)) return 1000000;
    }

    if (move.promotion) |promoted| {
        const victim_value = if (move.is_capture)
            if (thread.state.board.squares[move.to].piece) |p| eval.getPieceValue(p.kind) else 100
        else
            0;
        return 200000 + eval.getPieceValue(promoted) - eval.getPieceValue(.Pawn) + victim_value;
    }

    if (move.is_capture) {
        const victim_value = if (thread.state.board.squares[move.to].piece) |p|
            eval.getPieceValue(p.kind)
        else
            100;

        const attacker_value = if (thread.state.board.squares[move.from].piece) |p|
            eval.getPieceValue(p.kind)
        else
            100;

        return 100000 + victim_value - @divTrunc(attacker_value, 10);
    }

    if (thread.killers.isKiller(ply, move)) {
        return 9000;
    }

    if (thread.prev_move) |prev| {
        if (thread.counter_moves.get(thread.state.side_to_move, prev)) |counter| {
            if (move.equals(counter)) return 8000;
        }
    }

    return thread.history.getScore(thread.state.side_to_move, move);
}

fn hasAnyLegalMove(state: *GameState) bool {
    var moves = MoveList.init();
    movegen.generatePseudoLegalMoves(state, &moves);
    for (moves.moves[0..moves.count]) |move| {
        var undo = UndoInfo{
            .captured_piece = null,
            .castling_rights = state.castling_rights,
            .en_passant_square = state.en_passant_square,
            .halfmove_clock = state.halfmove_clock,
        };
        movegen.makeMove(state, move, &undo);
        const legal = !movegen.isInCheckState(state, 1 - state.side_to_move);
        movegen.unmakeMove(state, move, &undo);
        if (legal) return true;
    }
    return false;
}

fn rule50Terminal(thread: *SearchThread, in_check: bool) ?i32 {
    if (thread.ply == 0 or thread.state.halfmove_clock < 100) return null;
    if (!in_check) return 0;
    if (hasAnyLegalMove(&thread.state)) return 0;
    return -MATE_SCORE + @as(i32, @intCast(thread.ply));
}

fn hasPromotionCandidate(state: *const GameState) bool {
    const pawns = state.board.pieceBits(.Pawn, state.side_to_move);
    const pre_promotion_rank: u64 = if (state.side_to_move == 1)
        0x0000_0000_0000_ff00
    else
        0x00ff_0000_0000_0000;
    return pawns & pre_promotion_rank != 0;
}

fn orderMoves(thread: *SearchThread, moves: []Move, tt_move: ?Move, ply: usize) void {
    var scores: [256]i32 = undefined;
    for (moves, 0..) |move, i| {
        scores[i] = scoreMoveOrdering(thread, move, tt_move, ply);
    }

    for (moves, 0..) |_, i| {
        var best_idx = i;
        var best_score = scores[i];

        for (i + 1..moves.len) |j| {
            if (scores[j] > best_score) {
                best_score = scores[j];
                best_idx = j;
            }
        }

        if (best_idx != i) {
            std.mem.swap(Move, &moves[i], &moves[best_idx]);
            std.mem.swap(i32, &scores[i], &scores[best_idx]);
        }
    }
}

fn quiescence(thread: *SearchThread, alpha_init: i32, beta: i32, limits: *const SearchLimits) i32 {
    var alpha = alpha_init;
    thread.stats.qnodes += 1;

    if (thread.ply >= MAX_PLY - 1) return alpha;
    if (shouldStop(thread, limits)) return alpha;

    const in_check = movegen.isInCheckState(&thread.state, thread.state.side_to_move);
    if (rule50Terminal(thread, in_check)) |terminal| return terminal;
    var stand_pat: i32 = -INFINITY;
    if (!in_check) {
        stand_pat = if (thread.nnue) |net|
            net.evaluate(&thread.state)
        else
            eval.evaluate(&thread.state);

        if (stand_pat >= beta) return beta;
        if (stand_pat > alpha) alpha = stand_pat;

        if (stand_pat + 925 < alpha and !hasPromotionCandidate(&thread.state)) return alpha;
    }

    var moves = MoveList.init();
    if (in_check)
        movegen.generatePseudoLegalMoves(&thread.state, &moves)
    else
        movegen.generateNoisyMoves(&thread.state, &moves);
    orderMoves(thread, moves.moves[0..moves.count], null, thread.ply);

    var legal_count: usize = 0;

    for (moves.moves[0..moves.count]) |move| {
        if (!in_check and !move.is_capture and move.promotion == null) continue;

        if (!in_check and move.is_capture and move.promotion == null) {
            if (thread.state.board.squares[move.to].piece) |victim| {
                const victim_val = eval.getPieceValue(victim.kind);
                if (stand_pat + victim_val + 200 < alpha) continue;
            }
        }

        var undo = UndoInfo{
            .captured_piece = null,
            .castling_rights = thread.state.castling_rights,
            .en_passant_square = thread.state.en_passant_square,
            .halfmove_clock = thread.state.halfmove_clock,
        };

        movegen.makeMove(&thread.state, move, &undo);
        if (movegen.isInCheckState(&thread.state, 1 - thread.state.side_to_move)) {
            movegen.unmakeMove(&thread.state, move, &undo);
            continue;
        }

        if (thread.nnue) |net| {
            const captured_kind = if (undo.captured_piece) |piece| piece.kind else null;
            net.pushAndUpdateForMove(&thread.state, move, captured_kind);
        }

        legal_count += 1;
        thread.ply += 1;
        const score = -quiescence(thread, -beta, -alpha, limits);
        thread.ply -= 1;
        movegen.unmakeMove(&thread.state, move, &undo);
        if (thread.nnue) |net| net.popAccumulator();

        if (score >= beta) return beta;
        if (score > alpha) alpha = score;
    }

    if (in_check and legal_count == 0) {
        return -MATE_SCORE + @as(i32, @intCast(thread.ply));
    }

    return alpha;
}

fn getLMRReduction(depth: i32, move_num: usize, is_pv: bool) i32 {
    if (depth < LMR_MIN_DEPTH or move_num < LMR_MIN_MOVES) return 0;

    const depth_idx: usize = @intCast(@min(depth, MAX_DEPTH));
    const move_idx = @min(move_num, 255);
    var reduction: i32 = @intCast(LMR_REDUCTIONS[depth_idx][move_idx]);

    if (is_pv) reduction = @max(0, reduction - 1);

    return @min(reduction, depth - 1);
}

fn makeLMRTable() [@as(usize, @intCast(MAX_DEPTH)) + 1][256]u8 {
    @setEvalBranchQuota(50_000);
    var table = [_][256]u8{[_]u8{0} ** 256} ** (@as(usize, @intCast(MAX_DEPTH)) + 1);
    for (LMR_MIN_DEPTH..MAX_DEPTH + 1) |depth| {
        for (LMR_MIN_MOVES..256) |move_num| {
            const log_depth = @log(@as(f32, @floatFromInt(depth)));
            const log_moves = @log(@as(f32, @floatFromInt(move_num)));
            table[@intCast(depth)][move_num] = @intFromFloat(0.75 + log_depth * log_moves / 2.0);
        }
    }
    return table;
}

fn alphaBeta(
    thread: *SearchThread,
    depth: i32,
    alpha_init: i32,
    beta_init: i32,
    limits: *const SearchLimits,
    do_null: bool,
) anyerror!i32 {
    var alpha = alpha_init;
    var beta = beta_init;
    const is_pv = (beta - alpha) > 1;
    const is_root = (thread.ply == 0);

    if (@as(i32, @intCast(thread.ply)) > thread.stats.seldepth) {
        thread.stats.seldepth = @intCast(thread.ply);
    }

    if (shouldStop(thread, limits)) return alpha;

    const in_check = movegen.isInCheckState(&thread.state, thread.state.side_to_move);
    if (rule50Terminal(thread, in_check)) |terminal| return terminal;

    if (depth <= 0 or thread.ply >= MAX_PLY - 1) {
        return quiescence(thread, alpha, beta, limits);
    }

    thread.stats.nodes += 1;

    const mate_alpha = -MATE_SCORE + @as(i32, @intCast(thread.ply));
    const mate_beta = MATE_SCORE - @as(i32, @intCast(thread.ply)) - 1;
    if (mate_alpha >= beta) return mate_alpha;
    if (mate_beta <= alpha) return mate_beta;
    alpha = @max(alpha, mate_alpha);
    beta = @min(beta, mate_beta);
    if (alpha >= beta) return alpha;

    const hash = thread.hash_stack[thread.ply];
    if (!is_root and thread.state.halfmove_clock >= 4 and thread.ply >= 2) {
        const reversible_plies = @min(thread.ply, @as(usize, thread.state.halfmove_clock));
        var distance: usize = 2;
        while (distance <= reversible_plies) : (distance += 2) {
            if (thread.hash_stack[thread.ply - distance] == hash) return 0;
        }
    }
    var tt_move: ?Move = null;

    if (thread.tt.probe(hash)) |entry| {
        thread.stats.tt_hits += 1;
        tt_move = entry.best_move;

        if (entry.depth >= depth) {
            const adjusted_score = if (eval.isMateScore(entry.score))
                if (entry.score > 0)
                    entry.score - @as(i32, @intCast(thread.ply))
                else
                    entry.score + @as(i32, @intCast(thread.ply))
            else
                entry.score;

            switch (entry.entry_type) {
                .Exact => if (!is_root) return adjusted_score,
                .Alpha => if (!is_pv and adjusted_score <= alpha) return adjusted_score,
                .Beta => if (!is_pv and adjusted_score >= beta) return adjusted_score,
            }
        }
    }

    var static_eval: i32 = 0;
    var eval_cached = false;

    if (!in_check) {
        static_eval = if (thread.nnue) |net|
            net.evaluate(&thread.state)
        else
            eval.evaluate(&thread.state);
        eval_cached = true;
    }

    if (do_null and !is_pv and depth >= NULL_MOVE_MIN_DEPTH and !in_check and eval_cached) {
        if (static_eval >= beta) {
            const side = thread.state.side_to_move;
            const has_pieces = thread.state.board.pieceBits(.Knight, side) |
                thread.state.board.pieceBits(.Bishop, side) |
                thread.state.board.pieceBits(.Rook, side) |
                thread.state.board.pieceBits(.Queen, side) != 0;

            if (has_pieces) {
                const saved_ep = thread.state.en_passant_square;
                const saved_side = thread.state.side_to_move;

                thread.state.side_to_move = 1 - thread.state.side_to_move;
                thread.state.en_passant_square = null;
                thread.hash_stack[thread.ply + 1] = hashAfterNull(hash, saved_ep);
                thread.ply += 1;

                const R = NULL_MOVE_REDUCTION + @divTrunc(depth, 4) + @divTrunc(@max(0, static_eval - beta), 200) + @as(i32, if (is_pv) 0 else 1);
                const null_score = -try alphaBeta(thread, depth - 1 - R, -beta, -beta + 1, limits, false);

                thread.ply -= 1;
                thread.state.side_to_move = saved_side;
                thread.state.en_passant_square = saved_ep;

                if (null_score >= beta) {
                    if (null_score >= MATE_SCORE - 1000) {
                        return beta;
                    }
                    return null_score;
                }
            }
        }
    }

    if (!is_pv and !in_check and eval_cached) {
        if (depth <= RAZOR_DEPTH and static_eval + RAZOR_MARGINS[@intCast(depth)] < alpha) {
            const razor_score = quiescence(thread, alpha, beta, limits);
            if (razor_score < alpha) return razor_score;
        }

        if (depth <= RFP_MAX_DEPTH and static_eval - RFP_MARGIN * depth >= beta and @abs(beta) < MATE_SCORE - 1000) {
            return static_eval - RFP_MARGIN * depth;
        }
    }

    var futility_pruning = false;
    if (!is_pv and depth <= FUTILITY_DEPTH and !in_check and eval_cached) {
        const margin_idx: usize = @intCast(@min(depth, 8));
        if (static_eval + FUTILITY_MARGINS[margin_idx] < alpha) {
            futility_pruning = true;
        }
    }

    var moves = MoveList.init();
    movegen.generatePseudoLegalMoves(&thread.state, &moves);

    if (tt_move) |tm| {
        var is_legal = false;
        for (moves.moves[0..moves.count]) |m| {
            if (m.from == tm.from and m.to == tm.to and m.promotion == tm.promotion) {
                is_legal = true;
                break;
            }
        }
        if (!is_legal) tt_move = null;
    }

    orderMoves(thread, moves.moves[0..moves.count], tt_move, thread.ply);

    const iir: i32 = if (!is_pv and depth >= 4 and tt_move == null) 1 else 0;

    var best_move = Move{ .from = 0, .to = 0 };
    var best_score = -INFINITY;
    var entry_type: EntryType = .Alpha;
    var legal_moves: usize = 0;

    var child_pv = PrincipalVariation.init();
    var searched_quiets: [256]Move = undefined;
    var quiet_count: usize = 0;

    for (moves.moves[0..moves.count]) |move| {
        var undo = UndoInfo{
            .captured_piece = null,
            .castling_rights = thread.state.castling_rights,
            .en_passant_square = thread.state.en_passant_square,
            .halfmove_clock = thread.state.halfmove_clock,
        };

        const moving_piece = thread.state.board.squares[move.from].piece.?;
        movegen.makeMove(&thread.state, move, &undo);
        if (movegen.isInCheckState(&thread.state, 1 - thread.state.side_to_move)) {
            movegen.unmakeMove(&thread.state, move, &undo);
            continue;
        }
        thread.ply += 1;
        thread.hash_stack[thread.ply] = hashAfterMove(hash, &thread.state, move, &undo, moving_piece);

        var score: i32 = undefined;

        const is_quiet = !move.is_capture and move.promotion == null;
        const gives_check = movegen.isInCheckState(&thread.state, thread.state.side_to_move);

        const extension: i32 = if (gives_check and depth < 8) 1 else 0;
        const child_depth = depth - 1 - iir + extension;

        if (futility_pruning and is_quiet and !gives_check and legal_moves > 0) {
            thread.ply -= 1;
            movegen.unmakeMove(&thread.state, move, &undo);
            continue;
        }

        if (!is_pv and !in_check and is_quiet and !gives_check and depth <= 4 and legal_moves > 0) {
            if (legal_moves >= LATE_MOVE_PRUNING[@intCast(depth)]) {
                thread.ply -= 1;
                movegen.unmakeMove(&thread.state, move, &undo);
                continue;
            }
        }

        legal_moves += 1;
        if (is_quiet) {
            searched_quiets[quiet_count] = move;
            quiet_count += 1;
        }

        if (thread.nnue) |net| {
            const captured_kind = if (undo.captured_piece) |piece| piece.kind else null;
            net.pushAndUpdateForMove(&thread.state, move, captured_kind);
        }

        const saved_prev_move = thread.prev_move;
        thread.prev_move = move;

        if (legal_moves == 1) {
            score = -try alphaBeta(thread, child_depth, -beta, -alpha, limits, true);
        } else {
            var reduction: i32 = 0;
            if (!move.is_capture and move.promotion == null and !gives_check) {
                reduction = getLMRReduction(depth, legal_moves, is_pv);
                if (thread.killers.isKiller(thread.ply - 1, move)) {
                    reduction = @max(0, reduction - 1);
                }

                const hist = thread.history.getScore(thread.state.side_to_move, move);
                reduction -= @divTrunc(hist, 8000);
                reduction = @max(0, @min(depth - 1, reduction));
            }

            const reduced_depth = if (child_depth > 0)
                @max(@as(i32, 1), child_depth - reduction)
            else
                child_depth;
            score = -try alphaBeta(thread, reduced_depth, -alpha - 1, -alpha, limits, true);

            if (score > alpha and reduction > 0) {
                score = -try alphaBeta(thread, child_depth, -alpha - 1, -alpha, limits, true);
            }

            if (score > alpha and score < beta) {
                score = -try alphaBeta(thread, child_depth, -beta, -alpha, limits, true);
            }
        }

        thread.prev_move = saved_prev_move;

        thread.ply -= 1;
        movegen.unmakeMove(&thread.state, move, &undo);
        if (thread.nnue) |net| net.popAccumulator();

        if (shouldStop(thread, limits)) return alpha;

        if (score > best_score) {
            best_score = score;
            best_move = move;

            if (score > alpha) {
                alpha = score;
                entry_type = .Exact;

                if (is_root) {
                    thread.pv.update(move, &child_pv);
                }

                if (score >= beta) {
                    entry_type = .Beta;

                    if (is_quiet) {
                        thread.killers.store(thread.ply, move);
                        thread.history.update(thread.state.side_to_move, move, depth);

                        if (thread.prev_move) |prev| {
                            thread.counter_moves.store(thread.state.side_to_move, prev, move);
                        }

                        for (searched_quiets[0 .. quiet_count - 1]) |failed_quiet| {
                            thread.history.penalize(thread.state.side_to_move, failed_quiet, depth);
                        }
                    }

                    break;
                }
            }
        }
    }

    if (legal_moves == 0) {
        if (in_check) return -MATE_SCORE + @as(i32, @intCast(thread.ply));
        return 0;
    }

    const store_score = if (eval.isMateScore(best_score))
        if (best_score > 0)
            best_score + @as(i32, @intCast(thread.ply))
        else
            best_score - @as(i32, @intCast(thread.ply))
    else
        best_score;

    thread.tt.store(hash, best_move, store_score, @intCast(depth - iir), entry_type);

    return best_score;
}

fn aspirationSearch(
    thread: *SearchThread,
    depth: i32,
    prev_score: i32,
    limits: *const SearchLimits,
) anyerror!i32 {
    if (depth <= 4) {
        return try alphaBeta(thread, depth, -INFINITY, INFINITY, limits, true);
    }

    var alpha = prev_score - ASPIRATION_WINDOW;
    var beta = prev_score + ASPIRATION_WINDOW;
    var delta = ASPIRATION_WINDOW;

    while (true) {
        const score = try alphaBeta(thread, depth, alpha, beta, limits, true);

        if (shouldStop(thread, limits)) return score;

        if (score <= alpha) {
            alpha = @max(alpha - delta, -INFINITY);
            delta *= 2;
        } else if (score >= beta) {
            beta = @min(beta + delta, INFINITY);
            delta *= 2;
        } else {
            return score;
        }

        if (alpha <= -INFINITY and beta >= INFINITY) {
            return try alphaBeta(thread, depth, -INFINITY, INFINITY, limits, true);
        }
    }
}

fn iterativeDeepening(
    thread: *SearchThread,
    limits: *const SearchLimits,
    writer: anytype,
) !SearchResult {
    defer thread.publishNodes();
    var score: i32 = 0;

    var depth: i32 = if (thread.root_depth > 0) thread.root_depth else 1;
    var completed_score: i32 = 0;
    var completed_depth: i32 = 0;
    var completed_pv = PrincipalVariation.init();
    const start_time = std.time.milliTimestamp();
    var root_moves = MoveList.init();
    movegen.generateLegalMoves(&thread.state, &root_moves);
    if (root_moves.count == 0) {
        const in_check = movegen.isInCheckState(&thread.state, thread.state.side_to_move);
        return SearchResult{
            .best_move = Move{ .from = 0, .to = 0 },
            .score = if (in_check) -MATE_SCORE else 0,
            .depth = 0,
            .seldepth = 0,
            .nodes = 0,
            .time_ms = @intCast(@max(0, std.time.milliTimestamp() - start_time)),
            .pv = completed_pv,
        };
    }
    completed_pv.moves[0] = root_moves.moves[0];
    completed_pv.length = 1;

    if (thread.state.halfmove_clock >= 100) {
        return SearchResult{
            .best_move = completed_pv.moves[0],
            .score = 0,
            .depth = 0,
            .seldepth = 0,
            .nodes = 0,
            .time_ms = @intCast(@max(0, std.time.milliTimestamp() - start_time)),
            .pv = completed_pv,
        };
    }

    while (depth <= limits.max_depth) : (depth += 1) {
        thread.root_depth = depth;
        thread.ply = 0;

        thread.history.age();

        score = try aspirationSearch(thread, depth, score, limits);

        if (shouldStop(thread, limits)) break;

        completed_score = score;
        completed_depth = depth;
        completed_pv = thread.pv;

        const elapsed = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        thread.publishNodes();
        const total_nodes = thread.reportedNodes();
        const nps = if (elapsed > 0) total_nodes * 1000 / elapsed else 0;
        thread.stats.nps = nps;

        try printSearchInfo(thread, depth, score, elapsed, writer);

        if (eval.isMateScore(score)) {
            const moves_to_mate = eval.movesToMate(score);
            if (@abs(moves_to_mate) <= @divTrunc(depth, 2)) break;
        }
    }

    const total_time = @as(u64, @intCast(std.time.milliTimestamp() - start_time));

    return SearchResult{
        .best_move = completed_pv.moves[0],
        .score = completed_score,
        .depth = completed_depth,
        .seldepth = thread.stats.seldepth,
        .nodes = thread.reportedNodes(),
        .time_ms = total_time,
        .pv = completed_pv,
    };
}

fn printSearchInfo(thread: *SearchThread, depth: i32, score: i32, time_ms: u64, writer: anytype) !void {
    thread.publishNodes();
    const total_nodes = thread.reportedNodes();
    const nps = if (time_ms > 0) total_nodes * 1000 / time_ms else 0;

    var line_buf: [2048]u8 = undefined;
    var line_stream = std.io.fixedBufferStream(&line_buf);
    const line = line_stream.writer();

    if (eval.isMateScore(score)) {
        const moves_to_mate = eval.movesToMate(score);
        try line.print("info depth {d} seldepth {d} score mate {d} nodes {d} time {d} nps {d}", .{ depth, thread.stats.seldepth, moves_to_mate, total_nodes, time_ms, nps });
    } else {
        try line.print("info depth {d} seldepth {d} score cp {d} nodes {d} time {d} nps {d}", .{ depth, thread.stats.seldepth, score, total_nodes, time_ms, nps });
    }

    if (thread.pv.length > 0) {
        try line.print(" pv", .{});
        for (thread.pv.moves[0..thread.pv.length]) |move| {
            var buf: [6]u8 = undefined;
            const move_str = move.toUci(&buf);
            try line.print(" {s}", .{move_str});
        }
    }

    try line.writeByte('\n');
    try writer.writeAll(line_stream.getWritten());
}

pub fn search(
    allocator: std.mem.Allocator,
    root_state: GameState,
    limits: SearchLimits,
    tt: *TranspositionTable,
    stop_flag: *std.atomic.Value(bool),
    nnue_net: ?*nnue.Network,
    writer: anytype,
) !SearchResult {
    _ = allocator;

    tt.incrementAge();

    var thread = SearchThread.init(0, root_state, tt, stop_flag);
    thread.nnue = nnue_net;

    return try iterativeDeepening(&thread, &limits, writer);
}

const ThreadWorker = struct {
    thread: std.Thread,
    search_thread: *SearchThread,
    result: SearchResult,
    finished: std.atomic.Value(bool),
};

pub fn parallelSearch(
    _: std.mem.Allocator,
    root_state: GameState,
    limits: SearchLimits,
    tt: *TranspositionTable,
    stop_flag: *std.atomic.Value(bool),
    nnue_net: ?*nnue.Network,
    num_threads: usize,
    writer: anytype,
) !SearchResult {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (num_threads <= 1) {
        return try search(allocator, root_state, limits, tt, stop_flag, nnue_net, writer);
    }

    const actual_threads = @min(num_threads, MAX_THREADS);
    const parallel_start = std.time.milliTimestamp();

    tt.incrementAge();

    var threads = try allocator.alloc(SearchThread, actual_threads);
    defer allocator.free(threads);

    var workers = try allocator.alloc(ThreadWorker, actual_threads);
    defer allocator.free(workers);

    const node_counters = try allocator.alloc(std.atomic.Value(u64), actual_threads);
    defer allocator.free(node_counters);
    for (node_counters) |*counter| counter.* = std.atomic.Value(u64).init(0);

    var nnue_contexts: ?[]nnue.Network = null;
    var initialized_contexts: usize = 0;
    defer if (nnue_contexts) |contexts| {
        for (contexts[0..initialized_contexts]) |*context| context.deinit();
        allocator.free(contexts);
    };
    if (nnue_net) |source| {
        const contexts = try allocator.alloc(nnue.Network, actual_threads);
        nnue_contexts = contexts;
        for (contexts) |*context| {
            context.* = try nnue.Network.initShared(allocator, source);
            initialized_contexts += 1;
            context.initPosition(&root_state);
        }
    }

    for (threads, 0..) |*t, i| {
        t.* = SearchThread.init(i, root_state, tt, stop_flag);
        t.nnue = if (nnue_contexts) |contexts| &contexts[i] else null;
        t.node_counters = node_counters;
    }

    for (1..actual_threads) |i| {
        workers[i].search_thread = &threads[i];
        workers[i].finished = std.atomic.Value(bool).init(false);

        const depth_offset = @as(i32, @intCast(i % 4));
        threads[i].root_depth = depth_offset;

        workers[i].thread = try std.Thread.spawn(.{}, threadWorker, .{
            &threads[i],
            limits,
            &workers[i].result,
            &workers[i].finished,
        });
    }

    const main_result = try iterativeDeepening(&threads[0], &limits, writer);

    stop_flag.store(true, .monotonic);

    var best_result = main_result;
    for (1..actual_threads) |i| {
        workers[i].thread.join();

        if (workers[i].result.depth > best_result.depth or
            (workers[i].result.depth == best_result.depth and
                workers[i].result.score > best_result.score))
        {
            best_result = workers[i].result;
        }
    }

    stop_flag.store(false, .monotonic);

    var aggregate_nodes: u64 = 0;
    for (node_counters) |*counter| aggregate_nodes += counter.load(.acquire);
    best_result.nodes = aggregate_nodes;
    best_result.time_ms = @intCast(@max(0, std.time.milliTimestamp() - parallel_start));

    return best_result;
}

fn threadWorker(
    thread: *SearchThread,
    limits: SearchLimits,
    result: *SearchResult,
    finished: *std.atomic.Value(bool),
) void {
    const null_writer = std.io.null_writer;

    result.* = iterativeDeepening(thread, &limits, null_writer) catch |err| {
        std.debug.print("Thread {d} error: {any}\n", .{ thread.id, err });
        return;
    };

    finished.store(true, .monotonic);
}

pub fn searchLegacy(
    allocator: std.mem.Allocator,
    root_state: GameState,
    limits: SearchLimits,
    tt: *TranspositionTable,
    stop_flag: *std.atomic.Value(bool),
    nnue_net: ?*nnue.Network,
    writer: anytype,
) !SearchResult {
    return try search(
        allocator,
        root_state,
        limits,
        tt,
        stop_flag,
        nnue_net,
        writer,
    );
}

test "quiescence applies rule fifty before static evaluation" {
    zobrist.init();
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    const limits = SearchLimits{ .infinite = true };

    const quiet_draw = try GameState.fromFen("7k/8/8/8/8/8/8/K6R w - - 100 1");
    var quiet_thread = SearchThread.init(0, quiet_draw, &table, &stopped);
    quiet_thread.ply = 1;
    try std.testing.expectEqual(@as(i32, 0), quiescence(&quiet_thread, -INFINITY, INFINITY, &limits));

    const checked_with_evasion = try GameState.fromFen("7k/8/7Q/8/8/8/8/K7 b - - 100 1");
    var checked_thread = SearchThread.init(0, checked_with_evasion, &table, &stopped);
    checked_thread.ply = 1;
    try std.testing.expectEqual(@as(i32, 0), quiescence(&checked_thread, -INFINITY, INFINITY, &limits));

    const checkmate = try GameState.fromFen("7k/6Q1/6K1/8/8/8/8/8 b - - 100 1");
    var mate_thread = SearchThread.init(0, checkmate, &table, &stopped);
    mate_thread.ply = 1;
    try std.testing.expectEqual(-MATE_SCORE + 1, quiescence(&mate_thread, -INFINITY, INFINITY, &limits));
}

test "quiescence never delta prunes a capture promotion" {
    zobrist.init();
    var table = try TranspositionTable.init(std.testing.allocator, 1);
    defer table.deinit();
    var stopped = std.atomic.Value(bool).init(false);
    const limits = SearchLimits{ .infinite = true };
    const state = try GameState.fromFen("q6k/1P6/8/8/8/8/8/7K w - - 0 1");
    var thread = SearchThread.init(0, state, &table, &stopped);

    try std.testing.expectEqual(@as(i32, 401), quiescence(&thread, 400, 401, &limits));
}
