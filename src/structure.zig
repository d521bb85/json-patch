//! Reading the structure of JSON text 64 bytes at a time.
//!
//! A conventional validator steps from token to token, and spends most of its
//! time recovering from mispredicted branches, because the next token is hard
//! to guess. This one turns each block of text into bitmasks and checks the
//! grammar with arithmetic on those masks, so that its speed hardly depends on
//! how many tokens there are. Only brackets, numbers, literals, and escapes are
//! looked at individually.
//!
//! `document` is sound but not complete: all it accepts is valid, but it declines
//! anything unusual, such as a document that is not an object or an array. A
//! decline means nothing about the text, which then goes to the strict validator
//! in `validate.zig`, and that is also what reports where text is invalid. This
//! file only has to be right about what it accepts.
//!
//! The same pass records where containers end, in an `Index`, because finding
//! that is the expensive part of expanding one. `Index.build` does this for text
//! that was not validated, and one pass then replaces scanning every level of a
//! document as it is expanded.
//!
//! # How the grammar is checked
//!
//! Every token has to be one that may follow the token before it, and every
//! closing bracket has to match its opening bracket. So each kind of token
//! produces a mask of the positions just past it, and adding the mask of
//! whitespace to that carries each bit over any whitespace, which lands it on the
//! next token. All of these can be calculated at once for a whole block.
//!
//! Only two things depend on context: what may follow a comma, and whether a
//! string is a key. Both depend on the innermost container. Since that changes
//! only at brackets, the single loop over brackets produces a mask of which
//! bytes are directly within an object.

const std = @import("std");
const builtin = @import("builtin");
const scan = @import("scan.zig");
const strict = @import("validate.zig");

const Allocator = std.mem.Allocator;
const Block = scan.Block;
const Chunk = @Vector(scan.chunk_size, u8);
const maskOf = scan.maskOf;

/// Containers shorter than this are not listed in an index, because finding
/// their end takes about as long as looking it up, and most containers are short.
const min_indexed_len = 32;

/// Text shorter than this has too few containers that are long enough to list.
const min_indexed_document = 128;

/// The deepest nesting handled here. Deeper text is left to `validate.zig`.
const max_levels = 1024;

/// Where containers in some text end, in order of where they begin. Whatever is
/// not listed is short, and so is anything inside of it, so nothing is listed
/// inside of a container that is not listed.
pub const Index = struct {
    /// The last entry is a sentinel.
    entries: std.ArrayList(Entry) = .empty,

    pub const Entry = extern struct {
        /// The offset of the opening bracket.
        open: u32,
        /// The offset of the closing bracket.
        close: u32,
        /// The index of the first entry that follows this container.
        next: u32,
    };

    const sentinel: Entry = .{ .open = std.math.maxInt(u32), .close = 0, .next = 0 };

    /// Returns whether `len` bytes of text are worth an index, and can have one.
    pub fn suits(len: usize) bool {
        return len >= min_indexed_document and len <= std.math.maxInt(u32);
    }

    /// Records the containers of `text`, which starts with a bracket, assuming
    /// that it is valid. If it turns out not to be, the index is left empty.
    pub fn build(index: *Index, allocator: Allocator, text: []const u8) Allocator.Error!void {
        var table: Table = try .init(allocator, index, text.len);
        var levels: Levels(true) = .{};
        levels.stack[0] = 0;

        var in_string: u64 = 0;
        var escape_carry: u64 = 0;
        var pos: usize = 0;
        while (text.len - pos >= 64) : (pos += 64) {
            const block: Block = text[pos..][0..64].*;
            try table.reserve();
            if (levels.scanBrackets(&table, block, text[pos..][0..64], pos, &in_string, &escape_carry)) return;
        }
        var tail: [64]u8 = @splat(' ');
        @memcpy(tail[0 .. text.len - pos], text[pos..]);
        try table.reserve();
        if (levels.scanBrackets(&table, tail, &tail, pos, &in_string, &escape_carry)) return;
        table.discard();
    }

    /// Returns a cursor over the children of the container that starts `offset`
    /// bytes into the indexed text, of which `readable` bytes remain.
    pub fn cursor(index: *const Index, offset: usize, readable: usize) Cursor {
        var result: Cursor = .{ .readable = readable };
        const entries = index.entries.items;
        if (entries.len < 2) return result;
        var low: usize = 0;
        var size = entries.len - 1;
        while (size > 1) {
            const half = size / 2;
            if (entries[low + half].open <= offset) low += half;
            size -= half;
        }
        if (entries[low].open != offset) return result;
        result.entries = entries.ptr;
        result.next = @intCast(low + 1);
        result.base = offset;
        return result;
    }
};

