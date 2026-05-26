//! Public read view for fst v3 bytes.
/// Serialized fst version implemented by fysti.
pub const version: u64 = 3;

/// Number of bytes in the v3 header.
pub const header_len: usize = 16;

/// Number of bytes in the v3 trailer.
pub const trailer_len: usize = 20;

/// Conventional v3 kind value shared with the builder.
pub const Kind = builder.Kind;

/// Returns a read-view type for a supported value family.
pub fn Fst(comptime V: type) type {
    if (V != void and V != u64) {
        @compileError("fysti.Fst only supports void and u64 values");
    }

    if (V == void) {
        return struct {
            const SetFst = @This();

            /// Serialized fst v3 bytes owned by the caller.
            data: []const u8,

            /// Conventional type marker stored in header bytes 8 through 15.
            kind: Kind,

            /// Number of keys recorded by the v3 trailer.
            len: u64,

            /// Address of the root node's final byte.
            root_addr: u64,

            /// Masked CRC32C checksum stored in the v3 trailer.
            checksum: u32,

            /// Initializes a non-owning set view over caller-owned v3 bytes.
            pub fn init(data: []const u8) SetFst {
                const parsed = parseMetadata(V, data);
                return .{
                    .data = data,
                    .kind = parsed.kind,
                    .len = parsed.len,
                    .root_addr = parsed.root_addr,
                    .checksum = parsed.checksum,
                };
            }

            /// Returns whether `key` exists in a set fst.
            pub fn contains(fst: SetFst, key: []const u8) bool {
                return containsKey(fst.data, fst.root_addr, key);
            }

            /// Recomputes and compares the v3 trailer checksum.
            pub fn verify(fst: SetFst) error{InvalidChecksum}!void {
                return verifyChecksum(fst.data, fst.checksum);
            }
        };
    }

    return struct {
        const MapFst = @This();

        /// Serialized fst v3 bytes owned by the caller.
        data: []const u8,

        /// Conventional type marker stored in header bytes 8 through 15.
        kind: Kind,

        /// Number of keys recorded by the v3 trailer.
        len: u64,

        /// Address of the root node's final byte.
        root_addr: u64,

        /// Masked CRC32C checksum stored in the v3 trailer.
        checksum: u32,

        /// Initializes a non-owning map view over caller-owned v3 bytes.
        pub fn init(data: []const u8) MapFst {
            const parsed = parseMetadata(V, data);
            return .{
                .data = data,
                .kind = parsed.kind,
                .len = parsed.len,
                .root_addr = parsed.root_addr,
                .checksum = parsed.checksum,
            };
        }

        /// Returns whether `key` exists in a map fst.
        pub fn contains(fst: MapFst, key: []const u8) bool {
            return fst.get(key) != null;
        }

        /// Returns the map value for `key`, or null when absent.
        pub fn get(fst: MapFst, key: []const u8) ?u64 {
            const out = lookupOutput(fst.data, fst.root_addr, key) orelse return null;
            return out.value;
        }

        /// Recomputes and compares the v3 trailer checksum.
        pub fn verify(fst: MapFst) error{InvalidChecksum}!void {
            return verifyChecksum(fst.data, fst.checksum);
        }
    };
}

/// Parsed v3 header and trailer metadata shared by set and map views.
const ParsedMetadata = struct {
    /// Conventional type marker stored in header bytes 8 through 15.
    kind: Kind,

    /// Number of keys recorded by the v3 trailer.
    len: u64,

    /// Address of the root node's final byte.
    root_addr: u64,

    /// Masked CRC32C checksum stored in the v3 trailer.
    checksum: u32,
};

/// Reads and asserts v3 metadata fields from caller-owned bytes.
fn parseMetadata(comptime V: type, data: []const u8) ParsedMetadata {
    std.debug.assert(data.len >= header_len + trailer_len);
    const got_version = bytes.readU64(data[0..8]);
    std.debug.assert(got_version == version);

    const kind = readKind(bytes.readU64(data[8..16]));
    std.debug.assert(kindMatchesValue(V, kind));

    const trailer = data[data.len - trailer_len ..];
    const root_addr = bytes.readU64(trailer[8..16]);
    std.debug.assert(root_addr < data.len);

    return .{
        .kind = kind,
        .len = bytes.readU64(trailer[0..8]),
        .root_addr = root_addr,
        .checksum = bytes.readU32(trailer[16..20]),
    };
}

