const std = @import("std");
const Network = @import("network.zig").Network;
const INPUT_SIZE = @import("network.zig").INPUT_SIZE;
const HIDDEN_SIZE = @import("network.zig").HIDDEN_SIZE;
const L2_SIZE = @import("network.zig").L2_SIZE;
const L3_SIZE = @import("network.zig").L3_SIZE;
const NUM_LS_BUCKETS = @import("network.zig").NUM_LS_BUCKETS;
const OUTPUT_SIZE = @import("network.zig").OUTPUT_SIZE;

const VERSION = 0x6A448AFA;
const LEB128_MAGIC = "COMPRESSED_LEB128";

pub fn loadFromFile(network: *Network, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buffered = std.io.bufferedReader(file.reader());
    var reader = buffered.reader();

    std.debug.print("Loading Stockfish NNUE weights from: {s}\n", .{path});
    std.debug.print("Network architecture: L1={d}, L2={d}, L3={d}, {d} buckets\n", .{ HIDDEN_SIZE, L2_SIZE, L3_SIZE, NUM_LS_BUCKETS });

    const version = try readU32LE(&reader);
    if (version != VERSION) {
        std.debug.print("Warning: Unexpected version 0x{X}, expected 0x{X}\n", .{ version, VERSION });
    }

    const hash = try readU32LE(&reader);
    _ = hash;

    const desc_len = try readU32LE(&reader);
    var description_buf: [256]u8 = undefined;
    const desc_read = try reader.readAll(&description_buf);
    if (desc_read < desc_len) {
        return error.UnexpectedEOF;
    }
    const description = description_buf[0..desc_len];
    std.debug.print("Network description: {s}\n", .{description});

    const ft_hash = try readU32LE(&reader);
    _ = ft_hash;

    try readFeatureTransformer(network, &reader);

    for (0..NUM_LS_BUCKETS) |bucket| {
        const fc_hash = try readU32LE(&reader);
        _ = fc_hash;
        try readLayerStack(network, &reader, bucket);
    }

    std.debug.print("Stockfish NNUE weights loaded successfully!\n", .{});
    network.loaded = true;

    network.updater = @import("accumulator.zig").AccumulatorUpdater.init(
        network.ft_weights,
        network.ft_biases,
    );
}

fn readFeatureTransformer(network: *Network, reader: anytype) !void {
    var magic_buf: [18]u8 = undefined;
    const magic_read = try reader.readAll(&magic_buf);
    const is_compressed = if (magic_read == 18) blk: {
        break :blk std.mem.eql(u8, &magic_buf, LEB128_MAGIC);
    } else false;

    if (is_compressed) {
        std.debug.print("Feature transformer is LEB128 compressed\n", .{});

        const compressed_size = try readU32LE(reader);
        _ = compressed_size;

        try readFeatureTransformerCompressed(network, reader);
    } else {
        std.debug.print("Feature transformer is not compressed\n", .{});

        try readFeatureTransformerRaw(network, reader, &magic_buf);
    }
}

fn readFeatureTransformerRaw(network: *Network, reader: anytype, first_bytes: []const u8) !void {
    std.debug.print("Reading FT biases ({d} i16 values)...\n", .{HIDDEN_SIZE});

    _ = first_bytes;

    for (network.ft_biases) |*bias| {
        bias.* = try readI16LE(reader);
    }

    std.debug.print("Reading FT weights ({d} x {d})...\n", .{ INPUT_SIZE, HIDDEN_SIZE });
    for (network.ft_weights) |*weight_row| {
        for (weight_row) |*weight| {
            weight.* = try readI16LE(reader);
        }
    }

    std.debug.print("Skipping PSQT weights...\n", .{});
    for (0..INPUT_SIZE) |_| {
        _ = try readI32LE(reader);
    }
}

