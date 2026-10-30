//! A strict RFC 8259 validator.
//!
//! Strings must be valid UTF-8 and may not contain lone surrogate escapes,
//! matching `std.json`. Nesting is limited by `max_depth`, and no heap memory
//! is used.

const std = @import("std");
const scan = @import("scan.zig");

const Chunk = @Vector(scan.chunk_size, u8);

pub const Error = error{
    /// The text is not valid JSON.
    SyntaxError,
    /// The text nests arrays and objects more deeply than `max_depth`.
    NestingTooDeep,
};

/// The depth used when no other limit is requested. This matches simdjson.
pub const default_max_depth = 1024;

/// A position within JSON text.
///
/// After an error, `pos` is the offset of the byte that caused it, or of the
/// start of the number or literal it is part of.
pub const Cursor = struct {
    src: []const u8,
    pos: usize = 0,
    /// One bit per open container, set if the container is an object.
    kinds: [(std.math.maxInt(u16) + 1) / 8]u8 = undefined,

    pub fn skipWhitespace(cursor: *Cursor) void {
        cursor.pos = scan.skipWhitespace(cursor.src, cursor.pos);
    }

    /// Returns the next byte without consuming it, or null at the end of input.
    pub fn peek(cursor: *const Cursor) ?u8 {
        return if (cursor.pos < cursor.src.len) cursor.src[cursor.pos] else null;
    }

    /// Consumes a whitespace-delimited document and returns the slice holding
    /// its value, excluding surrounding whitespace.
    pub fn document(cursor: *Cursor, max_depth: u16) Error![]const u8 {
        cursor.skipWhitespace();
        const start = cursor.pos;
        try cursor.value(max_depth);
        const end = cursor.pos;
        cursor.skipWhitespace();
        if (cursor.pos != cursor.src.len) return error.SyntaxError;
        return cursor.src[start..end];
    }

    /// Consumes a string, starting at its opening quote. Returns whether it
    /// contains escape sequences.
    pub fn string(cursor: *Cursor) Error!bool {
        const start = cursor.pos + 1;
        const result = stringEnd(cursor.src, start) catch |err| {
            cursor.pos = failureOffset(cursor.src, start);
            return err;
        };
        cursor.pos = result.end;
        return result.escaped;
    }

    /// Consumes a single value, starting at its first byte.
    pub fn value(cursor: *Cursor, max_depth: u16) Error!void {
        const src = cursor.src;
        var i = cursor.pos;
        // Nothing may take the address of `i`, which would keep it out of a
        // register for this entire loop.
        defer cursor.pos = i;
        var depth: u32 = 0;
        var in_object = false;

        const State = enum { value, key, end_of_value };
        state: switch (State.value) {
            .value => {
                if (i >= src.len) return error.SyntaxError;
                switch (src[i]) {
                    '"' => i = shortStringEnd(src, i + 1) orelse {
                        const result = stringEnd(src, i + 1) catch |err| {
                            i = failureOffset(src, i + 1);
                            return err;
                        };
                        i = result.end;
                        continue :state .end_of_value;
                    },
                    '{', '[' => |open| {
                        if (depth == max_depth) return error.NestingTooDeep;
                        in_object = open == '{';
                        const byte = depth >> 3;
                        const bit: u8 = @as(u8, 1) << @intCast(depth & 7);
                        if (in_object) cursor.kinds[byte] |= bit else cursor.kinds[byte] &= ~bit;
                        depth += 1;
                        i = skipSpace(src, i + 1);
                        if (i < src.len and src[i] == open + 2) {
                            i += 1;
                            depth -= 1;
                            in_object = cursor.isObject(depth);
                            continue :state .end_of_value;
                        }
                        continue :state if (in_object) .key else .value;
                    },
                    '-', '0'...'9' => i = try numberEnd(src, i),
                    't' => i = try literalEnd(src, i, "true"),
                    'f' => i = try literalEnd(src, i, "false"),
                    'n' => i = try literalEnd(src, i, "null"),
                    else => return error.SyntaxError,
                }
                continue :state .end_of_value;
            },
            .key => {
                if (i >= src.len or src[i] != '"') return error.SyntaxError;
                i = shortStringEnd(src, i + 1) orelse blk: {
                    const result = stringEnd(src, i + 1) catch |err| {
                        i = failureOffset(src, i + 1);
                        return err;
                    };
                    break :blk result.end;
                };
                i = skipSpace(src, i);
                if (i >= src.len or src[i] != ':') return error.SyntaxError;
                i = skipSpace(src, i + 1);
                continue :state .value;
            },
            .end_of_value => {
                if (depth == 0) return;
                i = skipSpace(src, i);
                if (i >= src.len) return error.SyntaxError;
                switch (src[i]) {
                    ',' => {
                        i = skipSpace(src, i + 1);
                        continue :state if (in_object) .key else .value;
                    },
                    '}' => if (!in_object) return error.SyntaxError,
                    ']' => if (in_object) return error.SyntaxError,
                    else => return error.SyntaxError,
                }
                i += 1;
                depth -= 1;
                in_object = cursor.isObject(depth);
                continue :state .end_of_value;
            },
        }
    }

    /// Returns whether the container enclosing level `depth` is an object.
    inline fn isObject(cursor: *const Cursor, depth: u32) bool {
        if (depth == 0) return false;
        const top = depth - 1;
        return cursor.kinds[top >> 3] >> @intCast(top & 7) & 1 != 0;
    }
};

