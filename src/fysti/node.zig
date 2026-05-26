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

/// Number of transitions above which v3 stores a direct byte-to-index table.
pub const transition_index_threshold: usize = 32;

/// Packed byte widths for transition deltas and outputs.
pub const PackSizes = struct {
    /// Number of bytes used for each transition delta.
    delta: u4,

    /// Number of bytes used for each transition output.
    out: u4,

    /// Packs the two byte widths into upstream's high/low nibble layout.
    pub fn encode(sizes: PackSizes) u8 {
        std.debug.assert(sizes.delta <= 8);
        std.debug.assert(sizes.out <= 8);
        return (@as(u8, sizes.delta) << 4) | @as(u8, sizes.out);
    }

    /// Unpacks upstream's high/low nibble layout into byte widths.
    pub fn decode(byte: u8) PackSizes {
        const sizes: PackSizes = .{
            .delta = @intCast(byte >> 4),
            .out = @intCast(byte & 0x0f),
        };
        std.debug.assert(sizes.delta <= 8);
        std.debug.assert(sizes.out <= 8);
        return sizes;
    }
};

/// Borrowed view of a serialized fst v3 node.
pub const Node = struct {
    /// Full fst byte slice that contains this node.
    data: []const u8,

    /// Address of the final byte of this node.
    addr: u64,

    /// Creates a borrowed node view; `addr` must follow fst's last-byte rule.
    pub fn init(data: []const u8, addr: u64) Node {
        if (addr != empty_address) {
            const at: usize = @intCast(addr);
            std.debug.assert(at < data.len);
        }
        return .{
            .data = data,
            .addr = addr,
        };
    }

    /// Returns whether this node is final.
    pub fn isFinal(node: Node) bool {
        return switch (node.stateKind()) {
            .empty_final => true,
            .one_trans_next, .one_trans => false,
            .any_trans => node.stateByte() & any_trans_final_flag != 0,
        };
    }

    /// Returns this node's terminal output, or zero when absent.
    pub fn finalOutput(node: Node) output.Output {
        return switch (node.stateKind()) {
            .empty_final, .one_trans_next, .one_trans => output.Output.zero(),
            .any_trans => node.anyFinalOutput(),
        };
    }

    /// Returns the number of outgoing transitions.
    pub fn transitionCount(node: Node) usize {
        return switch (node.stateKind()) {
            .empty_final => 0,
            .one_trans_next, .one_trans => 1,
            .any_trans => node.anyTransitionCount(),
        };
    }

    /// Returns the transition at `index` in lexicographic order.
    pub fn transition(node: Node, index: usize) Transition {
        return switch (node.stateKind()) {
            .empty_final => unreachable,
            .one_trans_next => node.oneTransNextTransition(index),
            .one_trans => node.oneTransTransition(index),
            .any_trans => node.anyTransition(index),
        };
    }

    /// Finds a transition by input byte.
    pub fn findInput(node: Node, input: u8) ?Transition {
        return switch (node.stateKind()) {
            .empty_final => null,
            .one_trans_next, .one_trans => {
                const trans = node.transition(0);
                if (trans.input == input) {
                    return trans;
                }
                return null;
            },
            .any_trans => node.findAnyInput(input),
        };
    }

    /// Returns the serialized state family used by this node.
    fn stateKind(node: Node) StateKind {
        if (node.addr == empty_address) {
            return .empty_final;
        }
        return switch (node.stateByte() >> 6) {
            0b11 => .one_trans_next,
            0b10 => .one_trans,
            else => .any_trans,
        };
    }

    /// Returns the state byte at this node's last-byte address.
    fn stateByte(node: Node) u8 {
        const at: usize = @intCast(node.addr);
        std.debug.assert(at < node.data.len);
        return node.data[at];
    }

    /// Returns the address of the first byte in a OneTransNext node.
    fn oneTransNextStart(node: Node) u64 {
        const input_len = oneTransInputLen(node.stateByte());
        std.debug.assert(node.addr >= input_len);
        return node.addr - input_len;
    }

    /// Decodes the sole transition in a OneTransNext node.
    fn oneTransNextTransition(node: Node, index: usize) Transition {
        std.debug.assert(index == 0);
        const state = node.stateByte();
        const input = commonInput(state & common_input_mask) orelse node.data[@intCast(node.addr - 1)];
        return .{
            .input = input,
            .out = output.Output.zero(),
            .addr = node.oneTransNextStart() - 1,
        };
    }

    /// Returns the packed byte widths in a OneTrans node.
    fn oneTransSizes(node: Node) PackSizes {
        const input_len = oneTransInputLen(node.stateByte());
        const at: usize = @intCast(node.addr - input_len - 1);
        return PackSizes.decode(node.data[at]);
    }

    /// Returns the address of the first byte in a OneTrans node.
    fn oneTransStart(node: Node, sizes: PackSizes) u64 {
        const input_len = oneTransInputLen(node.stateByte());
        std.debug.assert(node.addr >= input_len + 1 + sizes.delta + sizes.out);
        return node.addr - input_len - 1 - sizes.delta - sizes.out;
    }

    /// Decodes the sole transition in a OneTrans node.
    fn oneTransTransition(node: Node, index: usize) Transition {
        std.debug.assert(index == 0);
        const state = node.stateByte();
        const sizes = node.oneTransSizes();
        const input = commonInput(state & common_input_mask) orelse node.data[@intCast(node.addr - 1)];
        const node_start = node.oneTransStart(sizes);
        const output_at: usize = @intCast(node_start);
        const delta_at: usize = @intCast(node.addr - oneTransInputLen(state) - 1 - sizes.delta);
        return .{
            .input = input,
            .out = unpackOutput(node.data[output_at..], sizes.out),
            .addr = unpackDelta(node.data[delta_at..], sizes.delta, node_start),
        };
    }

    /// Returns the explicit transition-count byte width for an AnyTrans node.
    fn anyTransitionCountLen(node: Node) u64 {
        if (node.stateByte() & any_trans_count_mask == 0) {
            return 1;
        }
        return 0;
    }

    /// Returns the transition count for an AnyTrans node.
    fn anyTransitionCount(node: Node) usize {
        const state_count = node.stateByte() & any_trans_count_mask;
        if (state_count != 0) {
            return state_count;
        }

        const encoded = node.data[@intCast(node.addr - 1)];
        if (encoded == 1) {
            return 256;
        }
        return encoded;
    }

    /// Returns the packed byte widths in an AnyTrans node.
    fn anySizes(node: Node) PackSizes {
        const at: usize = @intCast(node.addr - node.anyTransitionCountLen() - 1);
        return PackSizes.decode(node.data[at]);
    }

    /// Returns the size of the optional direct transition index.
    fn transitionIndexSize(ntrans: usize) u64 {
        if (ntrans > transition_index_threshold) {
            return 256;
        }
        return 0;
    }

    /// Returns the combined byte width of AnyTrans inputs, deltas, and index.
    fn anyTotalTransitionSize(sizes: PackSizes, ntrans: usize) u64 {
        return @as(u64, ntrans) + (@as(u64, ntrans) * sizes.delta) + transitionIndexSize(ntrans);
    }

    /// Returns the address of the first byte in an AnyTrans node.
    fn anyStart(node: Node, sizes: PackSizes, ntrans: usize) u64 {
        const final_output_size: u64 = if (node.isFinal()) sizes.out else 0;
        return node.addr - node.anyTransitionCountLen() - 1 - anyTotalTransitionSize(sizes, ntrans) - (@as(u64, ntrans) * sizes.out) - final_output_size;
    }

    /// Returns the input byte for an AnyTrans transition index.
    fn anyInput(node: Node, index: usize, ntrans: usize) u8 {
        std.debug.assert(index < ntrans);
        const index_size = transitionIndexSize(ntrans);
        const at: usize = @intCast(node.addr - node.anyTransitionCountLen() - 1 - index_size - index - 1);
        return node.data[at];
    }

    /// Returns the output for an AnyTrans transition index.
    fn anyOutput(node: Node, index: usize, sizes: PackSizes, ntrans: usize) output.Output {
        std.debug.assert(index < ntrans);
        if (sizes.out == 0) {
            return output.Output.zero();
        }
        const at: usize = @intCast(node.addr - node.anyTransitionCountLen() - 1 - anyTotalTransitionSize(sizes, ntrans) - (@as(u64, index) * sizes.out) - sizes.out);
        return unpackOutput(node.data[at..], sizes.out);
    }

    /// Returns the optional final output stored in an AnyTrans node.
    fn anyFinalOutput(node: Node) output.Output {
        const sizes = node.anySizes();
        if (!node.isFinal() or sizes.out == 0) {
            return output.Output.zero();
        }
        const ntrans = node.anyTransitionCount();
        const at: usize = @intCast(node.anyStart(sizes, ntrans));
        return unpackOutput(node.data[at..], sizes.out);
    }

    /// Returns the target address for an AnyTrans transition index.
    fn anyTransitionAddress(node: Node, index: usize, sizes: PackSizes, ntrans: usize) u64 {
        std.debug.assert(index < ntrans);
        const node_start = node.anyStart(sizes, ntrans);
        const at: usize = @intCast(node.addr - node.anyTransitionCountLen() - 1 - transitionIndexSize(ntrans) - @as(u64, ntrans) - (@as(u64, index) * sizes.delta) - sizes.delta);
        return unpackDelta(node.data[at..], sizes.delta, node_start);
    }

    /// Decodes an AnyTrans transition in lexicographic order.
    fn anyTransition(node: Node, index: usize) Transition {
        const ntrans = node.anyTransitionCount();
        const sizes = node.anySizes();
        return .{
            .input = node.anyInput(index, ntrans),
            .out = node.anyOutput(index, sizes, ntrans),
            .addr = node.anyTransitionAddress(index, sizes, ntrans),
        };
    }

    /// Finds an AnyTrans transition by input byte.
    fn findAnyInput(node: Node, input: u8) ?Transition {
        const ntrans = node.anyTransitionCount();
        if (ntrans > transition_index_threshold) {
            const index_start: usize = @intCast(node.addr - node.anyTransitionCountLen() - 1 - transitionIndexSize(ntrans));
            const index = node.data[index_start + input];
            if (@as(usize, index) >= ntrans) {
                return null;
            }
            return node.transition(index);
        }

        for (0..ntrans) |index| {
            const trans = node.anyTransition(index);
            if (trans.input == input) {
                return trans;
            }
        }
        return null;
    }
};

