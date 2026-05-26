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

        /// Whether root/trailer finalization succeeded; finish may still retry writer output.
        finalized: bool,

        /// Whether finalization failed after mutating graph state; insert/finish may not continue.
        finalize_failed: bool,

        /// Number of final bytes already accepted by the caller-owned writer.
        finish_written_len: usize,

        /// Whether `finish` has successfully flushed the caller-owned writer.
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
                .finalized = false,
                .finalize_failed = false,
                .finish_written_len = 0,
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
            std.debug.assert(!builder.finalized);
            std.debug.assert(!builder.finalize_failed);

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
            std.debug.assert(!builder.finalize_failed);

            if (builder.finished) {
                return;
            }

            if (!builder.finalized) {
                try builder.finalize(allocator);
            }
            try builder.writeFinalBytes();
            try builder.writer.flush();
            builder.finished = true;
        }

        /// Completes internal bytes once; later finish retries only emit/flush.
        fn finalize(
            builder: *Self,
            allocator: std.mem.Allocator,
        ) (OOM || std.Io.Writer.Error)!void {
            errdefer builder.finalize_failed = true;

            try builder.compileFrom(allocator, 0);
            std.debug.assert(builder.unfinished.items.len == 1);
            const root = &builder.unfinished.items[0];
            std.debug.assert(root.last == null);

            const root_addr = try builder.compileNode(allocator, root.node);
            const trailer_start = builder.buffer.items.len;
            errdefer builder.buffer.shrinkRetainingCapacity(trailer_start);

            try appendU64(allocator, &builder.buffer, builder.len);
            try appendU64(allocator, &builder.buffer, root_addr);
            try appendU32(allocator, &builder.buffer, crc32.checksum(builder.buffer.items));

            builder.finalized = true;
        }

        /// Emits any final bytes that were not accepted by a prior finish attempt.
        fn writeFinalBytes(builder: *Self) std.Io.Writer.Error!void {
            while (builder.finish_written_len < builder.buffer.items.len) {
                const written = try builder.writer.write(builder.buffer.items[builder.finish_written_len..]);
                builder.finish_written_len += written;
            }
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

/// Returns the root address stored in a complete v3 trailer.
fn rootAddress(built: []const u8) u64 {
    return bytes.readU64(built[built.len - 12 ..][0..8]);
}

/// Test writer that can fail after accepting bytes so finish retry proves resume.
const ControlledFailingWriter = struct {
    out: std.Io.Writer.Allocating,
    writer: std.Io.Writer,
    max_chunk_len: usize,
    successful_drains_before_failure: usize,
    write_failures_remaining: usize,
    flush_failures_remaining: usize,

    fn init(
        allocator: std.mem.Allocator,
        max_chunk_len: usize,
        successful_drains_before_failure: usize,
        write_failures_remaining: usize,
        flush_failures_remaining: usize,
    ) ControlledFailingWriter {
        std.debug.assert(max_chunk_len > 0);
        return .{
            .out = std.Io.Writer.Allocating.init(allocator),
            .writer = .{
                .buffer = &.{},
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
            },
            .max_chunk_len = max_chunk_len,
            .successful_drains_before_failure = successful_drains_before_failure,
            .write_failures_remaining = write_failures_remaining,
            .flush_failures_remaining = flush_failures_remaining,
        };
    }

    fn deinit(controlled: *ControlledFailingWriter) void {
        controlled.out.deinit();
    }

    fn written(controlled: *ControlledFailingWriter) []const u8 {
        return controlled.out.written();
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const controlled: *ControlledFailingWriter = @alignCast(@fieldParentPtr("writer", w));
        std.debug.assert(data.len == 1);
        std.debug.assert(splat == 1);

        if (controlled.write_failures_remaining > 0 and
            controlled.successful_drains_before_failure == 0)
        {
            controlled.write_failures_remaining -= 1;
            return error.WriteFailed;
        }

        const accepted = @min(controlled.max_chunk_len, data[0].len);
        try controlled.out.writer.writeAll(data[0][0..accepted]);
        if (controlled.successful_drains_before_failure > 0) {
            controlled.successful_drains_before_failure -= 1;
        }
        return accepted;
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const controlled: *ControlledFailingWriter = @alignCast(@fieldParentPtr("writer", w));
        if (controlled.flush_failures_remaining > 0) {
            controlled.flush_failures_remaining -= 1;
            return error.WriteFailed;
        }
        try controlled.out.writer.flush();
    }
};

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

test "Builder empty set key can be built" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "", {});
    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expectEqual(@as(u64, 1), bytes.readU64(built[built.len - 20 ..][0..8]));
    try std.testing.expectEqual(node.empty_address, rootAddress(built));
}

