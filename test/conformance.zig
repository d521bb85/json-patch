//! Runs the community test suite from https://github.com/json-patch/json-patch-tests
//! against every way of parsing and applying a patch.
//!
//! The suite marks a few cases as disabled because many implementations cannot
//! pass them. They are run here regardless. Fixtures are read with `Document`
//! so that the text of each patch reaches the parser as written, which matters
//! for the cases that have duplicate members.

const std = @import("std");
const json_patch = @import("json_patch");

const Document = json_patch.Document;
const Patch = json_patch.Patch;
const gpa = std.testing.allocator;

const Mode = struct {
    source: json_patch.Ownership,
    validation: @FieldType(Document.ParseOptions, "validation"),
    values: json_patch.Ownership,
};

const modes = [_]Mode{
    .{ .source = .copy, .validation = .full, .values = .copy },
    .{ .source = .borrow, .validation = .full, .values = .borrow },
    .{ .source = .borrow, .validation = .none, .values = .borrow },
};

test "tests.json" {
    try runSuite(@embedFile("json-patch-tests/tests.json"), 95);
}

test "spec_tests.json" {
    try runSuite(@embedFile("json-patch-tests/spec_tests.json"), 17);
}

fn runSuite(fixture: []const u8, expected_count: usize) !void {
    var suite: Document = try .parse(gpa, fixture, .{ .source = .borrow });
    defer suite.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var count: usize = 0;
    while (true) : (count += 1) {
        _ = arena.reset(.retain_capacity);
        const a = arena.allocator();
        const field = struct {
            fn get(s: *Document, allocator: std.mem.Allocator, i: usize, name: []const u8) !?[]const u8 {
                return s.get(try std.fmt.allocPrint(allocator, "/{d}/{s}", .{ i, name }));
            }
        }.get;

        if (try suite.get(try std.fmt.allocPrint(a, "/{d}", .{count})) == null) break;
        const document = try field(&suite, a, count, "doc") orelse continue;
        const patch = (try field(&suite, a, count, "patch")).?;
        const expected = try field(&suite, a, count, "expected");
        const expect_error = try field(&suite, a, count, "error") != null;

        for (modes) |mode| {
            runCase(a, document, patch, expected, expect_error, mode) catch |err| {
                std.debug.print("\ncase {d} failed in mode {any}: {s}\n", .{
                    count,
                    mode,
                    (try field(&suite, a, count, "comment")) orelse "",
                });
                return err;
            };
        }
    }
    try std.testing.expectEqual(expected_count, count);
}

fn runCase(
    a: std.mem.Allocator,
    document: []const u8,
    patch: []const u8,
    expected: ?[]const u8,
    expect_error: bool,
    mode: Mode,
) !void {
    var doc: Document = try .parse(gpa, document, .{ .source = mode.source, .validation = mode.validation });
    defer doc.deinit();

    var parsed = Patch.parse(gpa, patch, .{ .source = mode.source }) catch |err| {
        if (expect_error) return;
        return err;
    };
    defer parsed.deinit();

    doc.apply(&parsed, .{ .values = mode.values }) catch |err| {
        if (!expect_error) return err;
        // A patch that fails must not leave anything behind.
        const after = try doc.toOwnedSlice(a);
        return expectJsonEqual(a, document, after);
    };
    if (expect_error) return error.TestExpectedError;

    const result = try doc.toOwnedSlice(a);
    if (expected) |text| try expectJsonEqual(a, text, result);

    const oneshot = try json_patch.apply(a, document, patch, .{ .validation = mode.validation });
    try std.testing.expectEqualStrings(result, oneshot);
}

fn expectJsonEqual(a: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const x = try std.json.parseFromSliceLeaky(std.json.Value, a, expected, .{});
    const y = try std.json.parseFromSliceLeaky(std.json.Value, a, actual, .{});
    if (!jsonEql(x, y)) {
        std.debug.print("\nexpected: {s}\n  actual: {s}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

/// Compares parsed values independently of the implementation under test.
fn jsonEql(x: std.json.Value, y: std.json.Value) bool {
    if (asFloat(x)) |p| return if (asFloat(y)) |q| p == q else false;
    if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
    return switch (x) {
        .null => true,
        .bool => |b| b == y.bool,
        .string => |s| std.mem.eql(u8, s, y.string),
        .array => |array| {
            if (array.items.len != y.array.items.len) return false;
            for (array.items, y.array.items) |p, q| {
                if (!jsonEql(p, q)) return false;
            }
            return true;
        },
        .object => |object| {
            if (object.count() != y.object.count()) return false;
            var it = object.iterator();
            while (it.next()) |entry| {
                const other = y.object.get(entry.key_ptr.*) orelse return false;
                if (!jsonEql(entry.value_ptr.*, other)) return false;
            }
            return true;
        },
        .integer, .float, .number_string => unreachable,
    };
}

fn asFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}
