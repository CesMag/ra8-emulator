//! A Zig run's boundary close on the shared 1 ns wall clock (RA8EMU-643):
//! CPU0's stretch, charged at the image rate when the run is rate scaled
//! (RA8EMU-526), CPU1's round and any external-memory stalls the fabric owes
//! each initiator. The longest of them is what the board, both SysTick banks
//! and the window pacer see.
const std = @import("std");
const backing = @import("ra8_board").external_backing;
const clocks = @import("ra8_chip").periph.clocks;
const Clock = @import("run_clock.zig").Clock;

/// Charge `instructions` retired by CPU0 to both cores and the board.
pub fn close(clock: *Clock, instructions: u32) !void {
    const rate_scaled = clock.rateScaled();
    const cycles: u64 = if (rate_scaled) scaled: {
        const value = @as(u64, instructions) * clock.boundary_hz.? + clock.cycle_remainder;
        clock.cycle_remainder = value % clocks.timebase.default_hz;
        break :scaled value / clocks.timebase.default_hz;
    } else instructions;
    const fabric = backing.fabricOf(clock.memory.store);
    const cpu0_stall = if (fabric) |unit| unit.takePending(.cpu0) else 0;
    if (clock.cpu1) |second| if (rate_scaled)
        second.roundAt(instructions, clock.boundary_hz.?)
    else
        second.round(instructions);
    const cpu1_stall = if (fabric) |unit| unit.takePending(.cpu1) else 0;
    const ethos_stall = if (fabric) |unit| unit.takePending(.ethos_u55) else 0;
    const cpu1_ran = if (clock.cpu1) |second| second.last_ran else 0;
    const duration = @max(@max(cycles +| cpu0_stall, cpu1_ran +| cpu1_stall), ethos_stall);
    if (clock.cpu1) |second| second.advanceTime(duration -| cpu1_ran);
    clock.wall_cycles +|= duration;
    if (fabric) |unit| unit.setWall(clock.wall_cycles);
    var left = duration;
    while (left != 0) {
        const piece: u32 = @intCast(@min(left, std.math.maxInt(u32)));
        try clock.timebase.advance(clock.memory, piece);
        try clock.ns_timebase.advanceSysTick(clock.memory, piece);
        try clock.board.tick(clock.memory, piece);
        left -= piece;
    }
    clock.accounted += instructions;
    clock.resume_boundary = false;
    clock.resume_unscaled = false;
    if (clock.board.display.output.vsync) |*vsync| try vsync.settle(clock.board.time.base.now());
    clock.boundary_hz = null;
}

/// Close what the boot retired past the last boundary, then once more for
/// fabric service owed with nothing retired: vector reads, a faulting
/// fetch, or a synchronous NPU command.
pub fn finish(clock: *Clock, ran: u64) !void {
    while (clock.accounted < ran) {
        const piece: u32 = @intCast(@min(ran - clock.accounted, std.math.maxInt(u32)));
        try close(clock, piece);
    }
    try close(clock, 0);
}
