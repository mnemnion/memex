# fysti Builder-First Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first `fysti` milestone: a Zig-native, builder-first implementation of BurntSushi `fst` format v3 for `void` sets and `u64` maps, with enough exact lookup to validate emitted bytes.

**Architecture:** Implement a shared v3 format engine under `src/fysti/`, re-exported from `src/fysti.zig`. `Builder(V)` is public and writes through `std.Io.Writer`; `Fst(V)` is a non-owning read view over `[]const u8`. Sets and maps are thin value-family opinions over the same output/node/builder core.

**Tech Stack:** Zig 0.16.0, `std.Io.Writer`, `std.ArrayList`, `std.mem.Allocator`, `std.testing`, local upstream reference at `/private/tmp/codex-project-state/memex/fysti/fst`.

---

## Hard Constraints

- Do not implement Rust-shaped pseudo-traits. Zig does not need `AsRef`, `Streamer`, or borrow-checker lending abstractions.
- Do not support fst v1 or v2. `fysti` targets v3 only.
- Do not add default field values. Use explicit declaration literals at construction sites.
- Spell `std.mem.Allocator.Error` as `OOM` in code: `const OOM = std.mem.Allocator.Error;`.
- Imports and localizations at the bottom of the file, not the top.
- Comments are required on every function and every field. Comments must explain what the item is and why it exists, not merely restate the identifier.
- Use upstream comments as orientation, not as text to blindly clone.
- Malformed fst bytes are assertion territory, not user-facing parse errors.
- Public recoverable errors are for correct callers: OOM, writer failure, unsorted input, duplicate map keys, output overflow.
- Run Zig commands plainly first; do not set Zig cache environment variables unless a command actually fails due to cache permissions.

## File Structure

- Modify `build.zig`: add a `fysti` module and make `zig build test` run both `memex` and `fysti` tests.
- Modify `src/fysti.zig`: public entrypoint that re-exports the implementation modules and defines `Fst`, `Builder`, `Set`, `Map`, `SetBuilder`, and `MapBuilder`.
- Create `src/fysti/bytes.zig`: little-endian fixed integers and fixed-width packed integer helpers.
- Create `src/fysti/output.zig`: v3 output algebra over `u64`.
- Create `src/fysti/node.zig`: transition structs and v3 node encode/decode.
- Create `src/fysti/registry.zig`: bounded equivalent-node reuse.
- Create `src/fysti/builder.zig`: public `Builder(V)` core, sorted insertion, unfinished stack, node emission, trailer, checksum.
- Create `src/fysti/fst.zig`: public `Fst(V)` read view and exact lookup.
- Create `src/fysti/crc32.zig`: CRC32C Castagnoli plus upstream masking.
- Create `src/fysti/test_fixtures.zig`: small helper fixtures shared by tests.
- Do not add upstream Rust sources to this repository.

## Task 1: Wire the fysti Module and Test Target

**Files:**
- Modify: `build.zig`
- Modify: `src/fysti.zig`

- [ ] **Step 1: Replace `src/fysti.zig` with the public skeleton**

```zig
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

```

- [ ] **Step 2: Create temporary stub modules so the test target compiles**

Create each file with the exact content shown.

`src/fysti/bytes.zig`:

```zig
//! Byte encoding helpers for fst v3.
```

`src/fysti/output.zig`:

```zig
//! Output algebra for fst v3 map values.
```

`src/fysti/crc32.zig`:

```zig
//! CRC32C support for fst v3 trailers.
```

`src/fysti/node.zig`:

```zig
//! Node and transition encoding for fst v3.
```

`src/fysti/registry.zig`:

```zig
//! Bounded node registry for fst v3 builder deduplication.
```

`src/fysti/builder.zig`:

```zig
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
```

`src/fysti/fst.zig`:

```zig
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
```

`src/fysti/test_fixtures.zig`:

```zig
//! Test fixtures shared by fysti tests.
```

- [ ] **Step 3: Add fysti to `build.zig`**

