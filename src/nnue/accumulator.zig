const std = @import("std");
const GameState = @import("../gamestate.zig").GameState;
const Move = @import("../movegen.zig").Move;
const PieceKind = @import("../piece.zig").PieceKind;
const features = @import("features.zig");

pub const HIDDEN_SIZE: usize = 1024;
const SIMD_LANES: usize = 16;
const VecI16 = @Vector(SIMD_LANES, i16);

pub const Accumulator = struct {
    white: [HIDDEN_SIZE]i16,
    black: [HIDDEN_SIZE]i16,

    pub fn init() Accumulator {
        return Accumulator{
            .white = [_]i16{0} ** HIDDEN_SIZE,
            .black = [_]i16{0} ** HIDDEN_SIZE,
        };
    }

    pub fn copyFrom(self: *Accumulator, other: *const Accumulator) void {
        @memcpy(&self.white, &other.white);
        @memcpy(&self.black, &other.black);
    }

    pub fn reset(self: *Accumulator, biases: []const i16) void {
        @memcpy(&self.white, biases[0..HIDDEN_SIZE]);
        @memcpy(&self.black, biases[0..HIDDEN_SIZE]);
    }
};

pub const AccumulatorStack = struct {
    stack: []Accumulator,
    index: usize,
    allocator: std.mem.Allocator,
    needs_refresh: bool,

    last_white_king: ?u8,
    last_black_king: ?u8,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) !AccumulatorStack {
        const stack = try allocator.alloc(Accumulator, max_depth);
        for (stack) |*acc| {
            acc.* = Accumulator.init();
        }

        return AccumulatorStack{
            .stack = stack,
            .index = 0,
            .allocator = allocator,
            .needs_refresh = true,
            .last_white_king = null,
            .last_black_king = null,
        };
    }

    pub fn deinit(self: *AccumulatorStack) void {
        self.allocator.free(self.stack);
    }

    pub fn current(self: *AccumulatorStack) *Accumulator {
        return &self.stack[self.index];
    }

    pub fn currentConst(self: *const AccumulatorStack) *const Accumulator {
        return &self.stack[self.index];
    }

    pub fn push(self: *AccumulatorStack) void {
        if (self.index + 1 < self.stack.len) {
            self.index += 1;
            self.stack[self.index].copyFrom(&self.stack[self.index - 1]);
        }
    }

    pub fn pushEmpty(self: *AccumulatorStack) void {
        if (self.index + 1 < self.stack.len) self.index += 1;
    }

    pub fn pop(self: *AccumulatorStack) void {
        if (self.index > 0) {
            self.index -= 1;
        }
    }

    pub fn reset(self: *AccumulatorStack) void {
        self.index = 0;
        self.needs_refresh = true;
        self.last_white_king = null;
        self.last_black_king = null;
    }

    pub fn invalidate(self: *AccumulatorStack) void {
        self.needs_refresh = true;
    }
};

