//! Memex: std.mem, EXtended
const std = @import("std");

/// Return the index of the first difference between the two slices, such
/// that `std.mem.eql(T, first[0..idx], second[0..idx])` will be `true`.
pub fn indexOfDiff(T: type, first: []const T, second: []const T) usize {
    //
}

/// Return the index of the last difference between the two slices, such that
/// `std.mem.eql(T, first[idx..], second[idx..])` will be `true`.
pub fn indexOfLastDiff(T: type, first: []const T, second: []const T) usize {
    //
}