Replace the module/test setup at the top of `build.zig` with:

```zig
    const memex_mod = b.addModule("memex", .{
        .root_source_file = b.path("src/memex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fysti_mod = b.addModule("fysti", .{
        .root_source_file = b.path("src/fysti.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const memex_unit_tests = b.addTest(.{
        .root_module = memex_mod,
        .filters = test_filters,
    });

    const fysti_unit_tests = b.addTest(.{
        .root_module = fysti_mod,
        .filters = test_filters,
    });

    const run_memex_unit_tests = b.addRunArtifact(memex_unit_tests);
    const run_fysti_unit_tests = b.addRunArtifact(fysti_unit_tests);

    const test_step = b.step("test", "Run unit tests");

    test_step.dependOn(&run_memex_unit_tests.step);
    test_step.dependOn(&run_fysti_unit_tests.step);
```

Then update the coverage artifact reference from `module_unit_tests` to
`memex_unit_tests` for now:

```zig
    run_kcov.addArtifactArg(memex_unit_tests);
```

- [ ] **Step 4: Run the fysti alias test**

Run:

```bash
zig build -Dtest-filter="fysti public aliases" test
```

Expected: the fysti test target runs and passes.

- [ ] **Step 5: Run all tests**

Run:

```bash
zig build test
```

Expected: both memex and fysti test targets pass.

- [ ] **Step 6: Commit module wiring**

```bash
git add build.zig src/fysti.zig src/fysti
git commit -m "feat(fysti): Wire module skeleton"
```

## Task 2: Implement Byte Encoding Helpers

**Files:**
- Modify: `src/fysti/bytes.zig`

- [x] **Step 1: Replace `bytes.zig` with tests and implementation**

```zig
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
```

- [x] **Step 2: Run byte helper tests**

Run:

```bash
zig build -Dtest-filter="packed integers" test
zig build -Dtest-filter="fixed little-endian" test
```

Expected: both filtered tests pass.

- [x] **Step 3: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [x] **Step 4: Commit byte helpers**

```bash
git add src/fysti/bytes.zig
git commit -m "feat(fysti): Add byte encoding helpers"
```

## Task 3: Implement Output Algebra and Value Family Mapping

**Files:**
- Modify: `src/fysti/output.zig`

- [ ] **Step 1: Replace `output.zig` with tests and implementation**

```zig
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
```

- [ ] **Step 2: Run output tests**

Run:

```bash
zig build -Dtest-filter=output test
```

Expected: output tests pass.

- [ ] **Step 3: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 4: Commit output algebra**

```bash
git add src/fysti/output.zig
git commit -m "feat(fysti): Add output algebra"
```

## Task 4: Implement CRC32C Masking

**Files:**
- Modify: `src/fysti/crc32.zig`

- [ ] **Step 1: Replace `crc32.zig` with tests and implementation**

```zig
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
```

- [ ] **Step 2: Run CRC tests**

Run:

```bash
zig build -Dtest-filter=checksum test
```

Expected: checksum tests pass.

- [ ] **Step 3: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 4: Commit CRC support**

```bash
git add src/fysti/crc32.zig
git commit -m "feat(fysti): Add checksum masking"
```

## Task 5: Implement Node Model and Encoding Cases

**Files:**
- Modify: `src/fysti/node.zig`
- Modify: `src/fysti/test_fixtures.zig`

- [ ] **Step 1: Add transition and node types**

Implement `Transition`, `CompiledNode`, and the node constants. Every field gets
a comment. Use declaration literals in tests and construction.

```zig
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

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const output = @import("output.zig");
```

- [ ] **Step 2: Add minimal encode/decode functions**

Start with `EmptyFinal`, `OneTransNext`, and `OneTrans`. Leave `AnyTrans` for
Task 6 so this task stays reviewable.

