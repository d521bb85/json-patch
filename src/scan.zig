//! Fast, non-validating scanning over JSON text.
//!
//! Everything here assumes the structure of the input is mostly trustworthy
//! and is designed to find where a value ends without looking at what is
//! inside it. All functions stay within the bounds of the slice they are given
//! and report malformed input by returning `null`, so garbage in a document
//! that skipped validation can produce an error but never unsafe behavior.

const std = @import("std");
const builtin = @import("builtin");

const assert = std.debug.assert;

/// Width of the vectors used to search within strings.
const chunk_len = @min(std.simd.suggestVectorLength(u8) orelse 16, 32);
const Chunk = @Vector(chunk_len, u8);
pub const Block = @Vector(64, u8);

/// Returns whether two strings of the same length are equal. Comparing the first
/// and last bytes of a short string as integers, overlapping in the middle, needs
/// neither a loop nor a call.
pub inline fn eql(a: []const u8, b: []const u8) bool {
    const len = a.len;
    if (len >= 8) {
        if (len > 16) return std.mem.eql(u8, a, b);
        return load(u64, a, 0) == load(u64, b, 0) and load(u64, a, len - 8) == load(u64, b, len - 8);
    }
    if (len >= 4) return load(u32, a, 0) == load(u32, b, 0) and load(u32, a, len - 4) == load(u32, b, len - 4);
    if (len == 0) return true;
    return a[0] == b[0] and a[len / 2] == b[len / 2] and a[len - 1] == b[len - 1];
}

inline fn load(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

/// Returns the offset of the first `true` element of `mask`.
pub inline fn firstSet(mask: @Vector(chunk_len, bool)) ?usize {
    const bits = chunkBits(mask);
    return if (bits == 0) null else @ctz(bits) / chunk_bits;
}

/// How many bits `chunkBits` uses for each byte.
pub const chunk_bits = if (builtin.cpu.arch == .aarch64 and chunk_len == 16) 4 else 1;

/// Packs a mask of a chunk into an integer in which the lowest set bit stands
/// for the first `true` element. NEON cannot spare a bit for each byte, but it
/// can narrow each 16-bit lane by 4 bits with a single `shrn` instruction.
pub inline fn chunkBits(mask: @Vector(chunk_len, bool)) u64 {
    if (comptime chunk_bits == 4) {
        const bytes: @Vector(16, u8) = @select(u8, mask, @as(Chunk, @splat(0xff)), @as(Chunk, @splat(0)));
        const wide: @Vector(8, u16) = @bitCast(bytes);
        const narrow: @Vector(8, u8) = @truncate(wide >> @splat(4));
        return @bitCast(narrow);
    }
    const bits: @Int(.unsigned, chunk_len) = @bitCast(mask);
    return if (builtin.cpu.arch.endian() == .little) bits else @bitReverse(bits);
}

inline fn stopBits(chunk: Chunk) u64 {
    return chunkBits((chunk == @as(Chunk, @splat('"'))) | (chunk == @as(Chunk, @splat('\\'))));
}

pub inline fn loadChunk(src: []const u8, at: usize) Chunk {
    return src[at..][0..chunk_len].*;
}

pub inline fn hasChunk(src: []const u8, i: usize) bool {
    return src.len - i >= chunk_len;
}

pub const chunk_size = chunk_len;

pub inline fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

pub inline fn skipWhitespace(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] <= ' ' and isWhitespace(src[i])) i += 1;
    return i;
}

pub const StringEnd = struct {
    /// Index of the closing quote.
    end: usize,
    /// Whether the string contains a backslash.
    escaped: bool,
};

/// Finds the closing quote of a string whose contents begin at `start`.
pub inline fn stringEnd(src: []const u8, start: usize) ?StringEnd {
    var i = start;
    var escaped = false;
    // Most strings end within two chunks, and they often end close to the border
    // between them. Considering both at once makes that impossible to mispredict.
    if (src.len -| i >= 2 * chunk_len) {
        const first = stopBits(loadChunk(src, i));
        const second = stopBits(loadChunk(src, i + chunk_len));
        if (first | second != 0) {
            const offset = if (first != 0) @ctz(first) / chunk_bits else chunk_len + @ctz(second) / chunk_bits;
            if (src[i + offset] == '"') return .{ .end = i + offset, .escaped = false };
        }
    }
    while (src.len - i >= chunk_len) {
        const chunk = loadChunk(src, i);
        const stop = (chunk == @as(Chunk, @splat('"'))) | (chunk == @as(Chunk, @splat('\\')));
        const offset = firstSet(stop) orelse {
            i += chunk_len;
            continue;
        };
        i += offset;
        if (src[i] == '"') return .{ .end = i, .escaped = escaped };
        escaped = true;
        i += 2;
        if (i > src.len) return null;
    }
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            '"' => return .{ .end = i, .escaped = escaped },
            '\\' => {
                escaped = true;
                i += 1;
            },
            else => {},
        }
    }
    return null;
}