/// Traverses an fst without accumulating transition outputs.
fn containsKey(data: []const u8, root_addr: u64, key: []const u8) bool {
    var current = node.Node.init(data, root_addr);
    for (key) |input| {
        const trans = current.findInput(input) orelse return false;
        current = node.Node.init(data, trans.addr);
    }
    return current.isFinal();
}

/// Traverses a map fst and accumulates transition plus final outputs.
fn lookupOutput(data: []const u8, root_addr: u64, key: []const u8) ?output.Output {
    var current = node.Node.init(data, root_addr);
    var out = output.Output.zero();
    for (key) |input| {
        const trans = current.findInput(input) orelse return null;
        out = output.Output.cat(out, trans.out) catch unreachable;
        current = node.Node.init(data, trans.addr);
    }
    if (!current.isFinal()) {
        return null;
    }
    return output.Output.cat(out, current.finalOutput()) catch unreachable;
}

/// Recomputes and compares the v3 checksum stored after the trailer metadata.
fn verifyChecksum(data: []const u8, expected: u32) error{InvalidChecksum}!void {
    const got = crc32.checksum(data[0 .. data.len - 4]);
    if (got != expected) {
        return error.InvalidChecksum;
    }
}

/// Converts a raw v3 header kind into the shared builder enum.
fn readKind(raw: u64) Kind {
    std.debug.assert(raw == @intFromEnum(Kind.unspecified));
    return @enumFromInt(raw);
}

/// Checks that a header kind is compatible with the chosen value family.
fn kindMatchesValue(comptime V: type, kind: Kind) bool {
    if (kind != .unspecified) {
        return false;
    }
    return V == void or V == u64;
}

//| Tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "lookup set builder bytes verify and contain exact keys" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var set_builder = try builder.Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer set_builder.deinit(std.testing.allocator);

    for (test_fixtures.lookup_set_keys) |key| {
        try set_builder.insert(std.testing.allocator, key, {});
    }
    try set_builder.finish(std.testing.allocator);

    const set = Fst(void).init(out.written());
    try set.verify();
    try expectEqual(@as(u64, test_fixtures.lookup_set_keys.len), set.len);
    try expect(set.contains(""));
    try expect(set.contains("ant"));
    try expect(set.contains("cat"));
    try expect(set.contains("dog"));
    try expect(!set.contains("cow"));
}

test "lookup map builder bytes verify and return exact values" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var map_builder = try builder.Builder(u64).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer map_builder.deinit(std.testing.allocator);

    for (test_fixtures.lookup_map_entries) |entry| {
        try map_builder.insert(std.testing.allocator, entry.key, entry.value);
    }
    try map_builder.finish(std.testing.allocator);

    const map = Fst(u64).init(out.written());
    try map.verify();
    try expectEqual(@as(u64, test_fixtures.lookup_map_entries.len), map.len);
    try expectEqual(@as(?u64, 7), map.get(""));
    try expectEqual(@as(?u64, 10), map.get("ant"));
    try expectEqual(@as(?u64, 13), map.get("cat"));
    try expectEqual(@as(?u64, 21), map.get("dog"));
    try expectEqual(@as(?u64, null), map.get("cow"));
    try expect(map.contains("ant"));
}

test "lookup set read view does not expose map get" {
    try expect(!@hasDecl(Fst(void), "get"));
}

test "verify reports invalid checksum explicitly" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    var set_builder = try builder.Builder(void).init(
        std.testing.allocator,
        &out.writer,
        .unspecified,
        .{ .bucket_count = 10_000, .entries_per_bucket = 2 },
    );
    defer set_builder.deinit(std.testing.allocator);

    try set_builder.insert(std.testing.allocator, "key", {});
    try set_builder.finish(std.testing.allocator);

    const corrupted = try std.testing.allocator.dupe(u8, out.written());
    defer std.testing.allocator.free(corrupted);
    corrupted[corrupted.len - 1] ^= 0x01;

    const set = Fst(void).init(corrupted);
    try std.testing.expectError(error.InvalidChecksum, set.verify());
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const bytes = @import("bytes.zig");
const crc32 = @import("crc32.zig");
const node = @import("node.zig");
const output = @import("output.zig");
const builder = @import("builder.zig");
const test_fixtures = @import("test_fixtures.zig");