/// Walks the children of a container, skipping over those that are in the index
/// without looking at them. Children must be visited in order.
pub const Cursor = struct {
    entries: [*]const Index.Entry = @ptrCast(&Index.sentinel),
    next: u32 = 0,
    /// The offset of the container in the indexed text. The default is larger
    /// than any offset, so that a container that is not listed matches nothing.
    base: u64 = 1 << 63,
    /// How many bytes from the start of the container can be read, which is at
    /// least all of it. A scan never needs to go beyond the end of the container,
    /// but being able to read a whole block or chunk saves handling the bytes
    /// that remain one at a time, which is slow.
    readable: usize,

    /// Returns the bytes that can be read from `text`, which is the container.
    pub inline fn widen(cursor: *const Cursor, text: []const u8) []const u8 {
        return text.ptr[0..cursor.readable];
    }

    /// Returns the end of the container at `start`.
    inline fn containerEnd(cursor: *Cursor, text: []const u8, start: usize) ?usize {
        const entry = cursor.entries[cursor.next];
        if (entry.open != cursor.base + start) return scan.containerEnd(cursor.widen(text), start);
        cursor.next = entry.next;
        return @intCast(entry.close + 1 - cursor.base);
    }

    /// Returns the index just past the value that begins at `start`. See
    /// `scan.valueEnd`.
    pub inline fn valueEnd(cursor: *Cursor, text: []const u8, start: usize) ?usize {
        if (start >= text.len) return null;
        const end = switch (text[start]) {
            '{', '[' => cursor.containerEnd(text, start),
            else => scan.valueEnd(cursor.widen(text), start),
        } orelse return null;
        // Text that skipped validation may not be as well formed as it looks.
        return if (end <= text.len) end else null;
    }
};

/// An index under construction.
const Table = struct {
    allocator: Allocator,
    index: *Index,
    /// The most entries the index may have, which keeps it from outgrowing the
    /// text, however many containers the text has.
    limit: u32,
    entries: [*]Index.Entry,
    capacity: u32,
    count: u32 = 0,
    /// Whether too many containers were found for the index to be worthwhile.
    /// Entries keep being written, but no longer mean anything.
    overflowed: bool = false,

    fn init(allocator: Allocator, index: *Index, len: usize) Allocator.Error!Table {
        index.entries.clearRetainingCapacity();
        const limit: u32 = @intCast(len / @sizeOf(Index.Entry) + 128);
        try index.entries.ensureTotalCapacity(allocator, len / 256 + 128);
        return .{
            .allocator = allocator,
            .index = index,
            .limit = limit,
            .entries = index.entries.items.ptr,
            .capacity = @intCast(index.entries.capacity),
        };
    }

    /// Makes room for one block's worth of containers, and the sentinel.
    inline fn reserve(table: *Table) Allocator.Error!void {
        if (table.capacity - table.count < 66) try table.grow();
    }

    fn grow(table: *Table) Allocator.Error!void {
        const capacity = @min(table.capacity * 2, table.limit);
        if (capacity -| table.count < 66) {
            table.overflowed = true;
            table.count = 0;
            return;
        }
        table.index.entries.items.len = table.count;
        try table.index.entries.ensureTotalCapacity(table.allocator, capacity);
        table.entries = table.index.entries.items.ptr;
        table.capacity = @intCast(table.index.entries.capacity);
    }

    fn finish(table: *Table) void {
        if (table.overflowed) return table.discard();
        table.entries[table.count] = Index.sentinel;
        table.index.entries.items.len = table.count + 1;
    }

    /// Gives up on the index, which leaves it empty, so that expanding containers
    /// falls back on scanning them. The table cannot be used after this.
    fn discard(table: *Table) void {
        table.index.entries.clearAndFree(table.allocator);
    }
};

/// The stack of open containers, and optionally the index being built from it.
fn Levels(comptime record: bool) type {
    return struct {
        const Self = @This();

        /// Index 0 stands for the outside of the root, and looks like an array.
        /// Entries are the number of the index entry shifted left by one, plus
        /// a bit that is set for an object.
        stack: [max_levels + 2]u32 = undefined,
        /// The number of containers that are open.
        depth: u32 = 0,
        /// 1 if the innermost container is an object.
        in_object: u32 = 0,
        /// Nonzero if a closing bracket did not match.
        mismatched: u32 = 0,
        /// The offset just past the root, once it has been closed.
        end: usize = 0,

        /// Handles every bracket in `all_brackets`, a mask of `block`, which
        /// starts at offset `pos`. Returns a mask of the bytes directly within
        /// an object, in which an opening bracket counts as outside of what it
        /// opens, and a closing bracket as inside of what it closes.
        inline fn enter(
            levels: *Self,
            table: *Table,
            block: *const [64]u8,
            pos: usize,
            all_brackets: u64,
        ) u64 {
            var objects = 0 -% @as(u64, levels.in_object);
            var brackets = all_brackets;
            var depth = levels.depth;
            var in_object = levels.in_object;
            var count: u32 = if (record) table.count else 0;
            while (brackets != 0) : (brackets &= brackets - 1) {
                const at: u6 = @intCast(@ctz(brackets));
                const byte: u32 = block[at];
                // `{` and `[` have bit 1 set, and `{` and `}` have bit 5 set.
                const kind = byte >> 5 & 1;
                const offset: u32 = @truncate(pos + at);

                var enclosing = kind;
                if (byte & 2 != 0) {
                    depth += 1;
                    levels.stack[depth] = count << 1 | kind;
                    if (record) {
                        table.entries[count].open = offset;
                        count += 1;
                    }
                } else {
                    const slot = levels.stack[depth] >> 1;
                    if (record) {
                        const entries = table.entries;
                        entries[slot].close = offset;
                        entries[slot].next = count;
                        // Whatever is inside of this is even shorter, so none of it
                        // is listed, and this is the last entry.
                        if (offset -% entries[slot].open < min_indexed_len) count = slot;
                    }
                    levels.mismatched |= in_object ^ kind;
                    depth -= 1;
                    enclosing = levels.stack[depth] & 1;
                }
                objects ^= (0 -% @as(u64, in_object ^ enclosing)) << at << 1;
                in_object = enclosing;
                if (depth == 0) {
                    levels.end = pos + at + 1;
                    break;
                }
            }
            levels.depth = depth;
            levels.in_object = in_object;
            if (record) table.count = count;
            return objects;
        }

        /// Handles the brackets of a block of text that is assumed to be valid.
        /// Returns whether that is the end of the text, in which case `table`
        /// has been finished or, if the text turned out to be invalid, discarded.
        inline fn scanBrackets(
            levels: *Self,
            table: *Table,
            block: Block,
            bytes: *const [64]u8,
            pos: usize,
            in_string: *u64,
            escape_carry: *u64,
        ) bool {
            const quotes = maskOf(block, '"') & ~scan.escapedBytes(escape_carry, maskOf(block, '\\'));
            const strings = scan.stringBytes(in_string, quotes);
            const folded = block | @as(Block, @splat(0x20));
            const opening = maskOf(folded, '{') & ~strings;
            const closing = maskOf(folded, '}') & ~strings;
            if (levels.depth + @popCount(opening) > max_levels) {
                table.discard();
                return true;
            }
            _ = levels.enter(table, bytes, pos, opening | closing);
            if (levels.end != 0) {
                if (levels.mismatched == 0) table.finish() else table.discard();
                return true;
            }
            return false;
        }
    };
}

