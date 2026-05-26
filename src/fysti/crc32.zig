//! CRC32C support for fst v3 trailers.

/// Applies the masking transform used by upstream fst checksums.
pub fn mask(crc: u32) u32 {
    return ((crc >> 15) | (crc << 17)) +% 0xa282_ead8;
}

/// Removes the upstream checksum mask.
pub fn unmask(masked: u32) u32 {
    const rot = masked -% 0xa282_ead8;
    return (rot >> 17) | (rot << 15);
}

/// Returns the masked CRC32C checksum stored in an fst v3 trailer.
pub fn checksum(bytes: []const u8) u32 {
    const Crc32c = std.hash.crc.Crc32Iscsi;
    var hasher = Crc32c.init();
    hasher.update(bytes);
    return mask(hasher.final());
}

test "checksum mask round trips" {
    const values = [_]u32{ 0, 1, 0x1234_5678, 0xffff_ffff };
    for (values) |value| {
        try std.testing.expectEqual(value, unmask(mask(value)));
    }
}

test "checksum is stable for empty input" {
    try std.testing.expectEqual(mask(0), checksum(""));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
