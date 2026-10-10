//! Whether the board can go to its next queued event without a boundary in
//! between (RA8EMU-185, slice 3).
//!
//! A sleeping core with nothing pending may run straight to the next edge
//! the event queue knows about. The queue covers the timers (AGT, GPT, RTC,
//! the watchdogs). Some blocks still move once per boundary without a queued
//! event: the low-power timer counts boundaries, the microphone fills a
//! window each one, an armed DMA channel moves there, and the USB host,
//! Ethernet switch, NPU, ADC, CAN and IPC models step their work there. While any of them could be
//! working, a wider stretch would change what they do, so the width stays
//! where it was. The display's vsync is timed rather than stepped, so it is
//! an edge (`vsyncDue`) instead of a reason to stay narrow. So is the GPT:
//! it counts by virtual time, but a stretch over several of its wraps would
//! raise one overflow for all of them, so its next wrap, turn or compare
//! match is an edge too (`gptDue`).
//!
//! The answer is deliberately cautious. A block whose model only reports
//! whether firmware has ever used it counts as busy once it has, even when
//! nothing is in flight. That costs speed, never correctness. Narrower
//! per-block in-flight checks can widen it later. Level sources that raise
//! at every boundary (the console's TXI, USBFS_INT) are already pending when
//! the core is asked, so `sleep_pace.still` keeps the width for them.
const std = @import("std");
const Board = @import("board.zig").Board;
const gpt_sched = @import("ra8_chip").periph.gpt.sched;

/// Every block that moves per boundary and is not on the event queue is
/// idle, so nothing but a queued event can happen before the next one.
pub fn quietUntilDue(board: *const Board) bool {
    for (board.lowpower.channels) |channel| if (channel.running()) return false;
    for (&board.dma.channels) |*channel| if (channel.armed()) return false;
    if (!board.microphone.quiet()) return false;
    if (!board.usb.quiet()) return false;
    if (!board.rswitch.quiet() or !board.ptp.quiet()) return false;
    if (!board.npu.quiet() or !board.adc.quiet()) return false;
    if (!board.c6.quiet()) return false;
    return board.can.quiet() and board.mailbox.quiet();
}

/// Cycles until the display's next vsync: an edge of its own, kept on the
/// panel rather than the event queue. Zero when there is none.
pub fn vsyncDue(board: *const Board) u64 {
    const frame = board.display.output.vsync orelse return 0;
    return board.time.base.cyclesUntil(frame.next_ns);
}

/// Cycles until the earliest thing any running GPT channel does next: a
/// saw's wrap, a triangle's peak or trough, or a compare match. Zero when
/// every channel is stopped.
pub fn gptDue(board: *const Board) u64 {
    const now = board.time.base.now();
    var soonest: u64 = std.math.maxInt(u64);
    for (board.pwm.channels) |channel| {
        const times = [_]?u64{
            gpt_sched.dueAt(channel, now),
            gpt_sched.turnDueAt(channel, .trough, now),
            gpt_sched.compareDueAt(channel, .a, now),
            gpt_sched.compareDueAt(channel, .b, now),
        };
        for (times) |at| if (at) |ns| {
            soonest = @min(soonest, ns);
        };
    }
    if (soonest == std.math.maxInt(u64)) return 0;
    return @max(board.time.base.cyclesUntil(soonest), 1);
}
