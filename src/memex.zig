//! Memex: std.mem, EXtended
const std = @import("std");
const builtin = @import("builtin");

// Code borrowed and adapted from Zig 0.16 stdlib, std.mem.eql

const assert = std.debug.assert;
const native_endian = builtin.target.cpu.arch.endian();

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
pub fn lastIndexOfDiff(T: type, first: []const T, second: []const T) usize {
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

fn comparisonScan() type {
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
            return @bitCast(bytes[start..][0..@sizeOf(Chunk)].*);
        }
    };
}

fn indexOfDiffBytes(first: []const u8, second: []const u8) usize {
    comptime assert(use_vectors_for_comparison);

    const shortest = @min(first.len, second.len);
    if (shortest == 0 or first.ptr == second.ptr) return shortest;

    if (shortest <= 16) return firstDiffInShortChunk(first, second, 0, shortest);

    const Scan = comparisonScan();

    inline for (1..6) |s| {
        const n = 16 << s;
        if (n <= @sizeOf(Scan.Chunk) and shortest <= n) {
            const half = n / 2;
            const V = @Vector(half, u8);
            const zero: V = @splat(0);

            const prefix = @as(V, first[0..half].*) ^ @as(V, second[0..half].*);
            if (@reduce(.Or, prefix != zero)) return firstDiffInChunk(half, first, second, 0);

            const suffix_start = shortest - half;
            const suffix = @as(V, first[suffix_start..][0..half].*) ^
                @as(V, second[suffix_start..][0..half].*);
            if (@reduce(.Or, suffix != zero)) return firstDiffInChunk(half, first, second, suffix_start);

            return shortest;
        }
    }

    for (0..(shortest - 1) / @sizeOf(Scan.Chunk)) |chunk_idx| {
        const start = chunk_idx * @sizeOf(Scan.Chunk);
        if (Scan.isNotEqual(Scan.chunk(first, start), Scan.chunk(second, start))) {
            return firstDiffInChunk(@sizeOf(Scan.Chunk), first, second, start);
        }
    }

    const last_start = shortest - @sizeOf(Scan.Chunk);
    if (Scan.isNotEqual(Scan.chunk(first, last_start), Scan.chunk(second, last_start))) {
        return firstDiffInChunk(@sizeOf(Scan.Chunk), first, second, last_start);
    }

    return shortest;
}

fn indexOfLastDiffBytes(first: []const u8, second: []const u8) usize {
    comptime assert(use_vectors_for_comparison);

    if (first.len == 0 or first.ptr == second.ptr) return 0;

    if (first.len <= 16) return lastDiffAfterShortChunk(first, second, 0, first.len) orelse 0;

    const Scan = comparisonScan();
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
                return lastDiffAfterChunk(half, first, second, suffix_start);
            }

            const prefix = @as(V, first[0..half].*) ^ @as(V, second[0..half].*);
            if (@reduce(.Or, prefix != zero)) return lastDiffAfterChunk(half, first, second, 0);

            return 0;
        }
    }

    for (0..(first.len - 1) / @sizeOf(Scan.Chunk)) |chunk_idx| {
        const start = chunk_idx * @sizeOf(Scan.Chunk);
        if (Scan.isNotEqual(Scan.chunk(first, start), Scan.chunk(second, start))) {
            latest = lastDiffAfterChunk(@sizeOf(Scan.Chunk), first, second, start);
        }
    }

    const last_start = first.len - @sizeOf(Scan.Chunk);
    if (Scan.isNotEqual(Scan.chunk(first, last_start), Scan.chunk(second, last_start))) {
        latest = lastDiffAfterChunk(@sizeOf(Scan.Chunk), first, second, last_start);
    }

    return latest;
}

inline fn firstDiffInChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    if (len <= 16) {
        return firstDiffInShortFixedChunk(len, first, second, start);
    }
    return firstDiffInLongChunk(len, first, second, start);
}