```zig
/// Returns true when `node` is the implicit empty final node.
pub fn isEmptyFinalAddress(addr: u64) bool {
    return addr == empty_address;
}

/// Encodes a node with no transitions and optional final output.
pub fn encodeSimple(
    allocator: std.mem.Allocator,
    node: UnfinishedNode,
    previous_addr: u64,
    next_addr: u64,
) OOM![]u8 {
    _ = previous_addr;

    if (node.transitions.items.len == 0) {
        std.debug.assert(node.final_output != null);
        return allocator.dupe(u8, &.{0});
    }

    if (node.transitions.items.len == 1) {
        const trans = node.transitions.items[0];
        if (node.final_output == null and trans.out.value == 0 and trans.addr == next_addr) {
            return allocator.dupe(u8, &.{ trans.input, 0b1100_0000 });
        }

        var buf: [18]u8 = undefined;
        var len: usize = 0;
        buf[len] = trans.input;
        len += 1;

        const out_size = bytes.packSize(trans.out.value);
        buf[len] = out_size;
        len += 1;
        bytes.packUint(buf[len..], trans.out.value, out_size);
        len += out_size;

        const delta = trans.addr - next_addr;
        const delta_size = bytes.packSize(delta);
        buf[len] = delta_size;
        len += 1;
        bytes.packUint(buf[len..], delta, delta_size);
        len += delta_size;

        buf[len] = 0b1000_0000;
        len += 1;

        return allocator.dupe(u8, buf[0..len]);
    }

    std.debug.assert(node.transitions.items.len <= 1);
    unreachable;
}
```

- [ ] **Step 3: Add focused tests**

Add tests that prove empty and one-transition encodings are stable enough to
iterate on. If upstream line refs are needed, start from
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:244`.

```zig
test "empty final node encodes as the implicit final state" {
    var transitions: std.ArrayList(Transition) = .empty;
    const unfinished: UnfinishedNode = .{
        .final_output = output.Output.zero(),
        .transitions = transitions,
    };

    const encoded = try encodeSimple(std.testing.allocator, unfinished, 0, first_node_address);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, &.{0}, encoded);
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

    try std.testing.expectEqualSlices(u8, &.{ 'a', 0b1100_0000 }, encoded);
}
```

- [ ] **Step 4: Run node tests**

Run:

```bash
zig build -Dtest-filter="one transition" test
zig build -Dtest-filter="empty final" test
```

Expected: both filtered tests pass.

- [ ] **Step 5: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 6: Commit simple node encoding**

```bash
git add src/fysti/node.zig src/fysti/test_fixtures.zig
git commit -m "feat(fysti): Add simple node encoding"
```

## Task 6: Complete AnyTrans Node Encoding and Decoding

**Files:**
- Modify: `src/fysti/node.zig`
- Modify: `docs/inventory/fysti-upstream-fst.md` only if a source-reference correction is discovered

- [ ] **Step 1: Read the upstream node format**

Inspect:

```bash
sed -n '468,760p' /private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs
sed -n '806,860p' /private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs
```

Expected: confirm `AnyTrans` field order, transition-index threshold, pack-size
nibble layout, common-input encoding, and delta semantics.

- [ ] **Step 2: Implement AnyTrans pack-size and transition-index helpers**

Add helpers with comments:

```zig
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
        return .{
            .delta = @intCast(byte >> 4),
            .out = @intCast(byte & 0x0f),
        };
    }
};
```

- [ ] **Step 3: Replace `encodeSimple` with `encode`**

Rename `encodeSimple` to `encode`, route one-transition cases through existing
logic, and implement `AnyTrans` for two or more transitions. Keep transition
inputs sorted and assert sortedness before serializing.

The resulting signature:

```zig
/// Encodes a builder-side node into fst v3 node bytes.
pub fn encode(
    allocator: std.mem.Allocator,
    node: UnfinishedNode,
    next_addr: u64,
) OOM![]u8
```

- [ ] **Step 4: Add decode view sufficient for exact lookup**

Implement a borrowed `Node` view over serialized data with this completed public
shape:

```zig
/// Borrowed view of a serialized fst v3 node.
pub const Node = struct {
    /// Full fst byte slice that contains this node.
    data: []const u8,

    /// Address of the final byte of this node.
    addr: u64,

    /// Creates a borrowed node view; `addr` must follow fst's last-byte rule.
    pub fn init(data: []const u8, addr: u64) Node

    /// Returns whether this node is final.
    pub fn isFinal(node: Node) bool

    /// Returns the number of outgoing transitions.
    pub fn transitionCount(node: Node) usize

    /// Returns the transition at `index` in lexicographic order.
    pub fn transition(node: Node, index: usize) Transition

    /// Finds a transition by input byte.
    pub fn findInput(node: Node, input: u8) ?Transition
};
```

`findInput` uses the direct transition index when present and falls back to
linear search for small nodes.

- [ ] **Step 5: Add encode/decode round-trip tests**

Add tests for:

- `OneTransNext`;
- `OneTrans`;
- `AnyTrans` with two transitions;
- `AnyTrans` with 33 transitions and transition index.

Use declaration literals for all values.

- [ ] **Step 6: Run node tests**

Run:

```bash
zig build -Dtest-filter=AnyTrans test
zig build -Dtest-filter=OneTrans test
```

Expected: all node encode/decode tests pass.

- [ ] **Step 7: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 8: Commit complete node support**

```bash
git add src/fysti/node.zig docs/inventory/fysti-upstream-fst.md
git commit -m "feat(fysti): Complete node encoding"
```

If `docs/inventory/fysti-upstream-fst.md` was not changed, omit it from
`git add`.

## Task 7: Implement the Bounded Registry

**Files:**
- Modify: `src/fysti/registry.zig`

- [ ] **Step 1: Replace `registry.zig` with implementation and tests**

Use upstream as the source map:
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/registry.rs:29`.

