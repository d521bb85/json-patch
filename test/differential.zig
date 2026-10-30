//! Randomized testing against a reference model.
//!
//! `Model` below is a naive implementation of RFC 6902 on top of `std.json.Value`
//! that copies the whole document for every patch. It shares no code with the
//! library, so a disagreement between the two points to a bug in one of them.
//! Each round applies a stream of random patches to one long-lived document,
//! which exercises expansion, rollback, and hash tables across patches.

const std = @import("std");
const json_patch = @import("json_patch");

const Allocator = std.mem.Allocator;
const Document = json_patch.Document;
const Patch = json_patch.Patch;
const Random = std.Random;
const Value = std.json.Value;
const gpa = std.testing.allocator;

const keys = [_][]const u8{
    "a",    "b",           "c",  "0",               "1", "-", "", "~", "/", "a/b", "m~n",
    "é",
    "q\"t", "back\\slash", "01", "key with spaces",
    "😀",
};

const Model = struct {
    arena: Allocator,
    root: ?Value,

    const Error = error{ Failed, OutOfMemory };

    fn deepCopy(a: Allocator, value: Value) Allocator.Error!Value {
        switch (value) {
            .array => |array| {
                var copy: std.json.Array = .init(a);
                for (array.items) |item| try copy.append(try deepCopy(a, item));
                return .{ .array = copy };
            },
            .object => |object| {
                var copy: std.json.ObjectMap = .empty;
                var it = object.iterator();
                while (it.next()) |entry| {
                    try copy.put(a, entry.key_ptr.*, try deepCopy(a, entry.value_ptr.*));
                }
                return .{ .object = copy };
            },
            else => return value,
        }
    }

    fn arrayIndex(token: []const u8) ?usize {
        if (token.len == 0 or (token.len > 1 and token[0] == '0')) return null;
        for (token) |c| if (c < '0' or c > '9') return null;
        return std.fmt.parseInt(usize, token, 10) catch null;
    }

    fn resolve(model: *Model, tokens: []const []const u8) Error!*Value {
        if (model.root == null) return error.Failed;
        var node = &model.root.?;
        for (tokens) |token| switch (node.*) {
            .object => |*object| node = object.getPtr(token) orelse return error.Failed,
            .array => |*array| {
                const index = arrayIndex(token) orelse return error.Failed;
                if (index >= array.items.len) return error.Failed;
                node = &array.items[index];
            },
            else => return error.Failed,
        };
        return node;
    }

    fn add(model: *Model, tokens: []const []const u8, value: Value) Error!void {
        if (tokens.len == 0) {
            model.root = value;
            return;
        }
        const parent = try model.resolve(tokens[0 .. tokens.len - 1]);
        const token = tokens[tokens.len - 1];
        switch (parent.*) {
            .object => |*object| try object.put(model.arena, token, value),
            .array => |*array| {
                const index = if (std.mem.eql(u8, token, "-"))
                    array.items.len
                else
                    arrayIndex(token) orelse return error.Failed;
                if (index > array.items.len) return error.Failed;
                try array.insert(index, value);
            },
            else => return error.Failed,
        }
    }

    fn remove(model: *Model, tokens: []const []const u8) Error!Value {
        const target = try model.resolve(tokens);
        const value = target.*;
        if (tokens.len == 0) {
            model.root = null;
            return value;
        }
        const parent = try model.resolve(tokens[0 .. tokens.len - 1]);
        const token = tokens[tokens.len - 1];
        switch (parent.*) {
            .object => |*object| _ = object.orderedRemove(token),
            .array => |*array| _ = array.orderedRemove(arrayIndex(token).?),
            else => unreachable,
        }
        return value;
    }

    fn apply(model: *Model, operation: Op) Error!void {
        switch (operation) {
            .add => |o| try model.add(o.path, try deepCopy(model.arena, o.value)),
            .remove => |o| _ = try model.remove(o.path),
            .replace => |o| (try model.resolve(o.path)).* = try deepCopy(model.arena, o.value),
            .@"test" => |o| {
                if (!jsonEql(try model.resolve(o.path), &o.value)) return error.Failed;
            },
            .copy => |o| try model.add(o.path, try deepCopy(model.arena, (try model.resolve(o.from)).*)),
            .move => |o| {
                if (isPrefix(o.from, o.path)) return error.Failed;
                if (tokensEql(o.from, o.path)) {
                    _ = try model.resolve(o.from);
                    return;
                }
                try model.add(o.path, try model.remove(o.from));
            },
        }
    }
};

