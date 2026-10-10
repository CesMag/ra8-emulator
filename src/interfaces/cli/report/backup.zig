//! The battery-backed corner of the end-of-run report: the SYSC write-protect
//! register, the retained VBTBKRn bytes, and the VBATT control file beside
//! them. Split out of report.zig, which was at the file-length limit.
//!
//! PRCR drops a protected write in silence, so the loud lines here are the
//! ones that name a store nobody would otherwise know had vanished.
const std = @import("std");

const Board = @import("ra8_board").board.Board;

const Writer = *std.Io.Writer;

pub fn sections(board: *Board, out: Writer) !void {
    if (!board.protection.quiet()) {
        if (board.protection.bad_key != 0) {
            try out.print(
                "SYSC-PRCR: unlocks={d} REJECTED={d} (a PRCR write without the 0xA5 key unlocks nothing)\n",
                .{ board.protection.unlocks, board.protection.bad_key },
            );
        } else {
            try out.print("SYSC-PRCR: unlocks={d}, groups 0x{X:0>4}\n", .{ board.protection.unlocks, board.protection.groups });
        }
    }
    try controlFile(board, out);
    if (board.backup.quiet()) return;
    switch (board.backup.lastDrop()) {
        .locked => try out.print(
            "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (PRCR.PRC1 locked: unlock with 0xA502)\n",
            .{ board.backup.writes, board.backup.dropped_locked },
        ),
        .disabled => try out.print(
            "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (VBTBER.VBAE is 0)\n",
            .{ board.backup.writes, board.backup.dropped_disabled },
        ),
        .none => try out.print("VBATT-BKUP: VBTBKRn writes={d} (domain retained)\n", .{board.backup.writes}),
    }
}

/// The VBATT control file. A refused store is the loud case: those registers
/// are levels the pins and the power switch drive, so firmware writing one was
/// claiming a tamper event or a power-on flag it never saw.
fn controlFile(board: *Board, out: Writer) !void {
    const file = &board.backup.control;
    if (file.quiet() and board.backup.control_locked == 0) return;
    try out.print(
        "VBATT-CTRL: writes={d}, flags cleared={d}, VBAE={s}\n",
        .{ file.writes, file.cleared, if (file.vbaeSet()) "1" else "0" },
    );
    if (file.refused != 0) {
        try out.print(
            "VBATT-CTRL: REFUSED {d} store(s) to a monitor or status bit, firmware cannot raise one itself\n",
            .{file.refused},
        );
    }
    if (board.backup.control_locked != 0) {
        try out.print(
            "VBATT-CTRL: DROPPED {d} store(s) (PRCR.PRC1 locked: unlock with 0xA502)\n",
            .{board.backup.control_locked},
        );
    }
}
