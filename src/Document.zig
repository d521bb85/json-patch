//! A JSON document that can be patched in place.
//!
//! The document is lazy. Parsing validates the text but builds no tree, and
//! every value starts out as a slice of that text. When a patch needs to look
//! inside an object or array, only that one level is split into its children,
//! which remain slices in turn. Anything a patch does not reach is never
//! examined again, and is copied to the output verbatim, so formatting and
//! number precision are preserved. Parsing also records where large containers
//! end, or the first expansion does if parsing was told not to validate, so
//! that expanding a container does not have to scan its children to find them.
//!
//! Patches are atomic. Each change is recorded in an undo log, so a patch that
//! fails partway leaves the document as it was, without having to copy the
//! document up front.
//!
//! Memory is owned by an arena that is freed by `deinit`, so values replaced by
//! a patch are not reclaimed until then. A document that stays alive across
//! many patches can call `compact` to shed them.
//!
//! A document is not safe to use from multiple threads at once, even for
//! reading, because reading can expand values in place.

const std = @import("std");
const Arena = @import("Arena.zig");
const number = @import("number.zig");
const lib = @import("root.zig");
const scan = @import("scan.zig");
const string = @import("string.zig");
const structure = @import("structure.zig");
const validate = @import("validate.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = lib.Diagnostics;
const Document = @This();
const Operation = Patch.Operation;
const Patch = lib.Patch;
const Pointer = lib.Pointer;
const Token = Pointer.Token;
const Writer = std.Io.Writer;
const assert = std.debug.assert;

gpa: Allocator,
arena: Arena,
root: Node,
undo: std.ArrayList(Undo) = .empty,
/// The text of the root when the document was parsed.
source: []const u8,
/// Where the containers in `source` end, once that is known.
index: structure.Index = .{},
/// Whether `index` should be built the first time a container is expanded,
/// because the document was not validated.
wants_index: bool = false,

pub const ParseOptions = struct {
    /// Whether the document keeps its own copy of the source text. With
    /// `.borrow` no copy is made, and `source` must outlive the document.
    source: lib.Ownership = .copy,
    /// With `.none`, the text is assumed to be valid JSON, and parsing takes
    /// constant time. This is meant for text known to be good, such as what a
    /// database stored earlier. Invalid text can make later calls fail with
    /// `error.SyntaxError` or produce invalid output, but is memory safe.
    validation: enum { full, none } = .full,
    /// The deepest nesting allowed. See `default_max_depth`.
    max_depth: u16 = lib.default_max_depth,
    diagnostics: ?*Diagnostics = null,
};

pub const ParseError = validate.Error || Allocator.Error;

pub const ApplyOptions = struct {
    /// Whether values are copied out of the patch. With `.borrow` no copy is
    /// made, and the patch must outlive the document.
    values: lib.Ownership = .copy,
    diagnostics: ?*Diagnostics = null,
};

pub const ApplyError = Allocator.Error || error{
    /// A location that must exist does not.
    PathNotFound,
    /// A pointer used a token on an array that is not an index, or used `-`
    /// where an existing element is required.
    InvalidArrayIndex,
    /// An array index is greater than the number of elements.
    IndexOutOfBounds,
    /// A `test` operation found a different value.
    TestFailed,
    /// The patch removed the root, and so leaves no JSON document behind.
    RootRemoved,
    /// The document skipped validation and turned out to be invalid.
    SyntaxError,
};

pub const GetError = Pointer.ParseError || Allocator.Error || error{SyntaxError};

/// A value in the document. Containers that have been expanded point at their
/// `Array` or `Object`, and everything else is JSON text.
const Node = extern struct {
    ptr: [*]const u8,
    /// The length of the text, or one of the tags below.
    len: usize,

    const array_tag = std.math.maxInt(usize);
    const object_tag = array_tag - 1;
    const absent_tag = array_tag - 2;

    /// The state of a root that has been removed.
    const absent: Node = .{ .ptr = undefined, .len = absent_tag };

    const Unpacked = union(enum) {
        raw: []const u8,
        array: *Array,
        object: *Object,
        absent,
    };

    inline fn initRaw(text: []const u8) Node {
        return .{ .ptr = text.ptr, .len = text.len };
    }

    inline fn unpack(node: Node) Unpacked {
        return switch (node.len) {
            array_tag => .{ .array = @ptrCast(@alignCast(@constCast(node.ptr))) },
            object_tag => .{ .object = @ptrCast(@alignCast(@constCast(node.ptr))) },
            absent_tag => .absent,
            else => .{ .raw = node.ptr[0..node.len] },
        };
    }

    /// Returns the JSON text of the node, if it is still what the source says.
    inline fn cleanText(node: Node) ?[]const u8 {
        return switch (node.unpack()) {
            .raw => |raw| raw,
            .array => |array| if (array.dirty) null else array.span,
            .object => |object| if (object.dirty) null else object.span,
            .absent => null,
        };
    }
};

const Array = struct {
    items: std.ArrayList(Node) = .empty,
    /// The text this array was expanded from.
    span: []const u8,
    /// Whether this array or anything inside it has changed since then. This is
    /// never cleared by a rollback, which only costs some coalescing of output.
    dirty: bool = false,

    fn parse(arena: *Arena, text: []const u8, listed: structure.Cursor) ApplyError!*Array {
        const array = try arena.create(Array);
        array.* = .{ .span = text };
        var i = scan.skipWhitespace(text, 1);
        if (i < text.len and text[i] == ']') return array;

        var cursor = listed;
        const allocator = arena.allocator();
        array.items = arena.list(Node);
        defer arena.finishList(Node, &array.items);
        while (true) {
            const end = cursor.valueEnd(text, i) orelse return error.SyntaxError;
            if (array.items.items.len == array.items.capacity) try array.items.ensureUnusedCapacity(allocator, 1);
            array.items.appendAssumeCapacity(.initRaw(text[i..end]));
            i = scan.skipWhitespace(text, end);
            if (i >= text.len) return error.SyntaxError;
            switch (text[i]) {
                ',' => i = scan.skipWhitespace(text, i + 1),
                ']' => return array,
                else => return error.SyntaxError,
            }
        }
    }
};

const Object = struct {
    /// Members are appended and flagged as removed rather than taken out, which
    /// preserves their order, and keeps undoing a removal and `slots` trivial.
    members: std.ArrayList(Member) = .empty,
    /// The text this object was expanded from.
    span: []const u8,
    /// See `Array.dirty`.
    dirty: bool = false,
    /// A hash table of indices into `members` plus one, used once linear search
    /// has become too expensive.
    slots: []u32 = &.{},
    /// How many members have been visited by linear searches so far.
    visited: usize = 0,

    /// Objects smaller than this are always searched linearly.
    const min_indexed_len = 32;

    fn parse(arena: *Arena, text: []const u8, listed: structure.Cursor) ApplyError!*Object {
        const object = try arena.create(Object);
        object.* = .{ .span = text };
        var i = scan.skipWhitespace(text, 1);
        if (i < text.len and text[i] == '}') return object;

        var cursor = listed;
        const allocator = arena.allocator();
        object.members = arena.list(Member);
        defer arena.finishList(Member, &object.members);
        while (true) {
            if (i >= text.len or text[i] != '"') return error.SyntaxError;
            const key_start = i + 1;
            const key = scan.stringEnd(cursor.widen(text), key_start) orelse return error.SyntaxError;
            i = scan.skipWhitespace(text, key.end + 1);
            if (i >= text.len or text[i] != ':') return error.SyntaxError;
            i = scan.skipWhitespace(text, i + 1);
            const end = cursor.valueEnd(text, i) orelse return error.SyntaxError;
            if (object.members.items.len == object.members.capacity) try object.members.ensureUnusedCapacity(allocator, 1);
            object.members.appendAssumeCapacity(.{
                .key_ptr = text[key_start..].ptr,
                .key = .init(text[key_start..key.end], key.escaped),
                .value = .initRaw(text[i..end]),
            });
            i = scan.skipWhitespace(text, end);
            if (i >= text.len) return error.SyntaxError;
            switch (text[i]) {
                ',' => i = scan.skipWhitespace(text, i + 1),
                '}' => return object,
                else => return error.SyntaxError,
            }
        }
    }

    /// Finds the member named `key`, which is not escaped. As in most JSON
    /// parsers, the last of any duplicates wins.
    fn find(object: *Object, allocator: Allocator, key: []const u8) Allocator.Error!?usize {
        const members = object.members.items;
        if (object.slots.len == 0 and members.len >= min_indexed_len and
            members.len <= std.math.maxInt(u32) - 1)
        {
            // Building the table costs as much as a good number of linear
            // searches, so it is only worth it once that many have happened.
            object.visited += members.len;
            if (object.visited >= 32 * members.len) try object.buildIndex(allocator);
        }
        if (object.slots.len != 0) return object.probe(key);

        const word = Member.Key.wordFor(key);
        var i = members.len;
        while (i > 0) {
            i -= 1;
            if (members[i].matches(key, word)) return i;
        }
        return null;
    }

    fn probe(object: *Object, key: []const u8) ?usize {
        const word = Member.Key.wordFor(key);
        const mask = object.slots.len - 1;
        var slot = hash(object, key) & mask;
        while (true) : (slot = (slot + 1) & mask) {
            const entry = object.slots[slot];
            if (entry == 0) return null;
            if (object.members.items[entry - 1].matches(key, word)) return entry - 1;
        }
    }

    inline fn hash(object: *const Object, key: []const u8) usize {
        // The seed varies between objects and processes, so that keys cannot
        // be crafted in advance to collide.
        return @truncate(std.hash.Wyhash.hash(@intFromPtr(object), key));
    }

    fn buildIndex(object: *Object, allocator: Allocator) Allocator.Error!void {
        const len = object.members.items.len;
        const capacity = std.math.ceilPowerOfTwoAssert(usize, len * 2);
        object.slots = try allocator.alloc(u32, capacity);
        @memset(object.slots, 0);
        for (0..len) |i| {
            if (!object.members.items[i].key.removed) try object.insertSlot(allocator, i);
        }
    }

    /// Adds the member at `index` to the hash table. Any earlier member of the
    /// same name is flagged as removed, because it is now unreachable.
    fn insertSlot(object: *Object, allocator: Allocator, index: usize) Allocator.Error!void {
        const members = object.members.items;
        const member = &members[index];
        const key = if (member.key.escaped)
            try string.decode(allocator, member.name())
        else
            member.name();

        const word = Member.Key.wordFor(key);
        const mask = object.slots.len - 1;
        var slot = hash(object, key) & mask;
        while (true) : (slot = (slot + 1) & mask) {
            const entry = object.slots[slot];
            if (entry == 0) break;
            const other = &members[entry - 1];
            if (other.matches(key, word)) {
                other.key.removed = true;
                break;
            }
        }
        object.slots[slot] = @intCast(index + 1);
    }

    /// Appends a member, which is known not to exist yet, and returns its index.
    fn append(object: *Object, allocator: Allocator, name: []const u8, value: Node) Allocator.Error!void {
        const escaped = string.needsEscape(name);
        const quoted = if (escaped) try string.encodeQuoted(allocator, name) else plain: {
            const text = try allocator.alloc(u8, name.len + 2);
            text[0] = '"';
            @memcpy(text[1..][0..name.len], name);
            text[name.len + 1] = '"';
            break :plain text;
        };
        try object.members.append(allocator, .{
            .key_ptr = quoted[1..].ptr,
            .key = .init(quoted[1 .. quoted.len - 1], escaped),
            .value = value,
        });
        if (object.slots.len == 0) return;
        if (object.members.items.len * 2 > object.slots.len) {
            try object.buildIndex(allocator);
        } else {
            try object.insertSlot(allocator, object.members.items.len - 1);
        }
    }
};

const Member = struct {
    /// The key as it appears in JSON, escapes included. The bytes on either
    /// side of it are always its quotes.
    key_ptr: [*]const u8,
    key: Key,
    value: Node,

    const Key = packed struct(usize) {
        len: @Int(.unsigned, @bitSizeOf(usize) - @bitSizeOf(Fingerprint) - 2),
        /// A hash of the text of the key. Searching members compares this word,
        /// which saves reading the text of nearly all of them, and the text is
        /// spread throughout the document, unlike the members.
        fingerprint: Fingerprint,
        escaped: bool,
        removed: bool,

        /// Only keys that are larger than a terabyte are beyond what this can
        /// represent on 64-bit targets. There is no room for this on smaller ones.
        const Fingerprint = if (@bitSizeOf(usize) == 64) u22 else u0;

        inline fn init(text: []const u8, escaped: bool) Key {
            return .{ .len = @intCast(text.len), .fingerprint = fingerprintOf(text), .escaped = escaped, .removed = false };
        }

        /// Returns what `key` of a member is if its text is exactly `text`.
        inline fn wordFor(text: []const u8) usize {
            return @bitCast(init(text, false));
        }

        inline fn fingerprintOf(text: []const u8) Fingerprint {
            if (Fingerprint == u0) return 0;
            const len = text.len;
            const bytes: u64 = if (len >= 4)
                @as(u64, std.mem.readInt(u32, text[0..4], .little)) << 32 |
                    std.mem.readInt(u32, text[len - 4 ..][0..4], .little)
            else if (len != 0)
                @as(u64, text[0]) << 16 | @as(u64, text[len / 2]) << 8 | text[len - 1]
            else
                0;
            return @truncate((bytes *% 0x9e37_79b9_7f4a_7c15) >> 42);
        }
    };

    inline fn name(member: *const Member) []const u8 {
        return member.key_ptr[0..member.key.len];
    }

    /// Returns the key with its quotes.
    inline fn quoted(member: *const Member) []const u8 {
        return (member.key_ptr - 1)[0 .. @as(usize, member.key.len) + 2];
    }

    /// Returns whether this member is called `key`, for which `word` is the
    /// result of `Key.wordFor`.
    inline fn matches(member: *const Member, key: []const u8, word: usize) bool {
        // Comparing the whole word checks the length, the fingerprint, and both
        // flags at once.
        if (@as(usize, @bitCast(member.key)) == word) return scan.eql(member.name(), key);
        return member.key.escaped and !member.key.removed and string.eqlDecoded(member.name(), key);
    }
};

/// One step that reverses a single change.
const Undo = union(enum) {
    root: Node,
    array_set: struct { array: *Array, index: usize, value: Node },
    array_insert: struct { array: *Array, index: usize, value: Node },
    array_remove: struct { array: *Array, index: usize },
    member_set: struct { object: *Object, index: usize, value: Node },
    member_restore: struct { object: *Object, index: usize },
    member_remove: struct { object: *Object, index: usize },
};

/// Parses a document. On failure, `options.diagnostics` receives the offset of
/// the problem.
pub fn parse(gpa: Allocator, source: []const u8, options: ParseOptions) ParseError!Document {
    return parseInto(.init(gpa), source, options);
}

/// As `parse`, starting out with `buffer` instead of allocating, which is what
/// `lib.apply` uses, as it knows the document does not outlive it.
pub fn parseBuffered(gpa: Allocator, source: []const u8, options: ParseOptions, buffer: []u8) ParseError!Document {
    return parseInto(.initBuffer(gpa, buffer), source, options);
}

inline fn parseInto(empty: Arena, source: []const u8, options: ParseOptions) ParseError!Document {
    var arena = empty;
    errdefer arena.deinit();
    const gpa = arena.gpa;

    // A rough guess at what the index and the expanded containers will need, which
    // saves growing a very large one through a series of ever larger chunks.
    try arena.reserve(std.math.clamp(source.len / 16, 1024, 16 << 20));

    var index: structure.Index = .{};
    const text = switch (options.validation) {
        .full => try structure.document(arena.allocator(), source, options.max_depth, &index) orelse text: {
            var cursor: validate.Cursor = .{ .src = source };
            break :text cursor.document(options.max_depth) catch |err| {
                if (options.diagnostics) |diagnostics| diagnostics.* = .{ .offset = cursor.pos };
                return err;
            };
        },
        .none => text: {
            const trimmed = std.mem.trim(u8, source, " \t\r\n");
            if (trimmed.len == 0) return error.SyntaxError;
            break :text trimmed;
        },
    };
    const owned = switch (options.source) {
        .copy => try arena.allocator().dupe(u8, text),
        .borrow => text,
    };
    return .{
        .gpa = gpa,
        .arena = arena,
        .root = .initRaw(owned),
        .source = owned,
        .index = index,
        .wants_index = options.validation == .none and wantsIndex(owned),
    };
}

fn wantsIndex(text: []const u8) bool {
    return structure.Index.suits(text.len) and text[0] | 0x20 == '{';
}

pub fn deinit(doc: *Document) void {
    doc.arena.deinit();
    doc.* = undefined;
}

/// Applies every operation in `patch`, in order. If any of them fails, the
/// document is left as it was, `options.diagnostics` receives the index of the
/// failed operation, and its error is returned.
pub fn apply(doc: *Document, patch: *const Patch, options: ApplyOptions) ApplyError!void {
    var scratch: Arena = .init(doc.gpa);
    defer scratch.deinit();

    doc.undo.clearRetainingCapacity();
    // Most operations need one entry, and any that need more will still grow it.
    try doc.undo.ensureTotalCapacity(doc.arena.allocator(), patch.operations.items.len);
    for (patch.operations.items, 0..) |operation, i| {
        doc.step(operation, options.values, &scratch) catch |err| {
            doc.rollback();
            if (options.diagnostics) |diagnostics| diagnostics.* = .{ .operation = i };
            return err;
        };
    }
    if (doc.root.len == Node.absent_tag) {
        doc.rollback();
        if (options.diagnostics) |diagnostics| diagnostics.* = .{ .operation = patch.operations.items.len };
        return error.RootRemoved;
    }
}

fn step(
    doc: *Document,
    operation: Operation,
    values: lib.Ownership,
    scratch: *Arena,
) ApplyError!void {
    switch (operation) {
        .add => |o| try doc.insert(o.path, try doc.ownValue(o.value, values)),
        .remove => |o| _ = try doc.take(o.path),
        .replace => |o| {
            const value = try doc.ownValue(o.value, values);
            const location = try doc.locate(o.path.tokens, .write);
            try doc.undo.ensureUnusedCapacity(doc.arena.allocator(), 1);
            doc.undo.appendAssumeCapacity(location.undo());
            location.ptr.* = value;
        },
        .move => |o| {
            if (o.from.eql(o.path)) {
                _ = try doc.locate(o.from.tokens, .read);
            } else {
                try doc.insert(o.path, try doc.take(o.from));
            }
        },
        .copy => |o| {
            const source = try doc.locate(o.from.tokens, .read);
            try doc.insert(o.path, try doc.detached(source.ptr.*));
        },
        .@"test" => |o| {
            const target = try doc.locate(o.path.tokens, .read);
            defer scratch.reset();
            const text = try detachedText(doc.gpa, scratch.allocator(), target.ptr.*);
            if (sameTokens(text, o.value)) return;
            if (!try eql(scratch, text, o.value)) return error.TestFailed;
        },
    }
}

fn ownValue(doc: *Document, value: []const u8, values: lib.Ownership) Allocator.Error!Node {
    return .initRaw(switch (values) {
        .copy => try doc.arena.allocator().dupe(u8, value),
        .borrow => value,
    });
}

/// Returns a copy of `node` that does not share any mutable state with it.
/// Text is immutable, so it can be shared freely, which makes copying a value
/// that has not been expanded free.
fn detached(doc: *Document, node: Node) Allocator.Error!Node {
    return .initRaw(try detachedText(doc.gpa, doc.arena.allocator(), node));
}

fn detachedText(gpa: Allocator, allocator: Allocator, node: Node) Allocator.Error![]const u8 {
    if (node.cleanText()) |text| return text;
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    writeNode(gpa, node, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Expands `node` if needed and returns it, or fails if it is not a container.
inline fn open(doc: *Document, node: *Node) ApplyError!Node.Unpacked {
    const unpacked = node.unpack();
    switch (unpacked) {
        .array, .object => return unpacked,
        .absent => return error.PathNotFound,
        .raw => |text| switch (text[0]) {
            '{' => {
                const object = try Object.parse(&doc.arena, text, try doc.children(text));
                node.* = .{ .ptr = @ptrCast(object), .len = Node.object_tag };
                return .{ .object = object };
            },
            '[' => {
                const array = try Array.parse(&doc.arena, text, try doc.children(text));
                node.* = .{ .ptr = @ptrCast(array), .len = Node.array_tag };
                return .{ .array = array };
            },
            else => return error.PathNotFound,
        },
    }
}

/// Returns a cursor over what the index knows about the children of `text`.
inline fn children(doc: *Document, text: []const u8) Allocator.Error!structure.Cursor {
    if (doc.wants_index) {
        doc.wants_index = false;
        try doc.index.build(doc.arena.allocator(), doc.source);
    }
    // Values that came from a patch are outside of `source`, and this wraps
    // around to a large offset if they are before it.
    const offset = @intFromPtr(text.ptr) -% @intFromPtr(doc.source.ptr);
    if (offset >= doc.source.len) return .{ .readable = text.len };
    return doc.index.cursor(offset, doc.source.len - offset);
}

/// An existing value, and how to restore it after changing it.
const Location = struct {
    ptr: *Node,
    parent: union(enum) {
        root,
        array: struct { array: *Array, index: usize },
        object: struct { object: *Object, index: usize },
    },

    fn undo(location: Location) Undo {
        return switch (location.parent) {
            .root => .{ .root = location.ptr.* },
            .array => |p| .{ .array_set = .{ .array = p.array, .index = p.index, .value = location.ptr.* } },
            .object => |p| .{ .member_set = .{ .object = p.object, .index = p.index, .value = location.ptr.* } },
        };
    }
};

/// Whether a walk through the document is going to change what it reaches.
const Intent = enum { read, write };

/// Finds the existing value that `tokens` refers to.
fn locate(doc: *Document, tokens: []const Token, intent: Intent) ApplyError!Location {
    if (tokens.len == 0) {
        if (doc.root.len == Node.absent_tag) return error.PathNotFound;
        return .{ .ptr = &doc.root, .parent = .root };
    }
    const parent = try doc.descend(tokens[0 .. tokens.len - 1], intent);
    return doc.child(parent, tokens[tokens.len - 1], intent);
}

fn descend(doc: *Document, tokens: []const Token, intent: Intent) ApplyError!*Node {
    var node = &doc.root;
    for (tokens) |token| node = (try doc.child(node, token, intent)).ptr;
    return node;
}

inline fn child(doc: *Document, parent: *Node, token: Token, intent: Intent) ApplyError!Location {
    switch (try doc.open(parent)) {
        .object => |object| {
            object.dirty = object.dirty or intent == .write;
            const index = try object.find(doc.arena.allocator(), token.name) orelse
                return error.PathNotFound;
            return .{
                .ptr = &object.members.items[index].value,
                .parent = .{ .object = .{ .object = object, .index = index } },
            };
        },
        .array => |array| {
            array.dirty = array.dirty or intent == .write;
            const index: usize = switch (token.index) {
                .invalid, .end => return error.InvalidArrayIndex,
                .overflow => return error.IndexOutOfBounds,
                else => @backingInt(token.index),
            };
            if (index >= array.items.items.len) return error.IndexOutOfBounds;
            return .{
                .ptr = &array.items.items[index],
                .parent = .{ .array = .{ .array = array, .index = index } },
            };
        },
        .raw, .absent => unreachable,
    }
}

/// Performs the core of the `add` operation.
fn insert(doc: *Document, path: Pointer, value: Node) ApplyError!void {
    const tokens = path.tokens;
    try doc.undo.ensureUnusedCapacity(doc.arena.allocator(), 1);
    if (tokens.len == 0) {
        doc.undo.appendAssumeCapacity(.{ .root = doc.root });
        doc.root = value;
        return;
    }

    const token = tokens[tokens.len - 1];
    const allocator = doc.arena.allocator();
    switch (try doc.open(try doc.descend(tokens[0 .. tokens.len - 1], .write))) {
        .object => |object| {
            object.dirty = true;
            if (try object.find(allocator, token.name)) |index| {
                const member = &object.members.items[index];
                doc.undo.appendAssumeCapacity(.{ .member_set = .{
                    .object = object,
                    .index = index,
                    .value = member.value,
                } });
                member.value = value;
            } else {
                const index = object.members.items.len;
                try object.append(allocator, token.name, value);
                doc.undo.appendAssumeCapacity(.{ .member_remove = .{ .object = object, .index = index } });
            }
        },
        .array => |array| {
            array.dirty = true;
            const len = array.items.items.len;
            const index: usize = switch (token.index) {
                .invalid => return error.InvalidArrayIndex,
                .end => len,
                .overflow => return error.IndexOutOfBounds,
                else => @backingInt(token.index),
            };
            if (index > len) return error.IndexOutOfBounds;
            try array.items.insert(allocator, index, value);
            doc.undo.appendAssumeCapacity(.{ .array_remove = .{ .array = array, .index = index } });
        },
        .raw, .absent => unreachable,
    }
}

/// Performs the core of the `remove` operation, returning the removed value.
fn take(doc: *Document, path: Pointer) ApplyError!Node {
    const location = try doc.locate(path.tokens, .write);
    const value = location.ptr.*;
    try doc.undo.ensureUnusedCapacity(doc.arena.allocator(), 1);
    switch (location.parent) {
        .root => {
            doc.undo.appendAssumeCapacity(.{ .root = value });
            doc.root = .absent;
        },
        .array => |p| {
            _ = p.array.items.orderedRemove(p.index);
            doc.undo.appendAssumeCapacity(.{ .array_insert = .{ .array = p.array, .index = p.index, .value = value } });
        },
        .object => |p| {
            const object = p.object;
            const members = object.members.items;
            members[p.index].key.removed = true;
            doc.undo.appendAssumeCapacity(.{ .member_restore = .{ .object = object, .index = p.index } });
            if (object.slots.len != 0) return value;

            // Without a hash table, duplicates of the key may remain, and must
            // not come back to life.
            const name = path.tokens[path.tokens.len - 1].name;
            const word = Member.Key.wordFor(name);
            var i = p.index;
            while (i > 0) {
                i -= 1;
                if (!members[i].matches(name, word)) continue;
                try doc.undo.ensureUnusedCapacity(doc.arena.allocator(), 1);
                members[i].key.removed = true;
                doc.undo.appendAssumeCapacity(.{ .member_restore = .{ .object = object, .index = i } });
            }
        },
    }
    return value;
}

fn rollback(doc: *Document) void {
    while (doc.undo.pop()) |entry| switch (entry) {
        .root => |value| doc.root = value,
        .array_set => |u| u.array.items.items[u.index] = u.value,
        // Removing the element is what made room, so this cannot allocate.
        .array_insert => |u| u.array.items.insertAssumeCapacity(u.index, u.value),
        .array_remove => |u| _ = u.array.items.orderedRemove(u.index),
        .member_set => |u| u.object.members.items[u.index].value = u.value,
        .member_restore => |u| u.object.members.items[u.index].key.removed = false,
        .member_remove => |u| u.object.members.items[u.index].key.removed = true,
    };
}

/// Returns whether two JSON texts are identical apart from whitespace between
/// tokens. That makes them equal, and is by far the most common way for values
/// to be equal, so this avoids expanding either of them.
fn sameTokens(a: []const u8, b: []const u8) bool {
    if (a.len == b.len and std.mem.eql(u8, a, b)) return true;
    var i: usize = 0;
    var j: usize = 0;
    while (true) {
        i = scan.skipWhitespace(a, i);
        j = scan.skipWhitespace(b, j);
        if (i == a.len or j == b.len) return i == a.len and j == b.len;
        if (a[i] != b[j]) return false;
        if (a[i] != '"') {
            i += 1;
            j += 1;
            continue;
        }
        const x = scan.stringEnd(a, i + 1) orelse return false;
        const y = scan.stringEnd(b, j + 1) orelse return false;
        if (x.end - i != y.end - j or !scan.eql(a[i + 1 .. x.end], b[j + 1 .. y.end])) return false;
        i = x.end + 1;
        j = y.end + 1;
    }
}

/// Returns whether two JSON texts represent equal values, as defined by
/// RFC 6902: strings compare by code point, numbers by numeric value, arrays
/// in order, and objects without regard to the order of their members.
///
/// Recursion is bounded by the depth of the patch value, which was limited
/// when it was parsed, because the comparison descends both values together.
fn eql(arena: *Arena, a: []const u8, b: []const u8) ApplyError!bool {
    if (std.mem.eql(u8, a, b)) return true;
    switch (a[0]) {
        '"' => {
            if (a.len < 2) return error.SyntaxError;
            return b[0] == '"' and string.eql(a[1 .. a.len - 1], b[1 .. b.len - 1]);
        },
        '[' => {
            if (b[0] != '[') return false;
            const x = try Array.parse(arena, a, .{ .readable = a.len });
            const y = try Array.parse(arena, b, .{ .readable = b.len });
            if (x.items.items.len != y.items.items.len) return false;
            for (x.items.items, y.items.items) |p, q| {
                if (!try eql(arena, p.ptr[0..p.len], q.ptr[0..q.len])) return false;
            }
            return true;
        },
        '{' => {
            if (b[0] != '{') return false;
            const x = try Object.parse(arena, a, .{ .readable = a.len });
            const y = try Object.parse(arena, b, .{ .readable = b.len });
            return eqlObjects(arena, x, y);
        },
        '-', '0'...'9' => return (b[0] == '-' or b[0] -% '0' <= 9) and number.eql(a, b),
        else => return false,
    }
}

fn eqlObjects(arena: *Arena, x: *Object, y: *Object) ApplyError!bool {
    const allocator = arena.allocator();
    for (x.members.items) |*member| {
        const name = try string.decode(allocator, member.name());
        const theirs = try y.find(allocator, name) orelse return false;
        const ours = (try x.find(allocator, name)).?;
        const p = x.members.items[ours].value;
        const q = y.members.items[theirs].value;
        if (!try eql(arena, p.ptr[0..p.len], q.ptr[0..q.len])) return false;
    }
    for (y.members.items) |*member| {
        const name = try string.decode(allocator, member.name());
        if (try x.find(allocator, name) == null) return false;
    }
    return true;
}

/// Returns the JSON text of the value at `pointer`, or null if there is no such
/// value. The result is owned by the document, and stays valid until `deinit`
/// or `compact`.
pub fn get(doc: *Document, pointer: []const u8) GetError!?[]const u8 {
    var scratch: Arena = .init(doc.gpa);
    defer scratch.deinit();
    const parsed = try Pointer.parse(scratch.allocator(), pointer);
    const location = doc.locate(parsed.tokens, .read) catch |err| switch (err) {
        error.OutOfMemory, error.SyntaxError => |e| return e,
        else => return null,
    };
    return try detachedText(doc.gpa, doc.arena.allocator(), location.ptr.*);
}

/// Releases memory held by values that are no longer part of the document, and
/// returns it to the state of a freshly parsed one.
pub fn compact(doc: *Document) Allocator.Error!void {
    const text = try doc.toOwnedSlice(doc.gpa);
    defer doc.gpa.free(text);

    var arena: Arena = .init(doc.gpa);
    errdefer arena.deinit();
    const copy = try arena.allocator().dupe(u8, text);
    doc.arena.deinit();
    doc.arena = arena;
    doc.root = .initRaw(copy);
    doc.source = copy;
    doc.undo = .empty;
    doc.index = .{};
    doc.wants_index = wantsIndex(copy);
}

/// Returns the document as JSON text, which the caller owns.
pub fn toOwnedSlice(doc: *const Document, gpa: Allocator) Allocator.Error![]u8 {
    if (doc.root.cleanText()) |text| return gpa.dupe(u8, text);
    const expected_len = switch (doc.root.unpack()) {
        .array => |array| array.span.len,
        .object => |object| object.span.len,
        .raw, .absent => 0,
    };
    // A little extra saves having to move all of it because a patch added a few
    // bytes. The rest is given back in place.
    var out: Writer.Allocating = try .initCapacity(gpa, expected_len + expected_len / 8 + 256);
    errdefer out.deinit();
    writeNode(doc.gpa, doc.root, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Writes the document as JSON with `{f}`. Untouched values appear exactly as
/// they did in the source.
pub fn format(doc: *const Document, writer: *Writer) Writer.Error!void {
    writeNode(doc.gpa, doc.root, writer) catch return error.WriteFailed;
}

/// Allows a document to be written as part of larger output by
/// `std.json.Stringify`.
pub fn jsonStringify(doc: *const Document, jws: anytype) !void {
    try jws.print("{f}", .{doc});
}

/// Coalesces neighboring pieces of output. Children of a container that are
/// still adjacent in the source are written as a single slice, separators and
/// all, instead of one at a time.
const Run = struct {
    writer: *Writer,
    start: [*]const u8 = empty,
    end: [*]const u8 = empty,

    const empty: [*]const u8 = "";

    fn flush(run: *Run) Writer.Error!void {
        const len = @intFromPtr(run.end) - @intFromPtr(run.start);
        if (len != 0) try run.writer.writeAll(run.start[0..len]);
        run.end = run.start;
    }

    /// Queues `piece`, preceded by `separator` unless it is zero.
    inline fn emit(run: *Run, piece: []const u8, separator: u8, span: []const u8) Writer.Error!void {
        if (separator != 0 and run.isAdjacent(piece.ptr, separator, span)) {
            run.end = piece.ptr + piece.len;
            return;
        }
        try run.flush();
        if (separator != 0) try run.writer.writeByte(separator);
        run.start = piece.ptr;
        run.end = piece.ptr + piece.len;
    }

    /// Returns whether only `separator` and whitespace lie between the end of
    /// the run and `next` in `span`, the text the current container came from.
    inline fn isAdjacent(run: *const Run, next: [*]const u8, separator: u8, span: []const u8) bool {
        const from = @intFromPtr(run.end);
        const to = @intFromPtr(next);
        const low = @intFromPtr(span.ptr);
        if (from < low or from >= to or to >= low + span.len) return false;
        if (run.start == run.end) return false;
        for (run.end[0 .. to - from]) |c| {
            if (c != separator and !scan.isWhitespace(c)) return false;
        }
        return true;
    }
};

const Frame = struct {
    container: union(enum) { array: *const Array, object: *const Object },
    next: usize = 0,
    wrote_any: bool = false,
};

/// Writes `node` as JSON. This keeps an explicit stack, because the depth of
/// expanded nodes is controlled by whoever wrote the patches.
fn writeNode(gpa: Allocator, node: Node, writer: *Writer) (Writer.Error || Allocator.Error)!void {
    var buffer: [4096]u8 = undefined;
    var fallback: std.heap.BufferFirstAllocator = .init(&buffer, gpa);
    const allocator = fallback.allocator();
    var stack: std.ArrayList(Frame) = .empty;
    defer stack.deinit(allocator);

    var run: Run = .{ .writer = writer };
    var pending = node;
    var separator: u8 = 0;
    var span: []const u8 = "";

    outer: while (true) {
        if (pending.cleanText()) |text| {
            try run.emit(text, separator, span);
        } else switch (pending.unpack()) {
            .array => |array| {
                try run.emit("[", separator, span);
                try stack.append(allocator, .{ .container = .{ .array = array } });
            },
            .object => |object| {
                try run.emit("{", separator, span);
                try stack.append(allocator, .{ .container = .{ .object = object } });
            },
            .raw, .absent => {},
        }
        while (stack.items.len != 0) {
            const frame = &stack.items[stack.items.len - 1];
            switch (frame.container) {
                .array => |array| {
                    if (frame.next < array.items.items.len) {
                        pending = array.items.items[frame.next];
                        separator = if (frame.wrote_any) ',' else 0;
                        span = array.span;
                        frame.next += 1;
                        frame.wrote_any = true;
                        continue :outer;
                    }
                    try run.emit("]", 0, "");
                },
                .object => |object| {
                    const members = object.members.items;
                    while (frame.next < members.len and members[frame.next].key.removed) frame.next += 1;
                    if (frame.next < members.len) {
                        const member = &members[frame.next];
                        try run.emit(member.quoted(), if (frame.wrote_any) ',' else 0, object.span);
                        pending = member.value;
                        separator = ':';
                        span = object.span;
                        frame.next += 1;
                        frame.wrote_any = true;
                        continue :outer;
                    }
                    try run.emit("}", 0, "");
                },
            }
            stack.items.len -= 1;
        }
        break;
    }
    try run.flush();
}

const testing = std.testing;

fn expectPatch(document: []const u8, patch: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    var doc = try parse(gpa, document, .{});
    defer doc.deinit();
    var parsed = try Patch.parse(gpa, patch, .{});
    defer parsed.deinit();
    try doc.apply(&parsed, .{});
    try testing.expectFmt(expected, "{f}", .{&doc});
}

/// Expects `patch` to fail and to leave the document as it was.
fn expectFailure(expected: ApplyError, document: []const u8, patch: []const u8) !void {
    const gpa = testing.allocator;
    var doc = try parse(gpa, document, .{});
    defer doc.deinit();
    var parsed = try Patch.parse(gpa, patch, .{});
    defer parsed.deinit();
    try testing.expectError(expected, doc.apply(&parsed, .{}));

    const text = try doc.toOwnedSlice(gpa);
    defer gpa.free(text);
    var arena: Arena = .init(gpa);
    defer arena.deinit();
    try testing.expect(try eql(&arena, text, document));
}

test "untouched text is preserved exactly" {
    try expectPatch(
        \\{ "keep" : [ 1.50 , 2e0 ],
        \\  "big": 123456789012345678901234567890, "drop": 1 }
    ,
        \\[{"op":"remove","path":"/drop"}]
    ,
        \\{"keep" : [ 1.50 , 2e0 ],
        \\  "big": 123456789012345678901234567890}
    );
}

test "a patch that only reads changes nothing" {
    const text = "{\"a\": [1, 2, {\"b\": \"c\"}], \"d\": 1.0}";
    try expectPatch(text,
        \\[{"op":"test","path":"/a/2/b","value":"c"}]
    , text);
}

test "add" {
    try expectPatch("{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/b\",\"value\":2}]", "{\"a\":1,\"b\":2}");
    try expectPatch("{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/a\",\"value\":2}]", "{\"a\":2}");
    try expectPatch("{}", "[{\"op\":\"add\",\"path\":\"/\",\"value\":1}]", "{\"\":1}");
    try expectPatch("1", "[{\"op\":\"add\",\"path\":\"\",\"value\":2}]", "2");
    try expectPatch("[1,2]", "[{\"op\":\"add\",\"path\":\"/1\",\"value\":3}]", "[1,3,2]");
    try expectPatch("[1,2]", "[{\"op\":\"add\",\"path\":\"/2\",\"value\":3}]", "[1,2,3]");
    try expectPatch("[1,2]", "[{\"op\":\"add\",\"path\":\"/-\",\"value\":3}]", "[1,2,3]");
    try expectPatch("[]", "[{\"op\":\"add\",\"path\":\"/0\",\"value\":3}]", "[3]");
    try expectPatch("{\"-\":1}", "[{\"op\":\"add\",\"path\":\"/-\",\"value\":2}]", "{\"-\":2}");
    try expectPatch("{\"01\":1}", "[{\"op\":\"add\",\"path\":\"/01\",\"value\":2}]", "{\"01\":2}");
}

test "add encodes new keys" {
    try expectPatch("{}",
        \\[{"op":"add","path":"/a\"b\\c\nd~1e~0","value":1}]
    ,
        \\{"a\"b\\c\nd/e~":1}
    );
    try expectPatch(
        \\{"a\"b":1}
    ,
        \\[{"op":"replace","path":"/a\"b","value":2}]
    ,
        \\{"a\"b":2}
    );
}

test "keys match regardless of how they are escaped" {
    try expectPatch(
        \\{"\u0061":1}
    ,
        \\[{"op":"replace","path":"/a","value":2}]
    ,
        \\{"\u0061":2}
    );
    try expectPatch(
        \\{"a":1}
    ,
        \\[{"op":"replace","path":"/\u0061","value":2}]
    ,
        \\{"a":2}
    );
}

test "add fails on missing parents and bad indices" {
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"add\",\"path\":\"/a/b\",\"value\":1}]");
    try expectFailure(error.PathNotFound, "{\"a\":1}", "[{\"op\":\"add\",\"path\":\"/a/b\",\"value\":1}]");
    try expectFailure(error.IndexOutOfBounds, "[1]", "[{\"op\":\"add\",\"path\":\"/2\",\"value\":1}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"add\",\"path\":\"/a\",\"value\":1}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"add\",\"path\":\"/01\",\"value\":1}]");
    try expectFailure(error.IndexOutOfBounds, "[1]", "[{\"op\":\"add\",\"path\":\"/99999999999999999999\",\"value\":1}]");
}

test "remove" {
    try expectPatch("{\"a\":1,\"b\":2}", "[{\"op\":\"remove\",\"path\":\"/a\"}]", "{\"b\":2}");
    try expectPatch("{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"/a\"}]", "{}");
    try expectPatch("[1,2,3]", "[{\"op\":\"remove\",\"path\":\"/1\"}]", "[1,3]");
    try expectPatch("[1]", "[{\"op\":\"remove\",\"path\":\"/0\"}]", "[]");
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"remove\",\"path\":\"/a\"}]");
    try expectFailure(error.IndexOutOfBounds, "[1]", "[{\"op\":\"remove\",\"path\":\"/1\"}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"remove\",\"path\":\"/-\"}]");
}

test "the root can be removed only if it is put back" {
    try expectFailure(error.RootRemoved, "{\"a\":1}", "[{\"op\":\"remove\",\"path\":\"\"}]");
    try expectFailure(error.PathNotFound, "{\"a\":1}",
        \\[{"op":"remove","path":""},{"op":"add","path":"/a","value":1}]
    );
    try expectFailure(error.PathNotFound, "{\"a\":1}",
        \\[{"op":"remove","path":""},{"op":"test","path":"","value":1}]
    );
    try expectFailure(error.PathNotFound, "{\"a\":1}",
        \\[{"op":"remove","path":""},{"op":"remove","path":""}]
    );
    try expectPatch("{\"a\":1}",
        \\[{"op":"remove","path":""},{"op":"add","path":"","value":[]}]
    , "[]");
}

test "replace" {
    try expectPatch("{\"a\":1}", "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":[2]}]", "{\"a\":[2]}");
    try expectPatch("[1,2]", "[{\"op\":\"replace\",\"path\":\"/0\",\"value\":3}]", "[3,2]");
    try expectPatch("1", "[{\"op\":\"replace\",\"path\":\"\",\"value\":2}]", "2");
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"replace\",\"path\":\"/a\",\"value\":1}]");
    try expectFailure(error.IndexOutOfBounds, "[1]", "[{\"op\":\"replace\",\"path\":\"/1\",\"value\":1}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"replace\",\"path\":\"/-\",\"value\":1}]");
}

test "move" {
    try expectPatch("{\"a\":1}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b\"}]", "{\"b\":1}");
    try expectPatch("{\"a\":1,\"b\":2}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a\"}]", "{\"a\":1,\"b\":2}");
    try expectPatch("[1,2,3]", "[{\"op\":\"move\",\"from\":\"/0\",\"path\":\"/2\"}]", "[2,3,1]");
    try expectPatch("[1,2,3]", "[{\"op\":\"move\",\"from\":\"/2\",\"path\":\"/0\"}]", "[3,1,2]");
    try expectPatch("{\"a\":{\"b\":1}}", "[{\"op\":\"move\",\"from\":\"/a/b\",\"path\":\"/a\"}]", "{\"a\":1}");
    try expectPatch("{\"a\":{\"b\":1}}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"\"}]", "{\"b\":1}");
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/b\"}]");
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"move\",\"from\":\"/a\",\"path\":\"/a\"}]");
    // The element is gone by the time the destination is checked.
    try expectFailure(error.IndexOutOfBounds, "[1,2,3]", "[{\"op\":\"move\",\"from\":\"/0\",\"path\":\"/3\"}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"move\",\"from\":\"/-\",\"path\":\"/0\"}]");
}