test "Builder duplicate empty set key succeeds" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "", {});
    try builder.insert(std.testing.allocator, "", {});
    try builder.finish(std.testing.allocator);

    const built = out.written();
    try std.testing.expectEqual(@as(u64, 1), bytes.readU64(built[built.len - 20 ..][0..8]));
}

test "Builder duplicate empty map key returns DuplicateKey" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(u64).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "", 1);
    try std.testing.expectError(error.DuplicateKey, builder.insert(std.testing.allocator, "", 2));
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

test "Builder finish retry resumes after recoverable write failure" {
    var controlled = ControlledFailingWriter.init(std.testing.allocator, 7, 1, 1, 0);
    defer controlled.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &controlled.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "abc", {});
    try builder.insert(std.testing.allocator, "xbc", {});

    try std.testing.expectError(error.WriteFailed, builder.finish(std.testing.allocator));
    try std.testing.expect(builder.finalized);
    try std.testing.expect(!builder.finished);
    try std.testing.expectEqual(controlled.written().len, builder.finish_written_len);

    try builder.finish(std.testing.allocator);
    try std.testing.expect(builder.finished);

    var reference = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer reference.deinit();
    var reference_builder = try Builder(void).init(
        std.testing.allocator,
        &reference.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer reference_builder.deinit(std.testing.allocator);
    try reference_builder.insert(std.testing.allocator, "abc", {});
    try reference_builder.insert(std.testing.allocator, "xbc", {});
    try reference_builder.finish(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, reference.written(), controlled.written());
}

test "Builder finish retry only flushes after recoverable flush failure" {
    var controlled = ControlledFailingWriter.init(std.testing.allocator, 4096, 4096, 0, 1);
    defer controlled.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &controlled.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "abc", {});
    try builder.insert(std.testing.allocator, "xbc", {});

    try std.testing.expectError(error.WriteFailed, builder.finish(std.testing.allocator));
    try std.testing.expect(builder.finalized);
    try std.testing.expect(!builder.finished);
    try std.testing.expectEqual(builder.buffer.items.len, builder.finish_written_len);
    const len_after_failed_flush = controlled.written().len;

    try builder.finish(std.testing.allocator);
    try std.testing.expect(builder.finished);
    try std.testing.expectEqual(len_after_failed_flush, controlled.written().len);
}

test "Builder finalization allocation failure marks builder terminal" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "abc", {});
    try builder.insert(std.testing.allocator, "xbc", {});

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
    });
    try std.testing.expectError(error.OutOfMemory, builder.finish(failing.allocator()));
    try std.testing.expect(builder.finalize_failed);
    try std.testing.expect(!builder.finalized);
    try std.testing.expect(!builder.finished);
}

test "Builder reuses equivalent address-sensitive suffix nodes semantically" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var builder = try Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer builder.deinit(std.testing.allocator);

    try builder.insert(std.testing.allocator, "abc", {});
    try builder.insert(std.testing.allocator, "xbc", {});
    try builder.finish(std.testing.allocator);

    const built = out.written();
    const root = node.Node.init(built, rootAddress(built));
    try std.testing.expectEqual(@as(usize, 2), root.transitionCount());

    const first = root.transition(0);
    const second = root.transition(1);
    try std.testing.expectEqual(@as(u8, 'a'), first.input);
    try std.testing.expectEqual(@as(u8, 'x'), second.input);
    try std.testing.expectEqual(first.addr, second.addr);

    const shared = node.Node.init(built, first.addr);
    try std.testing.expectEqual(@as(usize, 1), shared.transitionCount());
    try std.testing.expectEqual(@as(u8, 'b'), shared.transition(0).input);
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const crc32 = @import("crc32.zig");
const node = @import("node.zig");
const output = @import("output.zig");
const registry = @import("registry.zig");
