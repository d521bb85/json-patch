//! A JSON Patch: a sequence of operations to apply to a document, as defined by
//! RFC 6902.
//!
//! A patch is immutable once built as far as `Document.apply` is concerned, so
//! the same patch can be applied to any number of documents, including from
//! multiple threads at once.

const std = @import("std");
const Arena = @import("Arena.zig");
const lib = @import("root.zig");
const scan = @import("scan.zig");
const string = @import("string.zig");
const structure = @import("structure.zig");
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
const Cursor = validate.Cursor;
const Diagnostics = lib.Diagnostics;
const Patch = @This();
const Pointer = lib.Pointer;
const Writer = std.Io.Writer;

arena: Arena,
operations: std.ArrayList(Operation) = .empty,

pub const Operation = union(enum) {
    add: WithValue,
    remove: Target,
    replace: WithValue,
    move: Transfer,
    copy: Transfer,
    @"test": WithValue,

    pub const Target = struct { path: Pointer };
    pub const WithValue = struct {
        path: Pointer,
        /// A valid JSON value as text, without surrounding whitespace.
        value: []const u8,
    };
    pub const Transfer = struct { from: Pointer, path: Pointer };
};

pub const ParseOptions = struct {
    /// Whether the patch keeps its own copy of the source text. With `.borrow`
    /// no copy is made, and `source` must outlive the patch.
    source: lib.Ownership = .copy,
    /// The deepest nesting allowed in the patch. See `default_max_depth`.
    max_depth: u16 = lib.default_max_depth,
    diagnostics: ?*Diagnostics = null,
};

pub const ParseError = validate.Error || Pointer.ParseError || error{
    /// The patch is valid JSON, but is not an array.
    NotAnArray,
    /// An element of the patch is not an object.
    NotAnObject,
    /// An operation has no `op`, `path`, `from`, or `value`, as it requires.
    MissingMember,
    /// An operation has more than one `op`, `path`, `from`, or `value`.
    DuplicateMember,
    /// A member of an operation has the wrong JSON type.
    InvalidMemberType,
    /// The value of `op` is not one of the six operations.
    UnknownOperation,
    /// A `move` has a `from` location that is a parent of its `path`.
    MoveIntoDescendant,
};

/// Everything that can go wrong adding an operation with the methods below.
pub const BuildError = validate.Error || Pointer.ParseError || error{MoveIntoDescendant};

/// Lets `add`, `replace`, and `testValue` accept JSON that is already text.
pub const Raw = struct {
    json: []const u8,

    pub fn jsonStringify(raw: Raw, jws: anytype) !void {
        try jws.print("{s}", .{raw.json});
    }
};