fn tokensEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn isPrefix(ancestor: []const []const u8, path: []const []const u8) bool {
    return ancestor.len < path.len and tokensEql(ancestor, path[0..ancestor.len]);
}

fn jsonEql(x: *const Value, y: *const Value) bool {
    if (asFloat(x.*)) |p| return if (asFloat(y.*)) |q| p == q else false;
    if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*)) return false;
    return switch (x.*) {
        .null => true,
        .bool => |b| b == y.bool,
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |array| {
            if (array.items.len != y.array.items.len) return false;
            for (array.items, y.array.items) |*p, *q| {
                if (!jsonEql(p, q)) return false;
            }
            return true;
        },
        .object => |object| {
            if (object.count() != y.object.count()) return false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const other = y.object.getPtr(entry.key_ptr.*) orelse return false;
                if (!jsonEql(entry.value_ptr, other)) return false;
            }
            return true;
        },
        .integer, .float, .number_string => unreachable,
    };
}

fn asFloat(value: Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

const Op = union(enum) {
    add: WithValue,
    remove: struct { path: []const []const u8 },
    replace: WithValue,
    move: Transfer,
    copy: Transfer,
    @"test": WithValue,

    const WithValue = struct { path: []const []const u8, value: Value };
    const Transfer = struct { from: []const []const u8, path: []const []const u8 };
};

const Generator = struct {
    a: Allocator,
    random: Random,

    fn value(g: *Generator, depth: usize) Allocator.Error!Value {
        const roll = g.random.uintLessThan(u8, if (depth == 0) 6 else 10);
        switch (roll) {
            0 => return .null,
            1 => return .{ .bool = g.random.boolean() },
            2, 3 => return .{ .integer = g.random.intRangeAtMost(i64, -3, 20) },
            4 => return .{ .float = @as(f64, @floatFromInt(g.random.intRangeAtMost(i32, -8, 8))) / 4 },
            5 => return .{ .string = keys[g.random.uintLessThan(usize, keys.len)] },
            6, 7 => {
                var array: std.json.Array = .init(g.a);
                for (0..g.random.uintLessThan(usize, 6)) |_| try array.append(try g.value(depth - 1));
                return .{ .array = array };
            },
            else => {
                var object: std.json.ObjectMap = .empty;
                for (0..g.random.uintLessThan(usize, 6)) |_| {
                    try object.put(g.a, keys[g.random.uintLessThan(usize, keys.len)], try g.value(depth - 1));
                }
                return .{ .object = object };
            },
        }
    }

    /// Writes `value` as JSON in a randomly chosen but equivalent spelling.
    fn write(g: *Generator, out: *std.Io.Writer, value_: Value) !void {
        switch (value_) {
            .null => try out.writeAll("null"),
            .bool => |b| try out.writeAll(if (b) "true" else "false"),
            .integer => |i| switch (g.random.uintLessThan(u8, 4)) {
                0 => try out.print("{d}.0", .{i}),
                1 => try out.print("{d}e0", .{i}),
                2 => if (i != 0) try out.print("{d}0E-1", .{i}) else try out.writeAll("-0"),
                else => try out.print("{d}", .{i}),
            },
            .float => |f| try out.print("{d}", .{f}),
            .string => |s| try g.writeString(out, s),
            .array => |array| {
                try g.space(out);
                try out.writeByte('[');
                for (array.items, 0..) |item, i| {
                    if (i != 0) try out.writeByte(',');
                    try g.space(out);
                    try g.write(out, item);
                    try g.space(out);
                }
                try out.writeByte(']');
            },
            .object => |object| {
                try out.writeByte('{');
                var it = object.iterator();
                var i: usize = 0;
                while (it.next()) |entry| : (i += 1) {
                    if (i != 0) try out.writeByte(',');
                    try g.space(out);
                    try g.writeString(out, entry.key_ptr.*);
                    try g.space(out);
                    try out.writeByte(':');
                    try g.space(out);
                    try g.write(out, entry.value_ptr.*);
                }
                try g.space(out);
                try out.writeByte('}');
            },
            .number_string => unreachable,
        }
    }

    fn space(g: *Generator, out: *std.Io.Writer) !void {
        if (g.random.uintLessThan(u8, 4) == 0) {
            try out.writeAll((&[_][]const u8{ " ", "\n", "\t ", "\r\n" })[g.random.uintLessThan(usize, 4)]);
        }
    }

    fn writeString(g: *Generator, out: *std.Io.Writer, text: []const u8) !void {
        try out.writeByte('"');
        for (text) |c| {
            if (c == '"' or c == '\\') {
                try out.print("\\{c}", .{c});
            } else if (c < 0x80 and g.random.uintLessThan(u8, 8) == 0) {
                try out.print("\\u{x:0>4}", .{c});
            } else {
                try out.writeByte(c);
            }
        }
        try out.writeByte('"');
    }

    /// Walks a random way into `root`, usually producing a path that exists.
    fn path(g: *Generator, root: ?*const Value) Allocator.Error![]const []const u8 {
        var tokens: std.ArrayList([]const u8) = .empty;
        var node = root;
        while (node != null and g.random.uintLessThan(u8, 5) != 0) {
            switch (node.?.*) {
                .object => |object| {
                    if (object.count() == 0) break;
                    const i = g.random.uintLessThan(usize, object.count());
                    try tokens.append(g.a, object.keys()[i]);
                    node = &object.values()[i];
                },
                .array => |array| {
                    if (array.items.len == 0) break;
                    const i = g.random.uintLessThan(usize, array.items.len);
                    try tokens.append(g.a, try std.fmt.allocPrint(g.a, "{d}", .{i}));
                    node = &array.items[i];
                },
                else => break,
            }
        }
        switch (g.random.uintLessThan(u8, 6)) {
            0 => try tokens.append(g.a, keys[g.random.uintLessThan(usize, keys.len)]),
            1 => try tokens.append(g.a, "-"),
            2 => try tokens.append(g.a, try std.fmt.allocPrint(g.a, "{d}", .{g.random.uintLessThan(usize, 8)})),
            else => {},
        }
        return tokens.items;
    }

    fn operation(g: *Generator, root: ?*const Value) Allocator.Error!Op {
        const path_ = try g.path(root);
        return switch (g.random.uintLessThan(u8, 6)) {
            0 => .{ .add = .{ .path = path_, .value = try g.value(2) } },
            1 => .{ .remove = .{ .path = path_ } },
            2 => .{ .replace = .{ .path = path_, .value = try g.value(2) } },
            3 => .{ .move = .{ .from = try g.path(root), .path = path_ } },
            4 => .{ .copy = .{ .from = try g.path(root), .path = path_ } },
            else => test_op: {
                // Half of the tests look at the value that is really there.
                const existing: ?Value = if (root != null and g.random.boolean()) blk: {
                    var model: Model = .{ .arena = g.a, .root = root.?.* };
                    const found = model.resolve(path_) catch break :blk null;
                    break :blk try Model.deepCopy(g.a, found.*);
                } else null;
                break :test_op .{ .@"test" = .{
                    .path = path_,
                    .value = existing orelse try g.value(2),
                } };
            },
        };
    }

    fn writePointer(_: *Generator, out: *std.Io.Writer, tokens: []const []const u8) !void {
        for (tokens) |token| {
            try out.writeByte('/');
            for (token) |c| switch (c) {
                '~' => try out.writeAll("~0"),
                '/' => try out.writeAll("~1"),
                else => try out.writeByte(c),
            };
        }
    }

    fn writeMember(g: *Generator, out: *std.Io.Writer, name: []const u8, tokens: []const []const u8) !void {
        var pointer: std.Io.Writer.Allocating = .init(g.a);
        try g.writePointer(&pointer.writer, tokens);
        try out.print("\"{s}\":", .{name});
        try g.writeString(out, pointer.written());
    }

    fn writeOperation(g: *Generator, out: *std.Io.Writer, op: Op) !void {
        try out.print("{{\"op\":\"{t}\",", .{op});
        switch (op) {
            .remove => |o| try g.writeMember(out, "path", o.path),
            .add, .replace, .@"test" => |o| {
                try g.writeMember(out, "path", o.path);
                try out.writeAll(",\"value\":");
                try g.write(out, o.value);
            },
            .move, .copy => |o| {
                try g.writeMember(out, "from", o.from);
                try out.writeByte(',');
                try g.writeMember(out, "path", o.path);
            },
        }
        try out.writeByte('}');
    }
};

fn expectMatches(a: Allocator, doc: *const Document, model: *const Model) !void {
    const text = try doc.toOwnedSlice(a);
    const parsed = try std.json.parseFromSliceLeaky(Value, a, text, .{ .duplicate_field_behavior = .use_last });
    if (!jsonEql(&parsed, &model.root.?)) {
        var out: std.Io.Writer.Allocating = .init(a);
        try std.json.Stringify.value(model.root.?, .{}, &out.writer);
        std.debug.print("\nexpected: {s}\n  actual: {s}\n", .{ out.written(), text });
        return error.TestExpectedEqual;
    }
}

fn runRound(seed: u64, patches: usize) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    // Everything from the model lives here until the end of the round.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var g: Generator = .{ .a = a, .random = random };

    const initial = while (true) {
        const value = try g.value(4);
        if (value == .object or value == .array) break value;
    };
    var text: std.Io.Writer.Allocating = .init(a);
    try g.write(&text.writer, initial);

    var doc: Document = try .parse(gpa, text.written(), .{});
    defer doc.deinit();
    var model: Model = .{ .arena = a, .root = initial };

    for (0..patches) |_| {
        var trial: Model = .{ .arena = a, .root = try Model.deepCopy(a, model.root.?) };

        var ops: std.ArrayList(Op) = .empty;
        const count = random.intRangeAtMost(usize, 1, 6);
        for (0..count) |_| {
            const op = try g.operation(if (trial.root) |*r| r else null);
            const before = if (trial.root) |r| try Model.deepCopy(a, r) else null;
            // Later operations should build on earlier ones. Most operations
            // that would fail are dropped, so that plenty of patches succeed.
            trial.apply(op) catch {
                trial.root = before;
                if (random.uintLessThan(u8, 8) != 0) continue;
            };
            try ops.append(a, op);
        }

        trial = .{ .arena = a, .root = try Model.deepCopy(a, model.root.?) };
        var ok = true;
        for (ops.items) |op| {
            trial.apply(op) catch {
                ok = false;
                break;
            };
        }
        if (trial.root == null) ok = false;

        var patch_text: std.Io.Writer.Allocating = .init(a);
        try patch_text.writer.writeByte('[');
        for (ops.items, 0..) |op, i| {
            if (i != 0) try patch_text.writer.writeByte(',');
            try g.writeOperation(&patch_text.writer, op);
        }
        try patch_text.writer.writeByte(']');

        var patch = Patch.parse(gpa, patch_text.written(), .{}) catch |err| switch (err) {
            // The model reports this when it reaches the operation, and an
            // earlier operation may have failed first. Both mean failure.
            error.MoveIntoDescendant => {
                try std.testing.expect(!ok);
                continue;
            },
            else => return err,
        };
        defer patch.deinit();

        if (doc.apply(&patch, .{})) |_| {
            if (!ok) {
                std.debug.print("\nunexpected success: {s}\n", .{patch_text.written()});
                return error.TestUnexpectedResult;
            }
            model = trial;
        } else |err| switch (err) {
            error.OutOfMemory, error.SyntaxError => return err,
            else => if (ok) {
                std.debug.print("\nunexpected {s}: {s}\n", .{ @errorName(err), patch_text.written() });
                return err;
            },
        }
        expectMatches(a, &doc, &model) catch |err| {
            std.debug.print("after patch: {s}\n", .{patch_text.written()});
            return err;
        };
    }
}

