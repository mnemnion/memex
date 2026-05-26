# fysti design

## Purpose

`fysti` is a Zig implementation of BurntSushi `fst` format version 3. The
module should track upstream nomenclature while avoiding Rust-only abstractions
that exist to satisfy ownership, lifetime, or trait constraints Zig does not
have.

The initial design is build-first. The builder is the first major milestone,
with enough read support to validate emitted bytes and prove v3 compatibility.

## Source Contract

The local upstream reference clone is:

`/private/tmp/codex-project-state/memex/fysti/fst`

Origin: `https://github.com/BurntSushi/fst.git`

Revision: `5907b4739793b3d5d7061eaa3f85274e09769d6a`

The source inventory for this reference is:

`docs/inventory/fysti-upstream-fst.md`

`fysti` targets only format version 3:

- reads accept v3 and assert on non-v3 data;
- writes always emit v3;
- there is no v1/v2 compatibility layer;
- there is no alternate dialect.

## Public API Shape

The public surface follows upstream FST nomenclature:

```zig
pub fn Fst(comptime V: type) type
pub fn Builder(comptime V: type) type

pub const Set = Fst(void);
pub const Map = Fst(u64);

pub const SetBuilder = Builder(void);
pub const MapBuilder = Builder(u64);
```

The supported value families are explicit:

- `void` for set membership;
- `u64` for map values compatible with upstream `fst`.

Other value types fail at comptime with a clear message. Publicly, `void` means
there is no user value. Internally, it still uses the shared v3 output machinery
with zero output.

`Fst(V)` is a non-owning view over `[]const u8` plus parsed metadata. Owned,
mmap, or file-backed helpers may wrap `Fst(V)` later, but should not change this
core shape.

`Builder(V)` is public and writes through `std.Io.Writer`. It owns construction
state using the caller's allocator. `SetBuilder` and `MapBuilder` are aliases or
thin wrappers over the same builder core, not separate engines.

## Architecture

The core implementation is shared between sets and maps:

```text
bytes.zig      little-endian fixed integers and fixed-width packed integers
output.zig     v3 Output algebra over u64
node.zig       v3 node encode/decode, transitions, addresses, deltas
fst.zig        Fst(V) read view, header/trailer/checksum metadata, lookup
builder.zig    Builder(V), unfinished stack, output factoring, node emission
registry.zig   bounded equivalent-node reuse
```

The raw v3 format code is a real format engine, not a Rust module mirror for its
own sake. Public set/map opinions sit on top of this core.

## V3 Byte Format

The serialized format is:

```text
header:
  version: u64 little-endian = 3
  kind:    u64 little-endian

body:
  compiled nodes, addressed by last-byte index

trailer:
  len:       u64 little-endian
  root_addr: u64 little-endian
  checksum: u32 little-endian, masked CRC32C over all prior bytes
```

Addressing follows upstream exactly:

- address `0` is `EMPTY_ADDRESS`;
- address `1` is `NONE_ADDRESS`;
- real node addresses point at the final byte of a serialized node, not one
  past it;
- transition deltas encode `node_addr - trans_addr`, except the empty sentinel
  stays `0`.

Node encoding/decoding supports the four upstream states:

- `EmptyFinal`;
- `OneTransNext`;
- `OneTrans`;
- `AnyTrans`.

`AnyTrans` includes final-output handling, transition outputs, packed deltas,
input bytes, optional transition index for large nodes, pack-size byte, optional
explicit transition count, and state byte.

Packed integers are fixed-width little-endian truncations selected by pack size.
They are not varints or LEB128.

## Build Flow

Construction is one shared path for `void` and `u64`:

```text
Builder(V).init(allocator, writer)
Builder(V).deinit(allocator)
Builder(V).insert(allocator, key, value)
  validate sorted input
  find common prefix against unfinished stack
  factor output through shared Output algebra
  compile closed suffix nodes through registry
  append new unfinished suffix
Builder(V).finish()
  compile root
  write len/root/checksum trailer
```