inline fn skipSpace(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] <= ' ') {
        if (!scan.isWhitespace(src[i])) return i;
        i += 1;
    }
    return i;
}

inline fn literalEnd(src: []const u8, i: usize, text: []const u8) Error!usize {
    if (!std.mem.startsWith(u8, src[i..], text)) return error.SyntaxError;
    return i + text.len;
}

/// Re-walks an invalid string to find the byte that made it invalid. Keeping
/// this out of the hot path lets `stringEnd` return only its result.
fn failureOffset(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len) {
        const next = stringStep(src, i) catch return i;
        i = next orelse return i;
    }
    return src.len;
}

/// Handles a string that is plain ASCII and ends within one chunk, which covers
/// most strings in practice, returning the index just past the closing quote.
/// Anything else is left to `stringEnd`.
inline fn shortStringEnd(src: []const u8, start: usize) ?usize {
    if (!scan.hasChunk(src, start)) return null;
    const chunk = scan.loadChunk(src, start);
    const stop = (chunk < @as(Chunk, @splat(0x20))) |
        (chunk >= @as(Chunk, @splat(0x80))) |
        (chunk == @as(Chunk, @splat('"'))) |
        (chunk == @as(Chunk, @splat('\\')));
    const offset = scan.firstSet(stop) orelse return null;
    const end = start + offset;
    return if (src[end] == '"') end + 1 else null;
}

const StringEnd = struct {
    /// The index just past the closing quote.
    end: usize,
    /// Whether the string contains escape sequences.
    escaped: bool,
};

/// Consumes the rest of a string whose contents begin at `start`.
fn stringEnd(src: []const u8, start: usize) Error!StringEnd {
    var i = start;
    var escaped = false;
    while (true) {
        while (scan.hasChunk(src, i)) {
            const chunk = scan.loadChunk(src, i);
            const stop = (chunk < @as(Chunk, @splat(0x20))) |
                (chunk >= @as(Chunk, @splat(0x80))) |
                (chunk == @as(Chunk, @splat('"'))) |
                (chunk == @as(Chunk, @splat('\\')));
            if (scan.firstSet(stop)) |offset| {
                i += offset;
                break;
            }
            i += scan.chunk_size;
        }
        while (true) {
            if (i >= src.len) return error.SyntaxError;
            const c = src[i];
            if (c == '"') return .{ .end = i + 1, .escaped = escaped };
            if (c >= 0x80) {
                i = try utf8RunEnd(src, i);
            } else if (c == '\\') {
                escaped = true;
                i = try escapeEnd(src, i);
            } else if (c < 0x20) {
                return error.SyntaxError;
            } else {
                i += 1;
            }
            if (i >= src.len or (src[i] < 0x80 and src[i] != '\\')) break;
        }
    }
}

