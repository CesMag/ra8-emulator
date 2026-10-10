//! The timer part of the end-of-run report: which channels actually counted,
//! and the writes a running channel refused. All three timer families live
//! here: the low-power timer that counts through standby, the interval
//! timers, and the PWM timers.
const gpt = @import("ra8_chip").periph.gpt;
const gtclkcr = @import("ra8_chip").periph.gtclkcr;
const iwdt = @import("ra8_chip").periph.iwdt;

const Board = @import("../../../board/board.zig").Board;
const Writer = @import("../report.zig").Writer;

/// AGT first, then GPT, the order dev's combined report used. A channel that
/// never ran and never counted anything says nothing.
pub fn sections(board: *Board, out: Writer) !void {
    try lowpower(board, out);
    try interval(board, out);
    try bankClock(board, out);
    try bankSync(board, out);
    try pwm(board, out);
    try independent(board, out);
}

/// GTCLKCR, the GPT bank's clock domain. It is written once, before the
/// first channel is released, so an image that never used a timer is silent.
fn bankClock(board: *Board, out: Writer) !void {
    const unit = &board.gpt_clock;
    if (unit.quiet()) return;
    if (unit.programmed()) {
        try out.print("GPT bank: GTCLK tied to PCLKA before the module-stop release\n", .{});
    }
    if (unit.prohibited_running != 0) {
        try out.print(
            "GPT bank: PROHIBITED {d} GTCLKCR store(s), the block was already released\n",
            .{unit.prohibited_running},
        );
    }
}

/// GTSTR, GTSTP and GTCLR name channels by bit, so the line worth reading is
/// a store that named several at once: that is a synchronised start, and it
/// is the only way the three-phase driver gets its phases onto one edge.
fn bankSync(board: *Board, out: Writer) !void {
    const state = &board.pwm.sync;
    if (state.quiet()) return;
    try out.print(
        "GPT bank: {d} channel start/stop/clear bit(s) acted on, {d} store(s) named several at once\n",
        .{ state.acted, state.together },
    );
    if (state.absent != 0) {
        try out.print(
            "GPT bank: {d} bit(s) named a channel this part does not carry\n",
            .{state.absent},
        );
    }
    if (state.stray != 0) {
        try out.print(
            "GPT bank: {d} store(s) named a channel but not the window they came through\n",
            .{state.stray},
        );
    }
}

/// The independent watchdog. An image that never touched it says nothing.
fn independent(board: *Board, out: Writer) !void {
    const unit = &board.heartbeat;
    if (unit.quiet()) return;
    try out.print(
        "IWDT: {d} refresh(es), counter {d}/{d}, {d} underflow(s), {s}\n",
        .{ unit.refreshes, unit.counter, iwdt.full_scale, unit.underflows, if (unit.armed) "running" else "stopped" },
    );
    if (unit.stoppedByOptions()) {
        try out.print(
            "IWDT: stopped by OFS0 (0x{X:0>8}, IWDTSTRT set); {d} refresh sequence(s) started nothing\n",
            .{ unit.option_word.?, unit.stopped_refreshes },
        );
    }
    if (unit.dropped != 0) {
        try out.print(
            "IWDT: {d} IWDTRR write(s) refreshed nothing (0x00 then 0xFF, in order, or the counter keeps falling)\n",
            .{unit.dropped},
        );
    }
    if (unit.nmis != 0) {
        try out.print("IWDT: {d} underflow(s) asked for an NMI, IWDTRCR.RSTIRQS clear\n", .{unit.nmis});
    }
    if (unit.bad_acks != 0) {
        try out.print("IWDT: {d} ack(s) wrote a one at a flag and cleared nothing (IWDTSR is write-zero-to-clear)\n", .{unit.bad_acks});
    }
    if (unit.frozen_writes != 0) {
        try out.print("IWDT: {d} store(s) carried CNTVAL bits, dropped (the counter is the hardware's)\n", .{unit.frozen_writes});
    }
}

fn lowpower(board: *Board, out: Writer) !void {
    const unit = &board.lowpower;
    if (unit.quiet()) return;
    for (&unit.channels, 0..) |*channel, index| {
        if (channel.underflows == 0 and !channel.running()) continue;
        try out.print(
            "ULPT{d}: counter 0x{X:0>8}, {d} underflow(s), divide by {d}, {s}\n",
            .{
                index,
                channel.counter,
                channel.underflows,
                channel.divider(),
                if (channel.running()) "running" else "stopped",
            },
        );
        if (channel.forced_stops != 0) {
            try out.print("ULPT{d}: {d} forced stop(s) through TSTOP\n", .{ index, channel.forced_stops });
        }
    }
    try compares(board, out);
}

/// The compare values a channel was given, and how often the count passed
/// one. A channel that was programmed and never reached its compare says so,
/// because that is the shape of a period that is too long for the run.
fn compares(board: *Board, out: Writer) !void {
    for (&board.lowpower.channels, 0..) |*channel, index| {
        const pair = &channel.compares;
        if (pair.quiet()) continue;
        try out.print(
            "ULPT{d}: compare match A {d} time(s) on 0x{X:0>8}, B {d} time(s) on 0x{X:0>8}\n",
            .{ index, pair.matches_a, pair.a, pair.matches_b, pair.b },
        );
    }
}

