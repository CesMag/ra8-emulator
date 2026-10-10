//! VBTBPCR1: the VBATT battery power-supply switch stop (RA8EMU-314).
//!
//!   VBTBPCR1 (0x4001_EA88, 8b)  BPWSWSTP b0  0 switch enabled, 1 stopped
//!
//! The offset and bit are ra8_bkup_regs.h's k_ra8_bkup_off_vbtbpcr1 (0xA88 on
//! the SYSC page) and k_ra8_bkup_vbtbpcr1_mask_bpwswstp (HUM Ch 12.2.11 p
//! 507). It sits outside the 0x4001_EC40 VBATT window bkup.zig claims, which
//! is why ctrl.zig leaves it alone and why it gets a block of its own.
//!
//! ra8_bkup.c stores 0 to enable the switch and BPWSWSTP to stop it, always
//! inside RA8_PROTECTED_WRITE(k_ra8_prcr_unlock_lpm): like the rest of the
//! VBATT file it is a PRC1 register (HUM Ch 13.1 Table 13.1 p 521). A store
//! with PRC1 locked is dropped and counted; reads are never gated.
//!
//! RESET STATE: the tree does not state one. This model starts at 0, the
//! switch enabled, which is the value ra8_bkup_init writes on its default
//! path; nothing in the corpus reads the register before writing it.
const periph = @import("../registry.zig");
const lanes = @import("../lanes.zig");
const prcr = @import("../prcr.zig");

pub const address: u32 = 0x4001_EA88;
pub const bpwswstp: u8 = 1 << 0;
pub const guard: u16 = prcr.group.lpm;

pub const Pcr1 = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    value: u8 = 0,
    /// Stores that landed.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC1 was locked.
    dropped_locked: u32 = 0,
    /// Times firmware stopped a running switch.
    stops: u32 = 0,
    /// Times firmware re-enabled a stopped switch.
    enables: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Pcr1 {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Pcr1) bool {
        return self.stores == 0 and self.dropped_locked == 0;
    }

    /// Whether the battery power-supply switch is enabled.
    pub fn switchEnabled(self: *const Pcr1) bool {
        return self.value & bpwswstp == 0;
    }

    pub fn read(self: *const Pcr1, at: u32, width: u3) u32 {
        return lanes.part(self.value, at - address, width);
    }

    pub fn write(self: *Pcr1, at: u32, width: u3, value: u32) void {
        _ = width;
        if (at != address) return;
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const was_enabled = self.switchEnabled();
        self.value = @truncate(value);
        self.stores +%= 1;
        if (was_enabled and !self.switchEnabled()) self.stops +%= 1;
        if (!was_enabled and self.switchEnabled()) self.enables +%= 1;
    }

    pub fn block(self: *Pcr1) periph.Block {
        return .{
            .name = "VBATT VBTBPCR1",
            .base = address,
            .size = 1,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, at: u32, width: u3) u32 {
    const self: *Pcr1 = @ptrCast(@alignCast(context));
    return self.read(at, width);
}

fn writeThunk(context: *anyopaque, at: u32, width: u3, value: u32) void {
    const self: *Pcr1 = @ptrCast(@alignCast(context));
    self.write(at, width, value);
}
