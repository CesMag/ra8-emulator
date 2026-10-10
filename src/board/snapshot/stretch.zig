//! What a saved run owed its clocks (RA8EMU-700): the instructions its last
//! stretch retired before the budget ran out, not yet charged. A load starts
//! the first stretch that far in (boot.Owed), so the restored run's
//! boundaries land where an uninterrupted run's do. The fractional core
//! cycles carried by the clock-rate conversion resume here too.
//!
//! A file saved before this section existed loads as owing nothing, the
//! behaviour it was saved under. An old four-byte section is unscaled and has
//! no fraction; an old twelve-byte section has no saved boundary rate.
const std = @import("std");
const file = @import("ra8_snapshot").file;

pub const Error = file.Error || error{BadValue};

pub const State = struct {
    owed: u32 = 0,
    cycle_remainder: u64 = 0,
    rate_known: bool = false,
    boundary_hz: ?u64 = null,
};

pub fn save(state: State, writer: anytype) !void {
    try file.writeSectionHeader(writer, .stretch, @sizeOf(u32) + @sizeOf(u64) + 1 + @sizeOf(u64));
    try writer.writeInt(u32, state.owed, .little);
    try writer.writeInt(u64, state.cycle_remainder, .little);
    try writer.writeByte(if (state.boundary_hz != null) 1 else 0);
    try writer.writeInt(u64, state.boundary_hz orelse 0, .little);
}

pub fn load(bytes: []const u8) Error!State {
    const section = try file.Reader.find(bytes, .stretch) orelse return .{};
    if (section.payload.len == @sizeOf(u32)) return .{
        .owed = std.mem.readInt(u32, section.payload[0..4], .little),
        .rate_known = true,
    };
    if (section.payload.len == @sizeOf(u32) + @sizeOf(u64)) return .{
        .owed = std.mem.readInt(u32, section.payload[0..4], .little),
        .cycle_remainder = std.mem.readInt(u64, section.payload[4..12], .little),
    };
    if (section.payload.len != @sizeOf(u32) + @sizeOf(u64) + 1 + @sizeOf(u64)) return Error.BadValue;
    const mode = section.payload[12];
    const hz = std.mem.readInt(u64, section.payload[13..21], .little);
    if (mode > 1 or (mode == 0) != (hz == 0)) return Error.BadValue;
    return .{
        .owed = std.mem.readInt(u32, section.payload[0..4], .little),
        .cycle_remainder = std.mem.readInt(u64, section.payload[4..12], .little),
        .rate_known = true,
        .boundary_hz = if (mode == 1) hz else null,
    };
}