test "random patches agree with the reference model" {
    var seed: u64 = 1;
    while (seed <= 3000) : (seed += 1) {
        runRound(seed, 12) catch |err| {
            std.debug.print("\nfailing seed: {d}\n", .{seed});
            return err;
        };
    }
}

test "a document survives a long stream of patches" {
    var seed: u64 = 1_000_000;
    while (seed < 1_000_020) : (seed += 1) {
        runRound(seed, 300) catch |err| {
            std.debug.print("\nfailing seed: {d}\n", .{seed});
            return err;
        };
    }
}

test "arbitrary input never misbehaves" {
    try std.testing.fuzz({}, fuzzOne, .{});
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var buffer: [512]u8 = undefined;
    const length = @min(smith.value(u16), buffer.len);
    smith.bytes(buffer[0..length]);
    const split = @min(smith.value(u16), length);
    const document = buffer[0..split];
    const patch = buffer[split..length];

    // Parsing arbitrary bytes must fail cleanly, and if a patch does parse, it
    // must apply cleanly to anything at all, including text never validated.
    var parsed = Patch.parse(gpa, patch, .{}) catch return;
    defer parsed.deinit();
    for ([_]@FieldType(Document.ParseOptions, "validation"){ .full, .none }) |validation| {
        var doc = Document.parse(gpa, document, .{ .validation = validation }) catch continue;
        defer doc.deinit();
        doc.apply(&parsed, .{}) catch {};
        const text = try doc.toOwnedSlice(gpa);
        gpa.free(text);
    }
}

