# fysti upstream fst inventory

## Scope and Revision

This guide is source archaeology for the upstream Rust `fst` repository at
`/private/tmp/codex-project-state/memex/fysti/fst`, origin
`https://github.com/BurntSushi/fst.git`, revision
`5907b4739793b3d5d7061eaa3f85274e09769d6a`.

The focus is the implementation of the main `fst` crate, not README-level API
docs. The optional in-crate Levenshtein automaton, deprecated `fst-regex` and
`fst-levenshtein` side crates, and enough `fst-bin` merge/mmap code were
inspected to map their role. Bench internals and most CLI command bodies were
not inspected.

## What the Crate Provides

The top-level crate exports five main API families:

- `Map`, `MapBuilder` from `map.rs`, for byte-string keys mapped to `u64`
  values. Re-exported at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:309`.
- `Set`, `SetBuilder` from `set.rs`, for byte-string membership. Re-exported at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:310`.
- `Automaton`, plus concrete automata/combinators from `automaton/mod.rs`.
  Re-exported at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:307` and
  module-wrapped at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:328`.
- `Streamer` and `IntoStreamer`, a streaming-iterator abstraction for borrowed
  per-result key slices. Re-exported at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:311`.
- `raw`, the lower-level finite state transducer layer. Exposed as `pub mod
  raw` at `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:321`.

`Set<D>` is a newtype over `raw::Fst<D>` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/set.rs:30`; `Map<D>` is
the same at `/private/tmp/codex-project-state/memex/fysti/fst/src/map.rs:55`.
Both accept any `D: AsRef<[u8]>`, so the same reader can wrap `Vec<u8>`,
`&[u8]`, `include_bytes!`, or mmap data. Their constructors warn that invalid
FST bytes may panic during reading even though Rust memory safety is preserved:
set at `/private/tmp/codex-project-state/memex/fysti/fst/src/set.rs:53`, map at
`/private/tmp/codex-project-state/memex/fysti/fst/src/map.rs:78`.

The raw layer exposes `Fst`, `Node`, `Transition`, `Output`, `Builder`,
stream/range types, and stream set operations. The raw module summary and
exports are at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:29`.

`Output` is a `u64` wrapper with algebraic operations used during transducer
construction: `zero`, `prefix` as `min`, `cat` as addition, and checked `sub` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1276`.
`Transition` stores one byte input, an `Output`, and a compiled node address at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1330`.

## Dependency Graph and Module Map

Workspace layout:

- Main crate `fst` is version `0.4.7`; workspace members are `bench` and
  `fst-bin`; `fst-levenshtein` and `fst-regex` are excluded deprecated side
  crates at `/private/tmp/codex-project-state/memex/fysti/fst/Cargo.toml:17`.
- Main crate has no default dependencies. Optional `levenshtein` feature
  enables `utf8-ranges` at
  `/private/tmp/codex-project-state/memex/fysti/fst/Cargo.toml:21`.
- `fst-bin` depends on `fst` with `levenshtein`, `memmap2`, `regex-automata`,
  `csv`, `bstr`, etc. at
  `/private/tmp/codex-project-state/memex/fysti/fst/fst-bin/Cargo.toml:23`.
- `fst-regex` is deprecated in favor of `regex-automata` with `transducer`; it
  depends on `fst`, `regex-syntax`, and `utf8-ranges` at
  `/private/tmp/codex-project-state/memex/fysti/fst/fst-regex/Cargo.toml:15`.
- `fst-levenshtein` is deprecated in favor of the main crate's `levenshtein`
  feature at
  `/private/tmp/codex-project-state/memex/fysti/fst/fst-levenshtein/Cargo.toml:5`.

Main module dependency shape:

- `lib.rs` re-exports public surface, wraps internal `inner_map`, `inner_set`,
  `inner_automaton`, and exposes `raw` at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:307`.