/// Returns true when `addr` points at the implicit empty final node.
pub fn isEmptyFinalAddress(addr: u64) bool {
    return addr == empty_address;
}

/// Encodes a builder-side node into fst v3 node bytes.
/// `node_start_addr` is the OneTrans delta base; `last_addr` enables OneTransNext.
pub fn encode(
    allocator: std.mem.Allocator,
    node: UnfinishedNode,
    node_start_addr: u64,
    last_addr: u64,
) OOM![]u8 {
    if (node.transitions.items.len == 0) {
        if (node.final_output) |final_output| {
            if (final_output.value == 0) {
                return allocator.dupe(u8, &.{});
            }
        }
        return encodeAnyTrans(allocator, node, node_start_addr);
    }

    if (node.transitions.items.len == 1) {
        const trans = node.transitions.items[0];
        if (node.final_output == null and trans.out.value == 0 and trans.addr == last_addr) {
            return encodeOneTransNext(allocator, trans.input);
        }

        if (node.final_output == null) {
            return encodeOneTrans(allocator, node_start_addr, trans);
        }
    }

    return encodeAnyTrans(allocator, node, node_start_addr);
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

/// Encodes upstream's general multi-transition state.
fn encodeAnyTrans(allocator: std.mem.Allocator, node: UnfinishedNode, node_addr: u64) OOM![]u8 {
    const ntrans = node.transitions.items.len;
    std.debug.assert(ntrans <= 256);
    assertSortedTransitions(node.transitions.items);

    const is_final = node.final_output != null;
    const final_output = node.final_output orelse output.Output.zero();
    var delta_size: u4 = 0;
    var out_size: u4 = bytes.packSize(final_output.value);
    var any_outs = final_output.value != 0;
    for (node.transitions.items) |trans| {
        delta_size = @max(delta_size, deltaPackSize(node_addr, trans.addr));
        out_size = @max(out_size, bytes.packSize(trans.out.value));
        any_outs = any_outs or trans.out.value != 0;
    }

    const sizes: PackSizes = .{
        .delta = delta_size,
        .out = if (any_outs) out_size else 0,
    };
    const count_len: usize = if (ntrans == 0 or ntrans > @as(usize, any_trans_count_mask)) 1 else 0;
    const index_len: usize = if (ntrans > transition_index_threshold) 256 else 0;
    const final_output_len: usize = if (is_final) sizes.out else 0;
    const encoded_len = final_output_len + (ntrans * @as(usize, sizes.out)) + (ntrans * @as(usize, sizes.delta)) + ntrans + index_len + 1 + count_len + 1;
    var encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);

    var len: usize = 0;
    if (sizes.out > 0) {
        if (is_final) {
            bytes.packUint(encoded[len..], final_output.value, sizes.out);
            len += sizes.out;
        }
        var index = ntrans;
        while (index > 0) {
            index -= 1;
            bytes.packUint(encoded[len..], node.transitions.items[index].out.value, sizes.out);
            len += sizes.out;
        }
    }

    var delta_index = ntrans;
    while (delta_index > 0) {
        delta_index -= 1;
        packDelta(encoded[len..], node_addr, node.transitions.items[delta_index].addr, sizes.delta);
        len += sizes.delta;
    }

    var input_index = ntrans;
    while (input_index > 0) {
        input_index -= 1;
        encoded[len] = node.transitions.items[input_index].input;
        len += 1;
    }

    if (ntrans > transition_index_threshold) {
        @memset(encoded[len..][0..256], 255);
        for (node.transitions.items, 0..) |trans, index| {
            encoded[len + @as(usize, trans.input)] = @intCast(index);
        }
        len += 256;
    }

    encoded[len] = sizes.encode();
    len += 1;

    if (count_len == 1) {
        encoded[len] = if (ntrans == 256) 1 else @intCast(ntrans);
        len += 1;
    }

    var state: u8 = 0;
    if (is_final) {
        state |= any_trans_final_flag;
    }
    if (ntrans > 0 and ntrans <= @as(usize, any_trans_count_mask)) {
        state |= @intCast(ntrans);
    }
    encoded[len] = state;
    len += 1;

    std.debug.assert(len == encoded.len);
    return encoded;
}

