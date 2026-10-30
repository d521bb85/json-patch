//! Measures the complete path from JSON text to JSON text, in the same way as
//! the programs in `compare/`. See `run.py`.
//!
//!     zig build bench -- <data directory> <milliseconds> <workload>...

const std = @import("std");
const baseline = @import("baseline.zig");
const json_patch = @import("json_patch");

const Document = json_patch.Document;
const Io = std.Io;
const Patch = json_patch.Patch;

const Mode = enum {
    /// The conventional approach, built on `std.json`.
    baseline,
    /// `json_patch.apply` with default options: the document is validated.
    full,
    /// The document is trusted, as it would be coming from a database.
    trusted,
    /// As `trusted`, with a parsed patch reused between iterations.
    reuse,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(arena);
    const dir_path = args[1];
    const min_ns = try std.fmt.parseInt(u64, args[2], 10) * std.time.ns_per_ms;
    const dir = try Io.Dir.cwd().openDir(io, dir_path, .{});

    var buffer: [4096]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &stdout.interface;

    for (args[3..]) |name| {
        const limit: Io.Limit = .unlimited;
        const doc_text = try dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.doc.json", .{name}), arena, limit);
        const patch_text = try dir.readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}.patch.json", .{name}), arena, limit);

        for (std.enums.values(Mode)) |mode| {
            var reusable = try Patch.parse(gpa, patch_text, .{ .source = .borrow });
            defer reusable.deinit();

            var times: std.ArrayList(u64) = .empty;
            defer times.deinit(gpa);
            var result: []u8 = &.{};
            const started = Io.Clock.awake.now(io);
            while (times.items.len < 5 or
                started.durationTo(Io.Clock.awake.now(io)).toNanoseconds() < min_ns)
            {
                const start = Io.Clock.awake.now(io);
                const text = switch (mode) {
                    .baseline => try baseline.apply(gpa, doc_text, patch_text),
                    .full => try json_patch.apply(gpa, doc_text, patch_text, .{}),
                    .trusted => try json_patch.apply(gpa, doc_text, patch_text, .{ .validation = .none }),
                    .reuse => reuse: {
                        var doc: Document = try .parse(gpa, doc_text, .{ .source = .borrow, .validation = .none });
                        defer doc.deinit();
                        try doc.apply(&reusable, .{ .values = .borrow });
                        break :reuse try doc.toOwnedSlice(gpa);
                    },
                };
                const elapsed = start.durationTo(Io.Clock.awake.now(io)).toNanoseconds();
                try times.append(gpa, @intCast(elapsed));
                std.mem.doNotOptimizeAway(text.ptr);
                gpa.free(result);
                result = text;
            }
            std.mem.sort(u64, times.items, {}, std.sort.asc(u64));
            try out.print("{s} {t} {d}\n", .{ name, mode, times.items[times.items.len / 2] });
            try out.flush();

            const path = try std.fmt.allocPrint(arena, "out/zig-{t}.{s}.json", .{ mode, name });
            try dir.writeFile(io, .{ .sub_path = path, .data = result });
            gpa.free(result);
        }
    }
}
