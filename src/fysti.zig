//! fysti: a Zig implementation of BurntSushi fst format v3.
/// Returns a v3 read view for the supported value family `V`.
pub fn Fst(comptime V: type) type {
    return fst.Fst(V);
}

/// Returns a v3 builder for the supported value family `V`.
pub fn Builder(comptime V: type) type {
    return builder.Builder(V);
}

/// Set read view: keys are present or absent and have no user value.
pub const Set = Fst(void);

/// Map read view: keys map to upstream-compatible `u64` values.
pub const Map = Fst(u64);

/// Set builder: emits v3 bytes with zero internal outputs.
pub const SetBuilder = Builder(void);

/// Map builder: emits v3 bytes with `u64` output factoring.
pub const MapBuilder = Builder(u64);

/// Serialized fst version implemented by fysti.
pub const version = fst.version;

/// Number of bytes in the v3 header.
pub const header_len = fst.header_len;

/// Number of bytes in the v3 trailer.
pub const trailer_len = fst.trailer_len;

/// Conventional v3 kind value shared by builders and readers.
pub const Kind = fst.Kind;

comptime {
    std.testing.refAllDecls(@This());
}

test "fysti public aliases use supported value families" {
    try std.testing.expect(Set == Fst(void));
    try std.testing.expect(Map == Fst(u64));
    try std.testing.expect(SetBuilder == Builder(void));
    try std.testing.expect(MapBuilder == Builder(u64));
}

const std = @import("std");

/// Canonical spelling for allocator failures in this module family.
const OOM = std.mem.Allocator.Error;

pub const bytes = @import("fysti/bytes.zig");
pub const output = @import("fysti/output.zig");
pub const crc32 = @import("fysti/crc32.zig");
pub const node = @import("fysti/node.zig");
pub const registry = @import("fysti/registry.zig");
pub const builder = @import("fysti/builder.zig");
pub const fst = @import("fysti/fst.zig");