inline fn lastDiffAfterChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    if (len <= 16) {
        return lastDiffAfterShortFixedChunk(len, first, second, start);
    }
    return lastDiffAfterLongChunk(len, first, second, start);
}

inline fn firstDiffInLongChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    const diff = diffVector(len, first, second, start);
    const all_max: @Vector(len, usize) = @splat(std.math.maxInt(usize));
    return start + @reduce(.Min, @select(usize, diff != @as(@Vector(len, u8), @splat(0)), std.simd.iota(usize, len), all_max));
}

inline fn lastDiffAfterLongChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    const diff = diffVector(len, first, second, start);
    const all_zeroes: @Vector(len, usize) = @splat(0);
    return start + @reduce(.Max, @select(usize, diff != @as(@Vector(len, u8), @splat(0)), std.simd.iota(usize, len), all_zeroes)) + 1;
}

fn firstDiffInShortChunk(first: []const u8, second: []const u8, start: usize, len: usize) usize {
    switch (@as(u5, @intCast(len))) {
        inline else => |chunk_len| {
            if (chunk_len == 0) return start;
            if (chunk_len > 16) unreachable;
            return firstDiffInShortFixedChunk(chunk_len, first, second, start);
        },
    }
}

fn lastDiffAfterShortChunk(first: []const u8, second: []const u8, start: usize, len: usize) ?usize {
    switch (len) {
        0 => return null,
        1 => return if (diffInt(u8, first, second, start) != 0) start + 1 else null,
        2, 3 => {
            const last_start = start + len - 2;
            const last_diff = diffInt(u16, first, second, last_start);
            if (last_diff != 0) {
                return last_start + lastDiffAfterByteInInt(u16, last_diff);
            }
            const diff = diffInt(u16, first, second, start);
            if (diff != 0) {
                return start + lastDiffAfterByteInInt(u16, diff);
            }
            return null;
        },
        4...7 => {
            const last_start = start + len - 4;
            const last_diff = diffInt(u32, first, second, last_start);
            if (last_diff != 0) {
                return last_start + lastDiffAfterByteInInt(u32, last_diff);
            }
            const diff = diffInt(u32, first, second, start);
            if (diff != 0) {
                return start + lastDiffAfterByteInInt(u32, diff);
            }
            return null;
        },
        8...16 => {
            const last_start = start + len - 8;
            const last_diff = diffInt(u64, first, second, last_start);
            if (last_diff != 0) {
                return last_start + lastDiffAfterByteInInt(u64, last_diff);
            }
            const diff = diffInt(u64, first, second, start);
            if (diff != 0) {
                return start + lastDiffAfterByteInInt(u64, diff);
            }
            return null;
        },
        else => unreachable,
    }
}

inline fn firstDiffInShortFixedChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    switch (len) {
        1 => return start + firstDiffByteInInt(u8, diffInt(u8, first, second, start)),
        2, 3 => {
            const diff = diffInt(u16, first, second, start);
            if (diff != 0) return start + firstDiffByteInInt(u16, diff);
            const last_start = start + len - 2;
            return last_start + firstDiffByteInInt(u16, diffInt(u16, first, second, last_start));
        },
        4...7 => {
            const diff = diffInt(u32, first, second, start);
            if (diff != 0) return start + firstDiffByteInInt(u32, diff);
            const last_start = start + len - 4;
            return last_start + firstDiffByteInInt(u32, diffInt(u32, first, second, last_start));
        },
        8...16 => {
            const diff = diffInt(u64, first, second, start);
            if (diff != 0) return start + firstDiffByteInInt(u64, diff);
            const last_start = start + len - 8;
            return last_start + firstDiffByteInInt(u64, diffInt(u64, first, second, last_start));
        },
        else => unreachable,
    }
}