/// Moves each bit of `tokens`, a mask of the last bytes of tokens, and each bit
/// of `after`, a mask of the bytes just past them, on to the next byte that is
/// not whitespace. `carry` holds what crosses into the next block.
inline fn nextToken(carry: *u64, tokens: u64, after: u64, whitespace: u64) u64 {
    const sum, const overflow = @addWithOverflow((tokens << 1) | after | carry.*, whitespace);
    carry.* = tokens >> 63 | overflow;
    return sum & ~whitespace;
}

/// Returns the offset just past the value at the start of `text`, if everything
/// from there to the end of `text` is valid. A result of null means nothing about
/// `text`. `text` must start with a bracket.
fn check(
    comptime record: bool,
    table: *Table,
    text: []const u8,
    limit: u32,
) Allocator.Error!?usize {
    var levels: Levels(record) = .{};
    levels.stack[0] = 0;
    var tail: [64]u8 = undefined;

    var in_string: u64 = 0;
    var escape_carry: u64 = 0;
    var scalar_carry: u64 = 0;
    var key_carry: u64 = 0;
    var bracket_carry: u64 = 0;
    var comma_carry: u64 = 0;
    var colon_carry: u64 = 0;
    var key_end_carry: u64 = 0;
    var value_carry: u64 = 0;
    // Where the last escape sequence and multi-byte character ended.
    var escape_end: usize = 0;
    var utf8_end: usize = 0;
    var utf8: Utf8 = .{};

    var pos: usize = 0;
    while (true) : (pos += 64) {
        const remaining = text.len - pos;
        const bytes: *const [64]u8 = if (remaining >= 64) text[pos..][0..64] else padded: {
            @memset(&tail, ' ');
            @memcpy(tail[0..remaining], text[pos..]);
            break :padded &tail;
        };
        const block: Block = bytes.*;
        if (record) try table.reserve();

        const quote_bytes = maskOf(block, '"');
        const backslashes = maskOf(block, '\\');
        const lowest = @reduce(.Min, block);
        var strings: u64 = std.math.maxInt(u64);

        // Text is often mostly long strings, and a block in the middle of one
        // has nothing in it that the grammar cares about.
        if (in_string != 0 and quote_bytes | backslashes == 0) {
            if (lowest < 0x20) return null;
            escape_carry = 0;
        } else {
            const folded = block | @as(Block, @splat(0x20));
            const opener_bytes = maskOf(folded, '{');
            const closer_bytes = maskOf(folded, '}');
            const colon_bytes = maskOf(block, ':');
            const comma_bytes = maskOf(block, ',');
            var whitespace_bytes = maskOf(block, ' ');

            const escaped = scan.escapedBytes(&escape_carry, backslashes);
            const quotes = quote_bytes & ~escaped;
            strings = scan.stringBytes(&in_string, quotes);

            // Control characters are never valid in a string, and only these three
            // are valid outside of one, so one mask serves to check both.
            var invalid: u64 = 0;
            if (lowest < 0x20) {
                const breaks = scan.bytesOf(block == @as(Block, @splat('\n'))) |
                    scan.bytesOf(block == @as(Block, @splat('\t'))) |
                    scan.bytesOf(block == @as(Block, @splat('\r')));
                const break_bytes = scan.bitsOfBytes(breaks);
                if (scan.bitsOf(block < @as(Block, @splat(0x20))) & ~break_bytes != 0) return null;
                invalid = break_bytes & strings;
                whitespace_bytes |= break_bytes;
            }

            // Outside of strings, whatever is not known to be something else is
            // taken to be part of a number or a literal, and checked as one.
            const outside = ~strings;
            const opening = quotes & strings;
            const closing = quotes & outside;
            const opener = opener_bytes & outside;
            const closer = closer_bytes & outside;
            const colon = colon_bytes & outside;
            const comma = comma_bytes & outside;
            const whitespace = whitespace_bytes & outside;
            const scalar = outside & ~(quotes | opener | closer | colon | comma | whitespace);

            const scalar_before = scalar << 1 | scalar_carry;
            scalar_carry = scalar >> 63;
            const scalar_start = scalar & ~scalar_before;
            const scalar_after = scalar_before & ~scalar;

            if (levels.depth + @popCount(opener) > limit) return null;
            const objects = levels.enter(table, bytes, pos, opener | closer);

            const value_start = opening | opener | scalar_start;
            const after_opener = nextToken(&bracket_carry, opener, 0, whitespace);
            const after_comma = nextToken(&comma_carry, comma, 0, whitespace);
            const after_colon = nextToken(&colon_carry, colon, 0, whitespace);

            // The run of string bytes of a key starts at its opening quote, so
            // adding that bit carries it along the run on to the closing quote.
            const key_start = (after_opener | after_comma) & objects & opening;
            const sum1, const overflow1 = @addWithOverflow(strings, key_start);
            const sum2, const overflow2 = @addWithOverflow(sum1, key_carry);
            key_carry = overflow1 | overflow2;
            const key_end = sum2 & closing;

            const after_key = nextToken(&key_end_carry, key_end, 0, whitespace);
            const after_value = nextToken(&value_carry, (closing & ~key_end) | closer, scalar_after, whitespace);

            invalid |= after_value & ~(comma | closer);
            invalid |= after_key ^ colon;
            invalid |= after_colon & ~value_start;
            invalid |= after_comma & ~value_start;
            invalid |= after_opener & ~(value_start | closer);
            invalid |= after_comma & objects & ~opening;
            invalid |= after_opener & objects & ~(opening | closer);
            if (invalid != 0 or levels.mismatched != 0) return null;

            var scalars = scalar_start;
            while (scalars != 0) : (scalars &= scalars - 1) {
                if (!isScalar(text, pos + @ctz(scalars))) return null;
            }

            if (backslashes != 0) {
                var escapes = backslashes & ~escaped & strings;
                while (escapes != 0) : (escapes &= escapes - 1) {
                    const at = pos + @ctz(escapes);
                    if (at >= escape_end) escape_end = strict.escapeEnd(text, at) catch return null;
                }
            }
        }

        const highest = @reduce(.Max, block);
        if (highest >= 0x80 or utf8.pending) {
            if (comptime Utf8.supported) {
                if (!utf8.check(block, highest)) return null;
            } else {
                var multibyte = scan.bitsOf(block >= @as(Block, @splat(0x80))) & strings;
                while (multibyte != 0) {
                    const at = pos + @ctz(multibyte);
                    if (at >= utf8_end) utf8_end = strict.utf8RunEnd(text, at) catch return null;
                    if (utf8_end - pos >= 64) break;
                    multibyte &= @as(u64, std.math.maxInt(u64)) << @intCast(utf8_end - pos);
                }
            }
        }

        if (levels.end != 0) {
            return if (scan.skipWhitespace(text, levels.end) == text.len) levels.end else null;
        }
        if (remaining <= 64) return null;
    }
}

