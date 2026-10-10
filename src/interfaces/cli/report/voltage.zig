//! The end-of-run lines for the core voltage range, and for the brown-out
//! hazard between that range and the clock the tree ended up on.
const Board = @import("ra8_board").board.Board;

pub fn sections(board: *const Board, out: anytype) !void {
    try range(board, out);
    try hazard(board, out);
}

fn range(board: *const Board, out: anytype) !void {
    const unit = &board.voltage;
    if (unit.quiet()) return;

    if (unit.stores != 0) {
        try out.print("core voltage: {s} range selected\n", .{unit.range().name()});
    }
    if (unit.transitions > 1) {
        try out.print("core voltage: {d} range change(s)\n", .{unit.transitions});
    }
    if (unit.dropped_locked != 0) {
        try out.print("core voltage: DROPPED {d} store(s), PRCR.PRC0 was locked\n", .{unit.dropped_locked});
    }
    if (unit.flag_writes != 0) {
        try out.print("core voltage: {d} store(s) named VSCMTSF, which only hardware sets\n", .{unit.flag_writes});
    }
}

/// A PLL select with the high-voltage range still in force is the brown-out
/// ra8_cgc.c's step 2 exists to avoid. The select landed, so this is the only
/// place the run can say the order was wrong.
fn hazard(board: *const Board, out: anytype) !void {
    const watch = &board.brownout;
    if (watch.quiet()) return;

    if (watch.brownouts != 0) {
        try out.print(
            "core voltage: BROWN-OUT HAZARD, {d} PLL clock select(s) with the high-voltage range still selected\n",
            .{watch.brownouts},
        );
    } else {
        try out.print(
            "core voltage: {d} PLL clock select(s), all with the core already out of the high-voltage range\n",
            .{watch.lifts},
        );
    }
}