inline fn lastDiffAfterShortFixedChunk(comptime len: usize, first: []const u8, second: []const u8, start: usize) usize {
    switch (len) {
        1 => return start + 1,
        2, 3 => {
            const last_start = start + len - 2;
            const diff = diffInt(u16, first, second, last_start);
            if (diff != 0) return last_start + lastDiffAfterByteInInt(u16, diff);
            return start + lastDiffAfterByteInInt(u16, diffInt(u16, first, second, start));
        },
        4...7 => {
            const last_start = start + len - 4;
            const diff = diffInt(u32, first, second, last_start);
            if (diff != 0) return last_start + lastDiffAfterByteInInt(u32, diff);
            return start + lastDiffAfterByteInInt(u32, diffInt(u32, first, second, start));
        },
        8...16 => {
            const last_start = start + len - 8;
            const diff = diffInt(u64, first, second, last_start);
            if (diff != 0) return last_start + lastDiffAfterByteInInt(u64, diff);
            return start + lastDiffAfterByteInInt(u64, diffInt(u64, first, second, start));
        },
        else => unreachable,
    }
}

inline fn diffInt(T: type, first: []const u8, second: []const u8, start: usize) T {
    return std.mem.readInt(T, first[start..][0..@sizeOf(T)], native_endian) ^
        std.mem.readInt(T, second[start..][0..@sizeOf(T)], native_endian);
}

inline fn diffVector(comptime len: usize, first: []const u8, second: []const u8, start: usize) @Vector(len, u8) {
    return @as(@Vector(len, u8), first[start..][0..len].*) ^
        @as(@Vector(len, u8), second[start..][0..len].*);
}

inline fn firstDiffByteInInt(T: type, diff: T) usize {
    return switch (native_endian) {
        .little => @ctz(diff) / 8,
        .big => @clz(diff) / 8,
    };
}

inline fn lastDiffAfterByteInInt(T: type, diff: T) usize {
    return switch (native_endian) {
        .little => (@bitSizeOf(T) - 1 - @clz(diff)) / 8 + 1,
        .big => @sizeOf(T) - @ctz(diff) / 8,
    };
}

test "short byte range diff helpers" {
    const first = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

    for (0..first.len + 1) |len| {
        try std.testing.expectEqual(len, firstDiffInShortChunk(&first, &first, 0, len));
        try std.testing.expectEqual(@as(?usize, null), lastDiffAfterShortChunk(&first, &first, 0, len));

        for (0..len) |idx| {
            var second = first;
            second[idx] ^= 0xff;

            try std.testing.expectEqual(idx, firstDiffInShortChunk(&first, &second, 0, len));
            try std.testing.expectEqual(@as(?usize, idx + 1), lastDiffAfterShortChunk(&first, &second, 0, len));
        }
    }

    var second = first;
    second[9] ^= 0xff;
    try std.testing.expectEqual(@as(usize, 9), firstDiffInShortChunk(&first, &second, 4, 10));
    try std.testing.expectEqual(@as(?usize, 10), lastDiffAfterShortChunk(&first, &second, 4, 10));
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

test lastIndexOfDiff {
    try std.testing.expectEqual(@as(usize, 0), lastIndexOfDiff(u8, "", ""));
    try std.testing.expectEqual(@as(usize, 0), lastIndexOfDiff(u8, "abc", "abc"));
    try std.testing.expectEqual(@as(usize, 1), lastIndexOfDiff(u8, "abc", "xbc"));
    try std.testing.expectEqual(@as(usize, 3), lastIndexOfDiff(u8, "abc", "abx"));
    try std.testing.expectEqual(@as(usize, 3), lastIndexOfDiff(u8, "abc", "abcdef"));
    try std.testing.expectEqual(@as(usize, 3), lastIndexOfDiff(u8, "abcdef", "abc"));
    try std.testing.expectEqual(@as(usize, 9), lastIndexOfDiff(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9 }, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 0 }));
    try std.testing.expectEqual(@as(usize, 1), lastIndexOfDiff(void, &.{ {}, {} }, &.{{}}));
}