/// Checks UTF-8 a block at a time, as described in "Validating UTF-8 In Less Than
/// One Instruction Per Byte" by John Keiser and Daniel Lemire.
///
/// Whether a byte is valid depends only on the three before it, and nearly all
/// errors can be seen in just two bytes, in 12 bits of them. Those bits are looked
/// up in three tables, with each table saying which errors are possible given
/// what it was indexed by. An error happened if all three agree on one. What
/// remains are the third and fourth bytes of long characters, which the tables
/// treat as if they were a continuation following a continuation.
const Utf8 = struct {
    /// The end of the previous block.
    previous: Lane = @splat(0),
    /// Whether the previous block had multi-byte characters, any of which might
    /// continue into this one.
    pending: bool = false,

    const Lane = @Vector(16, u8);

    /// Whether this can be used, which needs a table lookup instruction.
    const supported = builtin.cpu.arch == .aarch64;

    const too_short = 1 << 0; // 11______ 0_______ or 11______ 11______
    const too_long = 1 << 1; // 0_______ 10______
    const overlong_3 = 1 << 2; // 11100000 100_____
    const too_large = 1 << 3; // 11110100 1001____ and above
    const surrogate = 1 << 4; // 11101101 101_____
    const overlong_2 = 1 << 5; // 1100000_ 10______
    const overlong_4 = 1 << 6; // 11110000 1000____
    const too_large_1000 = 1 << 6; // 11110100 1000____ and above
    const two_continuations = 1 << 7; // 10______ 10______
    const carry = too_short | too_long | two_continuations;

    const first_high: Lane = .{
        too_long,                                            too_long,          too_long,
        too_long,                                            too_long,          too_long,
        too_long,                                            too_long,          two_continuations,
        two_continuations,                                   two_continuations, two_continuations,
        too_short | overlong_2,                              too_short,         too_short | overlong_3 | surrogate,
        too_short | too_large | too_large_1000 | overlong_4,
    };
    const first_low: Lane = .{
        carry | overlong_3 | overlong_2 | overlong_4,
        carry | overlong_2,
        carry,
        carry,
        carry | too_large,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000 | surrogate,
        carry | too_large | too_large_1000,
        carry | too_large | too_large_1000,
    };
    const second_high: Lane = .{
        too_short,
        too_short,
        too_short,
        too_short,
        too_short,
        too_short,
        too_short,
        too_short,
        too_long | overlong_2 | two_continuations | overlong_3 | too_large_1000 | overlong_4,
        too_long | overlong_2 | two_continuations | overlong_3 | too_large,
        too_long | overlong_2 | two_continuations | surrogate | too_large,
        too_long | overlong_2 | two_continuations | surrogate | too_large,
        too_short,
        too_short,
        too_short,
        too_short,
    };

    inline fn lookup(table: Lane, index: Lane) Lane {
        return asm ("tbl %[out].16b, {%[table].16b}, %[index].16b"
            : [out] "=w" (-> Lane),
            : [table] "w" (table),
              [index] "w" (index),
        );
    }

    /// Returns the last 16 bytes of `earlier` followed by `later`, starting
    /// `distance` bytes before `later`.
    inline fn before(earlier: Lane, later: Lane, comptime distance: comptime_int) Lane {
        const indices = comptime blk: {
            var result: @Vector(16, i32) = undefined;
            for (0..16) |i| {
                const position = 16 - distance + i;
                result[i] = if (position < 16) position else ~@as(i32, position - 16);
            }
            break :blk result;
        };
        return @shuffle(u8, earlier, later, indices);
    }

    inline fn errors(earlier: Lane, input: Lane) Lane {
        const low_nibble: Lane = @splat(0x0f);
        const previous1 = before(earlier, input, 1);
        const found = lookup(first_high, previous1 >> @splat(4)) &
            lookup(first_low, previous1 & low_nibble) &
            lookup(second_high, input >> @splat(4));
        // Only bytes at or above 0xe0 and 0xf0 keep their high bit.
        const third = before(earlier, input, 2) -| @as(Lane, @splat(0xe0 - 0x80));
        const fourth = before(earlier, input, 3) -| @as(Lane, @splat(0xf0 - 0x80));
        return ((third | fourth) & @as(Lane, @splat(0x80))) ^ found;
    }

    /// Returns whether the bytes of `block` can follow the ones before it. A
    /// character that is cut off is only noticed in the next block.
    inline fn check(utf8: *Utf8, block: Block, highest: u8) bool {
        const lanes: [4]Lane = @bitCast(block);
        const found = errors(utf8.previous, lanes[0]) | errors(lanes[0], lanes[1]) |
            errors(lanes[1], lanes[2]) | errors(lanes[2], lanes[3]);
        utf8.previous = lanes[3];
        utf8.pending = highest >= 0x80;
        return @reduce(.Max, found) == 0;
    }
};