Use the same shape: fixed bucket count and a small
per-bucket cell count. Do not use field defaults.

Required public shape:

```zig
//! Bounded node registry for fst v3 builder deduplication.
/// Candidate serialized node recorded for later equivalent-node reuse.
const Entry = struct {
    /// Hash of the serialized bytes used to choose a bucket.
    hash: u64,

    /// Serialized bytes owned by the registry.
    bytes: []u8,

    /// Address of the equivalent node in the output fst.
    address: u64,
};

/// Bounded approximate registry for serialized node reuse.
pub const Registry = struct {
    /// Buckets that hold recently seen serialized nodes.
    buckets: []std.ArrayList(Entry),

    /// Number of entries retained per bucket.
    entries_per_bucket: usize,

    /// Creates an empty registry with explicit sizing.
    pub fn init(
        allocator: std.mem.Allocator,
        bucket_count: usize,
        entries_per_bucket: usize,
    ) OOM!Registry;

    /// Releases all node bytes and bucket storage.
    pub fn deinit(registry: *Registry, allocator: std.mem.Allocator) void;

    /// Returns an equivalent node address if one is currently retained.
    pub fn get(registry: *Registry, bytes: []const u8) ?u64;

    /// Records a serialized node and evicts old entries from the target bucket.
    pub fn put(
        registry: *Registry,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        address: u64,
    ) OOM!void;
};

const std = @import("std");

const OOM = std.mem.Allocator.Error;
```

- [ ] **Step 2: Add registry tests**

Tests must prove:

- equal bytes reuse the first address;
- different bytes do not collide semantically even when hashes share a bucket;
- entries beyond `entries_per_bucket` are evicted.

- [ ] **Step 3: Run registry tests**

Run:

```bash
zig build -Dtest-filter=Registry test
```

Expected: registry tests pass.

- [ ] **Step 4: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 5: Commit registry**

```bash
git add src/fysti/registry.zig
git commit -m "feat(fysti): Add node registry"
```

## Task 8: Implement Builder Core