fn readFeatureTransformerCompressed(network: *Network, reader: anytype) !void {
    std.debug.print("Reading LEB128 compressed FT biases...\n", .{});

    const bias_size = try readU32LE(reader);
    var bias_data = try std.ArrayList(u8).initCapacity(network.allocator, bias_size);
    defer bias_data.deinit();

    try bias_data.resize(bias_size);
    const bytes_read = try reader.readAll(bias_data.items);
    if (bytes_read < bias_size) {
        return error.UnexpectedEOF;
    }

    var bias_values = try std.ArrayList(i16).initCapacity(network.allocator, HIDDEN_SIZE);
    defer bias_values.deinit();

    try decodeLeb128Array(&bias_data, HIDDEN_SIZE, &bias_values);

    for (network.ft_biases, 0..) |*bias, i| {
        if (i < bias_values.items.len) {
            bias.* = bias_values.items[i];
        }
    }

    std.debug.print("Reading LEB128 compressed FT weights...\n", .{});

    const halfka_weights_size = try readU32LE(reader);
    var halfka_weights_data = try std.ArrayList(u8).initCapacity(network.allocator, halfka_weights_size);
    defer halfka_weights_data.deinit();

    try halfka_weights_data.resize(halfka_weights_size);
    const halfka_bytes_read = try reader.readAll(halfka_weights_data.items);
    if (halfka_bytes_read < halfka_weights_size) {
        return error.UnexpectedEOF;
    }

    var weight_values = try std.ArrayList(i16).initCapacity(network.allocator, INPUT_SIZE * HIDDEN_SIZE);
    defer weight_values.deinit();

    try decodeLeb128Array(&halfka_weights_data, INPUT_SIZE * HIDDEN_SIZE, &weight_values);

    var idx: usize = 0;
    for (network.ft_weights) |*weight_row| {
        for (weight_row) |*weight| {
            if (idx < weight_values.items.len) {
                weight.* = weight_values.items[idx];
            }
            idx += 1;
        }
    }

    std.debug.print("Skipping LEB128 compressed PSQT weights...\n", .{});
    const psqt_size = try readU32LE(reader);
    var psqt_data = try std.ArrayList(u8).initCapacity(network.allocator, psqt_size);
    defer psqt_data.deinit();

    try psqt_data.resize(psqt_size);
    const psqt_bytes_read = try reader.readAll(psqt_data.items);
    if (psqt_bytes_read < psqt_size) {
        return error.UnexpectedEOF;
    }

    std.debug.print("Skipping Full_Threats weights...\n", .{});

    const threats_size = 60720 * HIDDEN_SIZE;
    for (0..threats_size) |_| {
        _ = try reader.readByte();
    }

    const threats_psqt_size = try readU32LE(reader);
    var threats_psqt_data = try std.ArrayList(u8).initCapacity(network.allocator, threats_psqt_size);
    defer threats_psqt_data.deinit();

    try threats_psqt_data.resize(threats_psqt_size);
    const threats_psqt_bytes_read = try reader.readAll(threats_psqt_data.items);
    if (threats_psqt_bytes_read < threats_psqt_size) {
        return error.UnexpectedEOF;
    }
}

fn readLayerStack(network: *Network, reader: anytype, bucket: usize) !void {
    if (bucket >= network.layer_stacks.len) return error.InvalidBucket;

    const ls = &network.layer_stacks[bucket];

    std.debug.print("Reading Layer Stack {d} Layer 1...\n", .{bucket});

    for (ls.l1_bias) |*bias| {
        bias.* = try readI32LE(reader);
    }

    for (ls.l1_weight_a) |*weight| {
        weight.* = @bitCast(try reader.readByte());
    }

    for (ls.l1_weight_b) |*weight| {
        weight.* = @bitCast(try reader.readByte());
    }

    std.debug.print("Reading Layer Stack {d} Layer 2...\n", .{bucket});

    for (ls.l2_bias) |*bias| {
        bias.* = try readI32LE(reader);
    }

    for (ls.l2_weight) |*weight| {
        weight.* = @bitCast(try reader.readByte());
    }

    std.debug.print("Reading Layer Stack {d} Output...\n", .{bucket});

    for (ls.output_bias) |*bias| {
        bias.* = try readI32LE(reader);
    }

    for (ls.output_weight) |*weight| {
        weight.* = @bitCast(try reader.readByte());
    }
}

fn decodeLeb128Array(data: *const std.ArrayList(u8), n: usize, result: *std.ArrayList(i16)) !void {
    var k: usize = 0;
    for (0..n) |_| {
        if (k >= data.items.len) return error.UnexpectedEOF;

        var r: i32 = 0;
        var shift: u5 = 0;
        while (true) {
            if (k >= data.items.len) return error.UnexpectedEOF;
            const byte = data.items[k];
            k += 1;
            r |= @as(i32, byte & 0x7F) << shift;
            shift += 7;
            if (byte & 0x80 == 0) {
                if (byte & 0x40 != 0) {
                    r |= ~@as(i32, (@as(i32, 1) << @as(u5, shift)) - 1);
                }
                break;
            }
        }
        try result.append(@intCast(r));
    }
}

fn readU32LE(reader: anytype) !u32 {
    const bytes = try reader.readBytesNoEof(4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readI16LE(reader: anytype) !i16 {
    const bytes = try reader.readBytesNoEof(2);
    const unsigned = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    return @bitCast(unsigned);
}

fn readI32LE(reader: anytype) !i32 {
    const bytes = try reader.readBytesNoEof(4);
    const unsigned = @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
    return @bitCast(unsigned);
}

pub fn verifyFile(path: []const u8) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Could not open NNUE file: {}\n", .{err});
        return false;
    };
    defer file.close();

    const stat = try file.stat();
    std.debug.print("File size: {d} bytes\n", .{stat.size});

    if (stat.size < 1000000) {
        std.debug.print("Warning: File seems too small for Stockfish NNUE format\n", .{});
        return false;
    }

    return true;
}

pub fn loadNetwork(network: *Network, path: []const u8) bool {
    loadFromFile(network, path) catch |err| {
        std.debug.print("Failed to load Stockfish NNUE network: {}\n", .{err});
        std.debug.print("Falling back to classical evaluation.\n", .{});
        return false;
    };
    return true;
}