test "copy" {
    try expectPatch("{\"a\":[1]}", "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"}]", "{\"a\":[1],\"b\":[1]}");
    try expectPatch("[1,2]", "[{\"op\":\"copy\",\"from\":\"/0\",\"path\":\"/-\"}]", "[1,2,1]");
    try expectPatch("{\"a\":1}", "[{\"op\":\"copy\",\"from\":\"\",\"path\":\"/b\"}]", "{\"a\":1,\"b\":{\"a\":1}}");
    try expectFailure(error.PathNotFound, "{}", "[{\"op\":\"copy\",\"from\":\"/a\",\"path\":\"/b\"}]");
    try expectFailure(error.InvalidArrayIndex, "[1]", "[{\"op\":\"copy\",\"from\":\"/-\",\"path\":\"/0\"}]");
}

test "a copy is independent of its source" {
    try expectPatch("{\"a\":{\"x\":1}}",
        \\[{"op":"copy","from":"/a","path":"/b"},
        \\ {"op":"add","path":"/a/y","value":2},
        \\ {"op":"copy","from":"/a","path":"/c"},
        \\ {"op":"add","path":"/c/z","value":3},
        \\ {"op":"remove","path":"/a/x"}]
    ,
        \\{"a":{"y":2},"b":{"x":1},"c":{"x":1,"y":2,"z":3}}
    );
}

