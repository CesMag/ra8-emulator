//! The unmodelled-register worklist in the end-of-run report: the lowest
//! peripheral addresses the firmware touched that no block models. The
//! summary line counts them; this names them, so the next model to write is
//! one run away instead of one bisection away.
const registry = @import("ra8_chip").periph.registry;

/// Enough to name the next model without burying the rest of the report.
pub const limit: usize = 16;

pub const Entry = struct {
    address: u32,
    written: bool,
};

/// Fill `out` with the lowest unmodelled addresses, ascending, and return the
/// filled prefix.
pub fn lowest(bus: *const registry.Bus, out: []Entry) []Entry {
    var count: usize = 0;
    var cells = bus.cells.iterator();
    while (cells.next()) |cell| {
        const entry: Entry = .{ .address = cell.key_ptr.*, .written = cell.value_ptr.written };
        count = insert(out, count, entry);
    }
    return out[0..count];
}

/// Insert into the sorted prefix `out[0..count]`, dropping the highest entry
/// once `out` is full. Returns the new prefix length.
fn insert(out: []Entry, count: usize, entry: Entry) usize {
    var at: usize = count;
    while (at > 0 and out[at - 1].address > entry.address) : (at -= 1) {}
    if (at >= out.len) return count;
    const kept = @min(count + 1, out.len);
    var slot: usize = kept - 1;
    while (slot > at) : (slot -= 1) out[slot] = out[slot - 1];
    out[at] = entry;
    return kept;
}

/// One line per listed address, then how many were left off.
pub fn section(bus: *const registry.Bus, out: anytype) !void {
    var buffer: [limit]Entry = undefined;
    const shown = lowest(bus, &buffer);
    for (shown) |entry| {
        const how = if (entry.written) "written" else "read only";
        try out.print("unmodelled: 0x{X:0>8} {s}\n", .{ entry.address, how });
    }
    const total = bus.unmodelledAddresses();
    if (total > shown.len) try out.print("unmodelled: {d} more not listed\n", .{total - shown.len});
}
