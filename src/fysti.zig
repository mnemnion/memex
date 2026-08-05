//! fysti: a Zig implementation of BurntSushi fst format v3.
//!
//! This is a translation of the following library:
//!
//! https://github.com/BurntSushi/fst
//!
//! Produced with minimal human direction.  Don't miss the blog post:
//!
//! https://burntsushi.net/transducers/
//!
//! The (very liberal and permissive) license of the original may be
//! found at the bottom of this source file.  It's not clear that a
//! second license bearing my name is a legitimate legal document,
//! but I've included one just in case, in the accustomed place.

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

/// Serialized fst version implemented by fysti.
pub const version = fst.version;

/// Number of bytes in the v3 header.
pub const header_len = fst.header_len;

/// Number of bytes in the v3 trailer.
pub const trailer_len = fst.trailer_len;

/// Conventional v3 kind value shared by builders and readers.
pub const Kind = fst.Kind;

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

/// Byte encoding helpers for fst v3.
pub const bytes = @import("fysti/bytes.zig");

/// Output algebra for supported fst value families.
pub const output = @import("fysti/output.zig");

/// CRC32C checksum helpers for fst trailers.
pub const crc32 = @import("fysti/crc32.zig");

/// Node and transition encoding for fst v3.
pub const node = @import("fysti/node.zig");

/// Bounded node registry used by the builder.
pub const registry = @import("fysti/registry.zig");

/// Public builder core for fst v3 bytes.
pub const builder = @import("fysti/builder.zig");

/// Public read view for fst v3 bytes.
pub const fst = @import("fysti/fst.zig");

// Original License:
//
// This project is dual-licensed under the Unlicense and MIT licenses.
//
// You may use this code under the terms of either license.
//
// The MIT License (MIT)
//
// Copyright (c) 2015 Andrew Gallant
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// This is free and unencumbered software released into the public domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.
//
// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
//
// For more information, please refer to <http://unlicense.org/>
