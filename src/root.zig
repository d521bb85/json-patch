//! JSON Patch (RFC 6902) and JSON Pointer (RFC 6901).
//!
//! The quickest way in is `apply`, which works on JSON text:
//!
//! ```
//! const result = try json_patch.apply(gpa, document, patch, .{});
//! defer gpa.free(result);
//! ```
//!
//! To apply patches repeatedly, or to apply the same patch to many documents,
//! use `Document` and `Patch` directly. See their tests for examples.

const std = @import("std");

pub const Document = @import("Document.zig");
pub const Patch = @import("Patch.zig");
pub const Pointer = @import("Pointer.zig");

/// The deepest nesting of arrays and objects accepted by default when parsing.
///
/// This exists to bound the stack used to compare values. Limits can be raised
/// up to 65535 through `Document.ParseOptions` and `Patch.ParseOptions`.
pub const default_max_depth = @import("validate.zig").default_max_depth;

/// Whether a value keeps its own copy of text it was given.
pub const Ownership = enum { copy, borrow };

/// Details about a failure, which are optionally filled in on error.
pub const Diagnostics = struct {
    /// When parsing, the byte offset of the problem. When parsing a patch, this
    /// is the start of the operation at fault if it is a valid JSON object.
    offset: usize = 0,
    /// The index in the patch of the operation at fault. If the patch as a
    /// whole failed, this is the number of operations.
    operation: ?usize = null,
};

pub const ApplyOptions = struct {
    /// See `Document.ParseOptions.validation`.
    validation: @FieldType(Document.ParseOptions, "validation") = .full,
    /// See `default_max_depth`.
    max_depth: u16 = default_max_depth,
    diagnostics: ?*Diagnostics = null,
};

pub const ApplyError = Document.ParseError || Patch.ParseError || Document.ApplyError;

/// Applies the JSON Patch `patch` to the JSON text `document` and returns the
/// resulting JSON text, which the caller owns.
pub fn apply(
    gpa: std.mem.Allocator,
    document: []const u8,
    patch: []const u8,
    options: ApplyOptions,
) ApplyError![]u8 {
    var parsed_patch: Patch = try .parse(gpa, patch, .{
        .source = .borrow,
        .max_depth = options.max_depth,
        .diagnostics = options.diagnostics,
    });
    defer parsed_patch.deinit();

    var doc: Document = try .parse(gpa, document, .{
        .source = .borrow,
        .validation = options.validation,
        .max_depth = options.max_depth,
        .diagnostics = options.diagnostics,
    });
    defer doc.deinit();

    try doc.apply(&parsed_patch, .{ .values = .borrow, .diagnostics = options.diagnostics });
    return doc.toOwnedSlice(gpa);
}

test apply {
    const gpa = std.testing.allocator;
    const result = try apply(gpa,
        \\{"name": "zig", "tags": ["fast"]}
    ,
        \\[
        \\  {"op": "replace", "path": "/name", "value": "json-patch"},
        \\  {"op": "add", "path": "/tags/-", "value": "safe"}
        \\]
    , .{});
    defer gpa.free(result);

    try std.testing.expectEqualStrings(
        \\{"name":"json-patch","tags":["fast","safe"]}
    , result);
}

test Document {
    const gpa = std.testing.allocator;

    var doc: Document = try .parse(gpa,
        \\{"balance": 100, "history": []}
    , .{});
    defer doc.deinit();

    // Build a patch in code, or parse one with `Patch.parse`.
    var patch: Patch = .init(gpa);
    defer patch.deinit();
    try patch.testValue("/balance", 100);
    try patch.replace("/balance", 75);
    try patch.add("/history/-", .{ .amount = -25 });

    try doc.apply(&patch, .{});
    try std.testing.expectEqualStrings("75", (try doc.get("/balance")).?);

    // Patches are atomic. The `test` now fails, so nothing is changed by the
    // operations before it.
    var stale: Patch = .init(gpa);
    defer stale.deinit();
    try stale.replace("/history", "gone");
    try stale.testValue("/balance", 100);

    var diagnostics: Diagnostics = .{};
    try std.testing.expectError(
        error.TestFailed,
        doc.apply(&stale, .{ .diagnostics = &diagnostics }),
    );
    try std.testing.expectEqual(1, diagnostics.operation);
    try std.testing.expectFmt(
        \\{"balance":75,"history":[{"amount":-25}]}
    , "{f}", .{&doc});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("number.zig");
    _ = @import("scan.zig");
    _ = @import("string.zig");
    _ = @import("validate.zig");
}
