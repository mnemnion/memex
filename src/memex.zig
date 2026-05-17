//! Memex: std.mem, EXtended
const std = @import("std");
const builtin = @import("builtin");

// Code borrowed and adapted from Zig 0.16 stdlib, std.mem.eql

const assert = std.debug.assert;

const use_vectors = switch (builtin.zig_backend) {
    .stage2_aarch64,
    .stage2_powerpc,
    .stage2_riscv64,
    => false,
    .stage2_spirv => false,
    else => true,
};

const use_vectors_for_comparison = use_vectors and !builtin.fuzz;

/// Return the index of the first difference between the two slices, such
/// that `std.mem.eql(T, first[0..idx], second[0..idx])` will be `true`.
pub fn indexOfDiff(T: type, first: []const T, second: []const T) usize {
    if (!@inComptime() and @sizeOf(T) != 0 and std.meta.hasUniqueRepresentation(T) and
        use_vectors_for_comparison)
    {
        return indexOfDiffBytes(std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(second)) / @sizeOf(T);
    }

    const shortest = @min(first.len, second.len);
    if (shortest == 0 or first.ptr == second.ptr) return shortest;

    for (first[0..shortest], second[0..shortest], 0..) |first_elem, second_elem, idx| {
        if (first_elem != second_elem) return idx;
    }
    return shortest;
}

/// Return the index of the last difference between the two slices, such that
/// `std.mem.eql(T, first[idx..], second[idx..])` will be `true`.
pub fn indexOfLastDiff(T: type, first: []const T, second: []const T) usize {
    if (first.len != second.len) return @min(first.len, second.len);

    if (!@inComptime() and @sizeOf(T) != 0 and std.meta.hasUniqueRepresentation(T) and
        use_vectors_for_comparison)
    {
        const byte_idx = indexOfLastDiffBytes(std.mem.sliceAsBytes(first), std.mem.sliceAsBytes(second));
        return byte_idx / @sizeOf(T) + @intFromBool(byte_idx % @sizeOf(T) != 0);
    }

    if (first.len == 0 or first.ptr == second.ptr) return 0;

    var idx = first.len;
    while (idx > 0) {
        idx -= 1;
        if (first[idx] != second[idx]) return idx + 1;
    }
    return 0;
}

fn comparisonScan(comptime size: comptime_int) type {
    return struct {
        const Chunk = if (std.simd.suggestVectorLength(u8)) |vec_size|
            @Vector(vec_size, u8)
        else
            usize;

        inline fn isNotEqual(first: Chunk, second: Chunk) bool {
            return switch (@typeInfo(Chunk)) {
                .vector => @reduce(.Or, first != second),
                else => first != second,
            };
        }

        inline fn chunk(bytes: []const u8, start: usize) Chunk {
            assert(size == @sizeOf(Chunk));
            return @bitCast(bytes[start..][0..size].*);
        }
    };
}

fn indexOfDiffBytes(first: []const u8, second: []const u8) usize {
    comptime assert(use_vectors_for_comparison);

    const shortest = @min(first.len, second.len);
    if (shortest == 0 or first.ptr == second.ptr) return shortest;

    if (shortest <= 16) return firstDiffInByteRange(first, second, 0, shortest) orelse shortest;

    const Scan = comparisonScan(std.simd.suggestVectorLength(u8) orelse @sizeOf(usize));

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= @sizeOf(Scan.Chunk) and shortest <= n) {
            const half = n / 2;
            const V = @Vector(half, u8);
            const zero: V = @splat(0);

            const prefix = @as(V, first[0..half].*) ^ @as(V, second[0..half].*);
            if (@reduce(.Or, prefix != zero)) return firstDiffInByteRange(first, second, 0, half).?;

            const suffix_start = shortest - half;
            const suffix = @as(V, first[suffix_start..][0..half].*) ^
                @as(V, second[suffix_start..][0..half].*);
            if (@reduce(.Or, suffix != zero)) return firstDiffInByteRange(first, second, suffix_start, half).?;

            return shortest;
        }
    }

    for (0..(shortest - 1) / @sizeOf(Scan.Chunk)) |chunk_idx| {
        const start = chunk_idx * @sizeOf(Scan.Chunk);
        if (Scan.isNotEqual(Scan.chunk(first, start), Scan.chunk(second, start))) {
            return firstDiffInByteRange(first, second, start, @sizeOf(Scan.Chunk)).?;
        }
    }

    const last_start = shortest - @sizeOf(Scan.Chunk);
    if (Scan.isNotEqual(Scan.chunk(first, last_start), Scan.chunk(second, last_start))) {
        return firstDiffInByteRange(first, second, last_start, @sizeOf(Scan.Chunk)).?;
    }

    return shortest;
}

