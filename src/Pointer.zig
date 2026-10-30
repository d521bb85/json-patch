//! A JSON Pointer, as defined by RFC 6901, split into its reference tokens.
//!
//! ```
//! ""        the whole document
//! "/a/0"    element 0 of the member "a"
//! "/a~1b"   the member named "a/b"
//! "/a~0b"   the member named "a~b"
//! ```

const std = @import("std");

const Allocator = std.mem.Allocator;
const Pointer = @This();

/// The pointer in its RFC 6901 string form.
text: []const u8,
tokens: []const Token,

/// The pointer that refers to the whole document.
pub const root: Pointer = .{ .text = "", .tokens = &.{} };

pub const ParseError = Allocator.Error || error{
    /// The text is not empty and does not begin with `/`, or it contains a `~`
    /// that is not followed by `0` or `1`.
    InvalidPointer,
};

pub const Token = struct {
    /// The reference token with `~0` and `~1` decoded.
    name: []const u8,
    /// What the token means when applied to an array.
    index: Index,

    inline fn init(allocator: anytype, text: []const u8, escaped: bool) ParseError!Token {
        const name = if (escaped) try unescape(allocator, text) else text;
        return .{ .name = name, .index = .parse(name) };
    }

    pub const Index = enum(usize) {
        /// The token is not a valid array index, such as `foo` or `01`.
        invalid = std.math.maxInt(usize),
        /// The token is `-`, which refers to the position after the last element.
        end = std.math.maxInt(usize) - 1,
        /// The token is a valid array index. Indices too large to be represented
        /// saturate here, which is past the end of any array that can exist.
        overflow = std.math.maxInt(usize) - 2,
        _,

        inline fn parse(name: []const u8) Index {
            if (name.len == 0) return .invalid;
            if (name[0] -% '0' > 9 and name.len != 1) return .invalid;
            return parseDigits(name);
        }

        fn parseDigits(name: []const u8) Index {
            if (name.len == 1 and name[0] == '-') return .end;
            if (name[0] == '0' and name.len > 1) return .invalid;
            var index: usize = 0;
            var overflowed = false;
            for (name) |c| {
                const digit = c -% '0';
                if (digit > 9) return .invalid;
                const scaled, const scale_overflow = @mulWithOverflow(index, 10);
                const sum, const add_overflow = @addWithOverflow(scaled, digit);
                index = sum;
                overflowed = overflowed or scale_overflow != 0 or add_overflow != 0;
            }
            if (overflowed or index >= @backingInt(Index.overflow)) return .overflow;
            return @fromBackingInt(@intCast(index));
        }
    };
};

/// Parses `text`, allocating with `allocator`. The result refers to `text` and
/// must not outlive it.
pub fn parse(allocator: Allocator, text: []const u8) ParseError!Pointer {
    return parseWith(allocator, text);
}

/// As `parse`, for anything with the `alloc` method of an allocator.
pub fn parseWith(allocator: anytype, text: []const u8) ParseError!Pointer {
    if (text.len == 0) return root;
    if (text[0] != '/') return error.InvalidPointer;
    if (text.len > max_short_len) return parseLong(allocator, text);

    // Recording every position and only advancing at a slash means that a token
    // ending costs no branch, and the length of a token is impossible to predict.
    var slashes: [max_short_len + 1]u8 = undefined;
    var count: usize = 0;
    var tildes: u8 = 0;
    for (text, 0..) |c, i| {
        slashes[count] = @intCast(i);
        count += @intFromBool(c == '/');
        tildes |= @intFromBool(c == '~');
    }
    slashes[count] = @intCast(text.len);

    const tokens = try allocator.alloc(Token, count);
    for (tokens, 0..) |*token, i| {
        token.* = try .init(allocator, text[@as(usize, slashes[i]) + 1 .. slashes[i + 1]], tildes != 0);
    }
    return .{ .text = text, .tokens = tokens };
}

/// The longest pointer that `parse` handles without a pass to count its tokens.
const max_short_len = 192;

fn parseLong(allocator: anytype, text: []const u8) ParseError!Pointer {
    var count: usize = 0;
    var escaped = false;
    for (text) |c| {
        count += @intFromBool(c == '/');
        escaped = escaped or c == '~';
    }

    const tokens = try allocator.alloc(Token, count);
    var next: usize = 0;
    var start: usize = 1;
    for (text[1..], 1..) |c, i| {
        if (c != '/') continue;
        tokens[next] = try .init(allocator, text[start..i], escaped);
        next += 1;
        start = i + 1;
    }
    tokens[next] = try .init(allocator, text[start..], escaped);
    return .{ .text = text, .tokens = tokens };
}

