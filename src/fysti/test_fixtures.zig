//! Test fixtures shared by fysti tests.
/// Upstream's implicit empty final node contributes no serialized bytes.
pub const empty_final_node: []const u8 = &.{};

/// Upstream OneTransNext for input `a`, encoded through the common-input table.
pub const one_transition_next_a: []const u8 = &.{0b1100_0101};

/// Upstream OneTrans for `z` with output 5 and delta 24 from node address 40.
pub const one_transition_z_output_delta: []const u8 = &.{ 5, 24, 0x11, 0b1011_0110 };

/// Small sorted key set used to connect builder output to reader lookup.
pub const lookup_set_keys: []const []const u8 = &.{ "", "ant", "cat", "dog" };

/// One sorted map entry used by reader tests.
pub const MapEntry = struct {
    /// Byte key inserted into the fixture map.
    key: []const u8,

    /// User value associated with `key`.
    value: u64,
};

/// Small sorted key/value set used to validate factored map outputs.
pub const lookup_map_entries: []const MapEntry = &.{
    .{ .key = "", .value = 7 },
    .{ .key = "ant", .value = 10 },
    .{ .key = "cat", .value = 13 },
    .{ .key = "dog", .value = 21 },
};