test sameTokens {
    try testing.expect(sameTokens("[1,{\"a\":\"b c\"}]", " [ 1 , { \"a\" : \"b c\" } ]\n"));
    try testing.expect(!sameTokens("\"a b\"", "\"ab\""));
    try testing.expect(!sameTokens("[1]", "[1,2]"));
    try testing.expect(!sameTokens("[1,2]", "[1]"));
    try testing.expect(!sameTokens("12", "13"));
    // Equal values can differ, which is for `eql` to determine.
    try testing.expect(!sameTokens("1.0", "1"));
}

test "test compares values by RFC 6902 rules" {
    const passing = [_][2][]const u8{
        .{ "1", "1.0" },
        .{ "100", "1e2" },
        .{ "\"a\"", "\"\\u0061\"" },
        .{ "[1,[2]]", "[1.0,[2e0]]" },
        .{ "{\"a\":1,\"b\":2}", "{\"b\":2.0,\"a\":1}" },
        .{ "{\"\\u0061\":1}", "{\"a\":1}" },
        .{ "[]", "[ ]" },
        .{ "{}", "{ }" },
        .{ "null", "null" },
        .{ "true", "true" },
        .{ "{\"a\":1,\"a\":2}", "{\"a\":2}" },
    };
    for (passing) |case| {
        const gpa = testing.allocator;
        const patch = try std.fmt.allocPrint(gpa, "[{{\"op\":\"test\",\"path\":\"\",\"value\":{s}}}]", .{case[1]});
        defer gpa.free(patch);
        try expectPatch(case[0], patch, case[0]);
    }
    const failing = [_][2][]const u8{
        .{ "1", "2" },
        .{ "1", "\"1\"" },
        .{ "null", "false" },
        .{ "true", "false" },
        .{ "true", "1" },
        .{ "\"a\"", "\"b\"" },
        .{ "\"a\"", "1" },
        .{ "[1,2]", "[2,1]" },
        .{ "[1]", "[1,2]" },
        .{ "[]", "{}" },
        .{ "{}", "[]" },
        .{ "{\"a\":1}", "{\"a\":2}" },
        .{ "{\"a\":1}", "{\"b\":1}" },
        .{ "{\"a\":1}", "{\"a\":1,\"b\":2}" },
        .{ "{\"a\":1,\"b\":2}", "{\"a\":1}" },
        .{ "{\"A\":1}", "{\"a\":1}" },
        .{ "9007199254740992", "9007199254740993" },
    };
    for (failing) |case| {
        const gpa = testing.allocator;
        const patch = try std.fmt.allocPrint(gpa, "[{{\"op\":\"test\",\"path\":\"\",\"value\":{s}}}]", .{case[1]});
        defer gpa.free(patch);
        try expectFailure(error.TestFailed, case[0], patch);
    }
}

