const std = @import("std");
const GameState = @import("../gamestate.zig").GameState;
const Move = @import("../movegen.zig").Move;
const features = @import("features.zig");
const accumulator = @import("accumulator.zig");
const Accumulator = accumulator.Accumulator;
const AccumulatorStack = accumulator.AccumulatorStack;
const AccumulatorUpdater = accumulator.AccumulatorUpdater;

pub const INPUT_SIZE: usize = features.INPUT_SIZE;
pub const HIDDEN_SIZE: usize = accumulator.HIDDEN_SIZE;
pub const L2_SIZE: usize = 32;
pub const L3_SIZE: usize = 32;
pub const NUM_LS_BUCKETS: usize = 8;
pub const OUTPUT_SIZE: usize = 1;

const SIMD_LANES: usize = 16;
const VecI8 = @Vector(SIMD_LANES, i8);
const VecI16 = @Vector(SIMD_LANES, i16);
const VecI32 = @Vector(SIMD_LANES, i32);
const VecF32 = @Vector(SIMD_LANES, f32);

pub const FT_QUANTIZED_ONE: f32 = 256.0;
pub const HIDDEN_QUANTIZED_ONE: f32 = 128.0;
pub const WEIGHT_SCALE_L1: f32 = 128.0;
pub const WEIGHT_SCALE_L2: f32 = 64.0;
pub const WEIGHT_SCALE_L_OUT: f32 = 128.0;
pub const WEIGHT_SCALE_OUT: f32 = 16.0;
pub const NNUE2SCORE: f32 = 600.0;
pub const INFERENCE_L0_DIVISION: f32 = 512.0;
pub const INFERENCE_SQR_CRELU_DIVISION: f32 = 128.0;

pub const LayerStack = struct {
    l1_weight_a: []i8,
    l1_weight_b: []i8,
    l1_bias: []i32,

    l2_weight: []i8,
    l2_bias: []i32,

    output_weight: []i8,
    output_bias: []i32,
};

