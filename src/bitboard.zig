pub const Bitboard = u64;

pub inline fn bit(square: u8) Bitboard {
    return @as(Bitboard, 1) << @intCast(square);
}

pub inline fn has(board: Bitboard, square: u8) bool {
    return board & bit(square) != 0;
}

pub inline fn popLsb(board: *Bitboard) u8 {
    const square: u8 = @intCast(@ctz(board.*));
    board.* &= board.* - 1;
    return square;
}

pub inline fn count(board: Bitboard) u7 {
    return @intCast(@popCount(board));
}

fn valid(rank: i16, file: i16) bool {
    return rank >= 0 and rank < 8 and file >= 0 and file < 8;
}

fn leaperAttacks(square: u8, deltas: anytype) Bitboard {
    const rank: i16 = @intCast(square / 8);
    const file: i16 = @intCast(square % 8);
    var attacks: Bitboard = 0;
    for (deltas) |delta| {
        const r = rank + delta[0];
        const f = file + delta[1];
        if (valid(r, f)) attacks |= bit(@intCast(r * 8 + f));
    }
    return attacks;
}

const knight_deltas = [_][2]i16{
    .{ -2, -1 }, .{ -2, 1 }, .{ -1, -2 }, .{ -1, 2 },
    .{ 1, -2 },  .{ 1, 2 },  .{ 2, -1 },  .{ 2, 1 },
};
const king_deltas = [_][2]i16{
    .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 }, .{ 0, -1 },
    .{ 0, 1 },   .{ 1, -1 }, .{ 1, 0 },  .{ 1, 1 },
};

pub const KNIGHT_ATTACKS: [64]Bitboard = blk: {
    @setEvalBranchQuota(10000);
    var table: [64]Bitboard = undefined;
    for (0..64) |square| table[square] = leaperAttacks(@intCast(square), knight_deltas);
    break :blk table;
};

pub const KING_ATTACKS: [64]Bitboard = blk: {
    @setEvalBranchQuota(10000);
    var table: [64]Bitboard = undefined;
    for (0..64) |square| table[square] = leaperAttacks(@intCast(square), king_deltas);
    break :blk table;
};

pub const PAWN_ATTACKS: [2][64]Bitboard = blk: {
    @setEvalBranchQuota(10000);
    var table: [2][64]Bitboard = [_][64]Bitboard{[_]Bitboard{0} ** 64} ** 2;
    for (0..64) |square_usize| {
        const square: u8 = @intCast(square_usize);
        const rank: i16 = @intCast(square / 8);
        const file: i16 = @intCast(square % 8);
        for ([_]i16{ -1, 1 }) |df| {
            if (valid(rank + 1, file + df)) table[0][square] |= bit(@intCast((rank + 1) * 8 + file + df));
            if (valid(rank - 1, file + df)) table[1][square] |= bit(@intCast((rank - 1) * 8 + file + df));
        }
    }
    break :blk table;
};

const bishop_directions = [_][2]i16{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } };
const rook_directions = [_][2]i16{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };

const Magic = struct {
    mask: Bitboard,
    multiplier: Bitboard,
    shift: u6,
    offset: u32,
};

const bishop_multipliers = [64]Bitboard{
    0x10102002004a1420, 0x3009080104082090, 0x20a2020400200808, 0x204404080020102,
    0x101104000000028,  0x28811008040000e8, 0x1031011032200020, 0x41040118921000,
    0x400041004812400,  0x4100108188008081, 0x20484604042a09,   0x2208a002100,
    0xa1210002805,      0x400a410460448100, 0x13060480a086000,  0x2101411400840412,
    0x1a10100404500409, 0x4010028401026400, 0x2050000800401020, 0x8202404001420,
    0x32880400a00600,   0x202000022100202,  0x204082082111040,  0x480c210084010800,
    0xc2620410200200,   0x80c2102042901202, 0x9000320050040040, 0x8004080010220040,
    0x20044002003004,   0x120401884100a003, 0x2004208014020128, 0x4010302005400a0,
    0x950084500600402,  0x81e0900901102200, 0x10040128008412c0, 0x402004042940100,
    0x2104204010040100, 0x420009100802400,  0x204082220808082,  0x2002004248020218,
    0x1042160208400,    0x440d0148101080,   0x8044a02030000802, 0xc081044206204800,
    0x219020800400,     0x8404010041000201, 0x2210c0102492209,  0x8010012110283100,
    0x183880109a00001,  0x1001411090900080, 0x2002120084045420, 0x2126087842020022,
    0x8040004010410128, 0x8024030c2008020,  0x121241004812002,  0x308010822004000,
    0x83042805141020,   0x220804212102288,  0x8000014100880400, 0x1000080000840410,
    0x88080031203200,   0x1002200202c202,   0x54802540400,      0xa010041108003100,
};
const rook_multipliers = [64]Bitboard{
    0x1080004008801020, 0x840092002c03000,  0x1900200010400900, 0x880100008000480,
    0x4200100420080200, 0x8100020100080400, 0x200040110886200,  0x200008040220411,
    0x404800084400220,  0x401000402000,     0x86001081220440,   0x408800800100280,
    0xa001201040820,    0x8848800200840080, 0x4001000100040200, 0x442000102105084,
    0x9080010020804100, 0x40404000201009,   0x808010002009,     0x2200090021d00100,
    0x8008008040080,    0x4004002010040,    0x11040008015042,   0xa0001768104,
    0x800080204009,     0x2010004140002001, 0x9800200280100080, 0x1000100080080080,
    0x50500500080100,   0x20080040080,      0xc10010400420810,  0x1040008200005104,
    0x1808240088004a0,  0x882804004802000,  0x880402001001100,  0x100080800800,
    0x2000480131001500, 0x2000400800280,    0x80020104000810,   0x80441044120000a1,
    0x800040008020,     0x41040201000c000,  0x1004020010010,    0x800100100090021,
    0x4080004008080,    0x10040002008080,   0x2012004881020004, 0x8300842444820011,
    0x88403882010200,   0x820400080210100,  0x110910040a00300,  0x801100280080480,
    0x242009008200600,  0x1002000489500200, 0x40800200010080,   0x91800041000080,
    0xc91800020c101,    0xa41104009802103,  0x880401202210a,    0x300089142101,
    0x8002002004100802, 0x30010002084c0007, 0x888221800813004,  0x8208044010a,
};