test "test sees changes made by earlier operations" {
    try expectPatch("{\"a\":[1]}",
        \\[{"op":"add","path":"/a/-","value":2},
        \\ {"op":"test","path":"/a","value":[1,2]},
        \\ {"op":"test","path":"","value":{"a":[1.0,2.0]}}]
    ,
        \\{"a":[1,2]}
    );
}

test "later operations reach into values added by earlier ones" {
    try expectPatch("{}",
        \\[{"op":"add","path":"/a","value":{"b":[1]}},
        \\ {"op":"add","path":"/a/b/-","value":{"c":null}},
        \\ {"op":"replace","path":"/a/b/1/c","value":true},
        \\ {"op":"move","from":"/a/b/1","path":"/d"}]
    ,
        \\{"a":{"b":[1]},"d":{"c":true}}
    );
}

test "a failed patch is undone completely" {
    const document =
        \\{"a":{"b":[1,2,3]},"c":"d","e":[{"f":1}]}
    ;
    try expectFailure(error.PathNotFound, document,
        \\[{"op":"add","path":"/x","value":1},
        \\ {"op":"remove","path":"/c"},
        \\ {"op":"replace","path":"/a/b/1","value":{"new":true}},
        \\ {"op":"add","path":"/a/b/0","value":0},
        \\ {"op":"remove","path":"/a/b/1"},
        \\ {"op":"move","from":"/e/0","path":"/a/z"},
        \\ {"op":"copy","from":"/a","path":"/y"},
        \\ {"op":"replace","path":"","value":{"c":[]}},
        \\ {"op":"add","path":"/c/-","value":1},
        \\ {"op":"test","path":"/nope","value":1}]
    );
}

