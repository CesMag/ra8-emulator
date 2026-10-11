//! The order the sections of a run's report come out in.
//!
//! Every other file in src/board writes one block's account of itself.
//! This one decides the running order and nothing else, so main.zig can ask
//! for the report in a single call and the order lives somewhere a reader
//! can find it.
//!
//! The undefined block comes last on purpose. It is the one section that
//! can invalidate everything above it: a run that executed an instruction
//! the architecture does not define has computed every address, length and
//! sector number after that point out of a program counter. Printed last it
//! reads as a verdict on the report rather than as one more block's account
//! of itself.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const report = @import("../report.zig");
const report_timing = @import("timing.zig");
const pacing = @import("ra8_session").run.pacing;
const RunPolicy = @import("ra8_session").run_policy.RunPolicy;
const idle = @import("ra8_chip").core.idle;
const report_part = @import("part.zig");
const clocks = @import("ra8_chip").periph.clocks;
const bus_fault = @import("ra8_chip").periph.bus_fault;

/// One line for the BusFaults a run raised, and nothing when it raised none.
pub fn busErrors(out: Writer, tally: bus_fault.Tally) !void {
    if (tally.raised == 0) return;
    try out.print("bus faults: {d} raised, {d} escalated to HardFault\n", .{ tally.raised, tally.escalated });
}

/// What a `--cpu zig` run can report: the part, the bus, its own timebase
/// and the blocks, with the instructions it retired as the elapsed time. The
/// pend/idle seam counts and the stepped-instruction counts have no source
/// on the Zig core, so a line says they are not
/// reported. The
/// BusFaults a `--bus-errors` run raised close it.
pub fn zigCore(out: Writer, board: *Board, policy: ?*const RunPolicy, timebase: clocks.Clocks, retired: u64, bus_errors: bus_fault.Tally) !void {
    try report_part.print(out, board.part);
    try report.bus(board, out);
    try report_timing.clock(out, timebase);
    if (policy) |asked| {
        try pacing.line(out, asked.pacing, board.time.base.now());
        try asked.soak.line(out);
    }
    try out.print("zig core: pend/idle seam counts and stepped-instruction counts are not reported\n", .{});
    try report.blocks(board, out, .{ .elapsed = retired });
    try busErrors(out, bus_errors);
}

/// What CPU1 did, printed under CPU0's own account of the run.
pub const cpu1 = @import("cores.zig").cpu1;