test "structured patches never misbehave, even on invalid documents" {
    try std.testing.fuzz({}, fuzzStructured, .{});
}

const fuzz_tokens = [_][]const u8{ "a", "b", "c", "0", "1", "2", "-", "", "~0", "~1", "01", "99" };
const fuzz_values = [_][]const u8{
    "null",                             "true",              "0", "-1.5e3", "\"s\"", "\"\\u0061\"", "[]", "{}", "[1,[2,{\"a\":3}]]",
    "{\"a\":{\"b\":[1,2]},\"c\":null}", "{\"a\":1,\"a\":2}",
};
const fuzz_documents = [_][]const u8{
    "{}",
    "[]",
    "1",
    "{\"a\":{\"b\":[1,2,{\"c\":3}]},\"b\":[[],{}],\"c\":\"x\"}",
    "[{\"a\":1},[2,3],\"b\",null]",
    "{ \"a\" : [ 1 , 2 ] ,\n \"\\u0062\" : { \"c\" : true } }",
    "{\"a\":1,\"b\":2,\"a\":3}",
};

fn fuzzPointer(smith: *std.testing.Smith, buffer: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    for (0..smith.value(u2)) |_| {
        writer.writeByte('/') catch unreachable;
        writer.writeAll(fuzz_tokens[smith.value(u8) % fuzz_tokens.len]) catch unreachable;
    }
    return writer.buffered();
}

