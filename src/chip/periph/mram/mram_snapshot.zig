//! The option MRAM's half of the `storage` snapshot section (RA8EMU-674,
//! RA8EMU-1104): the unit's plain state, then the OTP cells something
//! programmed as sparse entries (snapshot/sparse.zig), one byte each, by
//! ascending address.
//!
//! Not saved: `otp` (the cell map, rebuilt on load) and `memory` (the guest
//! memory handle the board attaches). A load is two steps, so the board's
//! section can read every half before it changes anything: `read` gives a
//! `Staged` unit, and `install` puts it in place once its cells are built.
const std = @import("std");
const fields = @import("ra8_snapshot").fields;
const sparse = @import("ra8_snapshot").sparse;
const Mram = @import("mram.zig").Mram;
const otp = @import("mram_otp.zig");

const wiring = .{ "otp", "memory" };
const Cells = sparse.List(1);
pub const Map = std.AutoHashMap(u32, u8);

pub fn write(writer: anytype, unit: *const Mram) !void {
    try fields.writeExcept(writer, unit.*, wiring);
    const cells = &unit.otp.written;
    const keys = try sparse.sortedKeys(cells.allocator, cells);
    defer cells.allocator.free(keys);
    try sparse.writeCount(writer, keys);
    for (keys) |key| {
        try fields.write(writer, key);
        try writer.writeByte(cells.get(key).?);
    }
}

/// A unit read from a payload and not yet in place: the live unit with the
/// saved fields read over it, and the cells its OTP is to hold.
pub const Staged = struct {
    unit: Mram,
    cells: Cells,

    /// Whether the command stream's length lands inside its buffer.
    pub fn fits(self: *const Staged) bool {
        const stream = self.unit.stream;
        return stream.len <= stream.payload.len;
    }

    /// The cell map this unit will hold. On failure nothing is left
    /// allocated.
    pub fn build(self: *const Staged) error{OutOfMemory}!Map {
        var map = Map.init(self.unit.otp.written.allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(self.cells.count);
        var i: u32 = 0;
        while (i < self.cells.count) : (i += 1) map.putAssumeCapacity(self.cells.number(i), self.cells.value(i)[0]);
        return map;
    }

    /// Put this unit in `live`'s place holding `map`, and free the cells
    /// `live` held.
    pub fn install(self: *Staged, live: *Mram, map: Map) void {
        live.otp.written.deinit();
        self.unit.otp.written = map;
        live.* = self.unit;
    }
};

pub fn read(cursor: *fields.Cursor, live: *const Mram) fields.Error!Staged {
    var unit = live.*;
    try fields.readOver(cursor, &unit, wiring);
    return .{ .unit = unit, .cells = try Cells.read(cursor, inWindow) };
}

fn inWindow(address: u32) bool {
    return address >= otp.window.lo and address < otp.window.hi + otp.window.program_bytes;
}
