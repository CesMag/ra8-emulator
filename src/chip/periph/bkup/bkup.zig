//! VBATT backup: the reset-retained register file, and the writes PRCR drops.
//!
//! The RA8D2 keeps 128 battery-backed bytes (VBTBKR0..127) in the R_SYSTEM
//! block at 0x4001_ED00, reachable through the VBATT window that starts at
//! VBTBER (0x4001_EC40). On silicon they keep their contents across a reset,
//! which is the contract a survival demo checks. Ported from
//! board_periph_bkup.c on dev.
//!
//!   VBTBER   (+0x000, 8b)  access enable, VBAE at bit 3, reset value 0x08
//!   VBTBKR0  (+0x0C0, 8b)  first of 128 byte-wide backup slots
//!
//! Two silicon preconditions gate a write here and both are modelled:
//!
//!   1. PRCR.PRC1 unlocked. Every register in the VBATT file is named under
//!      PRC1 (HUM Ch 13.1 Table 13.1 p 521). A write with PRC1 locked is
//!      discarded silently. That is the #131 root cause, bench-confirmed by
//!      J-Link: VBTBKR0 written with PRCR locked reads back 0x0000_0000, and
//!      after PRCR = 0xA502 the identical write sticks.
//!   2. VBTBER.VBAE set (HUM Ch 12.2.6 p 504, "You must write 1 to VBAE before
//!      accessing VBTBKR"). VBAE is already 1 out of reset, which is exactly
//!      why modelling only VBAE left the emulator green while the bench was
//!      red.
//!
//! Reads are never gated: PRCR gates writes only (HUM Ch 13.1 p 520), so a
//! dropped write shows up as a read-back of the old value rather than a fault.
pub const ctrl = @import("ctrl.zig");

/// VBTBPCR1, outside the window: pcr1.zig.
pub const pcr1 = @import("pcr1.zig");
const prcr = @import("../prcr.zig");
const periph = @import("../registry.zig");

/// VBATT window geometry (ra8_bkup_regs.h).
pub const win_base: u32 = 0x4001_EC40;
pub const win_span: u32 = 0x180;

pub const off_vbtber: u32 = ctrl.off.vbtber;
pub const off_vbtbkr0: u32 = 0x0C0;
pub const reg_count: u32 = 128;

/// VBTBER fields, owned by the control file next door.
pub const vbtber = ctrl.vbtber;

/// Why a write was dropped, so the report can name the cause instead of
/// leaving it to be inferred from a failing banner.
pub const Drop = enum { none, locked, disabled };

/// The battery-backed domain: the retained bytes, the access-enable byte and
/// the counters behind the end-of-run line.
pub const Bkup = struct {
    /// The retained bytes. `resetControl` deliberately leaves these alone:
    /// they clear only when the emulator process starts, which models the
    /// first-ever boot with a dead battery.
    data: [reg_count]u8 = @splat(0),
    /// Every BAT*/VBT* register in the window that is not a data byte.
    control: ctrl.Control = ctrl.Control.init(),
    writes: u32 = 0,
    dropped_locked: u32 = 0,
    dropped_disabled: u32 = 0,
    /// Stores to a control register that PRC1 dropped.
    control_locked: u32 = 0,
    /// The protection model this block asks before accepting a store.
    protection: *const prcr.Prcr,

    pub fn init(protection: *const prcr.Prcr) Bkup {
        return .{ .protection = protection };
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Bkup) bool {
        return self.writes == 0 and self.dropped_locked == 0 and self.dropped_disabled == 0;
    }

    /// A peripheral reset clears the control state and keeps the data, which
    /// is what makes the domain survive a reboot into the same process.
    pub fn resetControl(self: *Bkup) void {
        self.control.reset();
        self.writes = 0;
        self.dropped_locked = 0;
        self.dropped_disabled = 0;
        self.control_locked = 0;
    }

    /// What stopped the last write, for the report.
    pub fn lastDrop(self: *const Bkup) Drop {
        if (self.dropped_locked != 0) return .locked;
        if (self.dropped_disabled != 0) return .disabled;
        return .none;
    }

    pub fn read(self: *Bkup, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        var value: u32 = 0;
        var i: u32 = 0;
        if (offset < off_vbtbkr0) {
            while (i < width) : (i += 1) {
                const byte = self.control.read(offset + i);
                value |= @as(u32, byte) << @intCast(i * 8);
            }
            return value;
        }
        const index = offset - off_vbtbkr0;
        while (i < width and index + i < reg_count) : (i += 1) {
            value |= @as(u32, self.data[index + i]) << @intCast(i * 8);
        }
        return value;
    }

    pub fn write(self: *Bkup, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (!self.protection.unlocked(prcr.group.lpm)) {
            if (offset >= off_vbtbkr0) self.dropped_locked +%= 1 else self.control_locked +%= 1;
            return;
        }
        if (offset < off_vbtbkr0) {
            var byte: u32 = 0;
            while (byte < width) : (byte += 1) {
                const taken: u8 = @truncate(value >> @intCast(byte * 8));
                self.control.write(offset + byte, taken);
            }
            return;
        }
        if (!self.control.vbaeSet()) {
            self.dropped_disabled +%= 1;
            return;
        }
        const index = offset - off_vbtbkr0;
        var i: u32 = 0;
        while (i < width and index + i < reg_count) : (i += 1) {
            self.data[index + i] = @truncate(value >> @intCast(i * 8));
        }
        self.writes +%= 1;
    }

    pub fn block(self: *Bkup) periph.Block {
        return .{
            .name = "VBATT-BKUP",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Bkup = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Bkup = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one backup slot, so a test or a later slice does not have to
/// do the arithmetic itself.
pub fn slotAddress(index: u32) u32 {
    return win_base + off_vbtbkr0 + index;
}
