//! A bump allocator for memory that is all freed at once.
//!
//! This does what `std.heap.ArenaAllocator` does, without being safe to share
//! between threads. That safety costs at least one atomic operation for each
//! allocation, and nothing here shares an arena, while expanding a container
//! is mostly allocating.

const std = @import("std");

const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;
const Arena = @This();

gpa: Allocator,
/// The next free address in the newest chunk.
next: usize = 0,
/// The end of the newest chunk.
limit: usize = 0,
newest: ?*Chunk = null,

const Chunk = struct {
    older: ?*Chunk,
    /// The length of this allocation, including this header.
    len: usize,

    fn bytes(chunk: *Chunk) []align(@alignOf(Chunk)) u8 {
        return @as([*]align(@alignOf(Chunk)) u8, @ptrCast(chunk))[0..chunk.len];
    }
};

const min_chunk_len = 4096;

/// Chunks double in size only up to this. Beyond it, a chunk is as large as what
/// it is needed for, because a chunk that was large to hold one large value says
/// nothing about what comes next, and doubling that would never stop.
const max_doubled_len = 16 << 20;

pub fn init(gpa: Allocator) Arena {
    return .{ .gpa = gpa };
}

/// Returns an arena that starts out by using `buffer`, which is usually on the
/// stack, and which has to outlive it.
pub fn initBuffer(gpa: Allocator, buffer: []u8) Arena {
    return .{ .gpa = gpa, .next = @intFromPtr(buffer.ptr), .limit = @intFromPtr(buffer.ptr) + buffer.len };
}

pub fn deinit(arena: *Arena) void {
    var chunk = arena.newest;
    while (chunk) |current| {
        chunk = current.older;
        arena.gpa.free(current.bytes());
    }
    arena.* = undefined;
}

/// Frees everything except the newest chunk, ready to be used again.
pub fn reset(arena: *Arena) void {
    const newest = arena.newest orelse return;
    var chunk = newest.older;
    while (chunk) |current| {
        chunk = current.older;
        arena.gpa.free(current.bytes());
    }
    newest.older = null;
    arena.next = @intFromPtr(newest) + @sizeOf(Chunk);
}

/// Makes sure the next `len` bytes can be allocated without asking for more
/// memory, which saves growing through a series of ever larger chunks.
pub fn reserve(arena: *Arena, len: usize) Allocator.Error!void {
    if (arena.limit - arena.next < len) try arena.addChunk(len);
}

pub inline fn create(arena: *Arena, comptime T: type) Allocator.Error!*T {
    return @ptrCast(@alignCast(try arena.bump(@sizeOf(T), .of(T))));
}

/// Allocates `len` items, which must not be zero.
pub inline fn alloc(arena: *Arena, comptime T: type, len: usize) Allocator.Error![]T {
    const bytes = try arena.bump(len * @sizeOf(T), .of(T));
    return @as([*]T, @ptrCast(@alignCast(bytes)))[0..len];
}

inline fn bump(arena: *Arena, len: usize, alignment: Alignment) Allocator.Error![*]u8 {
    const start = alignment.forward(arena.next);
    if (start > arena.limit or arena.limit - start < len) return arena.bumpSlow(len, alignment);
    arena.next = start + len;
    return @ptrFromInt(start);
}

fn bumpSlow(arena: *Arena, len: usize, alignment: Alignment) Allocator.Error![*]u8 {
    try arena.addChunk(len + alignment.toByteUnits());
    return arena.bump(len, alignment);
}

fn addChunk(arena: *Arena, min_len: usize) Allocator.Error!void {
    const doubled = if (arena.newest) |newest| @min(newest.len * 2, max_doubled_len) else 0;
    const len = @max(min_len + @sizeOf(Chunk), doubled, min_chunk_len);
    const memory = try arena.gpa.alignedAlloc(u8, .of(Chunk), len);
    const chunk: *Chunk = @ptrCast(memory.ptr);
    chunk.* = .{ .older = arena.newest, .len = len };
    arena.newest = chunk;
    arena.next = @intFromPtr(chunk) + @sizeOf(Chunk);
    arena.limit = @intFromPtr(chunk) + len;
}

/// Returns an empty list that has the rest of the newest chunk as its capacity,
/// which saves growing it while it is filled. Nothing else can be allocated until
/// `finishList` has been called, unless the list has outgrown that capacity.
pub inline fn list(arena: *Arena, comptime T: type) std.ArrayList(T) {
    const start = std.mem.alignForward(usize, arena.next, @alignOf(T));
    if (start >= arena.limit) return .empty;
    const capacity = (arena.limit - start) / @sizeOf(T);
    if (capacity == 0) return .empty;
    arena.next = start + capacity * @sizeOf(T);
    return .{ .items = @as([*]T, @ptrFromInt(start))[0..0], .capacity = capacity, .pointer_stability = .{} };
}