fn indexOfLastDiffBytes(first: []const u8, second: []const u8) usize {
    comptime assert(use_vectors_for_comparison);
    assert(first.len == second.len);

    if (first.len == 0 or first.ptr == second.ptr) return 0;

    if (first.len <= 16) return lastDiffAfterByteRange(first, second, 0, first.len) orelse 0;

    const Scan = comparisonScan(std.simd.suggestVectorLength(u8) orelse @sizeOf(usize));
    var latest: usize = 0;

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= @sizeOf(Scan.Chunk) and first.len <= n) {
            const half = n / 2;
            const V = @Vector(half, u8);
            const zero: V = @splat(0);

            const suffix_start = first.len - half;
            const suffix = @as(V, first[suffix_start..][0..half].*) ^
                @as(V, second[suffix_start..][0..half].*);
            if (@reduce(.Or, suffix != zero)) {
                return lastDiffAfterByteRange(first, second, suffix_start, half).?;
            }

            const prefix = @as(V, first[0..half].*) ^ @as(V, second[0..half].*);
            if (@reduce(.Or, prefix != zero)) return lastDiffAfterByteRange(first, second, 0, half).?;

            return 0;
        }
    }

    for (0..(first.len - 1) / @sizeOf(Scan.Chunk)) |chunk_idx| {
        const start = chunk_idx * @sizeOf(Scan.Chunk);
        if (Scan.isNotEqual(Scan.chunk(first, start), Scan.chunk(second, start))) {
            latest = lastDiffAfterByteRange(first, second, start, @sizeOf(Scan.Chunk)).?;
        }
    }

    const last_start = first.len - @sizeOf(Scan.Chunk);
    if (Scan.isNotEqual(Scan.chunk(first, last_start), Scan.chunk(second, last_start))) {
        latest = lastDiffAfterByteRange(first, second, last_start, @sizeOf(Scan.Chunk)).?;
    }

    return latest;
}

fn firstDiffInByteRange(first: []const u8, second: []const u8, start: usize, len: usize) ?usize {
    for (first[start..][0..len], second[start..][0..len], start..) |first_byte, second_byte, idx| {
        if (first_byte != second_byte) return idx;
    }
    return null;
}

fn lastDiffAfterByteRange(first: []const u8, second: []const u8, start: usize, len: usize) ?usize {
    var offset = len;
    while (offset > 0) {
        offset -= 1;
        if (first[start + offset] != second[start + offset]) return start + offset + 1;
    }
    return null;
}

test indexOfDiff {
    try std.testing.expectEqual(@as(usize, 0), indexOfDiff(u8, "", ""));
    try std.testing.expectEqual(@as(usize, 3), indexOfDiff(u8, "abc", "abc"));
    try std.testing.expectEqual(@as(usize, 0), indexOfDiff(u8, "abc", "xbc"));
    try std.testing.expectEqual(@as(usize, 2), indexOfDiff(u8, "abc", "abx"));
    try std.testing.expectEqual(@as(usize, 3), indexOfDiff(u8, "abc", "abcdef"));
    try std.testing.expectEqual(@as(usize, 3), indexOfDiff(u8, "abcdef", "abc"));
    try std.testing.expectEqual(@as(usize, 8), indexOfDiff(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 0 }));
    try std.testing.expectEqual(@as(usize, 1), indexOfDiff(void, &.{ {}, {} }, &.{{}}));
}

test indexOfLastDiff {
    try std.testing.expectEqual(@as(usize, 0), indexOfLastDiff(u8, "", ""));
    try std.testing.expectEqual(@as(usize, 0), indexOfLastDiff(u8, "abc", "abc"));
    try std.testing.expectEqual(@as(usize, 1), indexOfLastDiff(u8, "abc", "xbc"));
    try std.testing.expectEqual(@as(usize, 3), indexOfLastDiff(u8, "abc", "abx"));
    try std.testing.expectEqual(@as(usize, 3), indexOfLastDiff(u8, "abc", "abcdef"));
    try std.testing.expectEqual(@as(usize, 3), indexOfLastDiff(u8, "abcdef", "abc"));
    try std.testing.expectEqual(@as(usize, 9), indexOfLastDiff(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 0 }));
    try std.testing.expectEqual(@as(usize, 1), indexOfLastDiff(void, &.{ {}, {} }, &.{{}}));
}