- `map.rs` and `set.rs` are thin public wrappers over `raw::Fst`,
  `raw::Builder`, `raw::Stream`, and `raw::OpBuilder`. They mostly convert
  `raw::Output` to `u64` or erase zero outputs.
- `stream.rs` defines `Streamer` and `IntoStreamer`, required because ordinary
  Rust `Iterator` cannot lend a key slice borrowed from the iterator itself
  without allocating a new key each time; see
  `/private/tmp/codex-project-state/memex/fysti/fst/src/stream.rs:1` and
  `/private/tmp/codex-project-state/memex/fysti/fst/src/stream.rs:97`.
- `automaton/mod.rs` defines byte-oriented `Automaton`, `Str`, `Subsequence`,
  `AlwaysMatch`, and combinators `StartsWith`, `Union`, `Intersection`,
  `Complement`; trait core is
  `/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:28`.
- `raw/mod.rs` owns format-level `Fst`, metadata, lookup, streaming, `Output`,
  `Transition`.
- `raw/build.rs` owns incremental construction and output factoring.
- `raw/node.rs` owns binary node encoding/decoding.
- `raw/registry.rs` owns bounded node deduplication; `raw/registry_minimal.rs`
  is a dead-code full `HashMap` alternative that guarantees minimality but is
  memory/CPU heavy at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/registry_minimal.rs:1`.
- `raw/ops.rs` owns multi-stream union/intersection/difference/symmetric
  difference.
- `bytes.rs` owns fixed little-endian and packed unsigned integer helpers.
- `raw/crc32.rs` and generated `raw/crc32_table.rs` own CRC32C checksumming; the
  generator is `build.rs` at
  `/private/tmp/codex-project-state/memex/fysti/fst/build.rs:69`.

## Core FST Format

The serialized file starts with two fixed little-endian `u64`s: API `VERSION`
and FST type. `VERSION` is currently `3` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:60`; the
builder writes version then type immediately at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:122`.

The builder reserves byte addresses `0..15` for header fields and uses `0` and
`1` as sentinels, so no real node may live there:
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:123`.
Sentinel `EMPTY_ADDRESS = 0` means empty final node, and `NONE_ADDRESS = 1`
means invalid/no node at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:62`.

After the header come compiled nodes, then a trailer: `len: u64`, `root_addr:
u64`, and for version 3, masked CRC32C `u32`. Builder writes these at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:215`.
`Fst::new` requires at least 36 bytes for v3, reads version/type, treats version
`<= 2` as legacy no-checksum, otherwise reads the final 4 bytes as checksum,
then reads `root_addr` and `len` from the end region at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:343`.
Important nuance: code rejects version `0` or future versions, but accepts older
versions up to `VERSION` with compatibility branches at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:353`.

`Fst::new` is intentionally cheap: no full validation, no checksum scan, only
size/version/root-address sanity. That warning is explicit at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:331`. Full
integrity check is opt-in via `verify`, which recomputes masked CRC32C over all
bytes except the final checksum at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:518`.

Integers are little-endian. Fixed `u32/u64` helpers are at
`/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:7` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:14`. Packed
integers are not LEB128: they are the low `nbytes` of a little-endian integer,
with no continuation bits, written by `pack_uint_in` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:79` and read by
`unpack_uint` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:99`.

Node addresses point to the last byte of a node, not the byte after it.
`Node::new` slices `data[..addr + 1]` and decodes backward from the state byte
at `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:55`.
Deltas are encoded as `node_addr - trans_addr`, except `EMPTY_ADDRESS` stays
`0`; see `pack_delta_in` and `unpack_delta` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:838`.

There are four node states:

- `EmptyFinal`: address `0`, final, zero output, no transitions at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:62`.
- `OneTransNext`: high state bits `11`; one zero-output transition to the
  previously compiled node. It encodes no transition delta and may omit common
  input bytes at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:311`.
