//! The SD host controller's half of the `sd` snapshot section (RA8EMU-664,
//! RA8EMU-1104): its registers, the transfer in flight and its counters.
//!
//! Not saved, because it is wiring: `card`, the line to the card in the
//! slot. A load keeps the target's.
const fields = @import("ra8_snapshot").fields;
const Sdhi = @import("sdhi.zig").Sdhi;
const xfer = @import("sdhi_xfer.zig");

const wiring = .{"card"};

pub fn write(writer: anytype, unit: *const Sdhi) !void {
    try fields.writeExcept(writer, unit.*, wiring);
}

/// `live` with the saved fields read over it. Nothing changes until the
/// caller stores the result.
pub fn read(cursor: *fields.Cursor, live: *const Sdhi) fields.Error!Sdhi {
    var unit = live.*;
    try fields.readOver(cursor, &unit, wiring);
    return unit;
}

/// Whether the transfer's word index lands inside a block.
pub fn fits(unit: *const Sdhi) bool {
    return unit.data.word_idx <= xfer.words_per_block;
}
