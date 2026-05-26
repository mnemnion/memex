//! Public builder core for fst v3 bytes.

/// Serialized fst version implemented by this builder.
pub const version: u64 = 3;

/// Conventional v3 type value stored in header bytes 8 through 15.
pub const Kind = enum(u64) {
    /// Upstream reserves the kind range but uses zero for sets and maps.
    unspecified = 0,
};

/// Explicit registry sizing for bounded node reuse.
pub const RegistryConfig = struct {
    /// Number of hash buckets retained by the registry.
    bucket_count: usize,

    /// Number of recently seen nodes retained per bucket.
    entries_per_bucket: usize,
};

/// Returns a builder type for a supported value family.
pub fn Builder(comptime V: type) type {
    if (V != void and V != u64) {
        @compileError("fysti.Builder only supports void and u64 values");
    }

    return struct {
        const Self = @This();

        /// Caller-owned writer that receives the complete fst once checksum bytes exist.
        writer: *std.Io.Writer,

        /// Builder-owned serialized bytes kept so the trailer checksum can cover the prefix.
        buffer: std.ArrayList(u8),

        /// Last accepted key used to enforce upstream's sorted-input construction rule.
        last_key: std.ArrayList(u8),

        /// Mutable frontier of trie states that may still receive transitions.
        unfinished: std.ArrayList(Unfinished),

        /// Bounded cache of already serialized nodes used for suffix reuse.
        registry: registry.Registry,

        /// Number of distinct keys accepted into the builder.
        len: u64,

        /// Address of the most recently serialized node for OneTransNext encoding.
        last_addr: u64,

        /// Whether `finish` has already emitted bytes to the caller-owned writer.
        finished: bool,

        /// Initializes a builder and writes the v3 header into the internal buffer.
        pub fn init(
            allocator: std.mem.Allocator,
            writer: *std.Io.Writer,
            kind: Kind,
            registry_config: RegistryConfig,
        ) (OOM || std.Io.Writer.Error)!Self {
            var buffer: std.ArrayList(u8) = .empty;
            errdefer buffer.deinit(allocator);
            try appendU64(allocator, &buffer, version);
            try appendU64(allocator, &buffer, @intFromEnum(kind));

            var last_key: std.ArrayList(u8) = .empty;
            errdefer last_key.deinit(allocator);

            var unfinished: std.ArrayList(Unfinished) = .empty;
            errdefer deinitUnfinishedList(&unfinished, allocator);
            try unfinished.append(allocator, initUnfinished(false));

            var reg = try registry.Registry.init(
                allocator,
                registry_config.bucket_count,
                registry_config.entries_per_bucket,
            );
            errdefer reg.deinit(allocator);

            return .{
                .writer = writer,
                .buffer = buffer,
                .last_key = last_key,
                .unfinished = unfinished,
                .registry = reg,
                .len = 0,
                .last_addr = node.none_address,
                .finished = false,
            };
        }

        /// Releases all builder-owned temporary state.
        pub fn deinit(builder: *Self, allocator: std.mem.Allocator) void {
            builder.registry.deinit(allocator);
            deinitUnfinishedList(&builder.unfinished, allocator);
            builder.last_key.deinit(allocator);
            builder.buffer.deinit(allocator);
            builder.* = undefined;
        }

        /// Inserts one sorted key/value pair into the unfinished transducer.
        pub fn insert(
            builder: *Self,
            allocator: std.mem.Allocator,
            key: []const u8,
            value: V,
        ) (OOM || std.Io.Writer.Error || output.Error || error{
            InputNotSorted,
            DuplicateKey,
        })!void {
            std.debug.assert(!builder.finished);

            if (builder.len > 0) {
                switch (std.mem.order(u8, key, builder.last_key.items)) {
                    .eq => {
                        if (V == void) {
                            return;
                        }
                        return error.DuplicateKey;
                    },
                    .lt => return error.InputNotSorted,
                    .gt => {},
                }
            }

            try builder.insertOutput(allocator, key, output.Output.fromValue(V, value));
            try builder.last_key.replaceRange(allocator, 0, builder.last_key.items.len, key);
        }

        /// Completes the fst by compiling the root and writing the v3 trailer.
        pub fn finish(
            builder: *Self,
            allocator: std.mem.Allocator,
        ) (OOM || std.Io.Writer.Error)!void {
            if (builder.finished) {
                return;
            }

            try builder.compileFrom(allocator, 0);
            std.debug.assert(builder.unfinished.items.len == 1);
            var root = builder.unfinished.pop().?;
            defer root.node.deinit(allocator);
            std.debug.assert(root.last == null);

            const root_addr = try builder.compileNode(allocator, root.node);
            try appendU64(allocator, &builder.buffer, builder.len);
            try appendU64(allocator, &builder.buffer, root_addr);
            try appendU32(allocator, &builder.buffer, crc32.checksum(builder.buffer.items));

            try builder.writer.writeAll(builder.buffer.items);
            try builder.writer.flush();
            builder.finished = true;
        }

        /// Inserts `key` after sortedness has been checked and factors map output.
        fn insertOutput(
            builder: *Self,
            allocator: std.mem.Allocator,
            key: []const u8,
            out: output.Output,
        ) (OOM || std.Io.Writer.Error || output.Error)!void {
            if (key.len == 0) {
                builder.len = 1;
                builder.unfinished.items[0].node.final_output = out;
                return;
            }

            const prefix_result = if (V == u64)
                try builder.findCommonPrefixAndSetOutput(key, out)
            else
                CommonPrefixResult{
                    .len = builder.findCommonPrefix(key),
                    .remaining_output = output.Output.zero(),
                };

            if (prefix_result.len == key.len) {
                std.debug.assert(prefix_result.remaining_output.value == 0);
                return;
            }

            builder.len += 1;
            try builder.compileFrom(allocator, prefix_result.len);
            try builder.addSuffix(allocator, key[prefix_result.len..], prefix_result.remaining_output);
        }

        /// Compiles unfinished nodes deeper than `prefix_len`.
        fn compileFrom(
            builder: *Self,
            allocator: std.mem.Allocator,
            prefix_len: usize,
        ) (OOM || std.Io.Writer.Error)!void {
            var addr = node.none_address;
            while (prefix_len + 1 < builder.unfinished.items.len) {
                var popped = builder.unfinished.pop().?;
                errdefer popped.node.deinit(allocator);

                if (addr == node.none_address) {
                    std.debug.assert(popped.last == null);
                } else {
                    try popped.freezeLast(allocator, addr);
                }

                addr = try builder.compileNode(allocator, popped.node);
                popped.node.deinit(allocator);
                std.debug.assert(addr != node.none_address);
            }
            try builder.topLastFreeze(allocator, addr);
        }

        /// Serializes or reuses one completed node.
        fn compileNode(
            builder: *Self,
            allocator: std.mem.Allocator,
            unfinished: node.UnfinishedNode,
        ) (OOM || std.Io.Writer.Error)!u64 {
            if (unfinished.final_output) |final_output| {
                if (unfinished.transitions.items.len == 0 and final_output.value == 0) {
                    return node.empty_address;
                }
            }

            if (builder.registry.get(&unfinished)) |addr| {
                return addr;
            }

            const node_start_addr: u64 = @intCast(builder.buffer.items.len);
            const encoded = try node.encode(allocator, unfinished, node_start_addr, builder.last_addr);
            defer allocator.free(encoded);

            try builder.buffer.appendSlice(allocator, encoded);
            const addr = node_start_addr + encoded.len - 1;
            builder.last_addr = addr;
            try builder.registry.put(allocator, &unfinished, addr);
            return addr;
        }

        /// Returns the active-prefix length shared with `key` for set construction.
        fn findCommonPrefix(builder: *Self, key: []const u8) usize {
            var len: usize = 0;
            while (len < key.len and len < builder.unfinished.items.len) : (len += 1) {
                const last = builder.unfinished.items[len].last orelse break;
                if (last.input != key[len]) {
                    break;
                }
            }
            return len;
        }

        /// Factors a map output across the existing active prefix and returns the suffix output.
        fn findCommonPrefixAndSetOutput(
            builder: *Self,
            key: []const u8,
            original_out: output.Output,
        ) (output.Error)!CommonPrefixResult {
            var len: usize = 0;
            var out = original_out;
            while (len < key.len and len < builder.unfinished.items.len) {
                const last = &builder.unfinished.items[len].last;
                if (last.* == null or last.*.?.input != key[len]) {
                    break;
                }

                len += 1;
                const common_prefix = last.*.?.out.prefix(out);
                const add_prefix = output.Output.sub(last.*.?.out, common_prefix);
                out = output.Output.sub(out, common_prefix);
                last.*.?.out = common_prefix;

                if (add_prefix.value != 0) {
                    try builder.unfinished.items[len].addOutputPrefix(add_prefix);
                }
            }

            return .{
                .len = len,
                .remaining_output = out,
            };
        }

        /// Adds new active suffix nodes after all closed suffixes have been compiled.
        fn addSuffix(
            builder: *Self,
            allocator: std.mem.Allocator,
            suffix: []const u8,
            out: output.Output,
        ) OOM!void {
            if (suffix.len == 0) {
                return;
            }

            const last_index = builder.unfinished.items.len - 1;
            std.debug.assert(builder.unfinished.items[last_index].last == null);
            builder.unfinished.items[last_index].last = .{
                .input = suffix[0],
                .out = out,
            };

            for (suffix[1..]) |byte| {
                try builder.unfinished.append(allocator, .{
                    .node = initNode(false),
                    .last = .{
                        .input = byte,
                        .out = output.Output.zero(),
                    },
                });
            }

            try builder.unfinished.append(allocator, initUnfinished(true));
        }

        /// Freezes the top pending transition when a compiled child address exists.
        fn topLastFreeze(
            builder: *Self,
            allocator: std.mem.Allocator,
            addr: u64,
        ) OOM!void {
            const last_index = builder.unfinished.items.len - 1;
            if (builder.unfinished.items[last_index].last != null) {
                std.debug.assert(addr != node.none_address);
                try builder.unfinished.items[last_index].freezeLast(allocator, addr);
            }
        }
    };
}