/// Asserts that transition inputs are strictly sorted in lexicographic order.
fn assertSortedTransitions(transitions: []const Transition) void {
    if (transitions.len < 2) {
        return;
    }
    for (transitions[1..], 1..) |trans, index| {
        std.debug.assert(transitions[index - 1].input < trans.input);
    }
}

/// Returns the delta address stored by upstream for a transition target.
fn deltaAddress(node_addr: u64, trans_addr: u64) u64 {
    if (trans_addr == empty_address) {
        return empty_address;
    }
    std.debug.assert(node_addr >= trans_addr);
    return node_addr - trans_addr;
}

/// Returns the number of bytes needed to pack an upstream transition delta.
fn deltaPackSize(node_addr: u64, trans_addr: u64) u4 {
    return bytes.packSize(deltaAddress(node_addr, trans_addr));
}

/// Writes an upstream transition delta with an already chosen byte width.
fn packDelta(out: []u8, node_addr: u64, trans_addr: u64, n: u4) void {
    std.debug.assert(n > 0);
    bytes.packUint(out, deltaAddress(node_addr, trans_addr), n);
}

/// Decodes a transition delta relative to an AnyTrans or OneTrans node start.
fn unpackDelta(data: []const u8, n: u4, node_start_addr: u64) u64 {
    std.debug.assert(n > 0);
    const delta = bytes.unpackUint(data, n);
    if (delta == empty_address) {
        return empty_address;
    }
    std.debug.assert(node_start_addr >= delta);
    return node_start_addr - delta;
}