const delimiters = blk: {
    var table: [256]bool = @splat(false);
    for (",]} \n\r\t") |c| table[c] = true;
    break :blk table;
};

/// Returns whether a number or literal starts at `start`, followed by something
/// that ends it. This handles literals and short numbers without a loop, in which
/// the branch that ends it would be mispredicted about as often as not. Anything
/// else is left to `strict`.
inline fn isScalar(text: []const u8, start: usize) bool {
    if (text.len - start < scan.chunk_size) return isOtherScalar(text, start);

    const word = std.mem.readInt(u64, text[start..][0..8], .little);
    const first = word & 0xffff_ffff;
    if (first == word_null or first == word_true) return delimiters[@as(u8, @truncate(word >> 32))];
    if (word & 0xff_ffff_ffff == word_false) return delimiters[@as(u8, @truncate(word >> 40))];

    const chunk = scan.loadChunk(text, start);
    const others = scan.chunkBits(chunk -% @as(Chunk, @splat('0')) >= @as(Chunk, @splat(10)));
    const len = @ctz(others) / scan.chunk_bits;
    // That is, it has at least one digit, ends here, and has no leading zero.
    if (len -% 1 >= scan.chunk_size - 1 or (text[start] == '0' and len != 1)) return isOtherScalar(text, start);
    const next = text[start + len];
    if (delimiters[next]) return true;
    if (next != '.' or len + 1 == scan.chunk_size) return isOtherScalar(text, start);

    const after = others & (@as(u64, std.math.maxInt(u64)) << @intCast((len + 1) * scan.chunk_bits));
    const end = @ctz(after) / scan.chunk_bits;
    if (end == len + 1 or end >= scan.chunk_size or !delimiters[text[start + end]]) return isOtherScalar(text, start);
    return true;
}

const word_null = std.mem.readInt(u32, "null", .little);
const word_true = std.mem.readInt(u32, "true", .little);
const word_false = std.mem.readInt(u40, "false", .little);

fn isOtherScalar(text: []const u8, start: usize) bool {
    const end = switch (text[start]) {
        '-', '0'...'9' => strict.numberEnd(text, start),
        't' => strict.literalEnd(text, start, "true"),
        'f' => strict.literalEnd(text, start, "false"),
        'n' => strict.literalEnd(text, start, "null"),
        else => return false,
    } catch return false;
    return end < text.len and delimiters[text[end]];
}

/// Validates the JSON text in `source`, and returns it without the whitespace
/// around it. A result of null means nothing about `source`, which then has to be
/// validated by `validate.zig`. If `index` is given, it receives the containers
/// of the result, allocated with `allocator`.
pub fn document(allocator: Allocator, source: []const u8, max_depth: u16, index: ?*Index) Allocator.Error!?[]const u8 {
    const start = scan.skipWhitespace(source, 0);
    if (start == source.len or source[start] | 0x20 != '{') return null;
    const text = source[start..];
    const limit = @min(max_depth, max_levels);

    if (index) |target| {
        if (Index.suits(text.len)) {
            var table: Table = try .init(allocator, target, text.len);
            const len = try check(true, &table, text, limit) orelse {
                table.discard();
                return null;
            };
            table.finish();
            return text[0..len];
        }
    }
    var table: Table = undefined;
    const len = try check(false, &table, text, limit) orelse return null;
    return text[0..len];
}