/// One unfinished stack entry matching upstream's mutable node plus pending edge.
const Unfinished = struct {
    /// Node body with already frozen transitions that can still receive prefixes.
    node: node.UnfinishedNode,

    /// Latest not-yet-frozen transition on the sorted active key path.
    last: ?LastTransition,

    /// Moves the pending transition into the sorted transition list with a child address.
    fn freezeLast(unfinished: *Unfinished, allocator: std.mem.Allocator, addr: u64) OOM!void {
        if (unfinished.last) |last| {
            try unfinished.node.transitions.append(allocator, .{
                .input = last.input,
                .out = last.out,
                .addr = addr,
            });
            unfinished.last = null;
        }
    }

    /// Pushes an output prefix through final, frozen, and pending outputs below this state.
    fn addOutputPrefix(unfinished: *Unfinished, prefix: output.Output) output.Error!void {
        if (unfinished.node.final_output) |final_output| {
            unfinished.node.final_output = try prefix.cat(final_output);
        }

        for (unfinished.node.transitions.items) |*trans| {
            trans.out = try prefix.cat(trans.out);
        }

        if (unfinished.last) |*last| {
            last.out = try prefix.cat(last.out);
        }
    }
};

/// Pending transition retained until its destination address is known.
const LastTransition = struct {
    /// Input byte that labels the pending edge.
    input: u8,

    /// Output emitted by the pending edge before any destination final output.
    out: output.Output,
};