/// Decodes a possibly absent packed output.
fn unpackOutput(data: []const u8, n: u4) output.Output {
    if (n == 0) {
        return output.Output.zero();
    }
    return .{ .value = bytes.unpackUint(data, n) };
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

/// Returns the common input byte for an encoded common-input index.
fn commonInput(index: u8) ?u8 {
    return switch (index) {
        0 => null,
        1 => 't',
        2 => 'e',
        3 => '/',
        4 => 'o',
        5 => 'a',
        6 => 's',
        7 => 'r',
        8 => 'i',
        9 => 'p',
        10 => 'c',
        11 => 'n',
        12 => 'w',
        13 => '.',
        14 => 'h',
        15 => 'l',
        16 => 'm',
        17 => '-',
        18 => 'd',
        19 => 'u',
        20 => '0',
        21 => '1',
        22 => '2',
        23 => 'g',
        24 => '=',
        25 => ':',
        26 => 'b',
        27 => 'f',
        28 => '3',
        29 => 'y',
        30 => '5',
        31 => '&',
        32 => '_',
        33 => '4',
        34 => 'v',
        35 => '9',
        36 => '6',
        37 => '7',
        38 => '8',
        39 => 'k',
        40 => '%',
        41 => '?',
        42 => 'x',
        43 => 'C',
        44 => 'D',
        45 => 'A',
        46 => 'S',
        47 => 'F',
        48 => 'I',
        49 => 'B',
        50 => 'E',
        51 => 'j',
        52 => 'P',
        53 => 'T',
        54 => 'z',
        55 => 'R',
        56 => 'N',
        57 => 'M',
        58 => '+',
        59 => 'L',
        60 => 'O',
        61 => 'q',
        62 => 'H',
        63 => 'G',
        else => unreachable,
    };
}

/// Returns the explicit input byte length for a one-transition state.
fn oneTransInputLen(state: u8) u64 {
    if (commonInput(state & common_input_mask) == null) {
        return 1;
    }
    return 0;
}

test "empty final node encodes as the implicit final state" {
    const transitions: std.ArrayList(Transition) = .empty;
    const unfinished: UnfinishedNode = .{
        .final_output = output.Output.zero(),
        .transitions = transitions,
    };

    const node_start_addr = first_node_address;
    const last_addr = first_node_address;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, last_addr);
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

    const node_start_addr = 34;
    const last_addr = 32;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, last_addr);
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

    const node_start_addr = 40;
    const last_addr = 32;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, last_addr);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, test_fixtures.one_transition_z_output_delta, encoded);
}

