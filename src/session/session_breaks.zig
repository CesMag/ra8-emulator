//! A core's breakpoints read back through the session (RA8EMU-765), for the
//! disassembly and source gutters. Each core keeps its own table, so the list
//! is per core and in the order the breaks were set.

const api = @import("api.zig");

/// One break as a gutter shows it.
pub const Entry = struct {
    address: u32,
    enabled: bool,
};

/// Fills `into` with `core`'s breaks in the order they were set and returns
/// the filled part. A table longer than `into` is cut at `into.len`.
pub fn list(session: *api.Session, core: api.Core, into: []Entry) anyerror![]Entry {
    const machine = try session.machine(core);
    const slots = machine.breaks.entries();
    const count = @min(slots.len, into.len);
    for (slots[0..count], into[0..count]) |slot, *entry| {
        entry.* = .{ .address = slot.point.address, .enabled = slot.enabled };
    }
    return into[0..count];
}

/// The addresses of `core`'s enabled breaks, in the order they were set: the
/// `breaks` slice the disassembly pane's draw takes.
pub fn addresses(session: *api.Session, core: api.Core, into: []u32) anyerror![]u32 {
    const machine = try session.machine(core);
    var count: usize = 0;
    for (machine.breaks.entries()) |slot| {
        if (!slot.enabled) continue;
        if (count == into.len) break;
        into[count] = slot.point.address;
        count += 1;
    }
    return into[0..count];
}