/// Result of common-prefix discovery plus remaining suffix output.
const CommonPrefixResult = struct {
    /// Number of input bytes already represented by the unfinished stack.
    len: usize,

    /// Output that still belongs on the newly appended suffix.
    remaining_output: output.Output,
};

/// Creates an unfinished stack entry with no pending transition.
fn initUnfinished(is_final: bool) Unfinished {
    return .{
        .node = initNode(is_final),
        .last = null,
    };
}

/// Creates a builder-side node with finality encoded as optional output.
fn initNode(is_final: bool) node.UnfinishedNode {
    return .{
        .final_output = if (is_final) output.Output.zero() else null,
        .transitions = .empty,
    };
}

/// Releases every unfinished node and then the stack storage.
fn deinitUnfinishedList(list: *std.ArrayList(Unfinished), allocator: std.mem.Allocator) void {
    for (list.items) |*unfinished| {
        unfinished.node.deinit(allocator);
    }
    list.deinit(allocator);
}

/// Appends one little-endian v3 `u64` field to a growable byte buffer.
fn appendU64(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: u64) OOM!void {
    var raw: [8]u8 = undefined;
    bytes.writeU64(&raw, value);
    try buffer.appendSlice(allocator, &raw);
}

/// Appends one little-endian v3 `u32` field to a growable byte buffer.
fn appendU32(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: u32) OOM!void {
    var raw: [4]u8 = undefined;
    bytes.writeU32(&raw, value);
    try buffer.appendSlice(allocator, &raw);
}

test "Builder empty set writes a valid v3 header and trailer" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expect(built.len >= 36);
    try std.testing.expectEqual(@as(u64, 3), bytes.readU64(built[0..8]));
    try std.testing.expectEqual(@as(u64, 0), bytes.readU64(built[8..16]));
    try std.testing.expectEqual(@as(u64, 0), bytes.readU64(built[built.len - 20 ..][0..8]));
    try std.testing.expectEqual(
        bytes.readU32(built[built.len - 4 ..][0..4]),
        crc32.checksum(built[0 .. built.len - 4]),
    );
}

test "Builder single-key set can be built" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "a", {});
    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expect(built.len > 36);
    try std.testing.expectEqual(@as(u64, 1), bytes.readU64(built[built.len - 20 ..][0..8]));
}

test "Builder duplicate set key succeeds" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "same", {});
    try builder.insert(std.testing.allocator, "same", {});
    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expectEqual(@as(u64, 1), bytes.readU64(built[built.len - 20 ..][0..8]));
}

test "Builder duplicate map key returns DuplicateKey" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(u64).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "same", 1);
    try std.testing.expectError(error.DuplicateKey, builder.insert(std.testing.allocator, "same", 2));
}

test "Builder unsorted key returns InputNotSorted" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "b", {});
    try std.testing.expectError(error.InputNotSorted, builder.insert(std.testing.allocator, "a", {}));
}

test "Builder map insert with increasing values builds without output overflow" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(u64).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "a", 1);
    try builder.insert(std.testing.allocator, "ab", 2);
    try builder.insert(std.testing.allocator, "b", 100);
    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expectEqual(@as(u64, 3), bytes.readU64(built[built.len - 20 ..][0..8]));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const crc32 = @import("crc32.zig");
const node = @import("node.zig");
const output = @import("output.zig");
const registry = @import("registry.zig");