test "OneTransNext encode decode round trip" {
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

    const node_start_addr = 33;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, 32);
    defer std.testing.allocator.free(encoded);

    const installed = try installNodeBytes(std.testing.allocator, encoded, node_start_addr);
    defer std.testing.allocator.free(installed.data);

    const node = Node.init(installed.data, installed.addr);
    try std.testing.expect(!node.isFinal());
    try std.testing.expectEqual(@as(usize, 1), node.transitionCount());
    try std.testing.expectEqual(Transition{
        .input = 'a',
        .out = output.Output.zero(),
        .addr = 32,
    }, node.transition(0));
    try std.testing.expectEqual(Transition{
        .input = 'a',
        .out = output.Output.zero(),
        .addr = 32,
    }, node.findInput('a').?);
    try std.testing.expectEqual(@as(?Transition, null), node.findInput('b'));
}

test "OneTrans encode decode round trip" {
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

    const node_start_addr = 40;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, 32);
    defer std.testing.allocator.free(encoded);

    const installed = try installNodeBytes(std.testing.allocator, encoded, node_start_addr);
    defer std.testing.allocator.free(installed.data);

    const node = Node.init(installed.data, installed.addr);
    try std.testing.expect(!node.isFinal());
    try std.testing.expectEqual(@as(usize, 1), node.transitionCount());
    try std.testing.expectEqual(Transition{
        .input = 'z',
        .out = .{ .value = 5 },
        .addr = first_node_address,
    }, node.transition(0));
    try std.testing.expectEqual(Transition{
        .input = 'z',
        .out = .{ .value = 5 },
        .addr = first_node_address,
    }, node.findInput('z').?);
    try std.testing.expectEqual(@as(?Transition, null), node.findInput('a'));
}

test "AnyTrans two transitions encode decode round trip" {
    var transitions: std.ArrayList(Transition) = .empty;
    defer transitions.deinit(std.testing.allocator);
    try transitions.append(std.testing.allocator, .{
        .input = 'a',
        .out = output.Output.zero(),
        .addr = 10,
    });
    try transitions.append(std.testing.allocator, .{
        .input = 'z',
        .out = .{ .value = 7 },
        .addr = 80,
    });

    const unfinished: UnfinishedNode = .{
        .final_output = .{ .value = 3 },
        .transitions = transitions,
    };

    const node_start_addr = 100;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, 32);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{
        3, 7, 0, 20, 90, 'z', 'a', 0x11, 0b0100_0010,
    }, encoded);

    const installed = try installNodeBytes(std.testing.allocator, encoded, node_start_addr);
    defer std.testing.allocator.free(installed.data);

    const node = Node.init(installed.data, installed.addr);
    try std.testing.expect(node.isFinal());
    try std.testing.expectEqual(@as(u64, 3), node.finalOutput().value);
    try std.testing.expectEqual(@as(usize, 2), node.transitionCount());
    try std.testing.expectEqual(Transition{
        .input = 'a',
        .out = output.Output.zero(),
        .addr = 10,
    }, node.transition(0));
    try std.testing.expectEqual(Transition{
        .input = 'z',
        .out = .{ .value = 7 },
        .addr = 80,
    }, node.transition(1));
    try std.testing.expectEqual(Transition{
        .input = 'z',
        .out = .{ .value = 7 },
        .addr = 80,
    }, node.findInput('z').?);
    try std.testing.expectEqual(@as(?Transition, null), node.findInput('b'));
}