fn fuzzStructured(_: void, smith: *std.testing.Smith) !void {
    var patch: Patch = .init(gpa);
    defer patch.deinit();
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    for (0..@as(usize, smith.value(u4)) + 1) |_| {
        const path = fuzzPointer(smith, &a);
        const value: Patch.Raw = .{ .json = fuzz_values[smith.value(u8) % fuzz_values.len] };
        switch (smith.value(enum { add, remove, replace, move, copy, @"test" })) {
            .add => try patch.add(path, value),
            .remove => try patch.remove(path),
            .replace => try patch.replace(path, value),
            .@"test" => try patch.testValue(path, value),
            .copy => try patch.copy(fuzzPointer(smith, &b), path),
            .move => patch.move(fuzzPointer(smith, &b), path) catch |err| switch (err) {
                error.MoveIntoDescendant => {},
                else => return err,
            },
        }
    }

    var garbage: [64]u8 = undefined;
    const use_garbage = smith.value(u3) == 0;
    const length = smith.value(u6);
    if (use_garbage) smith.bytes(garbage[0..length]);
    const document = if (use_garbage) garbage[0..length] else fuzz_documents[smith.value(u8) % fuzz_documents.len];

    var doc = Document.parse(gpa, document, .{ .validation = if (use_garbage) .none else .full }) catch return;
    defer doc.deinit();
    const before = try doc.toOwnedSlice(gpa);
    defer gpa.free(before);

    const applied = if (doc.apply(&patch, .{})) |_| true else |err| switch (err) {
        error.OutOfMemory => return err,
        else => false,
    };
    const after = try doc.toOwnedSlice(gpa);
    defer gpa.free(after);
    if (use_garbage) return;

    // Output must be valid JSON. A failed patch must leave the same value
    // behind, which `test` confirms at the level of JSON equality.
    var check: Document = try .parse(gpa, after, .{ .max_depth = 65535 });
    defer check.deinit();
    if (applied) return;
    var same: Patch = .init(gpa);
    defer same.deinit();
    try same.testValue("", Patch.Raw{ .json = before });
    try check.apply(&same, .{});
}
