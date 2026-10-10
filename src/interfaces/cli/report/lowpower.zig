//! The end-of-run lines for the low-power control bytes.
const std = @import("std");
const Board = @import("ra8_board").board.Board;

pub fn sections(board: *const Board, out: anytype) !void {
    const unit = &board.low_power;
    if (unit.quiet()) return;

    if (unit.stores != 0) {
        if (unit.state()) |selected| {
            try out.print("low power: WFI enters {s}, bus output {s}, IO {s}, DCDC soft-start {s}\n", .{
                selected.name(),
                if (unit.busOutputKept()) "kept" else "released",
                if (unit.ioKept()) "kept" else "released",
                unit.softStart().name(),
            });
        } else {
            try out.print("low power: LPSCR.LPMD = 0x{X}, which the HUM does not define\n", .{
                unit.lpscr & @import("ra8_chip").periph.lpm.field.lpmd,
            });
        }
    }
    if (unit.dropped_locked != 0) {
        try out.print("low power: DROPPED {d} store(s), PRCR.PRC1 was locked\n", .{unit.dropped_locked});
    }
    if (unit.standby_selects != 0) {
        try out.print("low power: {d} select(s) of a state that stops the peripherals\n", .{unit.standby_selects});
    }
    if (unit.undefined_modes != 0) {
        try out.print("low power: {d} store(s) selected an LPMD the HUM does not define\n", .{unit.undefined_modes});
    }
    if (unit.prohibited_softstart != 0) {
        try out.print("low power: {d} store(s) asked for DCSSMODE 0, which the HUM prohibits\n", .{unit.prohibited_softstart});
    }
}