fn slidingAttacks(square: u8, occupancy: Bitboard, directions: anytype) Bitboard {
    const start_rank: i16 = @intCast(square / 8);
    const start_file: i16 = @intCast(square % 8);
    var attacks: Bitboard = 0;
    for (directions) |direction| {
        var rank = start_rank + direction[0];
        var file = start_file + direction[1];
        while (valid(rank, file)) : ({
            rank += direction[0];
            file += direction[1];
        }) {
            const target: u8 = @intCast(rank * 8 + file);
            attacks |= bit(target);
            if (has(occupancy, target)) break;
        }
    }
    return attacks;
}

fn relevantMask(square: u8, directions: anytype) Bitboard {
    const start_rank: i16 = @intCast(square / 8);
    const start_file: i16 = @intCast(square % 8);
    var mask: Bitboard = 0;
    for (directions) |direction| {
        var rank = start_rank + direction[0];
        var file = start_file + direction[1];
        while (valid(rank, file)) {
            const next_rank = rank + direction[0];
            const next_file = file + direction[1];
            if (!valid(next_rank, next_file)) break;
            mask |= bit(@intCast(rank * 8 + file));
            rank = next_rank;
            file = next_file;
        }
    }
    return mask;
}

fn buildMagics(comptime multipliers: [64]Bitboard, comptime directions: anytype) [64]Magic {
    @setEvalBranchQuota(10000);
    var result: [64]Magic = undefined;
    var offset: u32 = 0;
    for (0..64) |square| {
        const mask = relevantMask(@intCast(square), directions);
        const bits: u6 = @intCast(@popCount(mask));
        result[square] = .{ .mask = mask, .multiplier = multipliers[square], .shift = @intCast(64 - @as(u7, bits)), .offset = offset };
        offset += @as(u32, 1) << bits;
    }
    return result;
}

const bishop_magics = buildMagics(bishop_multipliers, bishop_directions);
const rook_magics = buildMagics(rook_multipliers, rook_directions);

inline fn magicIndex(occupancy: Bitboard, magic: Magic) usize {
    return magic.offset + @as(usize, @intCast(((occupancy & magic.mask) *% magic.multiplier) >> magic.shift));
}

fn buildAttackTable(comptime size: usize, comptime magics: [64]Magic, comptime directions: anytype) [size]Bitboard {
    @setEvalBranchQuota(20000000);
    var table: [size]Bitboard = [_]Bitboard{0} ** size;
    for (0..64) |square| {
        const magic = magics[square];
        var subset: Bitboard = 0;
        while (true) {
            table[magicIndex(subset, magic)] = slidingAttacks(@intCast(square), subset, directions);
            if (subset == magic.mask) break;
            subset = (subset -% magic.mask) & magic.mask;
        }
    }
    return table;
}

const bishop_table = buildAttackTable(5248, bishop_magics, bishop_directions);
const rook_table = buildAttackTable(102400, rook_magics, rook_directions);

pub inline fn initMagics() void {}

pub inline fn bishopAttacks(square: u8, occupancy: Bitboard) Bitboard {
    return bishop_table[magicIndex(occupancy, bishop_magics[square])];
}

pub inline fn rookAttacks(square: u8, occupancy: Bitboard) Bitboard {
    return rook_table[magicIndex(occupancy, rook_magics[square])];
}

pub inline fn queenAttacks(square: u8, occupancy: Bitboard) Bitboard {
    return bishopAttacks(square, occupancy) | rookAttacks(square, occupancy);
}
