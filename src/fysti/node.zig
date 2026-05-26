//! Node and transition encoding for fst v3.
/// Address of the implicit empty final node in fst v3.
pub const empty_address: u64 = 0;

/// Address used by upstream to represent the absence of a node.
pub const none_address: u64 = 1;

/// First address available to serialized nodes after the v3 header.
pub const first_node_address: u64 = 16;

/// A byte-labelled transition leaving a node.
pub const Transition = struct {
    /// Input byte consumed by this transition.
    input: u8,

    /// Output added when this transition is taken.
    out: output.Output,

    /// Address of the destination node, using fst's last-byte convention.
    addr: u64,
};

/// A builder-side node before serialization.
pub const UnfinishedNode = struct {
    /// Final output for this node, or null when the node is not final.
    final_output: ?output.Output,

    /// Sorted outgoing transitions from this node.
    transitions: std.ArrayList(Transition),

    /// Releases transition storage owned by this node.
    pub fn deinit(node: *UnfinishedNode, allocator: std.mem.Allocator) void {
        node.transitions.deinit(allocator);
        node.* = undefined;
    }
};

/// A serialized node body plus its final-byte address.
pub const CompiledNode = struct {
    /// Serialized node bytes in forward file order.
    bytes: []const u8,

    /// Address of the last byte of `bytes` in the eventual fst file.
    address: u64,
};

/// Returns true when `node` is the implicit empty final node.
pub fn isEmptyFinalAddress(addr: u64) bool {
    return addr == empty_address;
}

/// Encodes a node with no transitions or one transition using fst v3 cases.
pub fn encodeSimple(
    allocator: std.mem.Allocator,
    node: UnfinishedNode,
    previous_addr: u64,
    next_addr: u64,
) OOM![]u8 {
    if (node.transitions.items.len == 0) {
        const final_output = node.final_output.?;
        std.debug.assert(final_output.value == 0);
        return allocator.dupe(u8, &.{});
    }

    if (node.transitions.items.len == 1) {
        const trans = node.transitions.items[0];
        if (node.final_output == null and trans.out.value == 0 and trans.addr == next_addr) {
            return encodeOneTransNext(allocator, trans.input);
        }

        std.debug.assert(node.final_output == null);
        return encodeOneTrans(allocator, previous_addr, trans);
    }

    std.debug.assert(node.transitions.items.len <= 1);
    unreachable;
}

/// Encodes upstream's one-transition-next state.
fn encodeOneTransNext(allocator: std.mem.Allocator, input: u8) OOM![]u8 {
    const common_index = commonInputIndex(input);
    if (common_index == 0) {
        return allocator.dupe(u8, &.{ input, one_trans_next_flag });
    }
    return allocator.dupe(u8, &.{one_trans_next_flag | common_index});
}

/// Encodes upstream's one-transition state with output and delta pack sizes.
fn encodeOneTrans(allocator: std.mem.Allocator, node_addr: u64, trans: Transition) OOM![]u8 {
    var buf: [19]u8 = undefined;
    var len: usize = 0;

    const out_size: u4 = if (trans.out.value == 0) 0 else bytes.packSize(trans.out.value);
    if (out_size > 0) {
        bytes.packUint(buf[len..], trans.out.value, out_size);
        len += out_size;
    }

    const delta = deltaAddress(node_addr, trans.addr);
    const delta_size = bytes.packSize(delta);
    bytes.packUint(buf[len..], delta, delta_size);
    len += delta_size;

    buf[len] = (@as(u8, delta_size) << 4) | @as(u8, out_size);
    len += 1;

    const common_index = commonInputIndex(trans.input);
    if (common_index == 0) {
        buf[len] = trans.input;
        len += 1;
    }

    buf[len] = one_trans_flag | common_index;
    len += 1;

    return allocator.dupe(u8, buf[0..len]);
}

/// Returns the delta address stored by upstream for a transition target.
fn deltaAddress(node_addr: u64, trans_addr: u64) u64 {
    if (trans_addr == empty_address) {
        return empty_address;
    }
    std.debug.assert(node_addr >= trans_addr);
    return node_addr - trans_addr;
}

/// Returns the encoded common-input index for `input`, or zero when absent.
fn commonInputIndex(input: u8) u8 {
    return switch (input) {
        't' => 1,
        'e' => 2,
        '/' => 3,
        'o' => 4,
        'a' => 5,
        's' => 6,
        'r' => 7,
        'i' => 8,
        'p' => 9,
        'c' => 10,
        'n' => 11,
        'w' => 12,
        '.' => 13,
        'h' => 14,
        'l' => 15,
        'm' => 16,
        '-' => 17,
        'd' => 18,
        'u' => 19,
        '0' => 20,
        '1' => 21,
        '2' => 22,
        'g' => 23,
        '=' => 24,
        ':' => 25,
        'b' => 26,
        'f' => 27,
        '3' => 28,
        'y' => 29,
        '5' => 30,
        '&' => 31,
        '_' => 32,
        '4' => 33,
        'v' => 34,
        '9' => 35,
        '6' => 36,
        '7' => 37,
        '8' => 38,
        'k' => 39,
        '%' => 40,
        '?' => 41,
        'x' => 42,
        'C' => 43,
        'D' => 44,
        'A' => 45,
        'S' => 46,
        'F' => 47,
        'I' => 48,
        'B' => 49,
        'E' => 50,
        'j' => 51,
        'P' => 52,
        'T' => 53,
        'z' => 54,
        'R' => 55,
        'N' => 56,
        'M' => 57,
        '+' => 58,
        'L' => 59,
        'O' => 60,
        'q' => 61,
        'H' => 62,
        'G' => 63,
        else => 0,
    };
}

test "empty final node encodes as the implicit final state" {
    const transitions: std.ArrayList(Transition) = .empty;
    const unfinished: UnfinishedNode = .{
        .final_output = output.Output.zero(),
        .transitions = transitions,
    };

    const encoded = try encodeSimple(std.testing.allocator, unfinished, 0, first_node_address);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, test_fixtures.empty_final_node, encoded);
}

test "one transition next omits delta and output" {
    var transitions: std.ArrayList(Transition) = .empty;
    defer transitions.deinit(std.testing.allocator);
    try transitions.append(std.testing.allocator, .{
        .input = 'a',
        .out = output.Output.zero(),
        .addr = 32,
    });

    const unfinished: UnfinishedNode = .{
        .final_output = null,
        .transitions = transitions,
    };

    const encoded = try encodeSimple(std.testing.allocator, unfinished, 0, 32);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, test_fixtures.one_transition_next_a, encoded);
}

test "one transition encodes output and node-relative delta" {
    var transitions: std.ArrayList(Transition) = .empty;
    defer transitions.deinit(std.testing.allocator);
    try transitions.append(std.testing.allocator, .{
        .input = 'z',
        .out = .{ .value = 5 },
        .addr = first_node_address,
    });

    const unfinished: UnfinishedNode = .{
        .final_output = null,
        .transitions = transitions,
    };

    const encoded = try encodeSimple(std.testing.allocator, unfinished, 40, 32);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, test_fixtures.one_transition_z_output_delta, encoded);
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const output = @import("output.zig");
const test_fixtures = @import("test_fixtures.zig");

const one_trans_flag: u8 = 0b1000_0000;
const one_trans_next_flag: u8 = 0b1100_0000;
