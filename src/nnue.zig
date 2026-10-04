pub const features = @import("nnue/features.zig");
pub const accumulator = @import("nnue/accumulator.zig");
pub const network = @import("nnue/network.zig");
pub const loader = @import("nnue/loader.zig");

pub const Network = network.Network;
pub const AccumulatorStack = accumulator.AccumulatorStack;
pub const Feature = features.Feature;

pub const INPUT_SIZE = network.INPUT_SIZE;
pub const HIDDEN_SIZE = network.HIDDEN_SIZE;
pub const OUTPUT_SIZE = network.OUTPUT_SIZE;

pub const loadNetwork = loader.loadNetwork;
pub const verifyFile = loader.verifyFile;
pub const evaluatePosition = network.evaluatePosition;