- `OneTrans`: high state bits `10`; one transition with packed output and
  packed delta at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:370`.
- `AnyTrans`: high state bits `00`/`01`; bit 6 is final flag, low six bits
  encode transition count when possible. It packs optional final output,
  transition outputs, transition deltas, input bytes, optional 256-byte
  transition index, pack-size byte, optional explicit transition count, then
  state byte at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:468`.

For `AnyTrans`, transitions are written in reverse order for compact backward
decoding, but public `transition(i)` returns lexicographic order. Large nodes
with more than 32 transitions get a 256-byte direct input index for version
`>= 2`; threshold and read/write are at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:16`,
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:515`, and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:691`.

`PackSizes` stores transition-delta byte width in the high nibble and output
byte width in the low nibble; zero is legal and means absent/no bytes. See
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:731`.

Common input bytes use static tables `COMMON_INPUTS` and inverse lookup to
sometimes store a 6-bit code instead of a byte. Lookup helpers are
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:806` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:818`.

Outputs are accumulated along the path: lookup starts at zero, adds transition
outputs, and if the terminal node is final, adds its final output. That path is
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:682`.

## Build Path

All construction goes through `raw::Builder<W>`, which streams bytes directly to
an `io::Write` wrapped by `CountingWriter`; it does no internal buffering at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:43`. Public
`SetBuilder` and `MapBuilder` are wrappers at
`/private/tmp/codex-project-state/memex/fysti/fst/src/set.rs:551` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/map.rs:609`.

Builder state is an unfinished-node stack, a registry of already compiled nodes,
last inserted key, last compiled address, and key count at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:43`.
Inserted keys must be sorted. For maps, duplicate equal keys are rejected; for
sets, exact duplicates collapse harmlessly because `add` disables duplicate
checking and duplicate no-output suffixes return early. The ordering checks are
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:140` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:295`.

The core insertion algorithm:

1. Find the common prefix between the new key and the current unfinished path.
   For sets, only bytes matter via `find_common_prefix` at
   `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:390`.
2. For maps, also factor outputs along the common prefix with
   `find_common_prefix_and_set_output` at
   `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:399`. It
   takes the minimum of existing transition output and new output as the shared
   prefix, subtracts the shared prefix from both sides, and pushes any leftover
   existing output down into the child node via `add_output_prefix` at
   `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:436`.
3. Compile all unfinished nodes deeper than the common prefix via `compile_from`
   at `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:260`.
4. Add the remaining key suffix as unfinished nodes via `add_suffix` at
   `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:374`.

The registry is a bounded approximate deduper, not a full minimalization table.
The default is `Registry::new(10_000, 2)` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:133`,
implemented as hashed buckets with two MRU cells at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/registry.rs:29`. If a
structurally equal finished node is found, the builder reuses its address;
otherwise it serializes the node and records the new address at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:275`. The
docs explicitly say this crate does not generally guarantee minimal transducers
because full minimality needs memory proportional to states; see
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:226`.

Finishing compiles down to root, writes length/root/checksum, flushes, and
returns the writer at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:215`.

## Read and Search Path

Exact lookup is a byte walk from root. `FstRef::get` follows `find_input`,
accumulates transition outputs, then requires the terminal node to be final and
adds the final output at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:682`.
`contains_key` is the same walk without output accumulation at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:703`.

Reverse lookup by value exists as `get_key_into`, but only when values are
monotonic in lexicographic key order; otherwise behavior is documented as
unspecified. Implementation greedily follows the last transition whose output is
`<= value` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:715`.

Streaming uses `StreamWithState`: it keeps one mutable key buffer `inp`, an
optional empty-key output, and a DFS stack of `{node, transition index,
accumulated output, automaton state}` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1065`.
`seek_min` initializes the stack for range lower bounds without scanning all
preceding keys; it walks the lower-bound prefix and when missing, starts at the
first transition greater than the current byte at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1111`.

Iteration pops states, prunes when all transitions are exhausted or
`aut.can_match` is false, pushes the sibling continuation and child descent,
stops forever when the upper bound is exceeded, and yields only final nodes
whose automaton state matches. This is the main loop at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1191`.

Range bounds are byte-vector `Included`, `Excluded`, or `Unbounded`, with
upper-bound stop logic in `Bound::exceeded_by` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:937`.