/// Returns an empty patch. Add to it with `add`, `remove`, `replace`, `move`,
/// `copy`, and `testValue`.
pub fn init(gpa: Allocator) Patch {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(patch: *Patch) void {
    patch.arena.deinit();
    patch.* = undefined;
}

/// Parses a JSON Patch document, reporting anything that RFC 6902 forbids. On
/// failure, `options.diagnostics` receives the location of the problem.
pub fn parse(gpa: Allocator, source: []const u8, options: ParseOptions) ParseError!Patch {
    return parseInto(.init(gpa), source, options);
}

/// As `parse`, starting out with `buffer` instead of allocating, which is what
/// `lib.apply` uses, as it knows the patch does not outlive it.
pub fn parseBuffered(gpa: Allocator, source: []const u8, options: ParseOptions, buffer: []u8) ParseError!Patch {
    return parseInto(.{ .arena = .initBuffer(gpa, buffer) }, source, options);
}

inline fn parseInto(empty: Patch, source: []const u8, options: ParseOptions) ParseError!Patch {
    var patch = empty;
    errdefer patch.deinit();

    const gpa = patch.arena.gpa;
    const arena = patch.arena.allocator();
    const text = switch (options.source) {
        .copy => try arena.dupe(u8, source),
        .borrow => source,
    };
    var parser: Parser = .{
        .arena = arena,
        .bump = &patch.arena,
        .cursor = .{ .src = text },
        .max_depth = options.max_depth,
    };
    errdefer if (options.diagnostics) |diagnostics| {
        diagnostics.* = .{ .offset = parser.cursor.pos, .operation = patch.operations.items.len };
    };
    // Operations are rarely shorter than this, so the list seldom has to grow.
    try patch.operations.ensureTotalCapacity(arena, text.len / 64 + 1);
    // Text that is known to be valid needs no checking while it is taken apart.
    if (std.mem.startsWith(u8, text[scan.skipWhitespace(text, 0)..], "[") and
        try structure.document(gpa, text, options.max_depth, null) != null)
    {
        try parser.walk(&patch.operations);
    } else {
        try parser.document(&patch.operations);
    }
    return patch;
}

const Parser = struct {
    arena: Allocator,
    /// The same arena as `arena`, for calls that are too frequent to go through
    /// an allocator.
    bump: *Arena,
    cursor: Cursor,
    max_depth: u16,

    const Member = enum { op, path, from, value };
    const Slot = struct {
        /// The value of the member as JSON text.
        text: []const u8 = "",
        /// Whether the value is a string containing escape sequences.
        escaped: bool = false,
        count: u8 = 0,
    };
    const Members = std.enums.EnumArray(Member, Slot);

    fn document(parser: *Parser, operations: *std.ArrayList(Operation)) ParseError!void {
        const cursor = &parser.cursor;
        cursor.skipWhitespace();
        if (cursor.peek() != '[') {
            const start = cursor.pos;
            _ = try cursor.document(parser.max_depth);
            cursor.pos = start;
            return error.NotAnArray;
        }
        cursor.pos += 1;
        cursor.skipWhitespace();
        if (cursor.peek() == ']') {
            cursor.pos += 1;
        } else while (true) {
            try operations.append(parser.arena, try parser.operation());
            cursor.skipWhitespace();
            const next = cursor.peek() orelse return error.SyntaxError;
            if (next != ',' and next != ']') return error.SyntaxError;
            cursor.pos += 1;
            if (next == ']') break;
            cursor.skipWhitespace();
        }
        cursor.skipWhitespace();
        if (cursor.pos != cursor.src.len) return error.SyntaxError;
    }

    /// Reads the operations of a patch that is known to be a valid JSON array.
    /// Bounds are checked regardless, because it costs little.
    fn walk(parser: *Parser, operations: *std.ArrayList(Operation)) ParseError!void {
        const src = parser.cursor.src;
        var i = skip(src, skip(src, 0) + 1);
        if (byteAt(src, i) == ']') return;
        while (true) {
            const start = i;
            if (byteAt(src, i) != '{') {
                parser.cursor.pos = i;
                return error.NotAnObject;
            }
            i = skip(src, i + 1);

            var members: Members = .initFill(.{});
            if (byteAt(src, i) == '}') {
                i += 1;
            } else while (true) {
                const key_start = i + 1;
                var which = knownMember(src, key_start);
                if (which) |known| {
                    i = key_start + key_lengths.get(known) + 1;
                } else {
                    const key = scan.stringEnd(src, key_start) orelse return error.SyntaxError;
                    which = try parser.classify(src[key_start..key.end], key.escaped);
                    i = key.end + 1;
                }
                i = skip(src, skip(src, i) + 1);

                const value_start = i;
                var escaped = false;
                if (byteAt(src, i) == '"') {
                    const end = scan.stringEnd(src, i + 1) orelse return error.SyntaxError;
                    escaped = end.escaped;
                    i = end.end + 1;
                } else {
                    i = scan.valueEnd(src, i) orelse return error.SyntaxError;
                }
                if (which) |known| {
                    const slot = members.getPtr(known);
                    slot.text = src[value_start..i];
                    slot.escaped = escaped;
                    slot.count +|= 1;
                }

                i = skip(src, i);
                const next = byteAt(src, i);
                i += 1;
                if (next == '}') break;
                i = skip(src, i);
            }

            parser.cursor.pos = start;
            const built = try parser.build(&members);
            if (operations.items.len == operations.capacity) try operations.ensureUnusedCapacity(parser.arena, 1);
            operations.appendAssumeCapacity(built);

            i = skip(src, i);
            if (byteAt(src, i) == ']') return;
            i = skip(src, i + 1);
        }
    }

    inline fn skip(src: []const u8, start: usize) usize {
        if (byteAt(src, start) > ' ') return start;
        return scan.skipWhitespace(src, start);
    }

    /// Returns the byte at `i`, or something that no caller is looking for.
    inline fn byteAt(src: []const u8, i: usize) u8 {
        return if (i < src.len) src[i] else 0;
    }

    const key_lengths: std.enums.EnumArray(Member, usize) = .init(.{ .op = 2, .path = 4, .from = 4, .value = 5 });

    /// Recognizes a key without escapes, whose text starts at `start`, by reading
    /// it as an integer, which is much faster than finding where it ends.
    inline fn knownMember(src: []const u8, start: usize) ?Member {
        if (src.len -| start < 6) return null;
        const word = std.mem.readInt(u32, src[start..][0..4], .little);
        const fifth = src[start + 4];
        if (word & 0xff_ffff == word_op) return .op;
        if (word == word_path and fifth == '"') return .path;
        if (word == word_value and fifth == 'e' and src[start + 5] == '"') return .value;
        if (word == word_from and fifth == '"') return .from;
        return null;
    }

    const word_op = std.mem.readInt(u24, "op\"", .little);
    const word_path = std.mem.readInt(u32, "path", .little);
    const word_value = std.mem.readInt(u32, "valu", .little);
    const word_from = std.mem.readInt(u32, "from", .little);

    fn operation(parser: *Parser) ParseError!Operation {
        const cursor = &parser.cursor;
        const start = cursor.pos;
        if (cursor.peek() != '{') {
            try cursor.value(parser.max_depth);
            cursor.pos = start;
            return error.NotAnObject;
        }
        cursor.pos += 1;
        cursor.skipWhitespace();

        var members: Members = .initFill(.{});
        if (cursor.peek() == '}') {
            cursor.pos += 1;
        } else while (true) {
            if (cursor.peek() != '"') return error.SyntaxError;
            const key_start = cursor.pos;
            const escaped = try cursor.string();
            const key = cursor.src[key_start + 1 .. cursor.pos - 1];

            cursor.skipWhitespace();
            if (cursor.peek() != ':') return error.SyntaxError;
            cursor.pos += 1;
            cursor.skipWhitespace();

            const value_start = cursor.pos;
            var value_escaped = false;
            if (cursor.peek() == '"') {
                value_escaped = try cursor.string();
            } else {
                try cursor.value(parser.max_depth);
            }
            if (try parser.classify(key, escaped)) |which| {
                const slot = members.getPtr(which);
                slot.text = cursor.src[value_start..cursor.pos];
                slot.escaped = value_escaped;
                slot.count +|= 1;
            }

            cursor.skipWhitespace();
            const next = cursor.peek() orelse return error.SyntaxError;
            if (next != ',' and next != '}') return error.SyntaxError;
            cursor.pos += 1;
            if (next == '}') break;
            cursor.skipWhitespace();
        }

        const end = cursor.pos;
        cursor.pos = start;
        const result = try parser.build(&members);
        cursor.pos = end;
        return result;
    }

    fn classify(parser: *Parser, key: []const u8, escaped: bool) Allocator.Error!?Member {
        const name = if (escaped) try string.decode(parser.arena, key) else key;
        return switch (name.len) {
            2 => if (std.mem.eql(u8, name, "op")) .op else null,
            4 => if (std.mem.eql(u8, name, "path"))
                .path
            else if (std.mem.eql(u8, name, "from")) .from else null,
            5 => if (std.mem.eql(u8, name, "value")) .value else null,
            else => null,
        };
    }

    fn kind(name: []const u8) ?std.meta.Tag(Operation) {
        return switch (name.len) {
            3 => if (std.mem.eql(u8, name, "add")) .add else null,
            4 => if (std.mem.eql(u8, name, "test"))
                .@"test"
            else if (std.mem.eql(u8, name, "copy"))
                .copy
            else if (std.mem.eql(u8, name, "move")) .move else null,
            6 => if (std.mem.eql(u8, name, "remove")) .remove else null,
            7 => if (std.mem.eql(u8, name, "replace")) .replace else null,
            else => null,
        };
    }

    fn build(parser: *Parser, members: *Members) ParseError!Operation {
        const name = try parser.stringValue(try member(members, .op));
        // Whatever an operation does not define must be ignored, so only the
        // members relevant to this operation are examined.
        return switch (kind(name) orelse return error.UnknownOperation) {
            .add => .{ .add = try parser.withValue(members) },
            .replace => .{ .replace = try parser.withValue(members) },
            .@"test" => .{ .@"test" = try parser.withValue(members) },
            .remove => .{ .remove = .{ .path = try parser.pointer(members, .path) } },
            .copy => .{ .copy = try parser.transfer(members) },
            .move => move: {
                const transfer_ = try parser.transfer(members);
                if (transfer_.path.isDescendantOf(transfer_.from)) return error.MoveIntoDescendant;
                break :move .{ .move = transfer_ };
            },
        };
    }

    fn withValue(parser: *Parser, members: *Members) ParseError!Operation.WithValue {
        return .{
            .path = try parser.pointer(members, .path),
            .value = (try member(members, .value)).text,
        };
    }

    fn transfer(parser: *Parser, members: *Members) ParseError!Operation.Transfer {
        return .{
            .from = try parser.pointer(members, .from),
            .path = try parser.pointer(members, .path),
        };
    }

    fn pointer(parser: *Parser, members: *Members, which: Member) ParseError!Pointer {
        return Pointer.parseWith(parser.bump, try parser.stringValue(try member(members, which)));
    }

    fn member(members: *const Members, which: Member) ParseError!Slot {
        const slot = members.get(which);
        return switch (slot.count) {
            0 => error.MissingMember,
            1 => slot,
            else => error.DuplicateMember,
        };
    }

    fn stringValue(parser: *Parser, slot: Slot) ParseError![]const u8 {
        if (slot.text[0] != '"') return error.InvalidMemberType;
        const body = slot.text[1 .. slot.text.len - 1];
        return if (slot.escaped) string.decode(parser.arena, body) else body;
    }
};

/// Appends an `add` operation. `value` is anything `std.json.Stringify` accepts.
/// Use `Raw` to pass JSON that is already text.
pub fn add(patch: *Patch, path: []const u8, value: anytype) BuildError!void {
    try patch.append(.{ .add = try patch.withValue(path, value) });
}

/// Appends a `remove` operation.
pub fn remove(patch: *Patch, path: []const u8) BuildError!void {
    try patch.append(.{ .remove = .{ .path = try patch.pointer(path) } });
}

/// Appends a `replace` operation. See `add` for what `value` can be.
pub fn replace(patch: *Patch, path: []const u8, value: anytype) BuildError!void {
    try patch.append(.{ .replace = try patch.withValue(path, value) });
}

/// Appends a `move` operation.
pub fn move(patch: *Patch, from: []const u8, path: []const u8) BuildError!void {
    const transfer = try patch.transferFrom(from, path);
    if (transfer.path.isDescendantOf(transfer.from)) return error.MoveIntoDescendant;
    try patch.append(.{ .move = transfer });
}

/// Appends a `copy` operation.
pub fn copy(patch: *Patch, from: []const u8, path: []const u8) BuildError!void {
    try patch.append(.{ .copy = try patch.transferFrom(from, path) });
}

/// Appends a `test` operation. See `add` for what `value` can be.
pub fn testValue(patch: *Patch, path: []const u8, value: anytype) BuildError!void {
    try patch.append(.{ .@"test" = try patch.withValue(path, value) });
}

fn append(patch: *Patch, operation: Operation) Allocator.Error!void {
    try patch.operations.append(patch.arena.allocator(), operation);
}

fn pointer(patch: *Patch, text: []const u8) BuildError!Pointer {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidPointer;
    const arena = patch.arena.allocator();
    return Pointer.parse(arena, try arena.dupe(u8, text));
}

fn transferFrom(patch: *Patch, from: []const u8, path: []const u8) BuildError!Operation.Transfer {
    return .{ .from = try patch.pointer(from), .path = try patch.pointer(path) };
}

fn withValue(patch: *Patch, path: []const u8, value: anytype) BuildError!Operation.WithValue {
    const text = try std.json.Stringify.valueAlloc(patch.arena.allocator(), value, .{});
    var cursor: Cursor = .{ .src = text };
    return .{
        .path = try patch.pointer(path),
        .value = try cursor.document(std.math.maxInt(u16)),
    };
}

/// Writes the patch as a JSON document with `{f}`.
pub fn format(patch: Patch, writer: *Writer) Writer.Error!void {
    try writer.writeByte('[');
    for (patch.operations.items, 0..) |operation, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"op\":\"{t}\"", .{operation});
        switch (operation) {
            .remove => |o| try writePath(writer, "path", o.path),
            .add, .replace, .@"test" => |o| {
                try writePath(writer, "path", o.path);
                try writer.print(",\"value\":{s}", .{o.value});
            },
            .move, .copy => |o| {
                try writePath(writer, "from", o.from);
                try writePath(writer, "path", o.path);
            },
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writePath(writer: *Writer, name: []const u8, path: Pointer) Writer.Error!void {
    try writer.print(",\"{s}\":", .{name});
    try std.json.Stringify.encodeJsonString(path.text, .{}, writer);
}

/// Allows a patch to be written as part of larger output by `std.json.Stringify`.
pub fn jsonStringify(patch: Patch, jws: anytype) !void {
    try jws.print("{f}", .{patch});
}

const testing = std.testing;

fn expectParseError(expected: ParseError, source: []const u8) !void {
    var patch = parse(testing.allocator, source, .{}) catch |err| {
        return testing.expectEqual(expected, err);
    };
    patch.deinit();
    return error.TestExpectedError;
}

test parse {
    var patch = try parse(testing.allocator,
        \\[
        \\  { "op": "test", "path": "/a/b/c", "value": "foo" },
        \\  { "op": "remove", "path": "/a/b/c" },
        \\  { "op": "add", "path": "/a/b/c", "value": ["foo", "bar"] },
        \\  { "op": "replace", "path": "/a/b/c", "value": 42 },
        \\  { "op": "move", "from": "/a/b/c", "path": "/a/b/d" },
        \\  { "op": "copy", "from": "/a/b/d", "path": "/a/b/e" }
        \\]
    , .{});
    defer patch.deinit();

    const operations = patch.operations.items;
    try testing.expectEqual(6, operations.len);
    try testing.expectEqualStrings("\"foo\"", operations[0].@"test".value);
    try testing.expectEqualStrings("/a/b/c", operations[1].remove.path.text);
    try testing.expectEqualStrings("[\"foo\", \"bar\"]", operations[2].add.value);
    try testing.expectEqualStrings("42", operations[3].replace.value);
    try testing.expectEqualStrings("/a/b/c", operations[4].move.from.text);
    try testing.expectEqualStrings("/a/b/e", operations[5].copy.path.text);
}

test "operation members may appear in any order" {
    var patch = try parse(testing.allocator,
        \\[{"value":1,"path":"/a","op":"add"},{"path":"/b","from":"/a","op":"move"}]
    , .{});
    defer patch.deinit();
    try testing.expectEqualStrings("1", patch.operations.items[0].add.value);
    try testing.expectEqualStrings("/a", patch.operations.items[1].move.from.text);
}

test "members undefined for an operation are ignored" {
    var patch = try parse(testing.allocator,
        \\[{"op":"remove","path":"/a","value":{"x":[]},"from":7,"from":8,"extra":null},
        \\ {"op":"add","path":"/b","value":1,"from":false}]
    , .{});
    defer patch.deinit();
    try testing.expectEqual(2, patch.operations.items.len);
}

test "unknown members are ignored even if they resemble known ones" {
    var patch = try parse(testing.allocator,
        \\[{"op":"move","from":"/a","path":"/b","xxxx":1,"yyyy":"/c","zz":0,"vvvvv":2,"OP":"x"}]
    , .{});
    defer patch.deinit();
    try testing.expectEqualStrings("/a", patch.operations.items[0].move.from.text);
    try testing.expectEqualStrings("/b", patch.operations.items[0].move.path.text);
}

test "keys that start like known ones are not mistaken for them" {
    var patch = try parse(testing.allocator,
        \\[{"opx":"copy","op":"add","opx":"move","op ":1,"o":2,"path":"/a","pathx":"/b","pat":3,
        \\  "value":1,"valuex":2,"valu":3,"from":"/c","fromx":"/d","fro":4}]
    , .{});
    defer patch.deinit();
    try testing.expectEqualStrings("/a", patch.operations.items[0].add.path.text);
    try testing.expectEqualStrings("1", patch.operations.items[0].add.value);

    var transfer = try parse(testing.allocator,
        \\[{"op":"move","from":"/a","fromx":"/b","path":"/c","pathx":"/d"}]
    , .{});
    defer transfer.deinit();
    try testing.expectEqualStrings("/a", transfer.operations.items[0].move.from.text);
    try testing.expectEqualStrings("/c", transfer.operations.items[0].move.path.text);
}

test "keys are recognized wherever they are in the text" {
    // Keys that end close to the end of the text cannot be read as a whole word.
    var patch = try parse(testing.allocator,
        \\[{"path":"/a","value":1,"op":"add"},{"value":2,"op":"add","path":"/b"},
        \\ {"path":"/c","op":"remove"},{"from":"/d","op":"copy","path":"/e"}]
    , .{});
    defer patch.deinit();
    try testing.expectEqual(4, patch.operations.items.len);
    try testing.expectEqualStrings("/e", patch.operations.items[3].copy.path.text);
}

test "escapes in keys and values are honored" {
    var patch = try parse(testing.allocator,
        \\[{"\u006fp":"\u0061dd","p\u0061th":"/\u0061~1b","value":1}]
    , .{});
    defer patch.deinit();
    const path = patch.operations.items[0].add.path;
    try testing.expectEqualStrings("/a~1b", path.text);
    try testing.expectEqualStrings("a/b", path.tokens[0].name);
}

test "rejects malformed patches" {
    try expectParseError(error.SyntaxError, "");
    try expectParseError(error.SyntaxError, "[");
    try expectParseError(error.SyntaxError, "[{\"op\":\"remove\",\"path\":\"/a\"}");
    try expectParseError(error.SyntaxError, "[] x");
    try expectParseError(error.SyntaxError, "[{\"op\":\"add\"");
    try expectParseError(error.SyntaxError, "[{\"op\":\"remove\",\"path\":\"/a\",}]");
    try expectParseError(error.SyntaxError, "[{\"op\":\"remove\",\"path\":\"/a\"},]");
    try expectParseError(error.SyntaxError, "[{\"op\":\"add\",\"path\":\"/a\",\"value\":01}]");
    try expectParseError(error.NotAnArray, "{}");
    try expectParseError(error.NotAnArray, "null");
    try expectParseError(error.NotAnObject, "[1]");
    try expectParseError(error.NotAnObject, "[[]]");
    try expectParseError(error.MissingMember, "[{}]");
    try expectParseError(error.MissingMember, "[{\"path\":\"/a\"}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"add\",\"value\":1}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"add\",\"path\":\"/a\"}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"replace\",\"path\":\"/a\"}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"test\",\"path\":\"/a\"}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"move\",\"path\":\"/a\"}]");
    try expectParseError(error.MissingMember, "[{\"op\":\"copy\",\"path\":\"/a\"}]");
    try expectParseError(error.DuplicateMember, "[{\"op\":\"add\",\"op\":\"add\",\"path\":\"/a\",\"value\":1}]");
    try expectParseError(error.DuplicateMember, "[{\"op\":\"add\",\"path\":\"/a\",\"path\":\"/b\",\"value\":1}]");
    try expectParseError(error.DuplicateMember, "[{\"op\":\"add\",\"path\":\"/a\",\"value\":1,\"value\":2}]");
    try expectParseError(error.DuplicateMember, "[{\"op\":\"move\",\"from\":\"/a\",\"from\":\"/b\",\"path\":\"/c\"}]");
    try expectParseError(error.InvalidMemberType, "[{\"op\":1,\"path\":\"/a\"}]");
    try expectParseError(error.InvalidMemberType, "[{\"op\":\"remove\",\"path\":1}]");
    try expectParseError(error.InvalidMemberType, "[{\"op\":\"move\",\"from\":null,\"path\":\"/a\"}]");
    try expectParseError(error.UnknownOperation, "[{\"op\":\"spam\",\"path\":\"/a\"}]");
    try expectParseError(error.UnknownOperation, "[{\"op\":\"ADD\",\"path\":\"/a\",\"value\":1}]");
    try expectParseError(error.InvalidPointer, "[{\"op\":\"remove\",\"path\":\"a\"}]");
    try expectParseError(error.InvalidPointer, "[{\"op\":\"remove\",\"path\":\"/~\"}]");
    try expectParseError(error.InvalidPointer, "[{\"op\":\"copy\",\"from\":\"a\",\"path\":\"/b\"}]");
    try expectParseError(error.MoveIntoDescendant, "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a/b\"}]");
    try expectParseError(error.MoveIntoDescendant, "[{\"op\":\"move\",\"from\":\"\",\"path\":\"/a\"}]");
}

test "an empty patch is valid" {
    var patch = try parse(testing.allocator, " [ ] ", .{});
    defer patch.deinit();
    try testing.expectEqual(0, patch.operations.items.len);
}

test "diagnostics locate the failing operation" {
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.UnknownOperation, parse(testing.allocator,
        \\[{"op":"remove","path":"/a"}, {"op":"nope","path":"/b"}]
    , .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(1, diagnostics.operation);
    try testing.expectEqual(30, diagnostics.offset);
}

test "building a patch and writing it as JSON" {
    var patch: Patch = .init(testing.allocator);
    defer patch.deinit();

    try patch.add("/a", .{ .x = 1, .y = "two" });
    try patch.remove("/b/0");
    try patch.replace("/c", true);
    try patch.move("/d", "/e");
    try patch.copy("/f", "/g~1h");
    try patch.testValue("/i", Raw{ .json = "[1, 2.50]" });
    try patch.add("/j", "plain \"string\"");

    try testing.expectError(error.InvalidPointer, patch.remove("no slash"));
    try testing.expectError(error.InvalidPointer, patch.remove("/\xff"));
    try testing.expectError(error.MoveIntoDescendant, patch.move("/a", "/a/b"));
    try testing.expectError(error.SyntaxError, patch.add("/a", Raw{ .json = "[1" }));

    try testing.expectFmt(
        \\[{"op":"add","path":"/a","value":{"x":1,"y":"two"}},
    ++
        \\{"op":"remove","path":"/b/0"},
    ++
        \\{"op":"replace","path":"/c","value":true},
    ++
        \\{"op":"move","from":"/d","path":"/e"},
    ++
        \\{"op":"copy","from":"/f","path":"/g~1h"},
    ++
        \\{"op":"test","path":"/i","value":[1, 2.50]},
    ++
        \\{"op":"add","path":"/j","value":"plain \"string\""}]
    , "{f}", .{patch});
}

test "a written patch parses back to the same patch" {
    const gpa = testing.allocator;
    var first = try parse(gpa,
        \\[{"op":"add","path":"/a\"b\\c/~0~1","value":[1,{"k":"v"}]},
        \\ {"op":"copy","from":"","path":"/x"}]
    , .{});
    defer first.deinit();

    const text = try std.fmt.allocPrint(gpa, "{f}", .{first});
    defer gpa.free(text);

    var second = try parse(gpa, text, .{});
    defer second.deinit();
    try testing.expectFmt(text, "{f}", .{second});
    try testing.expectEqualStrings("a\"b\\c", second.operations.items[0].add.path.tokens[0].name);
}