**Files:**
- Modify: `src/fysti/builder.zig`
- Modify: `src/fysti/node.zig`
- Modify: `src/fysti/crc32.zig`

- [ ] **Step 1: Replace the builder stub with real state**

The builder must store:

- `writer: *std.Io.Writer`;
- `buffer: std.ArrayList(u8)`;
- `last_key: std.ArrayList(u8)`;
- `unfinished: std.ArrayList(Unfinished)`;
- `registry: registry.Registry`;
- `len: u64`;
- `last_addr: u64`;
- `finished: bool`.

Every field needs a what/why comment.

- [ ] **Step 2: Implement initialization and deinitialization**

Use explicit declaration literals. Do not add default field values to structs.

Required shape:

```zig
/// Initializes a builder and writes the v3 header into the internal buffer.
pub fn init(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    kind: Kind,
    registry_config: RegistryConfig,
) (OOM || std.Io.Writer.Error)!Self

/// Releases all builder-owned temporary state.
pub fn deinit(builder: *Self, allocator: std.mem.Allocator) void
```

`RegistryConfig` must require explicit fields:

```zig
/// Explicit registry sizing for bounded node reuse.
pub const RegistryConfig = struct {
    /// Number of hash buckets retained by the registry.
    bucket_count: usize,

    /// Number of recently seen nodes retained per bucket.
    entries_per_bucket: usize,
};
```

Call sites use:

```zig
.{ .bucket_count = 10_000, .entries_per_bucket = 2 }
```

- [ ] **Step 3: Implement `insert`**

Required shape:

```zig
/// Inserts one sorted key/value pair into the unfinished transducer.
pub fn insert(
    builder: *Self,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: V,
) (OOM || std.Io.Writer.Error || output.Error || error{
    InputNotSorted,
    DuplicateKey,
})!void
```

Rules:

- compare `key` to `last_key`;
- `Builder(void)` tolerates equal keys by returning success without changing the graph;
- `Builder(u64)` returns `error.DuplicateKey` on equal keys;
- smaller keys return `error.InputNotSorted`;
- common-prefix and output factoring follow upstream `raw/build.rs:390` and `raw/build.rs:399`;
- compile closed suffixes before appending new suffix nodes.

- [ ] **Step 4: Implement suffix compilation and node reuse**

Required helper shapes:

```zig
/// Compiles unfinished nodes deeper than `prefix_len`.
fn compileFrom(
    builder: *Self,
    allocator: std.mem.Allocator,
    prefix_len: usize,
) (OOM || std.Io.Writer.Error)!void

/// Serializes or reuses one completed node.
fn compileNode(
    builder: *Self,
    allocator: std.mem.Allocator,
    unfinished: node.UnfinishedNode,
) (OOM || std.Io.Writer.Error)!u64
```

`compileNode` must:

- encode with `node.encode`;
- ask registry for equivalent bytes;
- write bytes when no equivalent exists;
- compute address as last-byte index;
- record in registry.

- [ ] **Step 5: Implement `finish`**

Required shape:

```zig
/// Completes the fst by compiling the root and writing the v3 trailer.
pub fn finish(
    builder: *Self,
    allocator: std.mem.Allocator,
) (OOM || std.Io.Writer.Error)!void
```

`finish` must:

- compile all unfinished nodes;
- write `len`;
- write `root_addr`;
- write masked CRC32C checksum over all bytes before the checksum;
- write the completed internal byte buffer to `writer`;
- flush the writer.

The first implementation keeps emitted bytes in `buffer` until `finish`, because
the checksum is over the entire file prefix. Do not add a tee writer in this
milestone.

- [ ] **Step 6: Add builder tests**

Tests:

- empty set writes a valid v3 header/trailer;
- single-key set can be built;
- duplicate set key succeeds;
- duplicate map key returns `error.DuplicateKey`;
- unsorted key returns `error.InputNotSorted`;
- map insert with increasing values builds without output overflow.

- [ ] **Step 7: Run builder tests**

Run:

```bash
zig build -Dtest-filter=Builder test
```

Expected: builder tests pass.

- [ ] **Step 8: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 9: Commit builder core**

```bash
git add src/fysti/builder.zig src/fysti/node.zig src/fysti/crc32.zig
git commit -m "feat(fysti): Add builder core"
```

## Task 9: Implement Fst View and Exact Lookup

**Files:**
- Modify: `src/fysti/fst.zig`
- Modify: `src/fysti.zig`
- Modify: `src/fysti/test_fixtures.zig`

- [ ] **Step 1: Implement metadata parsing**

Required constants:

```zig
/// Serialized fst version implemented by fysti.
pub const version: u64 = 3;

/// Number of bytes in the v3 header.
pub const header_len: usize = 16;

/// Number of bytes in the v3 trailer.
pub const trailer_len: usize = 20;
```

Required fields for `Fst(V)`:

- `data: []const u8`;
- `kind: Kind`;
- `len: u64`;
- `root_addr: u64`;
- `checksum: u32`.

`init(bytes)` asserts:

- `bytes.len >= header_len + trailer_len`;
- `version == 3`;
- `root_addr < bytes.len`;
- `kind` matches `V`.

- [ ] **Step 2: Implement exact lookup**

Required public methods:

```zig
/// Returns whether `key` exists in a set fst.
pub fn contains(fst: Self, key: []const u8) bool

/// Returns the map value for `key`, or null when absent.
pub fn get(fst: Self, key: []const u8) ?u64
```

For `Fst(void)`, `get` should not exist or should comptime-error with a clear
message. For `Fst(u64)`, `contains` may call `get`.

- [ ] **Step 3: Implement explicit checksum verification**

Required method:

```zig
/// Recomputes and compares the v3 trailer checksum.
pub fn verify(fst: Self) error{InvalidChecksum}!void
```

`verify()` is the only public malformed-data-style error in this milestone.

- [ ] **Step 4: Add builder-to-reader tests**

Tests:

- build `SetBuilder`, open `Set`, call `verify`, `contains`;
- build `MapBuilder`, open `Map`, call `verify`, `get`;
- absent key returns false/null;
- `Fst(void).get` fails at comptime if exposed accidentally;
- `Fst(u64).contains` returns true for existing map key.

- [ ] **Step 5: Run lookup tests**

Run:

```bash
zig build -Dtest-filter=lookup test
zig build -Dtest-filter=verify test
```

Expected: lookup and verification tests pass.

- [ ] **Step 6: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 7: Commit read view**

```bash
git add src/fysti/fst.zig src/fysti.zig src/fysti/test_fixtures.zig
git commit -m "feat(fysti): Add exact lookup"
```

## Task 10: Add Rust Compatibility Fixture Checks

**Files:**
- Create: `tools/fysti-rust-fixtures/README.md`
- Create: `tools/fysti-rust-fixtures/Cargo.toml`
- Create: `tools/fysti-rust-fixtures/src/main.rs`
- Modify: `src/fysti/test_fixtures.zig`

- [ ] **Step 1: Create a local fixture helper crate**

The helper crate must depend on the local upstream checkout by path, not by a
network fetch. `Cargo.toml`:

```toml
[package]
name = "fysti-rust-fixtures"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
fst = { path = "/private/tmp/codex-project-state/memex/fysti/fst" }
```

- [ ] **Step 2: Add fixture generator**

`src/main.rs` should:

- build a set with `["a", "ab", "b"]`;
- build a map with `[("a", 1), ("ab", 3), ("b", 10)]`;
- write byte arrays as Zig declarations to stdout.

- [ ] **Step 3: Generate fixture output**

Run:

```bash
cargo run --manifest-path tools/fysti-rust-fixtures/Cargo.toml
```

Expected: stdout contains Zig byte arrays for set and map fixtures.

Cargo must resolve the `fst` dependency from the local upstream clone. A network
fetch means the manifest is wrong.

