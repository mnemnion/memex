//! Public read view for fst v3 bytes.
/// Returns a read-view type for a supported value family.
pub fn Fst(comptime V: type) type {
    if (V != void and V != u64) {
        @compileError("fysti.Fst only supports void and u64 values");
    }

    return struct {
        const Self = @This();

        /// Serialized fst v3 bytes owned by the caller.
        data: []const u8,

        /// Initializes a non-owning view over caller-owned v3 bytes.
        pub fn init(data: []const u8) Self {
            return .{ .data = data };
        }
    };
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
