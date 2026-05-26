//! Bounded node registry for fst v3 builder deduplication.
/// Candidate builder node recorded for later equivalent-node reuse.
const Entry = struct {
    /// Hash of the semantic node used to choose a bucket.
    hash: u64,

    /// Final output for the retained node, or null when it is not final.
    final_output: ?output.Output,

    /// Transition list owned by the registry for semantic equality checks.
    transitions: []node.Transition,

    /// Address of the equivalent node in the output fst.
    address: u64,
};

/// Bounded approximate registry for semantic node reuse.
pub const Registry = struct {
    /// Buckets that hold recently seen semantic nodes.
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

    /// Releases all retained semantic nodes, transitions, and bucket storage.
    pub fn deinit(registry: *Registry, allocator: std.mem.Allocator) void {
        for (registry.buckets) |*bucket| {
            for (bucket.items) |entry| {
                allocator.free(entry.transitions);
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
    pub fn get(registry: *Registry, unfinished: *const node.UnfinishedNode) ?u64 {
        if (registry.buckets.len == 0 or registry.entries_per_bucket == 0) {
            return null;
        }

        const hash = hashNode(unfinished);
        const bucket = registry.bucketForHash(hash);
        const index = findEntryIndex(bucket, hash, unfinished) orelse return null;
        const address = bucket.items[index].address;
        promoteEntry(bucket, index);
        return address;
    }

    /// Records a semantic node and evicts old entries from the target bucket.
    pub fn put(
        registry: *Registry,
        allocator: std.mem.Allocator,
        unfinished: *const node.UnfinishedNode,
        address: u64,
    ) OOM!void {
        if (registry.buckets.len == 0 or registry.entries_per_bucket == 0) {
            return;
        }

        const hash = hashNode(unfinished);
        const bucket = registry.bucketForHash(hash);

        if (findEntryIndex(bucket, hash, unfinished)) |index| {
            promoteEntry(bucket, index);
            return;
        }

        const transitions = try allocator.dupe(node.Transition, unfinished.transitions.items);
        errdefer allocator.free(transitions);

        try bucket.ensureUnusedCapacity(allocator, 1);

        if (bucket.items.len == registry.entries_per_bucket) {
            const evicted = bucket.orderedRemove(bucket.items.len - 1);
            allocator.free(evicted.transitions);
        }

        bucket.appendAssumeCapacity(.{
            .hash = hash,
            .final_output = unfinished.final_output,
            .transitions = transitions,
            .address = address,
        });
        promoteEntry(bucket, bucket.items.len - 1);
    }

    /// Returns the bucket selected by a semantic node hash.
    fn bucketForHash(registry: *Registry, hash: u64) *std.ArrayList(Entry) {
        const index = @as(usize, @intCast(hash % registry.buckets.len));
        return &registry.buckets[index];
    }
};

/// Hashes a builder node with the same FNV-1a family used upstream.
fn hashNode(unfinished: *const node.UnfinishedNode) u64 {
    const fnv_prime: u64 = 1099511628211;
    var hash: u64 = 14695981039346656037;

    hash = (hash ^ @as(u64, @intFromBool(unfinished.final_output != null))) *% fnv_prime;
    hash = (hash ^ if (unfinished.final_output) |out| out.value else 0) *% fnv_prime;

    for (unfinished.transitions.items) |transition| {
        hash = (hash ^ transition.input) *% fnv_prime;
        hash = (hash ^ transition.out.value) *% fnv_prime;
        hash = (hash ^ transition.addr) *% fnv_prime;
    }

    return hash;
}

/// Returns the index of an equivalent retained entry in a bucket.
fn findEntryIndex(
    bucket: *const std.ArrayList(Entry),
    hash: u64,
    unfinished: *const node.UnfinishedNode,
) ?usize {
    for (bucket.items, 0..) |entry, index| {
        if (entry.hash == hash and equalEntry(entry, unfinished)) {
            return index;
        }
    }

    return null;
}

/// Returns whether a retained entry is semantically equal to `unfinished`.
fn equalEntry(entry: Entry, unfinished: *const node.UnfinishedNode) bool {
    if (!equalOptionalOutput(entry.final_output, unfinished.final_output)) {
        return false;
    }
    if (entry.transitions.len != unfinished.transitions.items.len) {
        return false;
    }
    for (entry.transitions, unfinished.transitions.items) |left, right| {
        if (left.input != right.input) return false;
        if (left.out.value != right.out.value) return false;
        if (left.addr != right.addr) return false;
    }
    return true;
}

/// Returns whether two optional final outputs encode the same finality and value.
fn equalOptionalOutput(left: ?output.Output, right: ?output.Output) bool {
    if (left == null or right == null) {
        return left == null and right == null;
    }
    return left.?.value == right.?.value;
}

/// Promotes a bucket entry to the most-recently-used position.
fn promoteEntry(bucket: *std.ArrayList(Entry), index: usize) void {
    var current = index;
    while (current > 0) : (current -= 1) {
        std.mem.swap(Entry, &bucket.items[current - 1], &bucket.items[current]);
    }
}

/// Creates an empty test node with explicit final output.
fn testNode(final_output: ?output.Output) node.UnfinishedNode {
    return .{
        .final_output = final_output,
        .transitions = .empty,
    };
}

/// Appends one test transition to a builder-side node.
fn appendTransition(
    unfinished: *node.UnfinishedNode,
    input: u8,
    out: u64,
    addr: u64,
) OOM!void {
    try unfinished.transitions.append(std.testing.allocator, .{
        .input = input,
        .out = .{ .value = out },
        .addr = addr,
    });
}

test "Registry equal nodes reuse the first address" {
    var registry = try Registry.init(std.testing.allocator, 4, 2);
    defer registry.deinit(std.testing.allocator);

    var first = testNode(output.Output.zero());
    defer first.deinit(std.testing.allocator);

    var second = testNode(output.Output.zero());
    defer second.deinit(std.testing.allocator);

    try registry.put(std.testing.allocator, &first, 123);
    try registry.put(std.testing.allocator, &second, 456);

    try std.testing.expectEqual(@as(?u64, 123), registry.get(&first));
}

test "Registry different nodes sharing a bucket remain distinct" {
    var registry = try Registry.init(std.testing.allocator, 1, 2);
    defer registry.deinit(std.testing.allocator);

    var first = testNode(null);
    defer first.deinit(std.testing.allocator);
    try appendTransition(&first, 'a', 0, 7);

    var second = testNode(null);
    defer second.deinit(std.testing.allocator);
    try appendTransition(&second, 'b', 0, 7);

    var absent = testNode(null);
    defer absent.deinit(std.testing.allocator);
    try appendTransition(&absent, 'c', 0, 7);

    try registry.put(std.testing.allocator, &first, 123);
    try registry.put(std.testing.allocator, &second, 456);

    try std.testing.expectEqual(@as(?u64, 123), registry.get(&first));
    try std.testing.expectEqual(@as(?u64, 456), registry.get(&second));
    try std.testing.expectEqual(@as(?u64, null), registry.get(&absent));
}

test "Registry evicts entries beyond entries per bucket" {
    var registry = try Registry.init(std.testing.allocator, 1, 2);
    defer registry.deinit(std.testing.allocator);

    var first = testNode(output.Output.zero());
    defer first.deinit(std.testing.allocator);

    var second = testNode(.{ .value = 1 });
    defer second.deinit(std.testing.allocator);

    var third = testNode(.{ .value = 2 });
    defer third.deinit(std.testing.allocator);

    try registry.put(std.testing.allocator, &first, 123);
    try registry.put(std.testing.allocator, &second, 456);
    try registry.put(std.testing.allocator, &third, 789);

    try std.testing.expectEqual(@as(?u64, null), registry.get(&first));
    try std.testing.expectEqual(@as(?u64, 456), registry.get(&second));
    try std.testing.expectEqual(@as(?u64, 789), registry.get(&third));
}

const std = @import("std");

const OOM = std.mem.Allocator.Error;

const node = @import("node.zig");
const output = @import("output.zig");