- [ ] **Step 4: Copy generated fixture arrays into `test_fixtures.zig`**

Add comments naming the upstream revision and command used. Do not check in the
upstream Rust repository.

- [ ] **Step 5: Add Zig tests for Rust-written bytes**

Tests:

- `Set.init(rust_set_fixture).verify()` passes;
- set contains `a`, `ab`, and `b`;
- `Map.init(rust_map_fixture).verify()` passes;
- map returns `1`, `3`, and `10`.

- [ ] **Step 6: Add Rust check for Zig-written bytes**

Use the helper crate to read a Zig-generated fixture file written by a small
temporary Zig test or command. The check must prove Rust `fst` can open and
query bytes written by `Builder(void)` and `Builder(u64)`.

- [ ] **Step 7: Run compatibility checks**

Run:

```bash
zig build -Dtest-filter=fixture test
cargo run --manifest-path tools/fysti-rust-fixtures/Cargo.toml -- check-zig
```

Expected: Zig reads Rust-written fixtures and Rust reads Zig-written fixtures.

- [ ] **Step 8: Run all tests**

Run:

```bash
zig build test
```

Expected: all Zig tests pass.

- [ ] **Step 9: Commit compatibility fixtures**

```bash
git add tools/fysti-rust-fixtures src/fysti/test_fixtures.zig
git commit -m "test(fysti): Add Rust compatibility fixtures"
```

## Task 11: Style, Documentation, and Full Verification

**Files:**
- Modify: any `src/fysti*.zig` files with missing comments or style issues
- Modify: `docs/superpowers/specs/2026-05-26-fysti-design.md` only if implementation reveals a design correction

- [ ] **Step 1: Comment audit**

Run:

```bash
rg -n "^(pub )?(const|var|fn|pub fn|pub const)|^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:" src/fysti.zig src/fysti
```

Expected: every function and every struct field has an immediately useful
comment explaining what and why. Add missing comments before proceeding.

- [ ] **Step 2: Default-value audit**

Run:

```bash
rg -n "= (null|false|true|0|\\.\\{|\\.empty)" src/fysti.zig src/fysti
```

Expected: no struct field default values. Declaration literals at use sites are
fine and expected.

- [ ] **Step 3: OOM spelling audit**

Run:

```bash
rg -n "Allocator\\.Error|OutOfMemory" src/fysti.zig src/fysti
```

Expected: allocator errors are introduced through `const OOM =
std.mem.Allocator.Error;`. Public prose may mention OOM, but code should not
spell allocator failures another way unless matching stdlib signatures.

- [ ] **Step 4: Format Zig files**

Run:

```bash
zig fmt src/fysti.zig src/fysti/*.zig build.zig
```

Expected: formatting completes without errors.

- [ ] **Step 5: Run narrow fysti tests**

Run:

```bash
zig build -Dtest-filter=fysti test
```

Expected: fysti-focused tests pass.

- [ ] **Step 6: Run all tests**

Run:

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 7: Run compatibility helper**

Run:

```bash
cargo run --manifest-path tools/fysti-rust-fixtures/Cargo.toml -- check-zig
```

Expected: Rust can open and query Zig-written v3 bytes.

- [ ] **Step 8: Commit final cleanup**

```bash
git add build.zig src/fysti.zig src/fysti docs/superpowers/specs/2026-05-26-fysti-design.md
git commit -m "style(fysti): Finish builder milestone cleanup"
```

Create this commit only when cleanup changed files.

## Self-Review Notes

- Spec coverage: the plan covers v3-only source contract, public `Fst(V)` and
  `Builder(V)`, `void`/`u64` value families, shared format core, builder-first
  flow, exact lookup, explicit verification, compatibility fixtures, and the
  iterator deferral.
- User notes coverage: the plan includes no field defaults, declaration literal
  use, OOM spelling, and required function/field comments.
- Scope: iterator, range search, automata, regex, Levenshtein, and set
  operations are intentionally out of this builder milestone.
