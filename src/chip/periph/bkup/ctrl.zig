//! The VBATT control register file: every BAT*/VBT* register in the backup
//! window that is not one of the 128 retained data bytes.
//!
//! The block next door (bkup.zig) claims the whole VBATT window so it can own
//! VBTBKRn, but it only ever answered two addresses inside it: VBTBER and the
//! data array. Everything between them read back zero and swallowed writes,
//! which is strictly worse than leaving the range to the sparse register file:
//! a driver that programs VBTBPCR2 or VBTICTLR and reads it back to confirm
//! the write took sees zero, decides the block is dead, and stops. Claiming a
//! window is a promise to answer all of it, and this file is the rest of that
//! promise. dev's board_periph_bkup.c has the same hole from the same cause.
//!
//! Offsets are from ra8_bkup_regs.h on ra8-firmware zig/dev, relative to the
//! VBTBER address (SYSC 0x4001_E000 + 0xC40) that the window starts at:
//!
//!   VBTBER   +0x000  backup-register access enable, VBAE at bit 3
//!   VBTBPCR2 +0x005  VDETBATT level select and VDETE
//!   VBTBPSR  +0x006  power-supply status: VBPORF (W0C), VBPORM, SWM
//!   VBTADSR  +0x008  tamper-detection status, VBTADF[2:0] (W0C)
//!   VBTADCR1 +0x009  tamper IRQ enable, backup-clear enable
//!   VBTADCR2 +0x00A  RTC time-capture event source select
//!   VBTICTLR +0x00C  RTCIC0..2 input enable
//!   VBTICTLR2+0x00D  RTCIC0..2 edge and noise-canceller select
//!   VBTIMONR +0x00E  RTCIC0..2 live input level, read-only
//!   VBTNCWCR +0x010  noise-canceller width select
//!   VBTADCR3 +0x014  tamper HUK zeroization enable
//!
//! VBTBPCR1 (the battery power-supply switch stop) sits at 0xA88, outside this
//! window, and is left to the sparse file where it already was.
//!
//! Only the bits with a field table in that header are writable here; a
//! register whose bit layout is not grounded in the tree is a plain retained
//! byte, which is honest and still better than a zero. Status bits are
//! write-zero-to-clear and monitor bits refuse a store outright, so firmware
//! cannot fake a tamper event or a power-on flag it never saw. PRCR gating is
//! not this file's job: the owning block asks the protection model first.

/// Byte offsets inside the VBATT window.
pub const off = struct {
    pub const vbtber: u32 = 0x000;
    pub const vbtbpcr2: u32 = 0x005;
    pub const vbtbpsr: u32 = 0x006;
    pub const vbtadsr: u32 = 0x008;
    pub const vbtadcr1: u32 = 0x009;
    pub const vbtadcr2: u32 = 0x00A;
    pub const vbtictlr: u32 = 0x00C;
    pub const vbtictlr2: u32 = 0x00D;
    pub const vbtimonr: u32 = 0x00E;
    pub const vbtncwcr: u32 = 0x010;
    pub const vbtadcr3: u32 = 0x014;
};

/// VBTBER fields (HUM Ch 12.2.6 p 504).
pub const vbtber = struct {
    /// VBAE at bit 3: 1 enables VBTBKRn access.
    pub const vbae: u8 = 0x08;
    /// "Value after reset" row: VBAE is already armed.
    pub const reset: u8 = 0x08;
};

/// VBTBPCR2 fields (HUM Ch 12.2.12 p 508).
pub const vbtbpcr2 = struct {
    /// VDETE at bit 4: VCC drop-detection enable.
    pub const vdete: u8 = 0x10;
    /// VDETLVL[2:0].
    pub const level: u8 = 0x07;
};

/// VBTBPSR fields (HUM Ch 12.2.13 p 509).
pub const vbtbpsr = struct {
    /// VBPORF at bit 0: the VBATT power-on-reset flag, write 0 to clear.
    pub const vbporf: u8 = 0x01;
    /// VBPORM at bit 4: VBATT_R level monitor, read-only.
    pub const vbporm: u8 = 0x10;
    /// SWM at bit 5: battery switch monitor, read-only.
    pub const swm: u8 = 0x20;
};

/// VBTADSR fields (HUM Ch 12.2.14 p 509).
pub const vbtadsr = struct {
    /// VBTADF[2:0], one tamper-detect flag per RTCIC channel, write 0 to clear.
    pub const flags: u8 = 0x07;
};

/// RTCIC0..RTCIC2, the three tamper-detect channels.
pub const channels: u32 = 3;

