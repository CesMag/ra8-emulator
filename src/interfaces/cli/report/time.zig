//! The timekeeping part of the end-of-run report: where the calendar got to,
//! and what the alarm actually did.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;

/// One line for the clock, then the things that went wrong separately. A
/// counter write the running clock refused and a store into a read-only
/// counter are both firmware bugs a bench run would show, so they are not
/// folded into the traffic that worked.
pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.clock;
    if (unit.quiet()) return;
    const now = unit.now;
    try out.print(
        "RTC: 20{d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} after {d} second(s)\n",
        .{ now.year, now.month, now.day, now.hour, now.minute, now.second, unit.seconds },
    );
    if (unit.matches != 0) {
        try out.print(
            "RTC: alarm matched {d} time(s), {d} raised as an event\n",
            .{ unit.matches, unit.alarms },
        );
    }
    if (unit.periodics != 0) {
        try out.print("RTC: {d} periodic event(s) raised\n", .{unit.periodics});
    }
    if (unit.refused_running != 0) {
        try out.print(
            "RTC: REFUSED {d} counter write(s) with the count running\n",
            .{unit.refused_running},
        );
    }
    if (unit.resets != 0) {
        try out.print(
            "RTC: {d} software reset(s), RCR2.RESET auto-cleared\n",
            .{unit.resets},
        );
    }
    if (unit.refused_read_only != 0) {
        try out.print(
            "RTC: REFUSED {d} store(s) into R64CNT, which is read-only\n",
            .{unit.refused_read_only},
        );
    }
    if (unit.count_source.chosen) {
        try out.print(
            "RTC: counting from the {s} (RCR4.RCKSEL)\n",
            .{unit.count_source.source.name()},
        );
    }
    if (unit.count_source.late != 0) {
        try out.print(
            "RTC: {d} RCKSEL store(s) after the initial register settings\n",
            .{unit.count_source.late},
        );
    }
    if (unit.count_source.unsourced != 0) {
        try out.print(
            "RTC: {d} software reset(s) with no count source selected\n",
            .{unit.count_source.unsourced},
        );
    }
    if (unit.divisor.hot_stores != 0) {
        try out.print(
            "RTC: {d} frequency register store(s) taken with the prescaler running\n",
            .{unit.divisor.hot_stores},
        );
    }
    if (unit.divisor.out_of_order != 0) {
        try out.print(
            "RTC: {d} RFRL store(s) with RFRH untouched since reset\n",
            .{unit.divisor.out_of_order},
        );
    }
}
