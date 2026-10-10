//! RA8EMU-150: an event INTSELR routes to CPU1 drives DTC1 through CPU1's
//! ICU table and leaves DTC0 and CPU0's table untouched. board/boundary.zig
//! offers a CPU1-routed event to `transfers1` (table .cpu1) only; this pins
//! that pair of controllers against one ICU.
const std = @import("std");
const ra8 = @import("ra8");
const dtc = ra8.chip.periph.dtc;
const icu = ra8.chip.periph.icu;
const xfer = ra8.chip.periph.dtc_xfer;

const Cells = struct {
    base: u32 = 0x2000_0000,
    bytes: [512]u8 = @splat(0),
};

/// One flat window with the calls the controller makes of a core.
const Memory = struct {
    cells: *Cells,

    fn window(self: Memory, address: u32, span: u32) ?[]u8 {
        if (address < self.cells.base) return null;
        const start = address - self.cells.base;
        if (start + span > self.cells.bytes.len) return null;
        return self.cells.bytes[start .. start + span];
    }

    pub fn read(self: Memory, address: u32, into: []u8) !void {
        const from = self.window(address, @intCast(into.len)) orelse return error.Unmapped;
        @memcpy(into, from);
    }

    pub fn write(self: Memory, address: u32, bytes: []const u8) !void {
        const into = self.window(address, @intCast(bytes.len)) orelse return error.Unmapped;
        @memcpy(into, bytes);
    }

    pub fn readWord(self: Memory, address: u32) !u32 {
        var word: [4]u8 = undefined;
        try self.read(address, &word);
        return std.mem.readInt(u32, &word, .little);
    }

    pub fn writeWord(self: Memory, address: u32, value: u32) !void {
        var word: [4]u8 = undefined;
        std.mem.writeInt(u32, &word, value, .little);
        try self.write(address, &word);
    }
};

const vector_base: u32 = 0x2000_0000;
const ti_at: u32 = 0x2000_0100;
const source_at: u32 = 0x2000_0140;
const dest_at: u32 = 0x2000_0180;
const event: u16 = 0x0CC;
const slot: usize = 7;

/// A byte copy, both addresses incrementing, interrupt on the last transfer.
const byte_copy: u32 = (@as(u32, 0b0000_1000) << 24) | (@as(u32, 0b0000_1000) << 16);

/// A started controller reading the descriptor at `ti_at` through `table`.
fn controller(table: ra8.chip.periph.registry.Issuer) dtc.Dtc {
    var unit = dtc.Dtc.init();
    unit.table = table;
    unit.write(dtc.win_base + dtc.off.dtcvbr, 4, vector_base);
    unit.write(dtc.win_base + dtc.off.dtcst, 1, dtc.field.start);
    return unit;
}

fn describe(memory: Memory, count: u16) void {
    memory.writeWord(dtc.entryAddress(vector_base, slot), ti_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.mr, byte_copy) catch unreachable;
    memory.writeWord(ti_at + xfer.off.sar, source_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.dar, dest_at) catch unreachable;
    memory.writeWord(ti_at + xfer.off.counts, @as(u32, count) << 16) catch unreachable;
}

test "a CPU1-routed event runs DTC1 and leaves DTC0 untouched" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    describe(memory, 4);
    cells.bytes[source_at - cells.base] = 0x5A;
    var links = icu.Icu.init();
    links.cpu1[slot] = event | icu.field.dtce;
    var dtc0 = controller(.cpu0);
    var dtc1 = controller(.cpu1);

    try std.testing.expectEqual(@as(?dtc.Outcome, null), dtc0.activate(memory, &links, event));
    const moved = dtc1.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, 1), moved.units);
    try std.testing.expectEqual(@as(u8, 0x5A), cells.bytes[dest_at - cells.base]);
    try std.testing.expectEqual(@as(u32, 1), dtc1.activations);
    try std.testing.expectEqual(@as(u32, 0), dtc0.activations);
    try std.testing.expectEqual(@as(u32, 0), dtc0.refused);
    try std.testing.expectEqual(@as(u32, 0), dtc0.read(dtc.win_base + dtc.off.dtcsts, 2));
    try std.testing.expectEqual(@as(u32, 0), links.links[slot]);
}

test "the last transfer takes DTCE down in CPU1's table, not CPU0's" {
    var cells = Cells{};
    const memory = Memory{ .cells = &cells };
    describe(memory, 1);
    var links = icu.Icu.init();
    links.cpu1[slot] = event | icu.field.dtce;
    links.links[slot] = event | icu.field.dtce;
    var dtc1 = controller(.cpu1);
    _ = dtc1.activate(memory, &links, event).?;
    try std.testing.expectEqual(@as(u32, event), links.cpu1[slot] & ~icu.field.ir);
    try std.testing.expectEqual(@as(u32, event | icu.field.dtce), links.links[slot]);
}
