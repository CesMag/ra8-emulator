//! Covers src/chip/periph/drw/drw_limit.zig: the linear form each edge limiter
//! carries, the band that turns a half-plane into a stroke, and the tree
//! CONTROL folds the six of them down.
const std = @import("std");
const ra8 = @import("ra8");

const limit = ra8.chip.periph.drw_limit;

/// One pixel of the sub-pixel grid the HAL writes in.
const unit: i32 = @intCast(limit.subpixel.unit);

fn enables(mask: u32) u32 {
    return mask & limit.control.enables;
}

test "a limiter's value is its linear form in sub-pixels" {
    const edge = limit.Limiter{ .start = 3 * unit, .xadd = -unit, .yadd = 2 * unit };
    try std.testing.expectEqual(@as(i64, 3 * unit), edge.value(0, 0));
    try std.testing.expectEqual(@as(i64, 0), edge.value(3, 0));
    try std.testing.expectEqual(@as(i64, 2 * unit), edge.value(3, 1));
}

test "a limiter admits its own half-plane and nothing on the other side" {
    const edge = limit.Limiter{ .start = 0, .xadd = unit };
    try std.testing.expect(edge.admits(0, 0, false));
    try std.testing.expect(edge.admits(4, 0, false));
    const facing = limit.Limiter{ .start = 0, .xadd = -unit };
    try std.testing.expect(facing.admits(0, 0, false));
    try std.testing.expect(!facing.admits(1, 0, false));
}

test "a band narrows the half-plane to a slab of that width" {
    const edge = limit.Limiter{ .start = 0, .xadd = unit, .band = 3 * @as(u32, @intCast(unit)) };
    try std.testing.expect(edge.admits(2, 0, true));
    try std.testing.expect(!edge.admits(3, 0, true));
    // With the band disabled the same limiter is an open half-plane again.
    try std.testing.expect(edge.admits(9, 0, false));
}

test "a band of zero does not close the half-plane" {
    const edge = limit.Limiter{ .start = 0, .xadd = unit, .band = 0 };
    try std.testing.expect(edge.admits(7, 0, true));
}

test "the boundary band is one sub-pixel either side of zero" {
    const edge = limit.Limiter{ .start = 0, .xadd = unit };
    try std.testing.expect(edge.onEdge(0, 0));
    try std.testing.expect(!edge.onEdge(1, 0));
}

test "a set with no enable has no opinion" {
    const set = limit.Set{};
    try std.testing.expect(!limit.Set.active(0));
    try std.testing.expect(set.admits(0, 5, 5));
}

test "latch takes the six starts, x adds, y adds and the two bands" {
    var set = limit.Set{};
    try std.testing.expect(set.latch(limit.off.start + 8, 7));
    try std.testing.expect(set.latch(limit.off.xadd + 20, 9));
    try std.testing.expect(set.latch(limit.off.yadd + 4, 11));
    try std.testing.expect(set.latch(limit.off.band2, 32));
    try std.testing.expectEqual(@as(i32, 7), set.edges[2].start);
    try std.testing.expectEqual(@as(i32, 9), set.edges[5].xadd);
    try std.testing.expectEqual(@as(i32, 11), set.edges[1].yadd);
    try std.testing.expectEqual(@as(u32, 32), set.edges[1].band);
}

test "latch leaves an offset that is not a limiter's alone" {
    var set = limit.Set{};
    try std.testing.expect(!set.latch(0x078, 1));
    try std.testing.expect(!set.latch(limit.off.start - 4, 1));
    try std.testing.expect(!set.latch(limit.off.start + 2, 1));
}

test "latch reads a start as signed, so an edge can face the other way" {
    var set = limit.Set{};
    _ = set.latch(limit.off.xadd, @bitCast(@as(i32, -unit)));
    try std.testing.expectEqual(@as(i32, -unit), set.edges[0].xadd);
}

test "two enabled limiters intersect by default" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = 0, .xadd = unit };
    set.edges[1] = .{ .start = 2 * unit, .xadd = -unit };
    const ctl = enables(0x3);
    try std.testing.expect(set.admits(ctl, 1, 0));
    try std.testing.expect(!set.admits(ctl, 3, 0));
}