test "AnyTrans final leaf output encode decode round trip" {
    const transitions: std.ArrayList(Transition) = .empty;
    const unfinished: UnfinishedNode = .{
        .final_output = .{ .value = 42 },
        .transitions = transitions,
    };

    const node_start_addr = first_node_address;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, first_node_address);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{
        42, 0x01, 0, 0b0100_0000,
    }, encoded);

    const installed = try installNodeBytes(std.testing.allocator, encoded, node_start_addr);
    defer std.testing.allocator.free(installed.data);

    const node = Node.init(installed.data, installed.addr);
    try std.testing.expect(node.isFinal());
    try std.testing.expectEqual(@as(u64, 42), node.finalOutput().value);
    try std.testing.expectEqual(@as(usize, 0), node.transitionCount());
    try std.testing.expectEqual(@as(?Transition, null), node.findInput('a'));
}

test "AnyTrans 33 transitions encode decode round trip with transition index" {
    var transitions: std.ArrayList(Transition) = .empty;
    defer transitions.deinit(std.testing.allocator);
    for (0..33) |i| {
        try transitions.append(std.testing.allocator, .{
            .input = @intCast(i),
            .out = output.Output.zero(),
            .addr = @intCast(700 + i),
        });
    }

    const unfinished: UnfinishedNode = .{
        .final_output = null,
        .transitions = transitions,
    };

    const node_start_addr = 1000;
    const encoded = try encode(std.testing.allocator, unfinished, node_start_addr, 600);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 357), encoded.len);
    const index_start = (33 * 2) + 33;
    try std.testing.expectEqual(@as(u8, 0), encoded[index_start]);
    try std.testing.expectEqual(@as(u8, 17), encoded[index_start + 17]);
    try std.testing.expectEqual(@as(u8, 32), encoded[index_start + 32]);
    try std.testing.expectEqual(@as(u8, 255), encoded[index_start + 200]);
    try std.testing.expectEqual(@as(u8, 0x20), encoded[encoded.len - 2]);
    try std.testing.expectEqual(@as(u8, 0b0010_0001), encoded[encoded.len - 1]);

    const installed = try installNodeBytes(std.testing.allocator, encoded, node_start_addr);
    defer std.testing.allocator.free(installed.data);

    const node = Node.init(installed.data, installed.addr);
    try std.testing.expect(!node.isFinal());
    try std.testing.expectEqual(@as(usize, 33), node.transitionCount());
    try std.testing.expectEqual(Transition{
        .input = 0,
        .out = output.Output.zero(),
        .addr = 700,
    }, node.transition(0));
    try std.testing.expectEqual(Transition{
        .input = 17,
        .out = output.Output.zero(),
        .addr = 717,
    }, node.findInput(17).?);
    try std.testing.expectEqual(Transition{
        .input = 32,
        .out = output.Output.zero(),
        .addr = 732,
    }, node.transition(32));
    try std.testing.expectEqual(@as(?Transition, null), node.findInput(200));
}

/// Installed serialized bytes and the address of their final byte.
const InstalledNodeBytes = struct {
    /// Full fake fst data containing the serialized node at its real address.
    data: []u8,

    /// Address of the serialized node's final byte.
    addr: u64,
};

/// Places encoded node bytes at `node_start_addr` in a fake fst byte slice.
fn installNodeBytes(allocator: std.mem.Allocator, encoded: []const u8, node_start_addr: u64) OOM!InstalledNodeBytes {
    const start: usize = @intCast(node_start_addr);
    const addr: u64 = node_start_addr + encoded.len - 1;
    const data = try allocator.alloc(u8, @intCast(addr + 1));
    @memset(data, 0);
    @memcpy(data[start..][0..encoded.len], encoded);
    return .{
        .data = data,
        .addr = addr,
    };
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const output = @import("output.zig");
const test_fixtures = @import("test_fixtures.zig");

const StateKind = enum {
    empty_final,
    one_trans_next,
    one_trans,
    any_trans,
};

const common_input_mask: u8 = 0b0011_1111;
const any_trans_final_flag: u8 = 0b0100_0000;
const any_trans_count_mask: u8 = 0b0011_1111;
const one_trans_flag: u8 = 0b1000_0000;
const one_trans_next_flag: u8 = 0b1100_0000;
