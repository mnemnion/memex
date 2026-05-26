//! Test fixtures shared by fysti tests.
/// Upstream's implicit empty final node contributes no serialized bytes.
pub const empty_final_node: []const u8 = &.{};

/// Upstream OneTransNext for input `a`, encoded through the common-input table.
pub const one_transition_next_a: []const u8 = &.{0b1100_0101};

/// Upstream OneTrans for `z` with output 5 and delta 24 from node address 40.
pub const one_transition_z_output_delta: []const u8 = &.{ 5, 24, 0x11, 0b1011_0110 };
