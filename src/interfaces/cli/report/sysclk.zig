//! The clock-tree part of the end-of-run report: which source the firmware
//! ended up on, what it divided down to, and every store the protection
//! register swallowed.
//!
//! A store dropped by PRC0 is the quiet one. Silicon discards it with no fault
//! and no status bit, so the run has to say it out loud or a bring-up that
//! never took effect looks like one that did.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const div = @import("ra8_chip").periph.sysclk_div;

pub fn sections(board: *Board, out: Writer) !void {
    const unit = &board.tree;
    if (unit.quiet()) return;
    try out.print("system clock: {s}", .{unit.source().name()});
    if (unit.programmed != 0) {
        try out.print(", ", .{});
        try tree(board, out);
    }
    try out.print("\n", .{});
    if (unit.dropped_locked != 0) {
        try out.print(
            "system clock: DROPPED {d} store(s), PRCR.PRC0 was locked\n",
            .{unit.dropped_locked},
        );
    }
    if (unit.unstable_selects != 0) {
        try out.print(
            "system clock: {d} select(s) of a source whose OSCSF flag was never up\n",
            .{unit.unstable_selects},
        );
    }
    if (unit.reserved_selects != 0) {
        try out.print(
            "system clock: {d} select(s) of CKSEL 7, which is not a defined source\n",
            .{unit.reserved_selects},
        );
    }
}

/// The twelve dividers, in the order the HUM table lists them. A code the
/// firmware tree does not define is printed as the code, not as a ratio.
fn tree(board: *Board, out: Writer) !void {
    const unit = &board.tree;
    for (div.domains, 0..) |domain, i| {
        if (i != 0) try out.print(" ", .{});
        try one(out, domain, unit.ratioOf(domain), div.codeAt(unit.divcr, domain.at));
    }
    for (div.domains2) |domain| {
        try out.print(" ", .{});
        try one(out, domain, unit.ratioOf2(domain), div.codeAt(unit.divcr2, domain.at));
    }
}

fn one(out: Writer, domain: div.Domain, ratio: ?u32, code: u4) !void {
    if (ratio) |by| {
        try out.print("{s}/{d}", .{ domain.name, by });
    } else {
        try out.print("{s}=code{d}", .{ domain.name, code });
    }
}
