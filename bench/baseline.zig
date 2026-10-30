//! RFC 6902 the conventional way, as a point of comparison: parse the whole
//! document into a tree with `std.json`, change the tree, and stringify all of
//! it. This is not a production implementation. It handles what the benchmark
//! inputs contain and does not attempt to be atomic.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub fn apply(gpa: Allocator, document: []const u8, patch: []const u8) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var root = try std.json.parseFromSliceLeaky(Value, a, document, .{});
    const operations = try std.json.parseFromSliceLeaky(Value, a, patch, .{});
    for (operations.array.items) |operation| try step(a, &root, operation.object);
    return std.json.Stringify.valueAlloc(gpa, root, .{});
}

fn step(a: Allocator, root: *Value, operation: std.json.ObjectMap) !void {
    const op = operation.get("op").?.string;
    const path = try tokens(a, operation.get("path").?.string);
    if (std.mem.eql(u8, op, "add")) {
        try add(a, root, path, try clone(a, operation.get("value").?));
    } else if (std.mem.eql(u8, op, "replace")) {
        (try resolve(root, path)).* = try clone(a, operation.get("value").?);
    } else if (std.mem.eql(u8, op, "remove")) {
        _ = try remove(root, path);
    } else if (std.mem.eql(u8, op, "test")) {
        if (!eql(try resolve(root, path), &operation.get("value").?)) return error.TestFailed;
    } else if (std.mem.eql(u8, op, "copy")) {
        const from = try tokens(a, operation.get("from").?.string);
        try add(a, root, path, try clone(a, (try resolve(root, from)).*));
    } else if (std.mem.eql(u8, op, "move")) {
        const from = try tokens(a, operation.get("from").?.string);
        try add(a, root, path, try remove(root, from));
    } else return error.UnknownOperation;
}

fn tokens(a: Allocator, pointer: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pointer, '/');
    _ = it.next();
    while (it.next()) |raw| {
        const once = try std.mem.replaceOwned(u8, a, raw, "~1", "/");
        try list.append(a, try std.mem.replaceOwned(u8, a, once, "~0", "~"));
    }
    return list.items;
}

fn resolve(root: *Value, path: []const []const u8) !*Value {
    var node = root;
    for (path) |token| switch (node.*) {
        .object => |*object| node = object.getPtr(token) orelse return error.PathNotFound,
        .array => |*array| {
            const index = try std.fmt.parseInt(usize, token, 10);
            if (index >= array.items.len) return error.PathNotFound;
            node = &array.items[index];
        },
        else => return error.PathNotFound,
    };
    return node;
}

fn add(a: Allocator, root: *Value, path: []const []const u8, value: Value) !void {
    const token = path[path.len - 1];
    const parent = try resolve(root, path[0 .. path.len - 1]);
    switch (parent.*) {
        .object => |*object| try object.put(a, token, value),
        .array => |*array| {
            const index = if (std.mem.eql(u8, token, "-"))
                array.items.len
            else
                try std.fmt.parseInt(usize, token, 10);
            try array.insert(index, value);
        },
        else => return error.PathNotFound,
    }
}

fn remove(root: *Value, path: []const []const u8) !Value {
    const value = (try resolve(root, path)).*;
    const token = path[path.len - 1];
    const parent = try resolve(root, path[0 .. path.len - 1]);
    switch (parent.*) {
        .object => |*object| _ = object.orderedRemove(token),
        .array => |*array| _ = array.orderedRemove(try std.fmt.parseInt(usize, token, 10)),
        else => return error.PathNotFound,
    }
    return value;
}

fn clone(a: Allocator, value: Value) Allocator.Error!Value {
    switch (value) {
        .array => |array| {
            var copy: std.json.Array = .init(a);
            for (array.items) |item| try copy.append(try clone(a, item));
            return .{ .array = copy };
        },
        .object => |object| {
            var copy: std.json.ObjectMap = .empty;
            var it = object.iterator();
            while (it.next()) |entry| try copy.put(a, entry.key_ptr.*, try clone(a, entry.value_ptr.*));
            return .{ .object = copy };
        },
        else => return value,
    }
}

fn eql(x: *const Value, y: *const Value) bool {
    if (asFloat(x.*)) |p| return if (asFloat(y.*)) |q| p == q else false;
    if (std.meta.activeTag(x.*) != std.meta.activeTag(y.*)) return false;
    return switch (x.*) {
        .null => true,
        .bool => |b| b == y.bool,
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |array| {
            if (array.items.len != y.array.items.len) return false;
            for (array.items, y.array.items) |*p, *q| if (!eql(p, q)) return false;
            return true;
        },
        .object => |object| {
            if (object.count() != y.object.count()) return false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const other = y.object.getPtr(entry.key_ptr.*) orelse return false;
                if (!eql(entry.value_ptr, other)) return false;
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
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
