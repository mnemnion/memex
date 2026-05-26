//! Writes Zig-built fysti bytes for the Rust compatibility helper.

/// Writes a set and map fixture to the paths passed on the command line.
pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) {
        return error.InvalidArgumentCount;
    }

    try writeSet(init.io, args[1]);
    try writeMap(init.io, args[2]);
}

/// Builds and writes the canonical compatibility set fixture.
fn writeSet(io: std.Io, path: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    var set_builder = try fysti.Builder(void).init(
        std.heap.page_allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer set_builder.deinit(std.heap.page_allocator);

    inline for (set_keys) |key| {
        try set_builder.insert(std.heap.page_allocator, key, {});
    }
    try set_builder.finish(std.heap.page_allocator);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// Builds and writes the canonical compatibility map fixture.
fn writeMap(io: std.Io, path: []const u8) !void {
    var out = std.Io.Writer.Allocating.init(std.heap.page_allocator);
    defer out.deinit();

    var map_builder = try fysti.Builder(u64).init(
        std.heap.page_allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer map_builder.deinit(std.heap.page_allocator);

    inline for (map_entries) |entry| {
        try map_builder.insert(std.heap.page_allocator, entry.key, entry.value);
    }
    try map_builder.finish(std.heap.page_allocator);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// One map entry used by the Zig-to-Rust compatibility writer.
const MapEntry = struct {
    /// Byte key inserted into the fixture map.
    key: []const u8,

    /// User value associated with `key`.
    value: u64,
};

/// Canonical keys written by the Zig set builder.
const set_keys: []const []const u8 = &.{ "", "ant", "cat", "dog" };

/// Canonical entries written by the Zig map builder.
const map_entries: []const MapEntry = &.{
    .{ .key = "", .value = 7 },
    .{ .key = "ant", .value = 10 },
    .{ .key = "cat", .value = 13 },
    .{ .key = "dog", .value = 21 },
};

const std = @import("std");

const fysti = @import("fysti");