const testing = std.testing;

fn isValid(text: []const u8) bool {
    var cursor: strict.Cursor = .{ .src = text };
    _ = cursor.document(strict.default_max_depth) catch return false;
    return true;
}

/// Generates valid JSON that exercises everything this file looks at, with
/// tokens falling at every position within a block.
const Generator = struct {
    random: std.Random,
    out: *std.Io.Writer,

    fn space(g: *Generator) !void {
        if (g.random.uintLessThan(u8, 4) != 0) return;
        for (0..g.random.uintLessThan(u8, 8)) |_| try g.out.writeByte(" \n\r\t"[g.random.uintLessThan(u8, 4)]);
    }

    fn string(g: *Generator) !void {
        try g.out.writeByte('"');
        const fragments = [_][]const u8{
            "a",                                "key",     " ",              "{}[]:,",   "1.5e3",
            "é",
            "€",
            "😀",
            "\u{10ffff}",                       "\\\"",    "\\\\",           "\\/",      "\\n",
            "\\u0041",                          "\\u00e9", "\\ud83d\\ude00", "\\\\\\\"", "\\b\\f\\r\\t",
            "0123456789abcdef0123456789abcdef", "true",
            "日本語のテキスト",
        };
        for (0..g.random.uintLessThan(u8, 10)) |_| try g.out.writeAll(fragments[g.random.uintLessThan(usize, fragments.len)]);
        try g.out.writeByte('"');
    }

    fn scalar(g: *Generator) !void {
        const scalars = [_][]const u8{
            "0",       "-0",   "1",     "-1",   "10",      "1.5",                                                                              "0.0",                                                                           "1e5", "1E+5", "1e-5",
            "123.456", "true", "false", "null", "-1.5E10", "12345678901234567890123456789012345678901234567890123456789012345678901234567890", "0.000000000000000000000000000000000000000000000000000000000000000000000000001",
        };
        try g.out.writeAll(scalars[g.random.uintLessThan(usize, scalars.len)]);
    }

    fn value(g: *Generator, depth: u32) anyerror!void {
        const choice = g.random.uintLessThan(u8, if (depth > 6) 2 else 4);
        switch (choice) {
            0 => try g.string(),
            1 => try g.scalar(),
            2 => try g.array(depth),
            else => try g.object(depth),
        }
    }

    fn array(g: *Generator, depth: u32) anyerror!void {
        try g.out.writeByte('[');
        try g.space();
        const len = g.random.uintLessThan(u8, 8);
        for (0..len) |i| {
            if (i != 0) {
                try g.out.writeByte(',');
                try g.space();
            }
            try g.value(depth + 1);
            try g.space();
        }
        try g.out.writeByte(']');
    }

    fn object(g: *Generator, depth: u32) anyerror!void {
        try g.out.writeByte('{');
        try g.space();
        const len = g.random.uintLessThan(u8, 8);
        for (0..len) |i| {
            if (i != 0) {
                try g.out.writeByte(',');
                try g.space();
            }
            try g.string();
            try g.space();
            try g.out.writeByte(':');
            try g.space();
            try g.value(depth + 1);
            try g.space();
        }
        try g.out.writeByte('}');
    }

    fn document(g: *Generator) !void {
        try g.space();
        if (g.random.boolean()) try g.array(0) else try g.object(0);
        try g.space();
    }
};

/// Fails if `text` is accepted when it should not be.
fn expectSound(text: []const u8) !void {
    const accepted = try document(testing.allocator, text, strict.default_max_depth, null) orelse return;
    testing.expect(isValid(text)) catch |err| {
        std.debug.print("invalid text was accepted: {x}\n{s}\n", .{ text, text });
        return err;
    };
    var cursor: strict.Cursor = .{ .src = text };
    try testing.expectEqual(try cursor.document(strict.default_max_depth), accepted);
}

/// Changes one byte of `text`, to something that is likely to matter.
fn mutate(random: std.Random, text: []u8) void {
    const bytes = "\"\\{}[]:,0123456789-+.eEtrufalsn \n\r\t\x00\x1f\x7f\x80\xbf\xc0\xc2\xe0\xed\xf0\xf4\xff/bu";
    text[random.uintLessThan(usize, text.len)] = bytes[random.uintLessThan(usize, bytes.len)];
}

test "accepts what it should" {
    const valid = [_][]const u8{
        "[]",                               "{}",                  " [ ] ",
        "\n{ }\n",                          "[1]",                 "{\"a\":1}",
        "[\"a\",\"b\"]",                    "[[],[]]",             "[{},{}]",
        "{\"a\":{},\"b\":[]}",              "[true,false,null]",   "[0,-0,1.5,1e5,1E+5,-1.5e-5]",
        "{\"a\" : 1 , \"b\" : [ 2 , 3 ] }", "[\"\\\"\",\"\\\\\"]", "[\"\\u0041\\ud83d\\ude00\"]",
        "[\"é€😀\"]",
    };
    for (valid) |text| try testing.expect(try document(testing.allocator, text, 1024, null) != null);
}