/// One register in the file.
pub const Slot = enum(u8) {
    ber,
    bpcr2,
    bpsr,
    adsr,
    adcr1,
    adcr2,
    ictlr,
    ictlr2,
    imonr,
    ncwcr,
    adcr3,
};

pub const slot_count: usize = 11;

/// How one register answers a store: the bits it keeps, the bits a zero
/// clears, and what it holds out of reset.
const Spec = struct {
    offset: u32,
    writable: u8,
    clearable: u8 = 0,
    reset: u8 = 0,
    name: []const u8,
};

const specs = [slot_count]Spec{
    .{ .offset = off.vbtber, .writable = vbtber.vbae, .reset = vbtber.reset, .name = "VBTBER" },
    .{ .offset = off.vbtbpcr2, .writable = vbtbpcr2.vdete | vbtbpcr2.level, .name = "VBTBPCR2" },
    .{ .offset = off.vbtbpsr, .writable = 0, .clearable = vbtbpsr.vbporf, .name = "VBTBPSR" },
    .{ .offset = off.vbtadsr, .writable = 0, .clearable = vbtadsr.flags, .name = "VBTADSR" },
    .{ .offset = off.vbtadcr1, .writable = 0xFF, .name = "VBTADCR1" },
    .{ .offset = off.vbtadcr2, .writable = 0xFF, .name = "VBTADCR2" },
    .{ .offset = off.vbtictlr, .writable = 0xFF, .name = "VBTICTLR" },
    .{ .offset = off.vbtictlr2, .writable = 0xFF, .name = "VBTICTLR2" },
    .{ .offset = off.vbtimonr, .writable = 0, .name = "VBTIMONR" },
    .{ .offset = off.vbtncwcr, .writable = 0xFF, .name = "VBTNCWCR" },
    .{ .offset = off.vbtadcr3, .writable = 0xFF, .name = "VBTADCR3" },
};

/// The register at `offset`, or null when nothing in the file lives there.
pub fn slotOf(offset: u32) ?Slot {
    for (&specs, 0..) |spec, index| {
        if (spec.offset == offset) return @fromBackingInt(@intCast(index));
    }
    return null;
}

pub fn nameOf(slot: Slot) []const u8 {
    return specs[@backingInt(slot)].name;
}

/// The retained bytes of the file, and what the run did to them.
pub const Control = struct {
    regs: [slot_count]u8 = defaults(),
    writes: u32 = 0,
    /// Stores that landed on a read-only register or a read-only bit.
    refused: u32 = 0,
    /// Status flags a write-zero actually cleared.
    cleared: u32 = 0,

    pub fn init() Control {
        return .{};
    }

    pub fn reset(self: *Control) void {
        self.* = .{};
    }

    pub fn quiet(self: *const Control) bool {
        return self.writes == 0 and self.refused == 0 and self.cleared == 0;
    }

    pub fn get(self: *const Control, slot: Slot) u8 {
        return self.regs[@backingInt(slot)];
    }

    /// Drive a bit the silicon owns rather than the firmware: a monitor level,
    /// a power-on flag, a tamper detection. Nothing in the tree raises these
    /// yet; the seam is here so the block that does is not tempted to make the
    /// firmware's own store do it.
    pub fn raise(self: *Control, slot: Slot, mask: u8) void {
        self.regs[@backingInt(slot)] |= mask;
    }

    pub fn vbaeSet(self: *const Control) bool {
        return self.get(.ber) & vbtber.vbae != 0;
    }

    /// Read one byte. An offset inside the window that the file does not own
    /// reads zero, the same answer it gave before this file existed.
    pub fn read(self: *const Control, offset: u32) u8 {
        const slot = slotOf(offset) orelse return 0;
        return self.get(slot);
    }

    /// Write one byte: writable bits take the value, clearable bits fall on a
    /// zero, and everything else keeps what it had.
    pub fn write(self: *Control, offset: u32, value: u8) void {
        const slot = slotOf(offset) orelse return;
        const spec = specs[@backingInt(slot)];
        const register = &self.regs[@backingInt(slot)];
        const before = register.*;
        register.* = (before & ~spec.writable) | (value & spec.writable);
        const falling = before & spec.clearable & ~value;
        register.* &= ~falling;
        if (falling != 0) self.cleared +%= 1;
        if (spec.writable != 0) {
            self.writes +%= 1;
        } else if (falling == 0) {
            self.refused +%= 1;
        }
    }
};

fn defaults() [slot_count]u8 {
    var out = @as([slot_count]u8, @splat(0));
    for (&specs, 0..) |spec, index| out[index] = spec.reset;
    return out;
}
