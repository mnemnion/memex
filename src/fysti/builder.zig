//! Public builder core for fst v3 bytes.

/// Returns a builder type for a supported value family.
pub fn Builder(comptime V: type) type {
    if (V != void and V != u64) {
        @compileError("fysti.Builder only supports void and u64 values");
    }

    return struct {
        const Self = @This();

        /// Writer that receives serialized v3 bytes.
        writer: *std.Io.Writer,

        /// Initializes an empty builder around the caller-owned writer.
        pub fn init(writer: *std.Io.Writer) Self {
            return .{ .writer = writer };
        }
    };
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
