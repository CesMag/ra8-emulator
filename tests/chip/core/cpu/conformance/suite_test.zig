//! The build-failing half of the conformance suite: a claimed encoding or a
//! registered decode group with no vector, or a vector naming an encoding or
//! group nobody claims, fails `zig build test`.
const std = @import("std");
const ra8 = @import("ra8");
const coverage = @import("coverage.zig");
const suite = @import("suite.zig");

test "every claimed encoding has at least one vector" {
    if (coverage.firstMissing(suite.claimed, suite.covered)) |gap| {
        std.debug.print("conformance: {s} is claimed but has no vector\n", .{gap});
        return error.MissingConformanceVector;
    }
}

test "every vector names an encoding the core claims" {
    if (coverage.firstUnclaimed(suite.claimed, suite.covered)) |stray| {
        std.debug.print("conformance: a vector names {s}, which nothing claims\n", .{stray});
        return error.UnclaimedConformanceVector;
    }
}

// Lay out Cpu before anything here reads the decode table: the groups'
// function pointers name Cpu, and evaluating them first loops through Cpu's
// decode cache.
comptime {
    std.debug.assert(@sizeOf(ra8.chip.core.cpu.cpu.Cpu) > 0);
}

/// Every group the decode table registers, by name, in decode order.
fn groupNames(into: [][]const u8) []const []const u8 {
    var n: usize = 0;
    for (ra8.chip.core.cpu.ops.table.groups) |group| {
        if (n == into.len) break;
        into[n] = group.name;
        n += 1;
    }
    return into[0..n];
}

/// The coverage document as it should read for the suite as it stands.
fn expectedDocument(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try coverage.writeDocument(&out.writer, suite.claimed, suite.covered);
    var names: [256][]const u8 = undefined;
    try coverage.writeDecoded(&out.writer, groupNames(&names), suite.decoded_covered);
    return out.toOwnedSlice();
}

test "tests/chip/core/cpu/conformance/coverage.md matches the suite, or is rewritten when blessed" {
    const allocator = std.testing.allocator;
    const want = try expectedDocument(allocator);
    defer allocator.free(want);
    if (try std.testing.environ.contains(allocator, "RA8_BLESS_CONFORMANCE")) {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = suite.table_path, .data = want });
        return;
    }
    const have = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, suite.table_path, allocator, .limited(1 << 20));
    defer allocator.free(have);
    if (!std.mem.eql(u8, have, want)) {
        std.debug.print("conformance: {s} is stale; run RA8_BLESS_CONFORMANCE=1 zig build test\n", .{suite.table_path});
        return error.StaleConformanceTable;
    }
}

test "the decode table section lists every registered group exactly once" {
    const groups = ra8.chip.core.cpu.ops.table.groups;
    var names: [256][]const u8 = undefined;
    const decoded = groupNames(&names);
    try std.testing.expect(groups.len <= names.len);
    try std.testing.expectEqual(groups.len, decoded.len);
    for (groups, decoded) |group, name| {
        try std.testing.expectEqualStrings(group.name, name);
        try std.testing.expectEqual(@as(usize, 1), coverage.count(name, decoded));
    }
}

test "every registered group has at least one vector" {
    var names: [256][]const u8 = undefined;
    if (coverage.firstMissing(groupNames(&names), suite.decoded_covered)) |gap| {
        std.debug.print("conformance: group {s} is decoded but has no vector\n", .{gap});
        return error.MissingConformanceVector;
    }
}

test "every decode-table vector names a registered group" {
    var names: [256][]const u8 = undefined;
    if (coverage.firstUnclaimed(groupNames(&names), suite.decoded_covered)) |stray| {
        std.debug.print("conformance: a vector names group {s}, which the decode table does not register\n", .{stray});
        return error.UnclaimedConformanceVector;
    }
}

test {
    _ = @import("base/all_test.zig");
}
