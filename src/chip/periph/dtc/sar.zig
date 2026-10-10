//! DTCSAR: the security attribution of the two transfer controllers' start
//! and status registers (HUM Rev 1.30 18.2.1, CPSCU 0x4000_8030).
//!
//! Bit 0 (DTCSTSA0) attributes DTC0.DTCST and DTC0.DTCSTS, bit 16 (DTCSTSA1)
//! the same pair on DTC1; 0 is Secure, 1 Non-secure, and the rest of the word
//! reads zero. Reset is zero, so both controllers start Secure.
//!
//! GATED BY PRCR_S.PRC4, the convention cpscu.zig holds for every CPSCU word
//! next door: a store with PRC4 shut is dropped and counted. A read is never
//! gated.
//!
//! RECORDED, NOT ENFORCED, the line cpscu.zig and the SAU model draw: the bus
//! here does not refuse a Non-secure access to DTCST because this word left
//! it Secure. The word is modelled so a driver reads back what it wrote
//! instead of the sparse bus's alternating cell.
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
const lanes = @import("../lanes.zig");

pub const win_base: u32 = 0x4000_8030;
pub const win_span: u32 = 0x4;
pub const reset: u32 = 0;

pub const field = struct {
    pub const dtcstsa0: u32 = 0x0000_0001;
    pub const dtcstsa1: u32 = 0x0001_0000;
    pub const writable: u32 = dtcstsa0 | dtcstsa1;
};

pub const Unit = struct {
    word: u32 = reset,
    /// Stores that landed with PRC4 open.
    writes: u32 = 0,
    /// Stores silicon would have discarded, because PRC4 was shut.
    locked_writes: u32 = 0,
    /// Null until wired; an unwired unit accepts nothing.
    protection: ?*const prcr.Prcr = null,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.writes == 0 and self.locked_writes == 0;
    }

    /// Whether the boot handed DTC0's (or DTC1's) start/status pair to the
    /// Non-secure world.
    pub fn nonSecure(self: *const Unit, controller: periph.Issuer) bool {
        const bit = switch (controller) {
            .cpu0 => field.dtcstsa0,
            .cpu1 => field.dtcstsa1,
        };
        return self.word & bit != 0;
    }

    pub fn read(self: *const Unit, address: u32, width: u3) u32 {
        return lanes.part(self.word, (address -% win_base) & 0x3, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const gate = self.protection orelse return;
        if (!gate.unlocked(prcr.group.sar)) {
            self.locked_writes +%= 1;
            return;
        }
        const merged = lanes.merge(self.word, (address -% win_base) & 0x3, width, value);
        self.word = merged & field.writable;
        self.writes +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "CPSCU-DTCSAR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