For `void`, the user value is `void` and the internal output is always zero.
For `u64`, the internal output is the user value and uses upstream's output
algebra:

- `zero`;
- `prefix` as `min`;
- `cat` as checked addition;
- `sub` as checked subtraction.

Duplicate policy is value-family-specific:

- `Builder(void)` tolerates duplicate keys to match upstream set behavior;
- `Builder(u64)` rejects duplicate keys.

## Zig-Native Simplifications

Keep abstractions that represent real FST concepts:

- `Fst(V)`;
- `Builder(V)`;
- `Output`;
- `Transition`;
- `Node`;
- `Registry`;
- range bounds;
- eventual iterator object;
- eventual automaton/search concept for pruning.

Do not copy Rust machinery that only exists for Rust:

- `D: AsRef<[u8]>`;
- `IntoStreamer` / `Streamer` trait split;
- borrow-checker-driven lending iterator traits;
- separate set/map construction engines;
- generic automaton combinator trait hierarchy as the first shape;
- legacy v1/v2 reader branches;
- deprecated regex/levenshtein side-crate structure.

Iteration, when added, is an explicit Zig iterator, not a stream:

```zig
var it = try fst.iterator(allocator, .{ .lower = .unbounded, .upper = .unbounded });
while (try it.next()) |entry| {
    // entry.key is borrowed from iterator-owned scratch space.
}
```

Returned key slices are invalidated by the next `next()` call unless copied.
This is documented on the iterator type instead of encoded as pseudo-traits.

Automata/search comes later as a Zig design, likely with comptime duck typing or
concrete searcher objects. Exact lookup and builder compatibility come first.

## Errors and Invariants

`fysti` is not a forgiving file parser API. It implements a specified v3 format.
Malformed bytes and impossible internal states are data-contract or programmer
violations and should be enforced with assertions.

Public errors should be limited to conditions a correct caller can recover from:

```zig
error{
    OutOfMemory,
    WriteFailed,
    InputNotSorted,
    DuplicateKey,
    OutputOverflow,
}
```

`InvalidChecksum` belongs only on an explicit `verify()` API, because that
method specifically asks whether a byte slice passes integrity verification.
Normal lookup and iteration do not translate malformed bytes into broad
user-facing error sets.

`Fst(V).init(bytes)` performs the cheap structural work needed to create a view:
read v3 header/trailer, assert the invariants required by valid v3 bytes, and
store metadata.

Internal node encodings, transition layouts, address math, and output underflow
from corrupt data or broken builder logic are assertion territory.

Builder-facing recoverable conditions remain errors:

- allocator failure;
- writer failure;
- input not sorted;
- duplicate map key;
- `u64` output overflow during construction.

## Testing and Bringup

Bringup should prove the v3 contract from both directions, with the builder as
the first major milestone.

Test layers:

```text
1. byte helpers
   little-endian fixed ints
   fixed-width packed ints
   pack-size boundaries

2. Output algebra
   zero / prefix-min / cat-add / sub
   overflow behavior

3. Node encode/decode
   EmptyFinal
   OneTransNext
   OneTrans
   AnyTrans
   transition index threshold
   address/delta semantics

4. Builder core
   sorted insertion
   duplicate policy for void vs u64
   common-prefix handling
   output factoring
   registry reuse
   finish trailer and checksum

5. Compatibility fixtures
   Zig-written v3 bytes are readable by Rust fst
   Rust-written v3 bytes are readable by Zig fysti
   lookup results match for set and map cases
```

Implementation order:

```text
bytes -> Output -> node encoding/decoding -> registry -> Builder(V)
-> Fst(V) minimal lookup -> compatibility fixtures -> iterator later
```

Although lookup follows builder, the first implementation still needs a narrow
exact-lookup reader to validate emitted bytes. Iterator, range search, automata,
and set operations are later work.

Cross-check Rust compatibility using fixtures or helper scripts from the local
upstream clone. Do not check upstream Rust sources into this repository.
