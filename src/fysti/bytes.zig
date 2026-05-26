//! Byte encoding helpers for fst v3.
/// Returns the `u64` stored in the next eight little-endian bytes.
pub fn readU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len >= 8);
    return std.mem.readInt(u64, bytes[0..8], .little);
}

/// Writes `value` as eight little-endian bytes.
pub fn writeU64(out: *[8]u8, value: u64) void {
    std.mem.writeInt(u64, out, value, .little);
}

/// Returns the `u32` stored in the next four little-endian bytes.
pub fn readU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return std.mem.readInt(u32, bytes[0..4], .little);
}

/// Writes `value` as four little-endian bytes.
pub fn writeU32(out: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, out, value, .little);
}

/// Returns the number of bytes required by fst's fixed-width integer packing.
pub fn packSize(value: u64) u4 {
    if (value < 1 << 8) return 1;
    const bits = 64 - @clz(value);
    return @intCast((bits + 7) / 8);
}

/// Writes the low `n` little-endian bytes of `value` into `out`.
pub fn packUint(out: []u8, value: u64, n: u4) void {
    std.debug.assert(n >= 1);
    std.debug.assert(n <= 8);
    std.debug.assert(out.len >= n);

    var full: [8]u8 = undefined;
    writeU64(&full, value);
    @memcpy(out[0..n], full[0..n]);
}

/// Reads a fixed-width little-endian integer from `n` bytes.
pub fn unpackUint(bytes: []const u8, n: u4) u64 {
    std.debug.assert(n >= 1);
    std.debug.assert(n <= 8);
    std.debug.assert(bytes.len >= n);

    var full: [8]u8 = .{0} ** 8;
    @memcpy(full[0..n], bytes[0..n]);
    return readU64(&full);
}

test "fixed little-endian integers round trip" {
    var buf64: [8]u8 = undefined;
    writeU64(&buf64, 0x0123_4567_89ab_cdef);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01 }, &buf64);
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), readU64(&buf64));

    var buf32: [4]u8 = undefined;
    writeU32(&buf32, 0x89ab_cdef);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xcd, 0xab, 0x89 }, &buf32);
    try std.testing.expectEqual(@as(u32, 0x89ab_cdef), readU32(&buf32));
}

test "packed integers use fixed little-endian truncation" {
    try std.testing.expectEqual(@as(u4, 1), packSize(0));
    try std.testing.expectEqual(@as(u4, 1), packSize(0xff));
    try std.testing.expectEqual(@as(u4, 2), packSize(0x0100));
    try std.testing.expectEqual(@as(u4, 8), packSize(std.math.maxInt(u64)));

    var buf: [8]u8 = .{0xaa} ** 8;
    packUint(&buf, 0x0102_0304, 4);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, buf[0..4]);
    try std.testing.expectEqual(@as(u64, 0x0102_0304), unpackUint(&buf, 4));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