/// Consumes one character of a string, returning null at the closing quote.
fn stringStep(src: []const u8, i: usize) Error!?usize {
    return switch (src[i]) {
        '"' => null,
        '\\' => try escapeEnd(src, i),
        0x00...0x1f => error.SyntaxError,
        0x20...0x21, 0x23...0x5b, 0x5d...0x7f => i + 1,
        0x80...0xff => try utf8End(src, i),
    };
}

fn escapeEnd(src: []const u8, start: usize) Error!usize {
    if (src.len - start < 2) return error.SyntaxError;
    switch (src[start + 1]) {
        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => return start + 2,
        'u' => {},
        else => return error.SyntaxError,
    }
    const unit = try hex4(src, start + 2);
    switch (unit) {
        0xd800...0xdbff => {
            const low_at = start + 6;
            if (src.len - low_at < 2 or src[low_at] != '\\' or src[low_at + 1] != 'u')
                return error.SyntaxError;
            switch (try hex4(src, low_at + 2)) {
                0xdc00...0xdfff => return low_at + 6,
                else => return error.SyntaxError,
            }
        },
        0xdc00...0xdfff => return error.SyntaxError,
        else => return start + 6,
    }
}

fn hex4(src: []const u8, at: usize) Error!u16 {
    if (src.len -| at < 4) return error.SyntaxError;
    return std.fmt.parseInt(u16, src[at..][0..4], 16) catch error.SyntaxError;
}

/// Consumes a run of multi-byte UTF-8 characters, starting at the first one.
///
/// Text in many languages is nearly all multi-byte, so rather than classify the
/// lead byte, this tests each shape against four bytes at once. The conditions
/// are those of Table 3-7 of the Unicode standard.
fn utf8RunEnd(src: []const u8, start: usize) Error!usize {
    var i = start;
    while (src.len - i >= 4) {
        const word = std.mem.readInt(u32, src[i..][0..4], .little);
        if (word & 0x80 == 0) return i;
        if (word & 0xc0e0 == 0x80c0) {
            // Rejects the overlong leads 0xc0 and 0xc1.
            if (word & 0x1e == 0) return error.SyntaxError;
            i += 2;
        } else if (word & 0xc0c0f0 == 0x8080e0) {
            // Rejects overlong forms (all zero) and surrogates (0xed, 0xa0).
            const bits = word & 0x200f;
            if (bits == 0 or bits == 0x200d) return error.SyntaxError;
            i += 3;
        } else if (word & 0xc0c0c0f8 == 0x808080f0) {
            // The lead bits and first continuation, which must be in the range
            // of 0xf0 0x90 to 0xf4 0x8f.
            const top = (word & 7) << 6 | (word >> 8 & 0x3f);
            if (top < 0x10 or top > 0x10f) return error.SyntaxError;
            i += 4;
        } else return error.SyntaxError;
    }
    while (i < src.len and src[i] >= 0x80) i = try utf8End(src, i);
    return i;
}

/// Validates the multi-byte UTF-8 sequence at `start`.
fn utf8End(src: []const u8, start: usize) Error!usize {
    const lead = src[start];
    const len: usize, const low: u8, const high: u8 = switch (lead) {
        0xc2...0xdf => .{ 2, 0x80, 0xbf },
        0xe0 => .{ 3, 0xa0, 0xbf },
        0xe1...0xec, 0xee...0xef => .{ 3, 0x80, 0xbf },
        0xed => .{ 3, 0x80, 0x9f },
        0xf0 => .{ 4, 0x90, 0xbf },
        0xf1...0xf3 => .{ 4, 0x80, 0xbf },
        0xf4 => .{ 4, 0x80, 0x8f },
        else => return error.SyntaxError,
    };
    if (src.len - start < len) return error.SyntaxError;
    const second = src[start + 1];
    if (second < low or second > high) return error.SyntaxError;
    for (src[start + 2 .. start + len]) |continuation| {
        if (continuation & 0xc0 != 0x80) return error.SyntaxError;
    }
    return start + len;
}