test "patches can fail and be retried on the same document" {
    const gpa = testing.allocator;
    var doc = try parse(gpa, "{\"n\":0,\"list\":[]}", .{});
    defer doc.deinit();

    var good = try Patch.parse(gpa,
        \\[{"op":"replace","path":"/n","value":1},{"op":"add","path":"/list/-","value":"x"}]
    , .{});
    defer good.deinit();
    var bad = try Patch.parse(gpa,
        \\[{"op":"replace","path":"/n","value":2},{"op":"remove","path":"/list/5"}]
    , .{});
    defer bad.deinit();

    var diagnostics: Diagnostics = .{};
    try doc.apply(&good, .{});
    try testing.expectError(error.IndexOutOfBounds, doc.apply(&bad, .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(1, diagnostics.operation);
    try testing.expectFmt("{\"n\":1,\"list\":[\"x\"]}", "{f}", .{&doc});
    try doc.apply(&good, .{});
    try testing.expectFmt("{\"n\":1,\"list\":[\"x\",\"x\"]}", "{f}", .{&doc});
}

test "large objects behave the same once they are indexed" {
    const gpa = testing.allocator;
    var text: Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.writeByte('{');
    for (0..500) |i| {
        if (i != 0) try text.writer.writeByte(',');
        try text.writer.print("\"key{d}\":{d}", .{ i, i });
    }
    try text.writer.writeByte('}');

    var doc = try parse(gpa, text.written(), .{});
    defer doc.deinit();

    // Enough lookups to trigger the hash table, then every kind of change.
    var patch: Patch = .init(gpa);
    defer patch.deinit();
    var name: [32]u8 = undefined;
    for (0..50) |i| try patch.testValue(try std.fmt.bufPrint(&name, "/key{d}", .{i}), i);
    try patch.remove("/key10");
    try patch.add("/key10", "back");
    try patch.add("/new", 1);
    try patch.remove("/key499");
    try patch.move("/key0", "/moved");
    for (0..400) |i| try patch.add(try std.fmt.bufPrint(&name, "/more{d}", .{i}), i);
    try doc.apply(&patch, .{});

    try testing.expectEqualStrings("\"back\"", (try doc.get("/key10")).?);
    try testing.expectEqualStrings("1", (try doc.get("/new")).?);
    try testing.expectEqualStrings("0", (try doc.get("/moved")).?);
    try testing.expectEqualStrings("399", (try doc.get("/more399")).?);
    try testing.expectEqual(null, try doc.get("/key499"));
    try testing.expectEqual(null, try doc.get("/key0"));

    var bad: Patch = .init(gpa);
    defer bad.deinit();
    try bad.remove("/key20");
    try bad.add("/key20", 7);
    try bad.remove("/more1");
    try bad.add("/extra", 7);
    try bad.remove("/absent");
    try testing.expectError(error.PathNotFound, doc.apply(&bad, .{}));
    try testing.expectEqualStrings("20", (try doc.get("/key20")).?);
    try testing.expectEqualStrings("1", (try doc.get("/more1")).?);
    try testing.expectEqual(null, try doc.get("/extra"));
}

test "duplicate keys: the last one wins and all of them are removed" {
    const document =
        \\{"a":1,"b":2,"a":3}
    ;
    try expectPatch(document,
        \\[{"op":"test","path":"/a","value":3}]
    , document);
    try expectPatch(document,
        \\[{"op":"replace","path":"/a","value":4}]
    ,
        \\{"a":1,"b":2,"a":4}
    );
    try expectPatch(document,
        \\[{"op":"remove","path":"/a"}]
    ,
        \\{"b":2}
    );
    try expectFailure(error.PathNotFound, document,
        \\[{"op":"remove","path":"/a"},{"op":"test","path":"/a","value":1}]
    );
}

test get {
    const gpa = testing.allocator;
    var doc = try parse(gpa, "{\"a\": {\"b\": [10, 20]}, \"c\": \"text\"}", .{});
    defer doc.deinit();

    try testing.expectEqualStrings("20", (try doc.get("/a/b/1")).?);
    try testing.expectEqualStrings("\"text\"", (try doc.get("/c")).?);
    try testing.expectEqualStrings("{\"b\": [10, 20]}", (try doc.get("/a")).?);
    try testing.expectEqual(null, try doc.get("/missing"));
    try testing.expectEqual(null, try doc.get("/a/b/2"));
    try testing.expectEqual(null, try doc.get("/a/b/x"));
    try testing.expectError(error.InvalidPointer, doc.get("no slash"));

    var patch: Patch = .init(gpa);
    defer patch.deinit();
    try patch.add("/a/b/-", 30);
    try doc.apply(&patch, .{});
    try testing.expectEqualStrings("{\"b\":[10, 20,30]}", (try doc.get("/a")).?);
}

test compact {
    const gpa = testing.allocator;
    var doc = try parse(gpa, "{\"a\":1}", .{});
    defer doc.deinit();
    var patch: Patch = .init(gpa);
    defer patch.deinit();
    try patch.add("/b", .{ .c = true });
    try patch.remove("/a");
    try doc.apply(&patch, .{});

    try doc.compact();
    try testing.expectFmt("{\"b\":{\"c\":true}}", "{f}", .{&doc});
    try testing.expectEqualStrings("true", (try doc.get("/b/c")).?);
}

test "a compacted document keeps working" {
    const gpa = testing.allocator;
    var text: Writer.Allocating = .init(gpa);
    defer text.deinit();
    try text.writer.writeAll("{\"gone\":[");
    for (0..1000) |i| try text.writer.print("[{d}],", .{i});
    try text.writer.writeAll("0],\"kept\":[[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]]}");

    var doc = try parse(gpa, text.written(), .{});
    defer doc.deinit();
    var remove: Patch = .init(gpa);
    defer remove.deinit();
    try remove.remove("/gone");
    try doc.apply(&remove, .{});
    try doc.compact();

    // Both of these were in memory that compacting freed, and an index that was
    // left over would describe different text.
    try testing.expectEqual(0, doc.undo.capacity);
    try testing.expectEqual(0, doc.index.entries.capacity);

    var add: Patch = .init(gpa);
    defer add.deinit();
    try add.add("/kept/0/-", 21);
    try doc.apply(&add, .{});
    try testing.expectEqualStrings("21", (try doc.get("/kept/0/20")).?);
}

test "ownership options" {
    const gpa = testing.allocator;
    const source = try gpa.dupe(u8, "  {\"a\":[1,2]}\n");
    defer gpa.free(source);

    var doc = try parse(gpa, source, .{ .source = .borrow, .validation = .none });
    defer doc.deinit();
    var patch = try Patch.parse(gpa,
        \\[{"op":"add","path":"/a/-","value":{"b":3}}]
    , .{ .source = .borrow });
    defer patch.deinit();
    try doc.apply(&patch, .{ .values = .borrow });
    try testing.expectFmt("{\"a\":[1,2,{\"b\":3}]}", "{f}", .{&doc});
}

test "parse failures carry an offset" {
    var diagnostics: Diagnostics = .{};
    try testing.expectError(error.SyntaxError, parse(testing.allocator, "{\"a\": tru}", .{ .diagnostics = &diagnostics }));
    try testing.expectEqual(6, diagnostics.offset);
}

test "invalid text that skipped validation fails safely" {
    const gpa = testing.allocator;
    const garbage = [_][]const u8{
        "{",    "[",    "{\"a\"", "{\"a\":", "[1",   "[1 2]", "{\"a\":1",                                     "{1:2}",
        "{\"a", "[\"a", "\"",     "1e!",     "-",    "1e",    "tru",                                          "]",
        "}",    ",",    ":",      "\"abc",   "1.e!", "-e-!",
        // A value that is empty, followed by enough for a whole chunk to be read.
         "[,1]                                        ", "{\"a\":,\"b\":1}                                ",
    };
    const patches = [_][]const u8{
        "[{\"op\":\"add\",\"path\":\"/a\",\"value\":1}]",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":\"x\"}]",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":1e5}]",
        "[{\"op\":\"test\",\"path\":\"\",\"value\":[1]}]",
        "[{\"op\":\"test\",\"path\":\"/0\",\"value\":1}]",
        "[{\"op\":\"test\",\"path\":\"/0/x\",\"value\":1}]",
        "[{\"op\":\"test\",\"path\":\"/a/x\",\"value\":1}]",
    };
    for (patches) |source| {
        var patch = try Patch.parse(gpa, source, .{});
        defer patch.deinit();
        for (garbage) |text| {
            var doc = try parse(gpa, text, .{ .validation = .none });
            defer doc.deinit();
            doc.apply(&patch, .{}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => {},
            };
        }
    }
}

test "a child that does not end inside its parent is an error, not a bad slice" {
    // Whoever scans `1",{"` from the start of the array sees a string in it, and
    // whoever steps through its elements sees a number, a comma, and an object.
    // That object closes at the bracket after the end of the inner array.
    const gpa = testing.allocator;
    var doc = try parse(gpa, "[[1\",{\"],\"]\"]", .{ .validation = .none });
    defer doc.deinit();
    var patch = try Patch.parse(gpa, "[{\"op\":\"test\",\"path\":\"/0/0\",\"value\":1}]", .{});
    defer patch.deinit();
    try testing.expectError(error.SyntaxError, doc.apply(&patch, .{}));
}

test "a key that does not end inside its object is an error, not a bad slice" {
    // Whoever scans `1",` from the start of the object sees a string in it, and
    // whoever steps through its members sees a number, a comma, and the start of
    // a key, which closes at the quote after the end of the object.
    const gpa = testing.allocator;
    var doc = try parse(gpa, "[{\"a\":1\",\":2},\"b\"]", .{ .validation = .none });
    defer doc.deinit();
    var patch = try Patch.parse(gpa, "[{\"op\":\"test\",\"path\":\"/0/x\",\"value\":1}]", .{});
    defer patch.deinit();
    try testing.expectError(error.SyntaxError, doc.apply(&patch, .{}));
}

test "text with nothing in it cannot skip validation" {
    try testing.expectError(error.SyntaxError, parse(testing.allocator, "", .{ .validation = .none }));
    try testing.expectError(error.SyntaxError, parse(testing.allocator, " \n", .{ .validation = .none }));
}

test "deep nesting built up by patches cannot overflow the stack" {
    const gpa = testing.allocator;
    const levels = 2000;
    var chain: Writer.Allocating = .init(gpa);
    defer chain.deinit();
    var bottom: Writer.Allocating = .init(gpa);
    defer bottom.deinit();
    try bottom.writer.writeAll("/b");
    for (0..levels) |_| {
        try chain.writer.writeAll("{\"a\":");
        try bottom.writer.writeAll("/a");
    }
    try chain.writer.writeAll("{}");
    try chain.writer.splatByteAll('}', levels);

    var doc = try parse(gpa, "{\"a\":{}}", .{});
    defer doc.deinit();
    var patch: Patch = .init(gpa);
    defer patch.deinit();

    // Each round expands a fresh chain and hangs the document off the bottom
    // of it, so the expanded tree ends up 200,000 levels deep.
    for (0..100) |_| {
        try patch.add("/b", Patch.Raw{ .json = chain.written() });
        try patch.move("/a", bottom.written());
        try patch.move("/b", "/a");
    }
    try doc.apply(&patch, .{});

    const text = try doc.toOwnedSlice(gpa);
    defer gpa.free(text);
    try testing.expect(text.len > 100 * (chain.written().len - 2));
}