test "UNION12 takes either side of the pair" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = -2 * unit, .xadd = unit };
    set.edges[1] = .{ .start = 0, .xadd = -unit };
    const ctl = enables(0x3) | limit.control.union12;
    try std.testing.expect(set.admits(ctl, 0, 0));
    try std.testing.expect(set.admits(ctl, 4, 0));
    try std.testing.expect(!set.admits(ctl, 1, 0));
}

test "an enabled limiter beside a disabled one decides the pair alone" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = 0, .xadd = unit };
    set.edges[1] = .{ .start = -unit };
    const ctl = enables(0x1);
    try std.testing.expect(set.admits(ctl, 0, 0));
}

test "the three pairs fold through A, B and D into one answer" {
    var set = limit.Set{};
    // A quad box: x >= 1, x <= 3, y >= 1, y <= 3.
    set.edges[0] = .{ .start = -unit, .xadd = unit };
    set.edges[1] = .{ .start = 3 * unit, .xadd = -unit };
    set.edges[2] = .{ .start = -unit, .yadd = unit };
    set.edges[3] = .{ .start = 3 * unit, .yadd = -unit };
    const ctl = enables(0xF);
    try std.testing.expect(set.admits(ctl, 2, 2));
    try std.testing.expect(!set.admits(ctl, 0, 2));
    try std.testing.expect(!set.admits(ctl, 2, 4));
}

test "UNIONAB unites the two pairs" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = -2 * unit, .xadd = unit };
    set.edges[2] = .{ .start = -2 * unit, .yadd = unit };
    const ctl = enables(0x5) | limit.control.union_ab;
    try std.testing.expect(set.admits(ctl, 3, 0));
    try std.testing.expect(set.admits(ctl, 0, 3));
    try std.testing.expect(!set.admits(ctl, 0, 0));
}

test "UNIONCD brings the third pair in" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = -4 * unit, .xadd = unit };
    set.edges[4] = .{ .start = 0, .xadd = -unit };
    const ctl = enables(0x11) | limit.control.union_cd;
    try std.testing.expect(set.admits(ctl, 0, 0));
    try std.testing.expect(set.admits(ctl, 5, 0));
    try std.testing.expect(!set.admits(ctl, 2, 0));
}

test "a band only applies where CONTROL asks for it" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = 0, .xadd = unit, .band = 2 * @as(u32, @intCast(unit)) };
    try std.testing.expect(set.admits(enables(0x1), 5, 0));
    try std.testing.expect(!set.admits(enables(0x1) | limit.control.band1, 5, 0));
}

test "onEdge names only the enabled limiters' boundaries" {
    var set = limit.Set{};
    set.edges[0] = .{ .start = 0, .xadd = unit };
    set.edges[1] = .{ .start = 0, .xadd = unit };
    try std.testing.expect(set.onEdge(enables(0x1), 0, 0));
    try std.testing.expect(!set.onEdge(enables(0x1), 2, 0));
    try std.testing.expect(!set.onEdge(0, 0, 0));
}

test "a triangle is three intersecting edges" {
    var set = limit.Set{};
    // x >= 0, y >= 0, x + y <= 4.
    set.edges[0] = .{ .xadd = unit };
    set.edges[1] = .{ .yadd = unit };
    set.edges[2] = .{ .start = 4 * unit, .xadd = -unit, .yadd = -unit };
    const ctl = enables(0x7);
    try std.testing.expect(set.admits(ctl, 0, 0));
    try std.testing.expect(set.admits(ctl, 4, 0));
    try std.testing.expect(set.admits(ctl, 1, 3));
    try std.testing.expect(!set.admits(ctl, 3, 3));
}

test "a set answers what it holds for a register, and nothing for another's" {
    var set = limit.Set{};
    _ = set.latch(limit.off.start + limit.off.stride, 0xDEAD_BEEF);
    _ = set.latch(limit.off.band1, 24);
    try std.testing.expectEqual(@as(?u32, 0xDEAD_BEEF), set.held(limit.off.start + limit.off.stride));
    try std.testing.expectEqual(@as(?u32, 24), set.held(limit.off.band1));
    try std.testing.expectEqual(@as(?u32, 0), set.held(limit.off.yadd));
    try std.testing.expectEqual(@as(?u32, null), set.held(0x078));
}

test "what a set holds is what latch put there, sign and all" {
    var set = limit.Set{};
    _ = set.latch(limit.off.xadd, @bitCast(@as(i32, -unit)));
    try std.testing.expectEqual(@as(?u32, @bitCast(@as(i32, -unit))), set.held(limit.off.xadd));
}