Automata are byte-based. The trait requires `start`, `is_match`, `can_match`,
`accept`, optional `accept_eof`, and `will_always_match` for combinators at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:28`.
Built-ins include exact `Str` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:169`,
`Subsequence` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:241`,
and `AlwaysMatch` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:291`.
Combinators compose states pairwise or wrap state: `StartsWith` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:321`,
union/intersection/complement at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:387`.

The optional `Levenshtein` builds a byte DFA from a dynamic edit-distance state
vector. Construction is `Levenshtein::new` at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/levenshtein.rs:112`;
dynamic edit-distance transition is
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/levenshtein.rs:179`;
the resulting automaton indexes `[Option<usize>; 256]` per state at
`/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/levenshtein.rs:218`.

Multi-FST operations operate on sorted streams and use a `BinaryHeap<Slot>`
ordered in reverse to pop the lexicographically smallest key at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:362` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:447`.
`Union` groups equal popped keys and yields all indexed outputs at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:210`.
`Intersection` yields only when the same key is popped from every stream at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:244`.
`Difference` advances non-primary streams up to the primary key and yields only
if none match at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:290`.
`SymmetricDifference` yields keys appearing an odd number of times at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:329`.

## Algorithms and Invariants

The data structure is an acyclic deterministic finite state transducer over
byte strings. Keys are transition labels along unique root-to-final paths; map
values are sums of outputs along the path plus the terminal final output. The
implementation notes this at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:84` and
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:171`.

Construction is incremental and sorted-input dependent. Once the next key
diverges from the previous unfinished path, the suffix below the common prefix
can never be extended again, so it is safe to compile and dedupe. This is the
Daciuk-style online construction described in comments/bibliography at
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:244`.

Output factoring is the most port-sensitive algorithm. Existing and new outputs
are split into shared prefix and residual suffix by `Output::prefix`, `sub`, and
`cat`. In this implementation those are `min`, checked subtraction, and
addition for `u64`; see
`/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1303`. The
invariant is that moving shared output earlier and residual output later
preserves path sums while maximizing suffix sharing.

The memory model is deliberately streaming. Builder memory is proportional to
current key length plus bounded registry, not full corpus size. Reader memory is
proportional to current key length plus traversal stack. Stream operations are
proportional to number of participating streams. The raw op docs state
multi-stream complexity `O(n1 + n2 + ...)` and memory proportional to stream
count at `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:36`.

Safety assumption: invalid bytes may panic during navigation. `Fst::new` checks
only coarse format; `Node` and byte helpers use indexing/assertions freely. For
a Zig port, decide whether to preserve panic-like programmer errors or expose
checked parsing/navigation APIs.

## Gotchas for a Zig Port

- Do not implement packed integers as LEB128. They are fixed-width
  little-endian truncations selected by `pack_size`; see
  `/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:64`.
- Preserve "address points to last byte of node." Many formulas subtract
  backward from `node.start`, and root sanity checks assume this offset
  convention at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:375`.
