//! The ICU's NMI and wake-up words (RA8EMU-305): NMIER, NMICLR, NMISR and
//! WUPEN0/WUPEN1.
//!
//! Offsets are ra8_icu_regs.h's, from the ICU base 0x4000_6000:
//!   NMIER  +0x6100 (32b)  which NMI sources are enabled
//!   NMICLR +0x6110 (32b)  write 1 to clear the matching NMISR bit
//!   NMISR  +0x6120 (32b)  latched NMI status, read only
//!   WUPEN0 +0x61A0 (32b)  wake-up enables, held as written
//!   WUPEN1 +0x61A4 (32b)
//! ra8_icu_init clears all of them, so every image that brings the ICU up
//! (icu_extint_demo, kint_demo) wrote four registers nothing modelled.
//!
//! NMIER is set-only: HUM Ch 14.2.14 makes each enable writable once, to 1,
//! so a zero store keeps what is already set. NMISR stays 0 because no NMI
//! source is modelled; NMICLR clears it anyway, so the sequence is honest
//! the day one is. Nothing here wakes a core: WUPEN is held for the
//! low-power model to read later.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");

pub const base: u32 = 0x4000_6000 + 0x6100;

pub const off = struct {
    pub const nmier: u32 = 0x00;
    pub const nmiclr: u32 = 0x10;
    pub const nmisr: u32 = 0x20;
    pub const wupen0: u32 = 0xA0;
    pub const wupen1: u32 = 0xA4;
    pub const span: u32 = 0xA8;
};

pub const Nmi = struct {
    enabled: u32 = 0,
    status: u32 = 0,
    wake: [2]u32 = .{ 0, 0 },
    writes: u32 = 0,

    pub fn quiet(self: *const Nmi) bool {
        return self.writes == 0;
    }

    pub fn read(self: *Nmi, address: u32, width: u3) u32 {
        const offset = address -% base;
        const word: u32 = switch (offset & ~@as(u32, 0x3)) {
            off.nmier => self.enabled,
            off.nmisr => self.status,
            off.wupen0 => self.wake[0],
            off.wupen1 => self.wake[1],
            else => 0,
        };
        return lanes.part(word, offset & 0x3, width);
    }

    pub fn write(self: *Nmi, address: u32, width: u3, value: u32) void {
        const offset = address -% base;
        if (offset >= off.span) return;
        self.writes +%= 1;
        const bits = lanes.merge(0, offset & 0x3, width, value);
        switch (offset & ~@as(u32, 0x3)) {
            off.nmier => self.enabled |= bits,
            off.nmiclr => self.status &= ~bits,
            off.wupen0 => self.wake[0] = lanes.merge(self.wake[0], offset & 0x3, width, value),
            off.wupen1 => self.wake[1] = lanes.merge(self.wake[1], offset & 0x3, width, value),
            else => {},
        }
    }

    pub fn block(self: *Nmi) periph.Block {
        return .{
            .name = "ICU NMI and wake-up",
            .base = base,
            .size = off.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Nmi = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Nmi = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