/// Returns the unused capacity of a list to the arena.
pub inline fn finishList(arena: *Arena, comptime T: type, items: *std.ArrayList(T)) void {
    const capacity_end = @intFromPtr(items.items.ptr) + items.capacity * @sizeOf(T);
    if (capacity_end != arena.next) return;
    arena.next = @intFromPtr(items.items.ptr) + items.items.len * @sizeOf(T);
    items.capacity = items.items.len;
}

pub fn allocator(arena: *Arena) Allocator {
    return .{
        .ptr = arena,
        .vtable = &.{ .alloc = allocate, .resize = resize, .remap = remap, .free = free },
    };
}

fn allocate(context: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const arena: *Arena = @ptrCast(@alignCast(context));
    return arena.bump(len, alignment) catch null;
}

fn resize(context: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
    const arena: *Arena = @ptrCast(@alignCast(context));
    const start = @intFromPtr(memory.ptr);
    if (start + memory.len != arena.next) return new_len <= memory.len;
    if (new_len > arena.limit - start) return false;
    arena.next = start + new_len;
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

fn free(context: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
    const arena: *Arena = @ptrCast(@alignCast(context));
    if (@intFromPtr(memory.ptr) + memory.len == arena.next) arena.next = @intFromPtr(memory.ptr);
}

const testing = std.testing;

test "allocations do not overlap and survive growth" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var slices: [200][]u8 = undefined;
    for (&slices, 0..) |*slice, i| {
        slice.* = try a.alloc(u8, 1 + i * 37);
        @memset(slice.*, @truncate(i));
    }
    for (slices, 0..) |slice, i| {
        for (slice) |byte| try testing.expectEqual(@as(u8, @truncate(i)), byte);
    }
}

test "the last allocation can grow and shrink in place" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const first = try a.alloc(u8, 16);
    try testing.expect(a.resize(first, 32));
    try testing.expect(a.resize(first.ptr[0..32], 8));
    const second = try a.alloc(u8, 16);
    try testing.expectEqual(first.ptr + 8, second.ptr);
    try testing.expect(!a.resize(first.ptr[0..8], 32));
    try testing.expect(a.resize(first.ptr[0..8], 4));
    a.free(second);
    try testing.expectEqual(first.ptr + 8, (try a.alloc(u8, 16)).ptr);
}

test "alignment is honored" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 1);
    const aligned = try a.alignedAlloc(u8, .@"64", 100);
    try testing.expectEqual(0, @intFromPtr(aligned.ptr) % 64);
    const large = try a.alignedAlloc(u8, .@"64", 100_000);
    try testing.expectEqual(0, @intFromPtr(large.ptr) % 64);
}

test "one large allocation does not make later chunks large" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const large = 3 * max_doubled_len;
    _ = try a.alloc(u8, large);
    try testing.expect(arena.newest.?.len >= large);

    _ = try a.alloc(u8, min_chunk_len);
    try testing.expectEqual(max_doubled_len, arena.newest.?.len);

    // Doubling stops at the limit however many chunks there are.
    for (0..8) |_| _ = try a.alloc(u8, max_doubled_len / 2);
    try testing.expectEqual(max_doubled_len, arena.newest.?.len);
}

test initBuffer {
    var buffer: [64]u8 align(16) = undefined;
    var arena: Arena = .initBuffer(testing.allocator, &buffer);
    defer arena.deinit();
    const inside = try arena.alloc(u64, 2);
    try testing.expect(@intFromPtr(inside.ptr) >= @intFromPtr(&buffer));
    try testing.expect(@intFromPtr(inside.ptr) < @intFromPtr(&buffer) + buffer.len);
    const outside = try arena.alloc(u64, 100);
    try testing.expect(@intFromPtr(outside.ptr) + 800 <= @intFromPtr(&buffer) or
        @intFromPtr(outside.ptr) >= @intFromPtr(&buffer) + buffer.len);
}

test reset {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    arena.reset();
    const first = try arena.allocator().alloc(u8, 100_000);
    _ = try arena.allocator().alloc(u8, 1_000_000);
    arena.reset();
    _ = try arena.allocator().alloc(u8, 10);
    try testing.expect(first.len != 0);
}

test "lists use the rest of a chunk and give back what they do not need" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const before = try a.create(u64);

    var numbers = arena.list(u64);
    try testing.expect(numbers.capacity > 100);
    for (0..100) |i| numbers.appendAssumeCapacity(i);
    arena.finishList(u64, &numbers);
    try testing.expectEqual(100, numbers.capacity);

    const after = try a.create(u64);
    try testing.expectEqual(numbers.items.ptr + 100, @as([*]u64, @ptrCast(after)));
    try testing.expectEqual(@as([*]u64, @ptrCast(before)) + 1, numbers.items.ptr);
}

test "a list can outgrow its chunk" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var numbers = arena.list(u64);
    for (0..100_000) |i| try numbers.append(a, i);
    arena.finishList(u64, &numbers);
    for (numbers.items, 0..) |number, i| try testing.expectEqual(i, number);
}