- Preserve sentinel addresses exactly: `0` empty final, `1` none. Deltas
  special-case `0` rather than subtracting it at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:844`.
- Version compatibility is subtle: version 1/2 nodes may lack the transition
  index and checksum; version 3 has checksum. `trans_index_size` is gated on
  `version >= 2` at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:594`, and
  checksum is absent for `version <= 2` at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:361`.
- `Streamer` lends slices into an internal mutable buffer. Zig equivalent should
  document that returned key slices are invalidated by the next `next()` call
  unless copied.
- Separate owned data from borrowed bytes. Rust's `Fst<D: AsRef<[u8]>>` hides
  this behind generics; Zig likely wants `FstView` over `[]const u8` plus
  optional owner wrappers.
- Mmap is just one source of bytes. CLI mmap helper is unsafe because OS/file
  lifetime is outside Rust's normal guarantees at
  `/private/tmp/codex-project-state/memex/fysti/fst/fst-bin/src/util.rs:14`.
- Error shape should distinguish format/version/checksum/build-order/duplicate/
  UTF-8/io. Raw errors are in
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/error.rs:11`;
  top-level wraps raw/io at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/error.rs:11`.
- Invalid input should preferably return Zig errors instead of panicking. Rust
  uses assertions and indexing in `bytes.rs`, `node.rs`, and `Output::sub`.
- Keep allocator boundaries explicit: building needs writer, unfinished stack,
  registry, previous key; reading can be allocation-free for exact lookup, but
  streaming needs key buffer and stack.
- Test against upstream-generated bytes, not just behavior. Useful tests include
  basic sets/maps and order errors at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:93`, big
  word list round-trips at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:105`, map
  output cases at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:149`,
  range edge cases at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:245`,
  multiple FSTs concatenated in one vec at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:485`, and
  checksum mutation at
  `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:573`.

## Suggested Port Order

1. Port `bytes.rs`: little-endian fixed ints, packed uints, pack-size tests.
2. Port `Output`, `Transition`, constants, and a read-only `FstView` over
   `[]const u8` with version/trailer parsing and no full validation.
3. Port `Node` decoding for all four state variants, including common input
   tables, pack sizes, deltas, transition indexing, and transition iteration.
4. Implement exact `get`/`contains_key` over raw FST bytes.
5. Add checksum verification: CRC32C Castagnoli plus Snappy-style mask from
   `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/crc32.rs:21`.
   Zig stdlib has a crc implementation at `std.hash.crc` which can be adapted
   to this purpose.
6. Port streaming traversal with reusable key buffer, lower/upper bounds, and
   `AlwaysMatch`.
7. Add `Set` and `Map` wrappers as thin API sugar.
8. Port builder for sets first: sorted input, unfinished stack, node
   serialization, registry dedupe, finish trailer/checksum.
9. Add map outputs and output factoring after set construction is
   byte-compatible.
10. Add raw multi-stream ops, then set/map op wrappers.
11. Add automata trait/struct shape, built-in `Str`, `Subsequence`,
    `StartsWith`, union/intersection/complement.
12. Treat Levenshtein/regex as later features.

## Source Index

- `/private/tmp/codex-project-state/memex/fysti/fst/Cargo.toml:1`: main crate
  metadata, features, workspace.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/lib.rs:307`: public
  re-exports.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/stream.rs:97`:
  `Streamer` and `IntoStreamer`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/mod.rs:28`:
  `Automaton` trait.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/automaton/levenshtein.rs:112`:
  optional Levenshtein constructor.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/map.rs:55`: `Map`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/map.rs:609`:
  `MapBuilder`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/set.rs:30`: `Set`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/set.rs:551`:
  `SetBuilder`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:60`: format
  version and address constants.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:269`:
  `Fst<D>` and metadata.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:343`:
  `Fst::new` byte parser.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:518`:
  checksum verification.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:682`: exact
  lookup.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:802`: range
  stream builder.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1065`:
  `StreamWithState`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/mod.rs:1276`:
  `Output`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:43`:
  `Builder<W>`.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:229`:
  insertion path.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/build.rs:399`:
  output factoring.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:51`: node
  decoding.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:244`: node
  compilation dispatch.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:468`:
  multi-transition encoding.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/node.rs:736`:
  pack-size nibble format.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/registry.rs:36`:
  bounded registry lookup.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:48`: raw
  stream operation builder.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/ops.rs:204`:
  union/intersection/difference/symmetric-difference streams.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/bytes.rs:7`: fixed and
  packed integer helpers.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/crc32.rs:10`:
  CRC32C checksummer.
- `/private/tmp/codex-project-state/memex/fysti/fst/src/raw/tests.rs:1`: core
  behavioral tests and test-vector patterns.
