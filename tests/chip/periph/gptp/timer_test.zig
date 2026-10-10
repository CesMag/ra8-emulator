//! The GPTP time arithmetic: the accumulator, the offset, and the two views.
const std = @import("std");
const ra8 = @import("ra8");

const timer = ra8.chip.periph.gptp_timer;

/// 4.0 nanoseconds per ESWCLK cycle in 5.27 fixed point, the increment a
/// driver programs for a 250 MHz clock.
const four_ns: u32 = 4 << timer.scale.subns_shift;

test "a stopped unit reads time zero" {
    var unit = timer.Unit{};
    unit.advance(four_ns, timer.scale.eswclk_hz);
    const now = unit.now();
    try std.testing.expectEqual(@as(u64, 0), now.sec);
    try std.testing.expectEqual(@as(u32, 0), now.nsec);
}

test "a running unit advances one second per ESWCLK second at 4 ns per clk" {
    var unit = timer.Unit{};
    unit.start();
    unit.advance(four_ns, timer.scale.eswclk_hz);
    try std.testing.expectEqual(@as(u64, 1), unit.now().sec);
    unit.advance(four_ns, timer.scale.eswclk_hz);
    try std.testing.expectEqual(@as(u64, 2), unit.now().sec);
}

test "half the increment is half the rate, a mis-programmed timer drifts" {
    var unit = timer.Unit{};
    unit.start();
    unit.advance(four_ns / 2, timer.scale.eswclk_hz);
    const now = unit.now();
    try std.testing.expectEqual(@as(u64, 0), now.sec);
    try std.testing.expectEqual(@as(u32, 500_000_000), now.nsec);
}

test "a zero increment stands still" {
    var unit = timer.Unit{};
    unit.start();
    unit.advance(0, timer.scale.eswclk_hz);
    try std.testing.expectEqual(@as(u64, 0), unit.now().sec);
    try std.testing.expectEqual(@as(u32, 0), unit.ticks);
}

test "a stop clears the count and keeps the staged offset" {
    var unit = timer.Unit{};
    unit.start();
    _ = unit.setOffset(1234, 500);
    unit.advance(four_ns, timer.scale.eswclk_hz);
    unit.stop();
    try std.testing.expectEqual(@as(u64, 0), unit.now().sec);
    unit.start();
    try std.testing.expectEqual(@as(u64, 1234), unit.now().sec);
    try std.testing.expectEqual(@as(u32, 500), unit.now().nsec);
}

test "the offset adds to the free-running count" {
    var unit = timer.Unit{};
    unit.start();
    try std.testing.expect(!unit.setOffset(10, 250_000_000));
    unit.advance(four_ns, timer.scale.eswclk_hz);
    const now = unit.now();
    try std.testing.expectEqual(@as(u64, 11), now.sec);
    try std.testing.expectEqual(@as(u32, 250_000_000), now.nsec);
}

test "an offset with more than a second of nanoseconds is normalized, not masked" {
    var unit = timer.Unit{};
    unit.start();
    // The field allows up to 2^30 - 1, which is above one second; dev
    // commits it as-is and reports a nanoseconds value of 1,050,000,000.
    try std.testing.expect(unit.setOffset(5, 1_050_000_000));
    const now = unit.now();
    try std.testing.expectEqual(@as(u64, 6), now.sec);
    try std.testing.expectEqual(@as(u32, 50_000_000), now.nsec);
    try std.testing.expect(now.nsec < timer.scale.ns_per_sec);
}

test "the carry out of the sum is completed" {
    var unit = timer.Unit{};
    unit.start();
    _ = unit.setOffset(0, 900_000_000);
    unit.advance(four_ns / 2, timer.scale.eswclk_hz);
    const now = unit.now();
    try std.testing.expectEqual(@as(u64, 1), now.sec);
    try std.testing.expectEqual(@as(u32, 400_000_000), now.nsec);
}

test "the AVTP view is the same instant flattened to nanoseconds" {
    const now = timer.Time{ .sec = 3, .nsec = 250 };
    try std.testing.expectEqual(@as(u64, 3_000_000_250), now.avtp());
}

test "the seconds split 32 and 16 across the M and U halves" {
    const now = timer.Time{ .sec = (7 << 32) | 0xDEAD_BEEF, .nsec = 0 };
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), now.middle());
    try std.testing.expectEqual(@as(u32, 7), now.upper());
}

test "an L sample holds the seconds for the M and U reads" {
    var unit = timer.Unit{};
    unit.start();
    _ = unit.setOffset((2 << 32) | 9, 0);
    _ = unit.sampleGptp();
    unit.advance(four_ns, timer.scale.eswclk_hz);
    try std.testing.expectEqual(@as(u32, 9), unit.latchedMiddle());
    try std.testing.expectEqual(@as(u32, 2), unit.latchedUpper());
}

test "an AVTP sample holds its upper half" {
    var unit = timer.Unit{};
    unit.start();
    _ = unit.setOffset(10, 0);
    const low = unit.sampleAvtp();
    const flat: u64 = 10 * timer.scale.ns_per_sec;
    try std.testing.expectEqual(@as(u32, @truncate(flat)), low);
    try std.testing.expectEqual(@as(u32, @truncate(flat >> 32)), unit.latchedAvtpUpper());
}

test "the sub-second accumulator never reaches one second" {
    var unit = timer.Unit{};
    unit.start();
    var round: u32 = 0;
    while (round < 16) : (round += 1) {
        unit.advance(four_ns + 7, timer.scale.eswclk_hz);
        try std.testing.expect(unit.fixed < timer.scale.one_second_fixed);
    }
    try std.testing.expectEqual(@as(u32, 16), unit.ticks);
}

test "a long elapsed span does not overflow the fixed-point product" {
    var unit = timer.Unit{};
    unit.start();
    const increment = std.math.maxInt(u32);
    const cycles = std.math.maxInt(u64);
    unit.advance(increment, cycles);
    const total = @as(u128, increment) * cycles;
    try std.testing.expectEqual(
        @as(u64, @truncate(total / timer.scale.one_second_fixed)),
        unit.acc_sec,
    );
    try std.testing.expectEqual(@as(u64, @intCast(total % timer.scale.one_second_fixed)), unit.fixed);
}

test "a unit that never ran says so" {
    var unit = timer.Unit{};
    try std.testing.expect(!unit.ran());
    unit.start();
    try std.testing.expect(unit.ran());
}