test "rejects what it should" {
    const invalid = [_][]const u8{
        "[",               "]",           "{",              "}",                  "[}",                   "{]",
        "[1,]",            "[,1]",        "[1 2]",          "[\"a\" \"b\"]",      "[\"a\"\"b\"]",         "[1\"a\"]",
        "{\"a\"}",         "{\"a\":}",    "{\"a\":1,}",     "{a:1}",              "{1:1}",                "{\"a\":1 \"b\":2}",
        "{\"a\":\"b\":1}", "[\"a\":1]",   "[1:2]",          "{,}",                "[,]",                  "{:}",
        "{\"a\"::1}",      "{\"a\":1,,}", "[1,,2]",         "[]]",                "[]1",                  "[],[]",
        "{}{}",            "[] []",       "[01]",           "[1.]",               "[.5]",                 "[1e]",
        "[-]",             "[+1]",        "[tru]",          "[truee]",            "[nul]",                "[falsee]",
        "[\"\\x\"]",       "[\"\\u12\"]", "[\"\\ud800\"]",  "[\"\\udc00\"]",      "[\"\\ud800\\u0041\"]", "[\"a\nb\"]",
        "[\"\x00\"]",      "[\"\xff\"]",  "[\"\xc0\x80\"]", "[\"\xed\xa0\x80\"]", "[\"\xe2\x82\"]",       "[\"a]",
        "[\\]",            "[@]",         "[\x00]",         "[\x0b]",             "[\xc3\xa9]",
    };
    for (invalid) |text| {
        testing.expectEqual(null, try document(testing.allocator, text, 1024, null)) catch |err| {
            std.debug.print("accepted: {s}\n", .{text});
            return err;
        };
    }
}

test "the nesting limit is respected" {
    var text: [4096]u8 = undefined;
    @memset(text[0..2048], '[');
    @memset(text[2048..], ']');
    try testing.expect(try document(testing.allocator, text[2040..2056], 8, null) != null);
    try testing.expectEqual(null, try document(testing.allocator, text[2039..2057], 8, null));
    try testing.expect(try document(testing.allocator, text[1024..3072], 1024, null) != null);
    try testing.expectEqual(null, try document(testing.allocator, text[1023..3073], 1024, null));
    try testing.expectEqual(null, try document(testing.allocator, &text, 1024, null));
}

test "agrees with the strict validator on random valid text and mutations of it" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6901);
    const random = prng.random();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();

    var accepted: usize = 0;
    for (0..4000) |_| {
        text.clearRetainingCapacity();
        var generator: Generator = .{ .random = random, .out = &text.writer };
        try generator.document();
        const written = text.written();
        try testing.expect(isValid(written));

        // A decline here would not be wrong, only slow, so this is what keeps
        // this file from quietly doing nothing.
        testing.expect(try document(gpa, written, strict.default_max_depth, null) != null) catch |err| {
            std.debug.print("valid text was declined: {s}\n", .{written});
            return err;
        };

        for (0..20) |_| {
            const copy = try gpa.dupe(u8, written);
            defer gpa.free(copy);
            for (0..random.intRangeAtMost(u8, 1, 3)) |_| mutate(random, copy);
            try expectSound(copy);
            if (isValid(copy)) accepted += 1;
        }
    }
    try testing.expect(accepted > 100);
}

test "agrees with the strict validator on random text" {
    var prng: std.Random.DefaultPrng = .init(0x6902);
    const random = prng.random();
    const alphabet = "{}[],:\"\\ 01-.eEtrufalsn\n\xc3\xa9";
    var buffer: [200]u8 = undefined;
    for (0..100_000) |_| {
        const len = random.uintLessThan(usize, buffer.len);
        const text = buffer[0..len];
        for (text) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        if (len > 0) text[0] = "{["[random.uintLessThan(usize, 2)];
        try expectSound(text);
    }
}

/// Returns the opening and closing offsets of every container in valid `text`, in
/// the order they open, found the slow way.
fn naiveContainers(gpa: Allocator, text: []const u8) ![]Index.Entry {
    var found: std.ArrayList(Index.Entry) = .empty;
    errdefer found.deinit(gpa);
    var open: std.ArrayList(usize) = .empty;
    defer open.deinit(gpa);

    var in_string = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (in_string) {
            if (text[i] == '\\') i += 1 else if (text[i] == '"') in_string = false;
            continue;
        }
        switch (text[i]) {
            '"' => in_string = true,
            '{', '[' => {
                try open.append(gpa, found.items.len);
                try found.append(gpa, .{ .open = @intCast(i), .close = 0, .next = 0 });
            },
            '}', ']' => found.items[open.pop().?].close = @intCast(i),
            else => {},
        }
    }
    return found.toOwnedSlice(gpa);
}

fn expectValidIndex(text: []const u8, index: *const Index) !void {
    const gpa = testing.allocator;
    const containers = try naiveContainers(gpa, text);
    defer gpa.free(containers);

    const entries = index.entries.items;
    try testing.expect(entries.len != 0);
    try testing.expectEqual(Index.sentinel, entries[entries.len - 1]);
    const listed = entries[0 .. entries.len - 1];

    // What is listed is real, in order, and knows what follows it.
    var position: usize = 0;
    for (listed, 0..) |entry, i| {
        while (containers[position].open != entry.open) position += 1;
        try testing.expectEqual(containers[position].close, entry.close);
        if (i != 0) try testing.expect(listed[i - 1].open < entry.open);
        var next = i + 1;
        while (next < listed.len and listed[next].open < entry.close) next += 1;
        try testing.expectEqual(next, entry.next);
    }

    // What is not listed is short, and has nothing listed inside of it.
    for (containers) |container| {
        var low: usize = 0;
        while (low < listed.len and listed[low].open < container.open) low += 1;
        if (low < listed.len and listed[low].open == container.open) continue;
        try testing.expect(container.close - container.open < min_indexed_len);
        if (low < listed.len) try testing.expect(listed[low].open > container.close);
    }

    // Walking the children of any container agrees with scanning them.
    for (containers) |container| {
        const body = text[container.open .. container.close + 1];
        var cursor = index.cursor(container.open, text.len - container.open);
        var i = scan.skipWhitespace(body, 1);
        while (i < body.len - 1) {
            if (body[i] == '"' and body[0] == '{') {
                i = scan.stringEnd(body, i + 1).?.end + 1;
                i = scan.skipWhitespace(body, scan.skipWhitespace(body, i) + 1);
            }
            const expected = scan.valueEnd(body, i);
            try testing.expectEqual(expected, cursor.valueEnd(body, i));
            i = scan.skipWhitespace(body, expected.?);
            if (body[i] == ',') i = scan.skipWhitespace(body, i + 1);
        }
    }
}

