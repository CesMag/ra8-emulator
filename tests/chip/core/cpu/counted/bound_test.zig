//! Covers src/chip/core/cpu/counted_bound.zig: how many more trips of a bounded
//! poll take the traced path (RA8EMU-602).
const std = @import("std");
const ra8 = @import("ra8");
const td = ra8.chip.core.cpu.cpu.trip_decode;
const cb = ra8.chip.core.cpu.cpu.counted.bound;

const max = 8;

/// A trip under test: narrow encodings, and the registers before each.
const Trip = struct {
    steps: [max]td.Step = undefined,
    regs: [max][16]u32 = undefined,
    len: usize = 0,
    head: [16]i64 = @splat(0),

    fn add(self: *Trip, hw: u16, before: [16]u32) void {
        self.steps[self.len] = td.decode(hw, 0);
        self.regs[self.len] = before;
        self.len += 1;
    }

    fn trips(self: *const Trip, words: []const cb.Word) ?u64 {
        return cb.trips(.{
            .steps = self.steps[0..self.len],
            .regs = self.regs[0..self.len],
            .head = self.head,
            .words = words,
        });
    }
};

fn regs(pairs: []const [2]u32) [16]u32 {
    var out: [16]u32 = @splat(0);
    out[13] = 0x2200_0F00;
    for (pairs) |pair| out[pair[0]] = pair[1];
    return out;
}

test "an up-count to a register limit stops short of the limit" {
    // adds r0,#1 ; cmp r0,r1 ; bls loop. The ADDS flags are dead.
    var trip = Trip{};
    trip.head[0] = 1;
    trip.add(0x3001, regs(&.{ .{ 0, 10 }, .{ 1, 100 } }));
    trip.add(0x4288, regs(&.{ .{ 0, 11 }, .{ 1, 100 } }));
    trip.add(0xD9FC, regs(&.{ .{ 0, 11 }, .{ 1, 100 } }));
    // The compare sees 11 now; 99 is 88 trips off, so 87 are safe.
    try std.testing.expectEqual(@as(?u64, 87), trip.trips(&.{}));
}

test "a down-count whose SUBS feeds BNE is bounded by the SUBS itself" {
    // subs r2,#1 ; bne loop
    var trip = Trip{};
    trip.head[2] = -1;
    trip.add(0x3A01, regs(&.{.{ 2, 50 }}));
    trip.add(0xD1FD, regs(&.{.{ 2, 49 }}));
    try std.testing.expectEqual(@as(?u64, 47), trip.trips(&.{}));
}

test "a counter kept in a stack word, as internal_ns_ipc_recv keeps it" {
    // ldr r3,[r7,#20] ; adds r3,#1 ; str r3,[r7,#20] ; ldr r3,[r7,#20] ;
    // ldr r2,[pc,#12] ; cmp r3,r2 ; bls loop
    const frame: u32 = 0x2200_0E00;
    var trip = Trip{};
    trip.head[3] = 1;
    trip.add(0x697B, regs(&.{ .{ 7, frame }, .{ 3, 41 } }));
    trip.add(0x3301, regs(&.{ .{ 7, frame }, .{ 3, 41 } }));
    trip.add(0x617B, regs(&.{ .{ 7, frame }, .{ 3, 42 } }));
    trip.add(0x697B, regs(&.{ .{ 7, frame }, .{ 3, 42 } }));
    trip.add(0x4A03, regs(&.{ .{ 7, frame }, .{ 3, 42 } }));
    trip.add(0x4293, regs(&.{ .{ 7, frame }, .{ 3, 42 }, .{ 2, 999_999 } }));
    trip.add(0xD9E4, regs(&.{ .{ 7, frame }, .{ 3, 42 }, .{ 2, 999_999 } }));
    const words = [_]cb.Word{.{ .address = frame + 20, .delta = 1 }};
    try std.testing.expectEqual(@as(?u64, 999_998 - 42 - 1), trip.trips(&words));
}

test "a poll whose decisions read nothing that moves is unbounded" {
    // adds r0,#1 ; ldr r3,[r5] ; cmp r3,r2 ; bne loop
    var trip = Trip{};
    trip.head[0] = 1;
    trip.add(0x3001, regs(&.{ .{ 0, 5 }, .{ 5, 0x2200_0100 } }));
    trip.add(0x682B, regs(&.{ .{ 0, 6 }, .{ 5, 0x2200_0100 } }));
    trip.add(0x4293, regs(&.{ .{ 0, 6 }, .{ 5, 0x2200_0100 } }));
    trip.add(0xD1FB, regs(&.{ .{ 0, 6 }, .{ 5, 0x2200_0100 } }));
    try std.testing.expectEqual(@as(?u64, cb.unbounded), trip.trips(&.{}));
}