fn numberEnd(src: []const u8, start: usize) Error!usize {
    var at = start;
    if (src[at] == '-') at += 1;
    if (at >= src.len) return error.SyntaxError;
    switch (src[at]) {
        '0' => at += 1,
        '1'...'9' => at = digitsEnd(src, at + 1),
        else => return error.SyntaxError,
    }
    if (at < src.len and src[at] == '.') {
        at += 1;
        const first = at;
        at = digitsEnd(src, at);
        if (at == first) return error.SyntaxError;
    }
    if (at < src.len and src[at] | 0x20 == 'e') {
        at += 1;
        if (at < src.len and (src[at] == '+' or src[at] == '-')) at += 1;
        const first = at;
        at = digitsEnd(src, at);
        if (at == first) return error.SyntaxError;
    }
    return at;
}

inline fn digitsEnd(src: []const u8, start: usize) usize {
    var i = start;
    while (i < src.len and src[i] -% '0' <= 9) i += 1;
    return i;
}

const testing = std.testing;

fn isValid(text: []const u8) bool {
    var cursor: Cursor = .{ .src = text };
    _ = cursor.document(default_max_depth) catch return false;
    return true;
}

test "accepts valid documents" {
    const valid = [_][]const u8{
        "null",               "true",                 "false",
        "0",                  "-0",                   "-1",
        "10",                 "1.5",                  "1e5",
        "1E+5",               "1e-5",                 "1.5e10",
        "0.0",                "\"\"",                 "\"a\"",
        "[]",                 "{}",                   "[ ]",
        "{ }",                " \t\r\n1 \t\r\n",      "[1,2]",
        "[ 1 , 2 ]",          "{\"a\":1}",            "{ \"a\" : 1 , \"b\" : 2 }",
        "[[],{}]",            "{\"a\":{\"b\":[{}]}}", "\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"",
        "\"\\u0041\\u00e9\"", "\"\\ud83d\\ude00\"",
        "\"é😀\"",
        "\"0123456789abcdefé\"",
        "\"\u{7f}\"",         "\"\u{10ffff}\"",       "\"0123456789abcdef0123456789abcdef0123456789abcdef\"",
    };
    for (valid) |text| {
        testing.expect(isValid(text)) catch |err| {
            std.debug.print("expected valid: {s}\n", .{text});
            return err;
        };
    }
}

test "rejects invalid documents" {
    const invalid = [_][]const u8{
        "",                     " ",                "nul",
        "nulll",                "tru",              "True",
        "01",                   "-",                "+1",
        ".5",                   "1.",               "1e",
        "1e+",                  "0x10",             "1 2",
        "[",                    "]",                "{",
        "}",                    "[1",               "[1,",
        "[1,]",                 "[,1]",             "[1 2]",
        "{\"a\"}",              "{\"a\":}",         "{\"a\":1,}",
        "{a:1}",                "{1:1}",            "[}",
        "{]",                   "[1}",              "{\"a\":1]",
        "\"",                   "\"abc",            "\"\\",
        "\"\\x\"",              "\"\\u12\"",        "\"\\u12G4\"",
        "\"\n\"",               "\"\x00\"",         "\"\\ud800\"",
        "\"\\ud800x\"",         "\"\\ud800\\n\"",   "\"\\ud800\\u0041\"",
        "\"\\udc00\"",          "\"\xc0\x80\"",     "\"\xc2\"",
        "\"\xe0\x80\x80\"",     "\"\xed\xa0\x80\"", "\"\xf0\x80\x80\x80\"",
        "\"\xf4\x90\x80\x80\"", "\"\xff\"",         "\"\x80\"",
        "\xef\xbb\xbf1",        "/* c */1",         "'a'",
        "\x0c1",
    };
    for (invalid) |text| {
        testing.expect(!isValid(text)) catch |err| {
            std.debug.print("expected invalid: {s}\n", .{text});
            return err;
        };
    }
}

