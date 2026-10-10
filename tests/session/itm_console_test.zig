//! Covers src/session/itm_console.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const itm = ra8.chip.periph.itm;
const itm_console = cli_app.zig_run.itm_console;

const demcr = ra8.chip.core.memmap.scb.demcr;
const trcena: u32 = 1 << 24;

/// A memory that keeps the last word written to each ITM register and DEMCR.
const Words = struct {
    words: [itm.limits.span / 4]u32 = @splat(0),
    demcr: u32 = 0x0100_0000 >> 24,

    pub fn readWord(self: *Words, address: u32) !u32 {
        if (address == demcr) return self.demcr;
        return self.words[(address - itm.base) / 4];
    }

    pub fn writeWord(self: *Words, address: u32, value: u32) !void {
        if (address == demcr) {
            self.demcr = value;
        } else self.words[(address - itm.base) / 4] = value;
    }
};

test "a console run opens the ITM with port 0 on, as a probe leaves it" {
    const port = itm_console.opened();
    try std.testing.expectEqual(itm.tcr_bits.itmena, port.tcr);
    try std.testing.expectEqual(@as(u32, 1), port.ter);
}

test "priming puts FIFOREADY in every stimulus port and TER and TCR beside them" {
    var memory: Words = .{};
    const port = itm_console.opened();
    try itm_console.prime(&memory, &port);
    for (0..itm.limits.ports) |stim| try std.testing.expectEqual(itm.fifo_ready, memory.words[stim]);
    try std.testing.expectEqual(@as(u32, 1), memory.words[itm.offsets.ter / 4]);
    try std.testing.expectEqual(itm.tcr_bits.itmena, memory.words[itm.offsets.tcr / 4]);
    // TRCENA joins whatever DEMCR already held.
    try std.testing.expectEqual(trcena | 1, memory.demcr);
}
