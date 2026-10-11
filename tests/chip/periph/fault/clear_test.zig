//! Tests for src/chip/periph/fault/clear.zig.

const std = @import("std");
const ra8 = @import("ra8");
const fault_clear = ra8.chip.periph.fault.status.clear;
const memmap = ra8.chip.core.memmap;

/// The two status words as plain memory, standing in for a core's PPB.
const Words = struct {
    cfsr: u32 = 0,
    hfsr: u32 = 0,
    sfsr: u32 = 0,
    afsr: u32 = 0,

    fn at(self: *Words, address: u32) *u32 {
        if (address == fault_clear.sfsr) return &self.sfsr;
        if (address == memmap.scb.afsr) return &self.afsr;
        return if (address == memmap.scb.cfsr) &self.cfsr else &self.hfsr;
    }

    pub fn readWord(self: *Words, address: u32) !u32 {
        return self.at(address).*;
    }

    pub fn writeWord(self: *Words, address: u32, value: u32) !void {
        self.at(address).* = value;
    }

    /// What a store does to RAM, after the hook has latched it.
    fn store(self: *Words, clears: *fault_clear.Clears, address: u32, size: u32, value: u32) void {
        const word = self.at(address & ~@as(u32, 3));
        clears.record(address, size, value, word.*);
        const shift: u5 = @intCast((address & 3) * 8);
        const lanes: u32 = (if (size >= 4) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(size * 8)) - 1) << shift;
        word.* = (word.* & ~lanes) | ((value << shift) & lanes);
    }
};

test "writing CFSR back to itself clears every bit it read" {
    var words = Words{ .cfsr = 0x0000_0082 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr, 4, words.cfsr);
    // Plain RAM: the store left the fault standing until the boundary.
    try std.testing.expectEqual(@as(u32, 0x82), words.cfsr);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0), words.cfsr);
}

test "a zero written to a bit leaves it standing" {
    var words = Words{ .cfsr = 0x0001_0082 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr, 4, 0x0000_0002);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x0001_0080), words.cfsr);
}

test "a byte store to BFSR clears BusFault bits only" {
    var words = Words{ .cfsr = 0x0001_8282 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr + 1, 1, 0x82);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x0001_0082), words.cfsr);
}

test "a halfword store to UFSR clears UsageFault bits only" {
    var words = Words{ .cfsr = 0x0201_0082 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr + 2, 2, 0x0200);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x0001_0082), words.cfsr);
}

test "several stores in one stretch clear the union of their ones" {
    var words = Words{ .cfsr = 0x0000_8283 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr, 4, 0x0000_0001);
    words.store(&clears, memmap.scb.cfsr, 4, 0x0000_8200);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x0000_0082), words.cfsr);
    try std.testing.expectEqual(@as(u32, 2), clears.stores);
}

test "a bit raised after the store survives the clear" {
    var words = Words{ .cfsr = 0x0000_0082 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.cfsr, 4, 0x0000_0082);
    // The boundary latches a new MemManage before the clear is applied.
    words.cfsr |= 0x0000_0001;
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x0000_0001), words.cfsr);
}

test "HFSR is cleared on its own, and CFSR is left alone" {
    var words = Words{ .cfsr = 0x0000_0082, .hfsr = 0x4000_0000 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.hfsr, 4, 0x4000_0000);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0), words.hfsr);
    try std.testing.expectEqual(@as(u32, 0x82), words.cfsr);
}

test "an apply with nothing latched writes nothing" {
    var words = Words{ .cfsr = 0x0000_0082 };
    var clears = fault_clear.Clears.init();
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x82), words.cfsr);
    try std.testing.expect(clears.slot(memmap.scb.cfsr + 0x10) == null);
}

test "writing SFSR back to itself clears it and leaves CFSR alone" {
    var words = Words{ .cfsr = 0x82, .sfsr = 0x48 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, fault_clear.sfsr, 4, words.sfsr);
    try std.testing.expectEqual(@as(u32, 0x48), words.sfsr);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0), words.sfsr);
    try std.testing.expectEqual(@as(u32, 0x82), words.cfsr);
}

test "a zero written to SFSR leaves every SecureFault bit standing" {
    var words = Words{ .sfsr = 0x10 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, fault_clear.sfsr, 4, 0);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0x10), words.sfsr);
}

test "writing AFSR back to itself clears the bits it read" {
    var words = Words{ .afsr = 0x0008_0000 };
    var clears = fault_clear.Clears.init();
    words.store(&clears, memmap.scb.afsr, 4, words.afsr);
    try clears.apply(&words);
    try std.testing.expectEqual(@as(u32, 0), words.afsr);
}