test "strings are checked the same way whatever follows them" {
    // Fast paths need a full chunk of input ahead of them, which these short
    // strings would not have without the padding.
    const invalid = [_][]const u8{
        "\"\n\"", "\"\x00\"", "\"\x1f\"", "\"a\tb\"", "\"\\x\"", "\"\\ud800\"", "\"\xff\"", "\"\xc0\x80\"",
    };
    var buffer: [64]u8 = undefined;
    for (invalid) |text| {
        const padded = try std.fmt.bufPrint(&buffer, "[{s},                                  1]", .{text});
        try testing.expect(!isValid(padded));
        const key = try std.fmt.bufPrint(&buffer, "{{{s}:1                                  }}", .{text});
        try testing.expect(!isValid(key));
    }
    try testing.expect(isValid("[\"a\\tb\",                                  1]"));
    try testing.expect(isValid("{\"a\\tb\":1                                  }"));
    try testing.expect(isValid("[\"\\u0041\xc3\xa9\",                                 1]"));
}

test "reports where validation failed" {
    var cursor: Cursor = .{ .src = "{\"a\": [1, x]}" };
    try testing.expectError(error.SyntaxError, cursor.document(default_max_depth));
    try testing.expectEqual(10, cursor.pos);

    cursor = .{ .src = "[\"ok\", \"b\\q\"]" };
    try testing.expectError(error.SyntaxError, cursor.document(default_max_depth));
    try testing.expectEqual(9, cursor.pos);
}

test "enforces the nesting limit" {
    var text: [2 * 2048]u8 = undefined;
    @memset(text[0..2048], '[');
    @memset(text[2048..], ']');

    var cursor: Cursor = .{ .src = text[1024..3072] };
    _ = try cursor.document(1024);

    cursor = .{ .src = text[1023..3073] };
    try testing.expectError(error.NestingTooDeep, cursor.document(1024));

    cursor = .{ .src = &text };
    _ = try cursor.document(4096);
}

test "agrees with std.json" {
    var prng: std.Random.DefaultPrng = .init(6902);
    const random = prng.random();
    const alphabet = "{}[],:\"\\ 01-.eEtrufalsn\n\xc3\xa9";
    var buffer: [24]u8 = undefined;

    for (0..200_000) |_| {
        const text = buffer[0..random.uintLessThan(usize, buffer.len)];
        for (text) |*c| c.* = alphabet[random.uintLessThan(usize, alphabet.len)];
        const expected = try std.json.validate(testing.allocator, text);
        testing.expectEqual(expected, isValid(text)) catch |err| {
            std.debug.print("disagreement on: {s}\n", .{text});
            return err;
        };
    }
}

test "UTF-8 validation agrees with the standard library" {
    var prng: std.Random.DefaultPrng = .init(3629);
    const random = prng.random();
    // Every boundary in Table 3-7, in sequences of every length and alignment.
    const bytes = [_]u8{
        'a',  0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xc1, 0xc2, 0xdf, 0xe0, 0xe1,
        0xec, 0xed, 0xee, 0xef, 0xf0, 0xf1, 0xf3, 0xf4, 0xf5, 0xff,
    };
    var buffer: [40]u8 = undefined;
    var valid_count: usize = 0;

    for (0..2_000_000) |_| {
        const len = random.uintLessThan(usize, buffer.len - 2);
        buffer[0] = '"';
        for (buffer[1..][0..len]) |*c| c.* = bytes[random.uintLessThan(usize, bytes.len)];
        buffer[len + 1] = '"';

        const expected = std.unicode.utf8ValidateSlice(buffer[1..][0..len]);
        if (expected) valid_count += 1;
        testing.expectEqual(expected, isValid(buffer[0 .. len + 2])) catch |err| {
            std.debug.print("disagreement on: {x}\n", .{buffer[0 .. len + 2]});
            return err;
        };
    }
    try testing.expect(valid_count > 1000);

    for ([_][]const u8{ "é", "€", "😀", "\u{7ff}", "\u{800}", "\u{d7ff}", "\u{e000}", "\u{ffff}", "\u{10000}", "\u{10ffff}" }) |character| {
        var text: [8]u8 = undefined;
        const quoted = try std.fmt.bufPrint(&text, "\"{s}\"", .{character});
        try testing.expect(isValid(quoted));
    }
}