/// Returns the index just past the value that begins at `start`, which must
/// not be whitespace.
pub inline fn valueEnd(src: []const u8, start: usize) ?usize {
    if (start >= src.len) return null;
    switch (src[start]) {
        '"' => {
            const string = stringEnd(src, start + 1) orelse return null;
            return string.end + 1;
        },
        '{', '[' => return containerEnd(src, start),
        else => return scalarEnd(src, start),
    }
}

/// Returns the index just past the number or literal at `start`.
inline fn scalarEnd(src: []const u8, start: usize) usize {
    if (src.len - start >= chunk_len) {
        const chunk = loadChunk(src, start);
        // Every byte that can end a scalar is at most a space, or it is a comma
        // or a closing bracket. The latter two differ only in bit 5.
        const closers = chunk | @as(Chunk, @splat(0x20));
        const stop = chunkBits((chunk <= @as(Chunk, @splat(' '))) | (chunk == @as(Chunk, @splat(','))) |
            (closers == @as(Chunk, @splat('}'))));
        // A value is never empty, even in text that is not valid.
        const after_first = stop & (@as(u64, std.math.maxInt(u64)) << chunk_bits);
        if (after_first != 0) return start + @ctz(after_first) / chunk_bits;
    }
    var i = start + 1;
    while (i < src.len) : (i += 1) {
        switch (src[i]) {
            ',', ']', '}', ' ', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    return i;
}

/// Returns the index just past the container that opens at `start`.
///
/// Rather than walking tokens, this classifies 64 bytes at a time into bitmasks
/// of quotes and brackets, then uses population counts to step over any block
/// in which the nesting depth cannot return to zero.
pub fn containerEnd(src: []const u8, start: usize) ?usize {
    assert(src[start] == '{' or src[start] == '[');
    var state: BlockState = .{};
    var pos = start;
    while (src.len - pos >= 64) : (pos += 64) {
        if (state.scan(src[pos..][0..64].*)) |offset| return pos + offset;
    }
    var tail: [64]u8 = @splat(' ');
    @memcpy(tail[0 .. src.len - pos], src[pos..]);
    const offset = state.scan(tail) orelse return null;
    return pos + offset;
}

const BlockState = struct {
    depth: u64 = 0,
    /// All ones if the previous block ended inside a string.
    in_string: u64 = 0,
    /// 1 if the previous block ended with an unescaped backslash.
    escape_carry: u64 = 0,

    /// Returns the offset just past the bracket that closes the container, if
    /// it is in `block`.
    inline fn scan(state: *BlockState, block: Block) ?usize {
        const quotes = maskOf(block, '"') & ~escapedBytes(&state.escape_carry, maskOf(block, '\\'));
        const strings = stringBytes(&state.in_string, quotes);

        // '[' and ']' differ from '{' and '}' only in bit 5.
        const folded = block | @as(Block, @splat(0x20));
        var opens = maskOf(folded, '{') & ~strings;
        var closes = maskOf(folded, '}') & ~strings;

        if (@popCount(closes) < state.depth) {
            state.depth = state.depth + @popCount(opens) - @popCount(closes);
            return null;
        }
        while (closes != 0) : (closes &= closes - 1) {
            const before = (closes & -%closes) - 1;
            state.depth += @popCount(opens & before);
            opens &= ~before;
            state.depth -= 1;
            if (state.depth == 0) return @as(usize, @ctz(closes)) + 1;
        }
        state.depth += @popCount(opens);
        return null;
    }
};

/// Returns a mask of the bytes that are escaped by the preceding backslash.
/// `carry` is 1 if the previous block ended with an unescaped backslash.
pub inline fn escapedBytes(carry: *u64, all_backslashes: u64) u64 {
    if (all_backslashes == 0) {
        defer carry.* = 0;
        return carry.*;
    }
    const even: u64 = 0x5555_5555_5555_5555;
    const backslashes = all_backslashes & ~carry.*;
    const follows = (backslashes << 1) | carry.*;
    const odd_starts = backslashes & ~even & ~follows;
    const sum, const overflow = @addWithOverflow(odd_starts, backslashes);
    carry.* = overflow;
    return (even ^ (sum << 1)) & follows;
}

/// Returns a mask of the bytes from each opening quote up to, but not including,
/// its closing quote. `in_string` is all ones if the previous block ended inside
/// a string.
pub inline fn stringBytes(in_string: *u64, quotes: u64) u64 {
    const strings = prefixXor(quotes) ^ in_string.*;
    in_string.* = @bitCast(@as(i64, @bitCast(strings)) >> 63);
    return strings;
}

pub inline fn maskOf(block: Block, byte: u8) u64 {
    return bitsOf(block == @as(Block, @splat(byte)));
}

/// Packs a mask into an integer, with bit `i` standing for byte `i`.
pub inline fn bitsOf(mask: @Vector(64, bool)) u64 {
    return bitsOfBytes(bytesOf(mask));
}

/// Returns a vector with all bits of each byte set if that element of `mask` is.
/// Logic on these is much faster than on vectors of `bool`, which most compilers
/// handle one element at a time on anything without mask registers.
pub inline fn bytesOf(mask: @Vector(64, bool)) Block {
    return @select(u8, mask, @as(Block, @splat(0xff)), @as(Block, @splat(0)));
}

/// As `bitsOf`, for a mask from `bytesOf`.
pub inline fn bitsOfBytes(mask: Block) u64 {
    if (comptime builtin.cpu.arch == .aarch64) return gatherBits(mask);
    const bits: u64 = @bitCast(mask == @as(Block, @splat(0xff)));
    return if (builtin.cpu.arch.endian() == .little) bits else @bitReverse(bits);
}

/// Compilers lower a plain bit cast on NEON by summing each lane separately,
/// which is several times slower than merging neighboring bytes of all lanes
/// together, as done here. This is written with `addp` because compilers replace
/// the equivalent vector arithmetic with two shuffles and an `orr`.
inline fn gatherBits(mask: Block) u64 {
    const Lane = @Vector(16, u8);
    const weights: Lane = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const bytes = mask & @shuffle(u8, weights, undefined, repeat_lane);
    const merge = struct {
        inline fn pairs(a: Lane, b: Lane) Lane {
            return asm ("addp %[out].16b, %[a].16b, %[b].16b"
                : [out] "=w" (-> Lane),
                : [a] "w" (a),
                  [b] "w" (b),
            );
        }
    };
    const lanes: [4]Lane = @bitCast(bytes);
    const halves = merge.pairs(merge.pairs(lanes[0], lanes[1]), merge.pairs(lanes[2], lanes[3]));
    const words: @Vector(2, u64) = @bitCast(merge.pairs(halves, halves));
    return words[0];
}

const repeat_lane: @Vector(64, i32) = blk: {
    var indices: [64]i32 = undefined;
    for (&indices, 0..) |*index, i| index.* = @intCast(i % 16);
    break :blk indices;
};

/// Each bit of the result is the parity of all lower bits of `x`, which turns a
/// mask of quotes into a mask of string contents.
pub inline fn prefixXor(x: u64) u64 {
    var y = x;
    y ^= y << 1;
    y ^= y << 2;
    y ^= y << 4;
    y ^= y << 8;
    y ^= y << 16;
    y ^= y << 32;
    return y;
}

const testing = std.testing;

/// A deliberately simple reference for `containerEnd`.
fn naiveContainerEnd(src: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_string) {
            if (c == '\\') i += 1 else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{', '[' => depth += 1,
            '}', ']' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

test eql {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    for (&a, 0..) |*byte, i| byte.* = @truncate('a' + i % 26);
    b = a;
    for (0..a.len) |len| {
        try testing.expect(eql(a[0..len], b[0..len]));
        for (0..len) |i| {
            b[i] ^= 1;
            try testing.expect(!eql(a[0..len], b[0..len]));
            b[i] ^= 1;
        }
    }
}

test containerEnd {
    try testing.expectEqual(2, containerEnd("{}", 0));
    try testing.expectEqual(2, containerEnd("[]  ", 0));
    try testing.expectEqual(5, containerEnd("[[[]]] ", 1));
    try testing.expectEqual(11, containerEnd(
        \\{"a":"}\""}x
    , 0));
    try testing.expectEqual(null, containerEnd("[1,2", 0));
    try testing.expectEqual(null, containerEnd("[\"]", 0));
}

test "containerEnd agrees with a naive scan across block boundaries" {
    var prng: std.Random.DefaultPrng = .init(0x6902);
    const random = prng.random();
    var buffer: [512]u8 = undefined;

    for (0..20_000) |_| {
        const len = random.intRangeAtMost(usize, 2, buffer.len);
        var fill: usize = 1;
        buffer[0] = '[';
        var depth: usize = 1;
        var in_string = false;
        while (fill < len - depth - @intFromBool(in_string) and fill < buffer.len - 2) {
            if (in_string) {
                switch (random.uintLessThan(u8, 6)) {
                    0 => {
                        buffer[fill] = '"';
                        in_string = false;
                    },
                    1 => {
                        // Long runs of backslashes exercise the carry.
                        const run = random.intRangeAtMost(usize, 1, 70);
                        for (0..run) |_| {
                            if (fill + 2 >= buffer.len) break;
                            buffer[fill] = '\\';
                            buffer[fill + 1] = '\\';
                            fill += 2;
                        }
                        continue;
                    },
                    2 => {
                        buffer[fill] = '\\';
                        buffer[fill + 1] = '"';
                        fill += 1;
                    },
                    else => buffer[fill] = "{}[]x,:"[random.uintLessThan(u8, 7)],
                }
            } else switch (random.uintLessThan(u8, 5)) {
                0 => {
                    buffer[fill] = '"';
                    in_string = true;
                },
                1 => {
                    buffer[fill] = '[';
                    depth += 1;
                },
                2 => {
                    buffer[fill] = '{';
                    depth += 1;
                },
                3 => {
                    if (depth > 1) {
                        buffer[fill] = if (random.boolean()) ']' else '}';
                        depth -= 1;
                    } else buffer[fill] = '1';
                },
                else => buffer[fill] = ',',
            }
            fill += 1;
        }
        if (in_string and fill < buffer.len) {
            buffer[fill] = '"';
            fill += 1;
        }
        while (depth > 0 and fill < buffer.len) : (depth -= 1) {
            buffer[fill] = ']';
            fill += 1;
        }
        const text = buffer[0..fill];
        try testing.expectEqual(naiveContainerEnd(text, 0), containerEnd(text, 0));
    }
}

test stringEnd {
    const plain = stringEnd("abc\"", 0).?;
    try testing.expectEqual(3, plain.end);
    try testing.expect(!plain.escaped);

    const escaped = stringEnd("a\\\"b\\\\\"z", 0).?;
    try testing.expectEqual(6, escaped.end);
    try testing.expect(escaped.escaped);

    const long = "0123456789abcdef0123456789abcdef0123456789abcdef\"";
    try testing.expectEqual(long.len - 1, stringEnd(long, 0).?.end);

    try testing.expectEqual(null, stringEnd("no end", 0));
    try testing.expectEqual(null, stringEnd("ends in \\", 0));
    try testing.expectEqual(null, stringEnd("0123456789abcdef0123456789abcdef0123456789abcde\\", 0));
}

test valueEnd {
    try testing.expectEqual(4, valueEnd("true,", 0));
    try testing.expectEqual(2, valueEnd("12}", 0));
    try testing.expectEqual(2, valueEnd("-1 ", 0));
    try testing.expectEqual(3, valueEnd("\"a\"", 0));
    try testing.expectEqual(null, valueEnd("", 0));

    // The same, with enough text after them to be read a chunk at a time.
    try testing.expectEqual(4, valueEnd("true,                                ", 0));
    try testing.expectEqual(2, valueEnd("12}                                  ", 0));
    try testing.expectEqual(5, valueEnd("12345\n                               ", 0));

    // Invalid text cannot produce an empty value.
    try testing.expectEqual(2, valueEnd(",1]                                  ", 0));
    try testing.expectEqual(1, valueEnd("]]                                   ", 0));
    try testing.expectEqual(1, valueEnd(":,                                   ", 0));
}
