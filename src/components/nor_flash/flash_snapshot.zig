//! The OSPI NOR flash's half of the `storage` snapshot section (RA8EMU-674,
//! RA8EMU-1104): the part's capacity, then the sectors something wrote as
//! sparse entries (snapshot/sparse.zig), 4 KiB each, by ascending number.
//!
//! The capacity is the board profile's, not state: a file saved for another
//! capacity is refused. A load is two steps, so the board's section can read
//! every half before it changes anything: `read` gives a `Staged` part, and
//! `install` puts the flash built from it in place.
const fields = @import("ra8_snapshot").fields;
const sparse = @import("ra8_snapshot").sparse;
const flash = @import("flash.zig");
const Flash = flash.Flash;

const sector_len = flash.part.sector_len;
const Sectors = sparse.List(sector_len);
/// The largest part the format takes, in bytes.
const max_capacity: u32 = 256 * 1024 * 1024;

pub fn write(writer: anytype, part: *const Flash) !void {
    try fields.write(writer, part.capacity);
    try fields.write(writer, part.live());
    var sector: [sector_len]u8 = undefined;
    for (0..part.capacity / sector_len) |index| {
        if (!part.sectorDirty(@intCast(index))) continue;
        try fields.write(writer, @as(u32, @intCast(index)));
        part.readSector(@intCast(index), &sector);
        try writer.writeAll(&sector);
    }
}

/// A part read from a payload and not yet built.
pub const Staged = struct {
    capacity: u32,
    sectors: Sectors,

    /// Whether the file was saved for `live`'s capacity and every sector
    /// lands inside it.
    pub fn fits(self: *const Staged, live: *const Flash) bool {
        if (self.capacity != live.capacity) return false;
        var i: u32 = 0;
        while (i < self.sectors.count) : (i += 1) {
            if (self.sectors.number(i) >= live.capacity / sector_len) return false;
        }
        return true;
    }

    /// A fresh flash of `live`'s capacity holding these sectors, on `live`'s
    /// allocator. On failure nothing is left allocated.
    pub fn build(self: *const Staged, live: *const Flash) !Flash {
        var built = Flash.init(live.allocator);
        errdefer built.deinit();
        built.capacity = live.capacity;
        try built.resize(built.capacity);
        var i: u32 = 0;
        while (i < self.sectors.count) : (i += 1) try built.loadSector(self.sectors.number(i), self.sectors.value(i));
        return built;
    }
};

pub fn read(cursor: *fields.Cursor) fields.Error!Staged {
    const capacity = try fields.read(u32, cursor);
    return .{ .capacity = capacity, .sectors = try Sectors.read(cursor, inMaximumPart) };
}

/// Put `built` in `live`'s place and free what `live` held.
pub fn install(live: *Flash, built: Flash) void {
    live.deinit();
    live.* = built;
}

fn inMaximumPart(number: u32) bool {
    return number < max_capacity / sector_len;
}
