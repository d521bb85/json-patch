//! Working with the bodies of JSON strings, which is the text between the
//! quotes. Bodies are assumed to be well formed; malformed escapes, which can
//! only come from a document that skipped validation, decode to something
//! arbitrary rather than failing.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Yields the bytes of the string that `body` represents.
pub const Decoder = struct {
    body: []const u8,
    i: usize = 0,
    pending: [4]u8 = undefined,
    pending_at: u8 = 0,
    pending_len: u8 = 0,

    pub fn next(decoder: *Decoder) ?u8 {
        if (decoder.pending_at < decoder.pending_len) {
            defer decoder.pending_at += 1;
            return decoder.pending[decoder.pending_at];
        }
        if (decoder.i >= decoder.body.len) return null;
        const c = decoder.body[decoder.i];
        if (c != '\\') {
            decoder.i += 1;
            return c;
        }
        decoder.i += unescape(decoder.body[decoder.i..], &decoder.pending, &decoder.pending_len);
        decoder.pending_at = 1;
        return decoder.pending[0];
    }
};

/// Decodes the escape sequence at the start of `text` to UTF-8. Returns the
/// number of bytes of `text` that it consumed.
fn unescape(text: []const u8, out: *[4]u8, out_len: *u8) usize {
    out_len.* = 1;
    if (text.len < 2) {
        out[0] = '\\';
        return 1;
    }
    switch (text[1]) {
        'b' => out[0] = 0x08,
        'f' => out[0] = 0x0c,
        'n' => out[0] = '\n',
        'r' => out[0] = '\r',
        't' => out[0] = '\t',
        'u' => {
            const high = hex4(text[2..]);
            var scalar: u21 = high;
            var consumed: usize = 6;
            if (std.unicode.utf16IsHighSurrogate(high) and text.len >= 12) {
                const low = hex4(text[8..]);
                if (std.unicode.utf16IsLowSurrogate(low)) {
                    scalar = 0x10000 + (@as(u21, high & 0x3ff) << 10 | (low & 0x3ff));
                    consumed = 12;
                }
            }
            const len = std.unicode.utf8Encode(scalar, out) catch blk: {
                out[0] = '?';
                break :blk 1;
            };
            out_len.* = len;
            return @min(consumed, text.len);
        },
        else => |c| out[0] = c,
    }
    return 2;
}

fn hex4(text: []const u8) u16 {
    if (text.len < 4) return 0;
    return std.fmt.parseInt(u16, text[0..4], 16) catch 0;
}

/// Returns the string that `body` represents. The result is `body` itself if
/// it contains no escapes.
pub fn decode(allocator: Allocator, body: []const u8) Allocator.Error![]const u8 {
    const first = std.mem.indexOfScalar(u8, body, '\\') orelse return body;
    const out = try allocator.alloc(u8, body.len);
    @memcpy(out[0..first], body[0..first]);
    var len = first;
    var i = first;
    while (i < body.len) {
        if (body[i] != '\\') {
            out[len] = body[i];
            len += 1;
            i += 1;
            continue;
        }
        var bytes: [4]u8 = undefined;
        var count: u8 = 0;
        i += unescape(body[i..], &bytes, &count);
        @memcpy(out[len..][0..count], bytes[0..count]);
        len += count;
    }
    return out[0..len];
}

/// Returns whether two string bodies represent the same string. Per RFC 6902
/// that means the same code points: no Unicode normalization is performed.
pub fn eql(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (std.mem.indexOfScalar(u8, a, '\\') == null and
        std.mem.indexOfScalar(u8, b, '\\') == null) return false;
    var x: Decoder = .{ .body = a };
    var y: Decoder = .{ .body = b };
    while (true) {
        const c = x.next();
        if (c != y.next()) return false;
        if (c == null) return true;
    }
}

/// Returns whether `body` represents exactly the bytes of `decoded`.
pub fn eqlDecoded(body: []const u8, decoded: []const u8) bool {
    var decoder: Decoder = .{ .body = body };
    for (decoded) |expected| {
        if (decoder.next() != expected) return false;
    }
    return decoder.next() == null;
}

/// Returns whether `text` must be escaped to appear in a JSON string.
pub fn needsEscape(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c == '"' or c == '\\') return true;
    }
    return false;
}

/// Writes `text` as a quoted JSON string.
pub fn encodeQuoted(allocator: Allocator, text: []const u8) Allocator.Error![]u8 {
    var size: usize = text.len + 2;
    for (text) |c| {
        size += switch (c) {
            '"', '\\', 0x08, 0x0c, '\n', '\r', '\t' => 1,
            0x00...0x07, 0x0b, 0x0e...0x1f => 5,
            else => 0,
        };
    }
    const out = try allocator.alloc(u8, size);
    var len: usize = 1;
    out[0] = '"';
    for (text) |c| {
        const short: ?u8 = switch (c) {
            '"' => '"',
            '\\' => '\\',
            0x08 => 'b',
            0x0c => 'f',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            else => null,
        };
        if (short) |letter| {
            out[len] = '\\';
            out[len + 1] = letter;
            len += 2;
        } else if (c < 0x20) {
            _ = std.fmt.bufPrint(out[len..][0..6], "\\u{x:0>4}", .{c}) catch unreachable;
            len += 6;
        } else {
            out[len] = c;
            len += 1;
        }
    }
    out[len] = '"';
    return out;
}

const testing = std.testing;

test decode {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_][2][]const u8{
        .{ "\\\"\\\\\\/\\b\\f\\n\\r\\t", "\"\\/\x08\x0c\n\r\t" },
        .{ "a\\u0041b", "aAb" },
        .{ "\\u00e9", "é" },
        .{ "\\u20ac", "€" },
        .{ "\\ud83d\\ude00!", "😀!" },
        .{ "\\u0000", "\x00" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try decode(arena.allocator(), case[0]));
        try testing.expect(eqlDecoded(case[0], case[1]));
        try testing.expect(!eqlDecoded(case[0], "other"));
    }
    const plain = "no escapes";
    try testing.expectEqual(plain.ptr, (try decode(arena.allocator(), plain)).ptr);
}

test eql {
    try testing.expect(eql("abc", "abc"));
    try testing.expect(eql("\\u0061bc", "a\\u0062c"));
    try testing.expect(!eql("abc", "abd"));
    try testing.expect(!eql("ab", "abc"));
    try testing.expect(!eql("\\u0061", "b"));
    // These render the same but are different code points.
    try testing.expect(!eql("\\u00e9", "e\\u0301"));
}

test encodeQuoted {
    const gpa = testing.allocator;
    const encoded = try encodeQuoted(gpa, "a\"\\\n\x01é");
    defer gpa.free(encoded);
    try testing.expectEqualStrings("\"a\\\"\\\\\\n\\u0001é\"", encoded);
    try testing.expect(needsEscape("a\"b"));
    try testing.expect(!needsEscape("é~/"));
}