pub const AccumulatorUpdater = struct {
    ft_weights: []const [HIDDEN_SIZE]i16,
    ft_biases: []const i16,

    pub fn init(ft_weights: []const [HIDDEN_SIZE]i16, ft_biases: []const i16) AccumulatorUpdater {
        return AccumulatorUpdater{
            .ft_weights = ft_weights,
            .ft_biases = ft_biases,
        };
    }

    pub fn refresh(self: *const AccumulatorUpdater, acc: *Accumulator, state: *const GameState) void {
        acc.reset(self.ft_biases);

        const white_king = state.king_squares[0];
        const black_king = state.king_squares[1];

        for (state.board.squares, 0..) |square, idx| {
            if (square.piece) |piece| {
                const feature = features.getFeatureWithKings(
                    piece.kind,
                    piece.color,
                    @intCast(idx),
                    white_king,
                    black_king,
                );
                self.addFeature(acc, feature);
            }
        }
    }

    pub fn addFeature(self: *const AccumulatorUpdater, acc: *Accumulator, feature: features.Feature) void {
        const white_idx = feature.index_white;
        const black_idx = feature.index_black;

        if (white_idx >= self.ft_weights.len or black_idx >= self.ft_weights.len) {
            return;
        }

        var i: usize = 0;
        while (i < HIDDEN_SIZE) : (i += SIMD_LANES) {
            const acc_white: VecI16 = @bitCast(acc.white[i..][0..SIMD_LANES].*);
            const acc_black: VecI16 = @bitCast(acc.black[i..][0..SIMD_LANES].*);
            const weights_white: VecI16 = @bitCast(self.ft_weights[white_idx][i..][0..SIMD_LANES].*);
            const weights_black: VecI16 = @bitCast(self.ft_weights[black_idx][i..][0..SIMD_LANES].*);
            acc.white[i..][0..SIMD_LANES].* = @bitCast(acc_white +% weights_white);
            acc.black[i..][0..SIMD_LANES].* = @bitCast(acc_black +% weights_black);
        }
    }

    pub fn removeFeature(self: *const AccumulatorUpdater, acc: *Accumulator, feature: features.Feature) void {
        const white_idx = feature.index_white;
        const black_idx = feature.index_black;

        if (white_idx >= self.ft_weights.len or black_idx >= self.ft_weights.len) {
            return;
        }

        var i: usize = 0;
        while (i < HIDDEN_SIZE) : (i += SIMD_LANES) {
            const acc_white: VecI16 = @bitCast(acc.white[i..][0..SIMD_LANES].*);
            const acc_black: VecI16 = @bitCast(acc.black[i..][0..SIMD_LANES].*);
            const weights_white: VecI16 = @bitCast(self.ft_weights[white_idx][i..][0..SIMD_LANES].*);
            const weights_black: VecI16 = @bitCast(self.ft_weights[black_idx][i..][0..SIMD_LANES].*);
            acc.white[i..][0..SIMD_LANES].* = @bitCast(acc_white -% weights_white);
            acc.black[i..][0..SIMD_LANES].* = @bitCast(acc_black -% weights_black);
        }
    }

    pub fn updateMove(
        self: *const AccumulatorUpdater,
        acc: *Accumulator,
        state: *const GameState,
        move: Move,
        captured_piece: ?PieceKind,
    ) bool {
        const white_king = state.king_squares[0];
        const black_king = state.king_squares[1];

        const moving_piece = state.board.squares[move.to].piece orelse return false;

        if (moving_piece.kind == .King) {
            return false;
        }

        if (move.is_castle or move.is_en_passant or move.promotion != null) {
            return false;
        }

        const old_feature = features.getFeatureWithKings(
            moving_piece.kind,
            moving_piece.color,
            move.from,
            white_king,
            black_king,
        );
        self.removeFeature(acc, old_feature);

        if (captured_piece) |cap_kind| {
            const cap_color = 1 - moving_piece.color;
            const cap_feature = features.getFeatureWithKings(
                cap_kind,
                cap_color,
                move.to,
                white_king,
                black_king,
            );
            self.removeFeature(acc, cap_feature);
        }

        if (move.promotion) |promo_kind| {
            const promo_feature = features.getFeatureWithKings(
                promo_kind,
                moving_piece.color,
                move.to,
                white_king,
                black_king,
            );
            self.addFeature(acc, promo_feature);
        } else {
            const new_feature = features.getFeatureWithKings(
                moving_piece.kind,
                moving_piece.color,
                move.to,
                white_king,
                black_king,
            );
            self.addFeature(acc, new_feature);
        }

        return true;
    }

    pub fn updateMoveFromParent(
        self: *const AccumulatorUpdater,
        parent: *const Accumulator,
        child: *Accumulator,
        state: *const GameState,
        move: Move,
        captured_piece: ?PieceKind,
    ) bool {
        const moving_piece = state.board.squares[move.to].piece orelse return false;
        if (moving_piece.kind == .King or move.is_castle or move.is_en_passant or move.promotion != null) {
            return false;
        }

        const white_king = state.king_squares[0];
        const black_king = state.king_squares[1];
        const old_feature = features.getFeatureWithKings(
            moving_piece.kind,
            moving_piece.color,
            move.from,
            white_king,
            black_king,
        );
        const new_feature = features.getFeatureWithKings(
            moving_piece.kind,
            moving_piece.color,
            move.to,
            white_king,
            black_king,
        );
        const captured_feature: ?features.Feature = if (captured_piece) |kind|
            features.getFeatureWithKings(
                kind,
                1 - moving_piece.color,
                move.to,
                white_king,
                black_king,
            )
        else
            null;

        var i: usize = 0;
        while (i < HIDDEN_SIZE) : (i += SIMD_LANES) {
            const parent_white: VecI16 = @bitCast(parent.white[i..][0..SIMD_LANES].*);
            const parent_black: VecI16 = @bitCast(parent.black[i..][0..SIMD_LANES].*);
            const old_white: VecI16 = @bitCast(self.ft_weights[old_feature.index_white][i..][0..SIMD_LANES].*);
            const old_black: VecI16 = @bitCast(self.ft_weights[old_feature.index_black][i..][0..SIMD_LANES].*);
            const new_white: VecI16 = @bitCast(self.ft_weights[new_feature.index_white][i..][0..SIMD_LANES].*);
            const new_black: VecI16 = @bitCast(self.ft_weights[new_feature.index_black][i..][0..SIMD_LANES].*);

            var child_white = parent_white -% old_white;
            var child_black = parent_black -% old_black;
            if (captured_feature) |captured| {
                const captured_white: VecI16 = @bitCast(self.ft_weights[captured.index_white][i..][0..SIMD_LANES].*);
                const captured_black: VecI16 = @bitCast(self.ft_weights[captured.index_black][i..][0..SIMD_LANES].*);
                child_white -%= captured_white;
                child_black -%= captured_black;
            }
            child.white[i..][0..SIMD_LANES].* = @bitCast(child_white +% new_white);
            child.black[i..][0..SIMD_LANES].* = @bitCast(child_black +% new_black);
        }
        return true;
    }
};
