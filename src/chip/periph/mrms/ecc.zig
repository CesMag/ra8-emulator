//! MRMS: the MRAM ECC controls, their error status, and the program-speed
//! register, the registers on the R_MRMS window that mrms.zig does not claim.
//!
//! Offsets are ra8_flash_regs.h's ra8_mram_off_t, from the R_MRMS base
//! 0x4013_C000 (HUM Ch 59.5, pp 3554..3580):
//!
//!   MRCDECC   +0x0010  code ECC decoder control, 16 bits, key 0x8C, DECECEN bit 1
//!   MRCRAEINT +0x0014  code read-error IRQ enable, INTENBDC bit 0, INTENBTC bit 1
//!   MRCRAES   +0x0018  code read-error status, DECERRC bit 0, TEDERRC bit 1
//!   MRCRTEA   +0x001C  code TED error address
//!   MRCRDEA   +0x0020  code DEC error address
//!   MRERAINT  +0x0034  extra read-error IRQ enable
//!   MRERAES   +0x0038  extra read-error status
//!   MRERTEA   +0x003C  extra TED error address
//!   MRERDEA   +0x0040  extra DEC error address
//!   MRPSC     +0x2800  program speed control, MHSPEN bit 0
//!   MRCEECC   +0x3804  code ECC encoder control, 16 bits, key 0xC0, ECCEN bit 0
//!
//! ra8_flash.c writes all of these during init: the speed bit, both ECC
//! controls with their keys, and a zero to each error status. Before this
//! file they fell to the sparse register file and every flash-using image
//! reported five unmodelled registers (ra8_ftl_demo, ota_ab_orchestration).
//!
//! THE KEYED CONTROLS keep only their enable bit. A store whose high byte is
//! not the key is dropped and counted, the same cut mrms.zig's frequency
//! latches take; the key is never read back.
//!
//! NO MRAM ECC ERROR IS EVER RAISED, because this model has no bit cells to
//! flip. So the status registers hold zero, a store can only clear bits
//! (writing 0 is how ra8_flash.c clears them), and the four error-address
//! registers read zero. Reset values are not taken from the HUM; every
//! register here starts at zero.
const periph = @import("../registry.zig");

pub const base: u32 = 0x4013_C000;

/// The ECC page: MRCDECC through MRERDEA.
pub const page = struct {
    pub const lo: u32 = base + 0x10;
    pub const span: u32 = 0x34;
};

pub const off = struct {
    pub const mrcdecc: u32 = 0x10;
    pub const mrcraeint: u32 = 0x14;
    pub const mrcraes: u32 = 0x18;
    pub const mrcrtea: u32 = 0x1C;
    pub const mrcrdea: u32 = 0x20;
    pub const mreraint: u32 = 0x34;
    pub const mreraes: u32 = 0x38;
    pub const mrertea: u32 = 0x3C;
    pub const mrerdea: u32 = 0x40;
    pub const mrpsc: u32 = 0x2800;
    pub const mrceecc: u32 = 0x3804;
};

pub const field = struct {
    pub const dececen: u32 = 0x02;
    pub const eccen: u32 = 0x01;
    pub const mhspen: u32 = 0x01;
    /// INTENBDC | INTENBTC, and DECERRC | TEDERRC.
    pub const pair: u32 = 0x03;
};

/// One keyed 16-bit control: KEY[15:8] gates the store, `keep` is the bits
/// the register holds.
pub const Keyed = struct {
    key: u32,
    keep: u32,
    value: u32 = 0,
    latched: u32 = 0,
    refused: u32 = 0,

    pub fn store(self: *Keyed, written: u32) void {
        if ((written >> 8) & 0xFF != self.key) {
            self.refused +%= 1;
            return;
        }
        self.value = written & self.keep;
        self.latched +%= 1;
    }
};

pub const Ecc = struct {
    decoder: Keyed = .{ .key = 0x8C, .keep = field.dececen },
    encoder: Keyed = .{ .key = 0xC0, .keep = field.eccen },
    code_irq: u32 = 0,
    extra_irq: u32 = 0,
    code_status: u32 = 0,
    extra_status: u32 = 0,
    speed: u32 = 0,

    /// An image that never touched the MRAM controls.
    pub fn quiet(self: *const Ecc) bool {
        return self.decoder.latched == 0 and self.decoder.refused == 0 and
            self.encoder.latched == 0 and self.encoder.refused == 0 and self.speed == 0;
    }

    pub fn read(self: *Ecc, address: u32, width: u3) u32 {
        _ = width;
        return switch (address -% base) {
            off.mrcdecc => self.decoder.value,
            off.mrcraeint => self.code_irq,
            off.mrcraes => self.code_status,
            off.mreraint => self.extra_irq,
            off.mreraes => self.extra_status,
            off.mrpsc => self.speed,
            off.mrceecc => self.encoder.value,
            else => 0,
        };
    }

    pub fn write(self: *Ecc, address: u32, width: u3, value: u32) void {
        _ = width;
        switch (address -% base) {
            off.mrcdecc => self.decoder.store(value & 0xFFFF),
            off.mrcraeint => self.code_irq = value & field.pair,
            off.mrcraes => self.code_status &= value,
            off.mreraint => self.extra_irq = value & field.pair,
            off.mreraes => self.extra_status &= value,
            off.mrpsc => self.speed = value & field.mhspen,
            off.mrceecc => self.encoder.store(value & 0xFFFF),
            else => {},
        }
    }

    /// The three windows: the ECC page, MRPSC and MRCEECC.
    pub fn attach(self: *Ecc, bus: *periph.Bus) periph.Error!void {
        try bus.add(self.window("MRMS-ECC", page.lo, page.span));
        try bus.add(self.window("MRPSC", base + off.mrpsc, 4));
        try bus.add(self.window("MRCEECC", base + off.mrceecc, 4));
    }

    fn window(self: *Ecc, name: []const u8, at: u32, size: u32) periph.Block {
        return .{
            .name = name,
            .base = at,
            .size = size,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ecc = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ecc = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