/// PRCR and the domain it protects. Both stay quiet when the firmware never
/// touched them, and both go loud when a write was dropped: on silicon those
/// writes vanish with no fault and no flag, which is the failure that is
/// impossible to spot from the firmware side.
fn interval(board: *Board, out: Writer) !void {
    for (&board.interval.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "AGT{d}: count 0x{X:0>4} of 0x{X:0>4}, {d} underflow(s), running={s}\n",
            .{ index, channel.counter, channel.reload, channel.underflows, yesno(channel.running()) },
        );
        if (channel.matches_a != 0 or channel.matches_b != 0) {
            try out.print(
                "AGT{d}: compare match A {d} time(s), B {d} time(s)\n",
                .{ index, channel.matches_a, channel.matches_b },
            );
        }
        if (channel.masked != 0) {
            try out.print(
                "AGT{d}: {d} compare crossing(s) raised nothing, AGTCMSR disabled\n",
                .{ index, channel.masked },
            );
        }
        if (channel.forced_stops != 0) {
            try out.print(
                "AGT{d}: {d} forced stop(s) through AGTCR.TSTOP\n",
                .{ index, channel.forced_stops },
            );
        }
        if (channel.refused_running != 0) {
            try out.print(
                "AGT{d}: REFUSED {d} counter/compare write(s) with the count running\n",
                .{ index, channel.refused_running },
            );
        }
        if (channel.dropped_cascade != 0) {
            try out.print(
                "AGT{d}: LOST {d} cascade underflow(s) while stopped, " ++
                    "AGT1's TSTART has to be set before AGT0's\n",
                .{ index, channel.dropped_cascade },
            );
        }
    }
}

fn pwm(board: *Board, out: Writer) !void {
    for (&board.pwm.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "GPT{d}: GTCNT 0x{X:0>8} of 0x{X:0>8}, counting as {s}, {d} overflow(s), running={s}\n",
            .{ index, channel.cnt, channel.periodOrDefault(), channel.shape().name(), channel.overflows, yesno(channel.running()) },
        );
        try pwmShape(index, channel.shapes, channel.shape(), out);
        try pwmSource(index, channel.source(), out);
        try pwmCompares(index, &channel.compares, out);
        try pwmPeriod(index, &channel.period, out);
        try pwmProtection(index, &channel.guard, out);
    }
}

/// The shape a channel asked for against the one it ended up counting in.
/// MD shares GTCR with CST, so a driver that starts a channel by writing the
/// whole control word also rewrites the shape; this is the line that says the
/// channel is not counting the way its own init configured it.
fn pwmShape(index: usize, log: gpt.mode.Log, now: gpt.mode.Mode, out: Writer) !void {
    if (!log.overwritten(now)) return;
    const first = log.first orelse return;
    try out.print(
        "GPT{d}: MD FIRST SELECTED {s}, NOW {s} AFTER {d} CHANGE(S)\n",
        .{ index, first.name(), now.name(), log.changes },
    );
}

/// The clock GTCR.TPCS picked for this channel. An undivided channel says
/// nothing, because that is the reset state every channel starts in; a
/// channel a driver deliberately slowed is the line worth reading, and so is
/// an encoding this model does not recognise.
fn pwmSource(index: usize, source: gpt.clock.Source, out: Writer) !void {
    if (source == .pclkd) return;
    try out.print("GPT{d}: counting on {s}\n", .{ index, source.name() });
}

/// GTCCRA and GTCCRB, but only for a channel that programmed one. A compare
/// armed and never reached is the interesting line, so it is printed with its
/// value rather than dropped for having matched nothing.
fn pwmCompares(index: usize, pair: *const gpt.match.Pair, out: Writer) !void {
    if (pair.writes == 0) return;
    try out.print(
        "GPT{d}: compare A 0x{X:0>8} matched {d} time(s), B 0x{X:0>8} matched {d} time(s)\n",
        .{ index, pair.value(.a), pair.matches(.a), pair.value(.b), pair.matches(.b) },
    );
}

/// GTPBR, the period parked to become the live one at the next cycle end.
/// Only a channel that parked one says anything, and the line worth reading is
/// a runtime period change: parking the buffer is the only way the HAL moves
/// the period of a channel that is already counting.
fn pwmPeriod(index: usize, parked: *const gpt.periods.Period, out: Writer) !void {
    if (!parked.parked) return;
    try out.print(
        "GPT{d}: GTPBR 0x{X:0>8}, {d} buffer load(s), {d} moved the period\n",
        .{ index, parked.buffer, parked.loads, parked.changes },
    );
    if (parked.loads == 0) {
        try out.print(
            "GPT{d}: the parked period never arrived, no counting cycle ended\n",
            .{index},
        );
    }
}

/// GTWP, but only when the protection actually cost a store. A shut channel
/// is ordinary: the HAL locks every channel it finishes with. A store the
/// lock turned away is the line worth reading, because the driver that made
/// it thinks it landed.
fn pwmProtection(index: usize, guard: *const gpt.protection.Lock, out: Writer) !void {
    if (guard.refused == 0) return;
    try out.print(
        "GPT{d}: REFUSED {d} write(s), GTWP shut\n",
        .{ index, guard.refused },
    );
}

fn yesno(value: bool) []const u8 {
    return if (value) "yes" else "no";
}