fn unescape(allocator: anytype, escaped: []const u8) ParseError![]const u8 {
    const first = std.mem.indexOfScalar(u8, escaped, '~') orelse return escaped;
    const out = try allocator.alloc(u8, escaped.len);
    @memcpy(out[0..first], escaped[0..first]);
    var len = first;
    var i = first;
    while (i < escaped.len) : (i += 1) {
        if (escaped[i] != '~') {
            out[len] = escaped[i];
            len += 1;
            continue;
        }
        i += 1;
        if (i == escaped.len) return error.InvalidPointer;
        // Decoding in a single pass ensures `~01` becomes `~1`, not `/`.
        out[len] = switch (escaped[i]) {
            '0' => '~',
            '1' => '/',
            else => return error.InvalidPointer,
        };
        len += 1;
    }
    return out[0..len];
}

/// Returns whether the two pointers refer to the same location.
pub fn eql(a: Pointer, b: Pointer) bool {
    // Each token has exactly one valid spelling, so comparing text is enough.
    return std.mem.eql(u8, a.text, b.text);
}

/// Returns whether `pointer` refers to a location strictly inside `ancestor`.
pub fn isDescendantOf(pointer: Pointer, ancestor: Pointer) bool {
    return pointer.text.len > ancestor.text.len and
        pointer.text[ancestor.text.len] == '/' and
        std.mem.startsWith(u8, pointer.text, ancestor.text);
}

/// Formats the pointer in its RFC 6901 string form with `{f}`.
pub fn format(pointer: Pointer, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll(pointer.text);
}

const testing = std.testing;

fn expectTokens(text: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const pointer = try parse(arena.allocator(), text);
    try testing.expectEqual(expected.len, pointer.tokens.len);
    for (expected, pointer.tokens) |name, token| {
        try testing.expectEqualStrings(name, token.name);
    }
}

test "RFC 6901 section 5 examples" {
    try expectTokens("", &.{});
    try expectTokens("/foo", &.{"foo"});
    try expectTokens("/foo/0", &.{ "foo", "0" });
    try expectTokens("/", &.{""});
    try expectTokens("/a~1b", &.{"a/b"});
    try expectTokens("/c%d", &.{"c%d"});
    try expectTokens("/e^f", &.{"e^f"});
    try expectTokens("/g|h", &.{"g|h"});
    try expectTokens("/i\\j", &.{"i\\j"});
    try expectTokens("/k\"l", &.{"k\"l"});
    try expectTokens("/ ", &.{" "});
    try expectTokens("/m~0n", &.{"m~n"});
}

test "decoding is a single pass" {
    try expectTokens("/~01", &.{"~1"});
    try expectTokens("/~10", &.{"/0"});
    try expectTokens("/~0~1", &.{"~/"});
    try expectTokens("//", &.{ "", "" });
    try expectTokens("/a/", &.{ "a", "" });
}

test "rejects invalid pointers" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for ([_][]const u8{ "a", "a/b", " /a", "/~", "/a~", "/~2", "/~a", "/a~/b" }) |text| {
        try testing.expectError(error.InvalidPointer, parse(arena.allocator(), text));
    }
}

test "interprets array indices" {
    const cases = [_]struct { []const u8, Token.Index }{
        .{ "0", @fromBackingInt(@intCast(0)) },
        .{ "7", @fromBackingInt(@intCast(7)) },
        .{ "10", @fromBackingInt(@intCast(10)) },
        .{ "-", .end },
        .{ "", .invalid },
        .{ "00", .invalid },
        .{ "01", .invalid },
        .{ "-1", .invalid },
        .{ "+1", .invalid },
        .{ "1e0", .invalid },
        .{ "1.0", .invalid },
        .{ " 1", .invalid },
        .{ "--", .invalid },
        .{ "a", .invalid },
        .{ "18446744073709551616", .overflow },
        .{ "99999999999999999999999999", .overflow },
    };
    for (cases) |case| try testing.expectEqual(case[1], Token.Index.parse(case[0]));
}

test isDescendantOf {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const parent = try parse(a, "/a");
    try testing.expect((try parse(a, "/a/b")).isDescendantOf(parent));
    try testing.expect((try parse(a, "/a/")).isDescendantOf(parent));
    try testing.expect((try parse(a, "/a/b/c")).isDescendantOf(parent));
    try testing.expect((try parse(a, "/a")).isDescendantOf(root));
    try testing.expect(!(try parse(a, "/ab")).isDescendantOf(parent));
    try testing.expect(!(try parse(a, "/a")).isDescendantOf(parent));
    try testing.expect(!root.isDescendantOf(root));
    try testing.expect(!root.isDescendantOf(parent));
}
