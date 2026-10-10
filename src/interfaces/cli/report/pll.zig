//! The end-of-run lines for the PLL configuration registers, one PLL at a
//! time, plus MOSCWTCR and the stores the PRCR gate turned away.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const Config = @import("ra8_chip").periph.pll.config.Config;

fn ratio(value: ?u8, out: anytype) !void {
    if (value) |one| {
        try out.print("/{d}", .{one});
    } else {
        try out.print("/?", .{});
    }
}

/// One PLL's own lines. Silent when firmware never touched it, so a board
/// that only brings up PLL1 says nothing about PLL2.
fn onePll(label: []const u8, one: Config, out: anytype) !void {
    if (one.quiet()) return;
    if (one.configured()) {
        const mul = one.multiplier();
        try out.print("{s}: {s} in ", .{ label, one.source().name() });
        try ratio(one.inputRatio(), out);
        try out.print(", x{d}.{d:0>2}, P", .{ mul.whole(), mul.hundredths() });
        const outputs = one.outputRatios();
        try ratio(outputs[0], out);
        try out.print(" Q", .{});
        try ratio(outputs[1], out);
        try out.print(" R", .{});
        try ratio(outputs[2], out);
        try out.print("\n", .{});
    }
    if (one.dropped_running != 0) {
        try out.print(
            "{s}: DROPPED {d} configuration store(s), {s} was still running\n",
            .{ label, one.dropped_running, label },
        );
    }
    if (one.prohibited_divider != 0) {
        try out.print(
            "{s}: REJECTED {d} CCR2 store(s) carrying a prohibited divider code\n",
            .{ label, one.prohibited_divider },
        );
    }
}

pub fn sections(board: *const Board, out: anytype) !void {
    const unit = &board.plls;
    if (unit.quiet()) return;

    try onePll("PLL1", unit.pll1, out);
    try onePll("PLL2", unit.pll2, out);
    if (unit.moscwtcr != 0) {
        try out.print("PLL1: main oscillator wait code {d}\n", .{unit.moscwtcr});
    }
    if (unit.dropped_locked != 0) {
        try out.print("PLL: DROPPED {d} store(s), PRCR.PRC0 was locked\n", .{unit.dropped_locked});
    }
}