test "a shift of the counter or a moving base is refused" {
    var shifted = Trip{};
    shifted.head[0] = 1;
    shifted.add(0x3001, regs(&.{.{ 0, 5 }}));
    shifted.add(0x0A03, regs(&.{.{ 0, 6 }})); // lsrs r3,r0,#8
    shifted.add(0xD1FC, regs(&.{.{ 0, 6 }}));
    try std.testing.expectEqual(@as(?u64, null), shifted.trips(&.{}));

    var tested = Trip{};
    tested.head[0] = 1;
    tested.add(0x3001, regs(&.{.{ 0, 5 }}));
    tested.add(0xB900, regs(&.{.{ 0, 6 }})); // cbnz r0
    // A CBNZ on the counter is bounded like a compare with zero (RA8EMU-610).
    try std.testing.expectEqual(@as(?u64, cb.limit(6, 1, 0)), tested.trips(&.{}));

    var walked = Trip{};
    walked.head[0] = 4;
    walked.add(0x6801, regs(&.{.{ 0, 0x2200_0000 }})); // ldr r1,[r0]
    walked.add(0x3004, regs(&.{.{ 0, 0x2200_0000 }})); // adds r0,#4
    walked.add(0xE7FC, regs(&.{.{ 0, 0x2200_0004 }}));
    try std.testing.expectEqual(@as(?u64, null), walked.trips(&.{}));
}

test "a value that starts moving inside the trip, or a moving SP, is refused" {
    // mov r1,r0 ; adds r0,#1 ; b loop. R1 copies the counter, so it moves
    // between trips although the head said it stood still.
    var trip = Trip{};
    trip.head[0] = 1;
    trip.add(0x4601, regs(&.{.{ 0, 10 }}));
    trip.add(0x3001, regs(&.{ .{ 0, 10 }, .{ 1, 10 } }));
    trip.add(0xE7FC, regs(&.{ .{ 0, 11 }, .{ 1, 10 } }));
    try std.testing.expectEqual(@as(?u64, null), trip.trips(&.{}));
    trip.head[1] = 1;
    try std.testing.expectEqual(@as(?u64, cb.unbounded), trip.trips(&.{}));
    trip.head[13] = 4;
    try std.testing.expectEqual(@as(?u64, null), trip.trips(&.{}));
}

test "limit stops before the still value, the sign boundary and the wrap" {
    try std.testing.expectEqual(@as(u64, 7), cb.limit(10, 1, 19));
    try std.testing.expectEqual(@as(u64, 0), cb.limit(18, 1, 19));
    try std.testing.expectEqual(@as(u64, 2), cb.limit(0x7FFF_FFFC, 1, 0xFFFF_0000));
    try std.testing.expectEqual(@as(u64, 4), cb.limit(10, -2, 0));
    try std.testing.expectEqual(@as(u64, 1), cb.limit(0xFFFF_FFFD, 1, 3));
    try std.testing.expectEqual(cb.unbounded, cb.limit(5, 0, 5));
}

test "a CBZ on the down-counter, as txm_fault_cpu1's main polls" {
    // cbz r1,out ; ldr r5,[r2] ; cmp r5,r4 ; bne skip ; skip: subs r1,#1 ; b loop
    const shared: u32 = 0x2210_0000;
    const mark: u32 = 0x5A5A_0001;
    var trip = Trip{};
    trip.head[1] = -1;
    trip.add(0xB181, regs(&.{ .{ 1, 1000 }, .{ 2, shared }, .{ 4, mark } }));
    trip.add(0x6815, regs(&.{ .{ 1, 1000 }, .{ 2, shared }, .{ 4, mark } }));
    trip.add(0x42A5, regs(&.{ .{ 1, 1000 }, .{ 2, shared }, .{ 4, mark } }));
    trip.add(0xD109, regs(&.{ .{ 1, 1000 }, .{ 2, shared }, .{ 4, mark } }));
    trip.add(0x3901, regs(&.{ .{ 1, 1000 }, .{ 2, shared }, .{ 4, mark } }));
    trip.add(0xE7EF, regs(&.{ .{ 1, 999 }, .{ 2, shared }, .{ 4, mark } }));
    // Zero is 1000 trips off and one is 999, so 998 are safe.
    try std.testing.expectEqual(@as(?u64, 998), trip.trips(&.{}));
}

test "a CBNZ on a moving value sitting at zero allows no trips" {
    // cbnz r0,out ; adds r0,#1 ; b loop
    var trip = Trip{};
    trip.head[0] = 1;
    trip.add(0xB908, regs(&.{.{ 0, 0 }}));
    trip.add(0x3001, regs(&.{.{ 0, 0 }}));
    trip.add(0xE7FC, regs(&.{.{ 0, 1 }}));
    try std.testing.expectEqual(@as(?u64, 0), trip.trips(&.{}));
}

test "a CBZ on a value faster than the followed pace is refused" {
    // cbz r0,out ; b loop, with the head saying r0 moves 0x10000 a trip
    var trip = Trip{};
    trip.head[0] = 0x1_0000;
    trip.add(0xB108, regs(&.{.{ 0, 5 }}));
    trip.add(0xE7FD, regs(&.{.{ 0, 5 }}));
    try std.testing.expectEqual(@as(?u64, null), trip.trips(&.{}));
}
