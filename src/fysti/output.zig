//! Output algebra for fst v3 map values.
/// Recoverable output failures caused by caller-provided map values.
pub const Error = error{
    OutputOverflow,
};

/// Internal fst output value stored as the upstream `u64` monoid.
pub const Output = struct {
    /// Numeric value encoded on a transition or final node.
    value: u64,

    /// Returns the identity output.
    pub fn zero() Output {
        return .{ .value = 0 };
    }

    /// Converts a supported user value into an internal output.
    pub fn fromValue(comptime V: type, value: V) Output {
        if (V == void) {
            return .{ .value = 0 };
        }
        if (V == u64) {
            return .{ .value = value };
        }
        @compileError("fysti only supports void and u64 values");
    }

    /// Returns the shared prefix output used for transducer factoring.
    pub fn prefix(first: Output, second: Output) Output {
        return .{ .value = @min(first.value, second.value) };
    }

    /// Concatenates outputs by checked addition.
    pub fn cat(first: Output, second: Output) Error!Output {
        return .{ .value = std.math.add(u64, first.value, second.value) catch return error.OutputOverflow };
    }

    /// Removes `prefix_output` from `output`; callers assert the fst invariant.
    pub fn sub(output: Output, prefix_output: Output) Output {
        std.debug.assert(output.value >= prefix_output.value);
        return .{ .value = output.value - prefix_output.value };
    }
};

test "void values map to zero output" {
    try std.testing.expectEqual(@as(u64, 0), Output.fromValue(void, {}).value);
}

test "u64 values use upstream min add subtract algebra" {
    const a: Output = .{ .value = 10 };
    const b: Output = .{ .value = 4 };
    try std.testing.expectEqual(@as(u64, 4), Output.prefix(a, b).value);
    try std.testing.expectEqual(@as(u64, 14), (try Output.cat(a, b)).value);
    try std.testing.expectEqual(@as(u64, 6), Output.sub(a, b).value);
}

test "output addition reports overflow" {
    const a: Output = .{ .value = std.math.maxInt(u64) };
    const b: Output = .{ .value = 1 };
    try std.testing.expectError(error.OutputOverflow, Output.cat(a, b));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