test "the index is correct whether or not the text was validated" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x6903);
    const random = prng.random();
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();

    var checked: usize = 0;
    for (0..300) |_| {
        text.clearRetainingCapacity();
        var generator: Generator = .{ .random = random, .out = &text.writer };
        try text.writer.writeByte('[');
        var first = true;
        while (text.written().len < 4096) {
            if (!first) try text.writer.writeByte(',');
            first = false;
            try generator.value(0);
        }
        try text.writer.writeByte(']');
        const written = text.written();

        var validated: Index = .{};
        defer validated.entries.deinit(gpa);
        const accepted = (try document(gpa, written, strict.default_max_depth, &validated)).?;
        try testing.expectEqual(written.len, accepted.len);
        if (validated.entries.items.len == 0) continue;
        checked += 1;
        try expectValidIndex(written, &validated);

        var built: Index = .{};
        defer built.entries.deinit(gpa);
        try built.build(gpa, written);
        try testing.expectEqualSlices(Index.Entry, validated.entries.items, built.entries.items);
    }
    try testing.expect(checked > 100);
}

test "an index that would outgrow the text is dropped, and the text still accepted" {
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.append(gpa, '[');
    for (0..20_000) |_| try text.appendSlice(gpa, "[[[[[[[[1,2,3,4,5,6,7,8,9,1,2,3,4,5,6,7,8,9]]]]]]]],");
    try text.appendSlice(gpa, "[]]");

    var index: Index = .{};
    defer index.entries.deinit(gpa);
    try testing.expect(try document(gpa, text.items, strict.default_max_depth, &index) != null);
    try testing.expectEqual(0, index.entries.capacity);
}

test "UTF-8 agrees with the standard library at every position in a block" {
    var prng: std.Random.DefaultPrng = .init(0x6905);
    const random = prng.random();
    const characters = [_][]const u8{
        "a",          "\x7f",
        "é",
        "€",
        "😀",
        "\u{7ff}",    "\u{800}",
        "\u{d7ff}",   "\u{e000}",
        "\u{ffff}",   "\u{10000}",
        "\u{10ffff}",
    };
    // Every boundary in Table 3-7 of the Unicode standard.
    const bytes = [_]u8{
        0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xe1,
        0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf3, 0xf4, 0xf5, 0xff, 'a',
    };
    var buffer: [320]u8 = undefined;
    var valid: usize = 0;
    var invalid: usize = 0;

    for (0..300_000) |_| {
        var len: usize = 0;
        buffer[0] = '[';
        buffer[1] = '"';
        const padding = random.uintLessThan(usize, 70);
        @memset(buffer[2..][0..padding], 'x');
        len = 2 + padding;
        const start = len;
        // Most text is mostly right, which is where a mistake could hide.
        for (0..random.uintLessThan(usize, 24)) |_| {
            if (random.uintLessThan(u8, 8) != 0) {
                const character = characters[random.uintLessThan(usize, characters.len)];
                @memcpy(buffer[len..][0..character.len], character);
                len += character.len;
            } else {
                buffer[len] = bytes[random.uintLessThan(usize, bytes.len)];
                len += 1;
            }
        }
        const expected = std.unicode.utf8ValidateSlice(buffer[start..len]);
        buffer[len] = '"';
        buffer[len + 1] = ']';
        const text = buffer[0 .. len + 2];

        testing.expectEqual(expected, try document(testing.allocator, text, 1024, null) != null) catch |err| {
            std.debug.print("disagreement on: {x}\n", .{text});
            return err;
        };
        if (expected) valid += 1 else invalid += 1;
    }
    try testing.expect(valid > 1000 and invalid > 1000);
}

test "an index is not kept for text that turns out to be malformed" {
    const gpa = testing.allocator;
    var index: Index = .{};
    defer index.entries.deinit(gpa);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.append(gpa, '[');
    for (0..100) |_| try text.appendSlice(gpa, "\"0123456789abcdef0123456789abcdef0123456789abcdef\",");

    // Unclosed.
    try index.build(gpa, text.items);
    try testing.expectEqual(0, index.entries.items.len);

    // Closed by the wrong kind of bracket.
    try text.appendSlice(gpa, "1}");
    try index.build(gpa, text.items);
    try testing.expectEqual(0, index.entries.items.len);

    // Too deep.
    text.clearRetainingCapacity();
    try text.appendNTimes(gpa, '[', 2000);
    try index.build(gpa, text.items);
    try testing.expectEqual(0, index.entries.items.len);
}
