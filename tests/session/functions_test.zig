//! Tests for src/session/functions.zig.
//!
//! An ELF is not built here. The sampler's own decision is which key a pc
//! is counted under, and the counting below it is hotspots.Table, which
//! has its own tests: so these drive the part that is this file's, using
//! an image with no symbol tables, where every pc is unnamed and keeps its
//! own address.
const std = @import("std");
const ra8 = @import("ra8");
const functions = ra8.session.functions;
const hotspots = ra8.session.hotspots;
const elf = ra8.board.image.elf;

/// An ELF header with no sections on it, so `symbols.inside` finds no
/// symbol table, every pc comes back unnamed, and the path this file owns
/// is the one under test. Zeroed rather than empty: the header is read
/// before the section count is, so the bytes have to be there.
const headless: [64]u8 = @splat(0);

fn bare() elf.Image {
    return .{ .bytes = &headless };
}

test "a pc with no function keeps its own address and is counted as unnamed" {
    var table = functions.Table{ .image = bare() };
    table.sample(0x0200_1234);
    try std.testing.expectEqual(@as(u64, 1), table.unnamed);
    try std.testing.expectEqual(@as(u64, 1), table.sites.total);
}

test "the same unnamed address folds into one site" {
    var table = functions.Table{ .image = bare() };
    for (0..40) |_| table.sample(0x0200_1234);
    try std.testing.expectEqual(@as(u64, 40), table.sites.total);
    try std.testing.expectEqual(@as(usize, 1), table.sites.used);
    try std.testing.expectEqual(@as(u64, 40), table.unnamed);
}

test "the run's total counts every sample, named or not" {
    var table = functions.Table{ .image = bare() };
    for (0..7) |index| table.sample(@intCast(0x0200_0000 + index * 4));
    try std.testing.expectEqual(@as(u64, 7), table.sites.total);
    try std.testing.expectEqual(@as(usize, 7), table.sites.used);
}

test "a table nothing was sampled into stays quiet" {
    var table = functions.Table{ .image = bare() };
    try std.testing.expect(table.sites.quiet());
    try std.testing.expectEqual(@as(u64, 0), table.unnamed);
}
