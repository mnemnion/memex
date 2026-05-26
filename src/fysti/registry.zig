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
    ) OOM!Registry {
        const buckets = try allocator.alloc(std.ArrayList(Entry), bucket_count);
        errdefer allocator.free(buckets);

        for (buckets) |*bucket| {
            bucket.* = .empty;
        }

        return .{
            .buckets = buckets,
            .entries_per_bucket = entries_per_bucket,
        };
    }

    /// Releases all node bytes and bucket storage.
    pub fn deinit(registry: *Registry, allocator: std.mem.Allocator) void {
        for (registry.buckets) |*bucket| {
            for (bucket.items) |entry| {
                allocator.free(entry.bytes);
            }
            bucket.deinit(allocator);
        }

        allocator.free(registry.buckets);

        registry.* = .{
            .buckets = &.{},
            .entries_per_bucket = 0,
        };
    }

    /// Returns an equivalent node address if one is currently retained.
    pub fn get(registry: *Registry, bytes: []const u8) ?u64 {
        if (registry.buckets.len == 0 or registry.entries_per_bucket == 0) {
            return null;
        }

        const hash = hashBytes(bytes);
        const bucket = registry.bucketForHash(hash);
        const index = findEntryIndex(bucket, hash, bytes) orelse return null;
        const address = bucket.items[index].address;
        promoteEntry(bucket, index);
        return address;
    }

    /// Records a serialized node and evicts old entries from the target bucket.
    pub fn put(
        registry: *Registry,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        address: u64,
    ) OOM!void {
        if (registry.buckets.len == 0 or registry.entries_per_bucket == 0) {
            return;
        }

        const hash = hashBytes(bytes);
        const bucket = registry.bucketForHash(hash);

        if (findEntryIndex(bucket, hash, bytes)) |index| {
            promoteEntry(bucket, index);
            return;
        }

        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);

        try bucket.ensureUnusedCapacity(allocator, 1);

        if (bucket.items.len == registry.entries_per_bucket) {
            const evicted = bucket.orderedRemove(bucket.items.len - 1);
            allocator.free(evicted.bytes);
        }

        bucket.appendAssumeCapacity(.{
            .hash = hash,
            .bytes = owned_bytes,
            .address = address,
        });
        promoteEntry(bucket, bucket.items.len - 1);
    }

    /// Returns the bucket selected by a serialized byte hash.
    fn bucketForHash(registry: *Registry, hash: u64) *std.ArrayList(Entry) {
        const index = @as(usize, @intCast(hash % registry.buckets.len));
        return &registry.buckets[index];
    }
};

/// Hashes serialized node bytes with the same FNV-1a family used upstream.
fn hashBytes(bytes: []const u8) u64 {
    const fnv_prime: u64 = 1099511628211;
    var hash: u64 = 14695981039346656037;

    for (bytes) |byte| {
        hash = (hash ^ byte) *% fnv_prime;
    }

    return hash;
}

/// Returns the index of an equivalent retained entry in a bucket.
fn findEntryIndex(bucket: *const std.ArrayList(Entry), hash: u64, bytes: []const u8) ?usize {
    for (bucket.items, 0..) |entry, index| {
        if (entry.hash == hash and std.mem.eql(u8, entry.bytes, bytes)) {
            return index;
        }
    }

    return null;
}

/// Promotes a bucket entry to the most-recently-used position.
fn promoteEntry(bucket: *std.ArrayList(Entry), index: usize) void {
    var current = index;
    while (current > 0) : (current -= 1) {
        std.mem.swap(Entry, &bucket.items[current - 1], &bucket.items[current]);
    }
}

test "Registry equal bytes reuse the first address" {
    var registry = try Registry.init(std.testing.allocator, 4, 2);
    defer registry.deinit(std.testing.allocator);

    try registry.put(std.testing.allocator, "abc", 123);
    try registry.put(std.testing.allocator, "abc", 456);

    try std.testing.expectEqual(@as(?u64, 123), registry.get("abc"));
}

test "Registry different bytes sharing a bucket remain distinct" {
    var registry = try Registry.init(std.testing.allocator, 1, 2);
    defer registry.deinit(std.testing.allocator);

    try registry.put(std.testing.allocator, "abc", 123);
    try registry.put(std.testing.allocator, "abd", 456);

    try std.testing.expectEqual(@as(?u64, 123), registry.get("abc"));
    try std.testing.expectEqual(@as(?u64, 456), registry.get("abd"));
    try std.testing.expectEqual(@as(?u64, null), registry.get("abe"));
}

test "Registry evicts entries beyond entries per bucket" {
    var registry = try Registry.init(std.testing.allocator, 1, 2);
    defer registry.deinit(std.testing.allocator);

    try registry.put(std.testing.allocator, "abc", 123);
    try registry.put(std.testing.allocator, "abd", 456);
    try registry.put(std.testing.allocator, "abe", 789);

    try std.testing.expectEqual(@as(?u64, null), registry.get("abc"));
    try std.testing.expectEqual(@as(?u64, 456), registry.get("abd"));
    try std.testing.expectEqual(@as(?u64, 789), registry.get("abe"));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;