pub const Network = struct {
    ft_weights: [][HIDDEN_SIZE]i16,
    ft_biases: []i16,

    layer_stacks: []LayerStack,

    acc_stack: AccumulatorStack,
    updater: AccumulatorUpdater,

    allocator: std.mem.Allocator,
    loaded: bool,
    owns_weights: bool,

    pub fn init(allocator: std.mem.Allocator) !Network {
        const ft_weights = try allocator.alloc([HIDDEN_SIZE]i16, INPUT_SIZE);
        const ft_biases = try allocator.alloc(i16, HIDDEN_SIZE);

        @memset(ft_weights, [_]i16{0} ** HIDDEN_SIZE);
        @memset(ft_biases, 0);

        const layer_stacks = try allocator.alloc(LayerStack, NUM_LS_BUCKETS);
        for (layer_stacks) |*ls| {
            ls.* = try initLayerStack(allocator);
        }

        const acc_stack = try AccumulatorStack.init(allocator, 128);

        return Network{
            .ft_weights = ft_weights,
            .ft_biases = ft_biases,
            .layer_stacks = layer_stacks,
            .acc_stack = acc_stack,
            .updater = AccumulatorUpdater.init(ft_weights, ft_biases),
            .allocator = allocator,
            .loaded = false,
            .owns_weights = true,
        };
    }

    fn initLayerStack(allocator: std.mem.Allocator) !LayerStack {
        const l1_weight_a = try allocator.alloc(i8, L2_SIZE * (HIDDEN_SIZE / 2));
        const l1_weight_b = try allocator.alloc(i8, L2_SIZE * (HIDDEN_SIZE / 2));
        const l1_bias = try allocator.alloc(i32, L2_SIZE);

        const l2_weight = try allocator.alloc(i8, L3_SIZE * (L2_SIZE * 2));
        const l2_bias = try allocator.alloc(i32, L3_SIZE);

        const output_weight = try allocator.alloc(i8, 1 * ((L2_SIZE * 2) + (L3_SIZE * 2)));
        const output_bias = try allocator.alloc(i32, 1);

        @memset(l1_weight_a, 0);
        @memset(l1_weight_b, 0);
        @memset(l1_bias, 0);
        @memset(l2_weight, 0);
        @memset(l2_bias, 0);
        @memset(output_weight, 0);
        @memset(output_bias, 0);

        return LayerStack{
            .l1_weight_a = l1_weight_a,
            .l1_weight_b = l1_weight_b,
            .l1_bias = l1_bias,
            .l2_weight = l2_weight,
            .l2_bias = l2_bias,
            .output_weight = output_weight,
            .output_bias = output_bias,
        };
    }

    fn deinitLayerStack(self: *LayerStack, allocator: std.mem.Allocator) void {
        allocator.free(self.l1_weight_a);
        allocator.free(self.l1_weight_b);
        allocator.free(self.l1_bias);
        allocator.free(self.l2_weight);
        allocator.free(self.l2_bias);
        allocator.free(self.output_weight);
        allocator.free(self.output_bias);
    }

    pub fn initShared(allocator: std.mem.Allocator, source: *const Network) !Network {
        const acc_stack = try AccumulatorStack.init(allocator, 128);
        return Network{
            .ft_weights = source.ft_weights,
            .ft_biases = source.ft_biases,
            .layer_stacks = source.layer_stacks,
            .acc_stack = acc_stack,
            .updater = AccumulatorUpdater.init(source.ft_weights, source.ft_biases),
            .allocator = allocator,
            .loaded = source.loaded,
            .owns_weights = false,
        };
    }

    pub fn deinit(self: *Network) void {
        if (self.owns_weights) {
            self.allocator.free(self.ft_weights);
            self.allocator.free(self.ft_biases);
            for (self.layer_stacks) |*ls| {
                deinitLayerStack(ls, self.allocator);
            }
            self.allocator.free(self.layer_stacks);
        }
        self.acc_stack.deinit();
    }

    pub fn isLoaded(self: *const Network) bool {
        return self.loaded;
    }

    pub fn initPosition(self: *Network, state: *const GameState) void {
        self.acc_stack.reset();
        self.updater.refresh(self.acc_stack.current(), state);
        self.acc_stack.needs_refresh = false;
    }

    pub fn pushAccumulator(self: *Network) void {
        self.acc_stack.push();
    }

    pub fn popAccumulator(self: *Network) void {
        self.acc_stack.pop();
    }

    pub fn pushAndUpdateForMove(
        self: *Network,
        state: *const GameState,
        move: Move,
        captured_piece: ?@import("../piece.zig").PieceKind,
    ) void {
        const parent = self.acc_stack.currentConst();
        self.acc_stack.pushEmpty();
        const child = self.acc_stack.current();
        if (!self.updater.updateMoveFromParent(parent, child, state, move, captured_piece)) {
            self.updater.refresh(child, state);
        }
        self.acc_stack.needs_refresh = false;
    }

    pub fn updateForMove(
        self: *Network,
        state: *const GameState,
        move: Move,
        captured_piece: ?@import("../piece.zig").PieceKind,
    ) void {
        const acc = self.acc_stack.current();

        const updated = self.updater.updateMove(acc, state, move, captured_piece);

        if (!updated) {
            self.updater.refresh(acc, state);
            self.acc_stack.needs_refresh = false;
        }
    }

    pub fn evaluate(self: *Network, state: *const GameState) i32 {
        if (!self.loaded) return 0;

        if (self.acc_stack.needs_refresh) {
            self.updater.refresh(self.acc_stack.current(), state);
            self.acc_stack.needs_refresh = false;
        }

        const acc = self.acc_stack.currentConst();
        const active_perspective = state.side_to_move;

        const acc_active = if (active_perspective == 1) &acc.white else &acc.black;
        const acc_non_active = if (active_perspective == 1) &acc.black else &acc.white;

        var piece_count: u32 = 0;
        for (state.board.squares) |sq| {
            if (sq.piece != null) piece_count += 1;
        }
        const ls_bucket = @min(piece_count / 4, NUM_LS_BUCKETS - 1);

        return self.forward(acc_active, acc_non_active, @intCast(ls_bucket));
    }

    fn forward(self: *const Network, acc_active: []const i16, acc_non_active: []const i16, ls_bucket: usize) i32 {
        const ls = &self.layer_stacks[ls_bucket];

        var hidden: [HIDDEN_SIZE]f32 = undefined;
        for (0..HIDDEN_SIZE) |i| {
            const combined = @as(i32, acc_active[i]) + @as(i32, acc_non_active[i]);
            hidden[i] = @as(f32, @floatFromInt(@max(0, @min(127, combined))));
        }

        var fc0_out: [L2_SIZE]f32 = [_]f32{0.0} ** L2_SIZE;
        for (0..L2_SIZE) |j| {
            var sum: f32 = 0.0;

            {
                var ii: usize = 0;
                while (ii < HIDDEN_SIZE / 2) : (ii += SIMD_LANES) {
                    const h_vec: VecF32 = hidden[ii..][0..SIMD_LANES].*;
                    const w_vec: VecI8 = @bitCast(ls.l1_weight_a[j * (HIDDEN_SIZE / 2) + ii ..][0..SIMD_LANES].*);
                    const w_f32: VecF32 = @floatFromInt(@as(VecI32, @intCast(w_vec)));
                    sum += @reduce(.Add, h_vec * w_f32);
                }
            }

            {
                var ii: usize = 0;
                while (ii < HIDDEN_SIZE / 2) : (ii += SIMD_LANES) {
                    const h_vec: VecF32 = hidden[HIDDEN_SIZE / 2 + ii ..][0..SIMD_LANES].*;
                    const w_vec: VecI8 = @bitCast(ls.l1_weight_b[j * (HIDDEN_SIZE / 2) + ii ..][0..SIMD_LANES].*);
                    const w_f32: VecF32 = @floatFromInt(@as(VecI32, @intCast(w_vec)));
                    sum += @reduce(.Add, h_vec * w_f32);
                }
            }
            fc0_out[j] = sum + @as(f32, @floatFromInt(ls.l1_bias[j]));
        }

        var concat1: [L2_SIZE * 2]f32 = undefined;
        for (0..L2_SIZE) |i| {
            const crelu_val = @max(0.0, @min(1.0, fc0_out[i] / HIDDEN_QUANTIZED_ONE));
            concat1[i] = crelu_val * crelu_val;
            concat1[L2_SIZE + i] = crelu_val;
        }

        var fc1_out: [L3_SIZE]f32 = [_]f32{0.0} ** L3_SIZE;
        for (0..L3_SIZE) |j| {
            var sum: f32 = 0.0;
            var ii: usize = 0;
            while (ii < L2_SIZE * 2) : (ii += SIMD_LANES) {
                const remaining = @min(SIMD_LANES, L2_SIZE * 2 - ii);
                if (remaining == SIMD_LANES) {
                    const a_vec: VecF32 = concat1[ii..][0..SIMD_LANES].*;
                    const w_vec: VecI8 = @bitCast(ls.l2_weight[j * (L2_SIZE * 2) + ii ..][0..SIMD_LANES].*);
                    const w_f32: VecF32 = @floatFromInt(@as(VecI32, @intCast(w_vec)));
                    sum += @reduce(.Add, a_vec * w_f32);
                } else {
                    var jj: usize = 0;
                    while (jj < remaining) : (jj += 1) {
                        sum += concat1[ii + jj] * @as(f32, @floatFromInt(ls.l2_weight[j * (L2_SIZE * 2) + ii + jj]));
                    }
                }
            }
            fc1_out[j] = sum + @as(f32, @floatFromInt(ls.l2_bias[j]));
        }

        var concat2: [L2_SIZE * 2 + L3_SIZE * 2]f32 = undefined;

        for (0..L2_SIZE * 2) |i| {
            concat2[i] = concat1[i];
        }

        for (0..L3_SIZE) |i| {
            const crelu_val = @max(0.0, @min(1.0, fc1_out[i] / HIDDEN_QUANTIZED_ONE));
            concat2[L2_SIZE * 2 + i] = crelu_val * crelu_val;
            concat2[L2_SIZE * 2 + L3_SIZE + i] = crelu_val;
        }

        var output_sum: f32 = 0.0;
        {
            var ii: usize = 0;
            while (ii < L2_SIZE * 2 + L3_SIZE * 2) : (ii += SIMD_LANES) {
                const remaining = @min(SIMD_LANES, L2_SIZE * 2 + L3_SIZE * 2 - ii);
                if (remaining == SIMD_LANES) {
                    const a_vec: VecF32 = concat2[ii..][0..SIMD_LANES].*;
                    const w_vec: VecI8 = @bitCast(ls.output_weight[ii..][0..SIMD_LANES].*);
                    const w_f32: VecF32 = @floatFromInt(@as(VecI32, @intCast(w_vec)));
                    output_sum += @reduce(.Add, a_vec * w_f32);
                } else {
                    var jj: usize = 0;
                    while (jj < remaining) : (jj += 1) {
                        output_sum += concat2[ii + jj] * @as(f32, @floatFromInt(ls.output_weight[ii + jj]));
                    }
                }
            }
        }
        output_sum += @as(f32, @floatFromInt(ls.output_bias[0]));

        output_sum += fc0_out[L2_SIZE - 2] - fc0_out[L2_SIZE - 1];

        return @intFromFloat(@round(output_sum * 9600.0 / 16384.0));
    }
};

pub fn evaluatePosition(network: *Network, state: *const GameState) i32 {
    if (!network.loaded) {
        return 0;
    }
    return network.evaluate(state);
}
