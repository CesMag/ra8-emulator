//! Covers src/chip/periph/time/systick_due.zig: each core's SysTick wraps at the
//! virtual ns its own clock puts it at.
const std = @import("std");
const ra8 = @import("ra8");

const due = ra8.chip.periph.clocks.systick_due;
const rate = ra8.chip.periph.sysclk.rate;
const TimeBase = ra8.chip.periph.clocks.timebase.TimeBase;
const Timer = ra8.chip.core.systick_bank.Timer;
const clocks = ra8.chip.periph.clocks;

const running = clocks.csr_enable | clocks.csr_tickint;
const quickstart_pll1 = rate.PllConfig{ .ccr = 0xFA02, .ccr2 = 0x451 };

fn tree(divcr2: u16) rate.Inputs {
    return .{ .source = .pll1, .divcr2 = divcr2, .pll1 = quickstart_pll1, .pll2 = .{} };
}

test "the bring-up dividers put the same counter's wrap four times later on CPU1" {
    // Armed as firmware arms it, CVR cleared: zero comes a full period in (RA8EMU-657).
    const counter = due.Counter{ .csr = running, .rvr = 999, .cvr = 0 };
    try std.testing.expectEqual(@as(?u64, 1_000), due.coreDueNs(tree(0x2020), .cpu0, counter, 0));
    try std.testing.expectEqual(@as(?u64, 4_000), due.coreDueNs(tree(0x2020), .cpu1, counter, 0));
}

test "different dividers on each core move each wrap with its own clock" {
    // CPU0 /2 at 500 MHz, CPU1 /4 at 250 MHz.
    const counter = due.Counter{ .csr = running, .rvr = 499, .cvr = 0 };
    try std.testing.expectEqual(@as(?u64, 5_000 + 1_000), due.coreDueNs(tree(0x0021), .cpu0, counter, 5_000));
    try std.testing.expectEqual(@as(?u64, 5_000 + 2_000), due.coreDueNs(tree(0x0021), .cpu1, counter, 5_000));
}

test "a disabled counter, a zero reload and an unpriced tree never wrap" {
    const off = due.Counter{ .csr = 0, .rvr = 99, .cvr = 99 };
    try std.testing.expectEqual(@as(?u64, null), due.dueNs(off, 0, 1_000_000_000));
    const empty = due.Counter{ .csr = running, .rvr = 0, .cvr = 0 };
    try std.testing.expectEqual(@as(?u64, null), due.dueNs(empty, 0, 1_000_000_000));
    const counter = due.Counter{ .csr = running, .rvr = 99, .cvr = 99 };
    const loco = rate.Inputs{ .source = .loco, .divcr2 = 0, .pll1 = .{}, .pll2 = .{} };
    try std.testing.expectEqual(@as(?u64, null), due.coreDueNs(loco, .cpu0, counter, 0));
}

/// Run a SysTick on a core clocked at `hz` up to its due time and check it
/// wraps exactly there: not one cycle sooner, and on the cycle it reaches it.
fn wrapsAtDue(hz: u64, start_ns: u64) !void {
    var timer = Timer{ .csr = running, .rvr = 2_499, .cvr = 1_234 };
    var base = TimeBase{};
    base.setRate(hz);
    base.base_ns = start_ns;
    const at = due.dueNs(.{ .csr = timer.csr, .rvr = timer.rvr, .cvr = timer.cvr }, base.now(), hz).?;
    const cycles = base.cyclesUntil(at);
    try std.testing.expectEqual(@as(u64, 0), timer.advance(@intCast(cycles - 1)));
    base.advance(cycles - 1);
    try std.testing.expect(base.now() < at);
    try std.testing.expectEqual(@as(u64, 1), timer.advance(1));
    base.advance(1);
    try std.testing.expectEqual(at, base.now());
    try std.testing.expect(timer.pending);
}

test "a core's SysTick wraps on the cycle that reaches its due time, both cores at the bring-up rates" {
    try wrapsAtDue(rate.coreHz(tree(0x2020), .cpu0).?, 0);
    try wrapsAtDue(rate.coreHz(tree(0x2020), .cpu1).?, 70_000);
    try wrapsAtDue(rate.coreHz(tree(0x0021), .cpu0).?, 12_345);
    try wrapsAtDue(rate.coreHz(tree(0x0021), .cpu1).?, 3);
}
