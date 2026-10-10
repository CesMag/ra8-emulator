//! SRAMPRCR: the half-word key that decides whether a store to the SRAM
//! controller's configuration registers lands at all.
//!
//! The control window opens with two protection registers, SRAMPRCR_S at
//! +0x00 and SRAMPRCR_NS at +0x04, both 16 bits. The upper byte is the key
//! KW and has to read 0xA5 for the store to be looked at; the bottom bit PR
//! is the write enable. 0xA501 opens SRAMWTSC, SRAMCRn and SRAMECCRGNn to
//! writes and 0xA500 shuts them again, and a store carrying any other key is
//! not a lock change at all: the register keeps the state it had.
//!
//! Grounded on ra8-firmware's ra8_sram_regs.h on zig/dev, which carries the
//! window table (PRCR_S 0x00, PRCR_NS 0x04, WTSC 0x08, CRn 0x10..0x1C,
//! ECCRGNn 0x30..0x3C) and the key enumeration k_ra8_sram_prcr_unlock
//! 0xA501, k_ra8_sram_prcr_lock 0xA500, k_ra8_sram_prcr_kw 0xA500 and
//! k_ra8_sram_prcr_pr_msk 0x0001, citing HUM Ch 58.2.4 p 3530. Its driver
//! ra8_sram.c drives exactly that: internal_write_cr_locked,
//! internal_write_eccrgn_locked and internal_write_wtsc_locked each unlock,
//! write the one register, and re-lock.
//!
//! WHICH REGISTERS THE KEY GUARDS is the HUM's own list and no wider. The
//! error side of the block is outside it: SRAMESR is what the decoder found,
//! SRAMESCLR is how firmware clears it and SRAMEARnm is where the address is
//! parked, and none of the three is a configuration register the protection
//! register names. A locked controller still reports and still clears.
//!
//! NOT MODELLED, AND NOT GUESSED: what SRAMPRCR reads back. The header gives
//! the values to write and no read behaviour, and silicon commonly answers a
//! key field as zero. The store is interpreted for the lock decision here and
//! the shadow still answers the read, so a driver's read-modify-write of the
//! register survives unchanged; only the effect of the key is modelled, not a
//! readback nobody in either tree has written down. The secure and
//! non-secure copies are tracked separately and either one open is enough,
//! because TrustZone partitioning is not modelled here and the bare-metal
//! build drives the secure alias.
const std = @import("std");

/// Where the two protection registers and the registers they guard sit
/// (ra8_sram_regs.h window table).
pub const off = struct {
    pub const prcr_s: u32 = 0x00;
    pub const prcr_ns: u32 = 0x04;
    pub const wtsc: u32 = 0x08;
    pub const cr0: u32 = 0x10;
    pub const eccrgn0: u32 = 0x30;
};

/// SRAMPRCR's two fields (k_ra8_sram_prcr_*).
pub const key = struct {
    /// KW[7:0] sits in the top half and has to carry this to be heard.
    pub const word: u16 = 0xA5;
    pub const shift: u4 = 8;
    /// PR, the write enable the key admits.
    pub const enable: u16 = 0x0001;
    pub const unlock: u16 = 0xA501;
    pub const lock: u16 = 0xA500;
};

/// The guarded registers, as counts of consecutive words from their first.
pub const guarded = struct {
    pub const banks: u32 = 4;
    pub const stride: u32 = 4;
};

/// Which protection register a store landed on.
pub const Half = enum { secure, non_secure };

/// A store's effect on the lock.
pub const Effect = enum {
    /// Not a protection register at all.
    elsewhere,
    /// The key was right and the lock moved.
    accepted,
    /// The key was wrong, so the lock kept the state it had.
    ignored,
};

/// Whether a store to a guarded register is allowed through.
pub const Verdict = enum { unguarded, allowed, blocked };

/// The protection state of one SRAM controller.
pub const Lock = struct {
    open_secure: bool = false,
    open_non_secure: bool = false,
    /// Key writes that moved the lock.
    accepted: u32 = 0,
    /// Key writes whose KW field was not 0xA5.
    ignored: u32 = 0,
    /// Guarded stores refused because both halves were locked.
    blocked: u32 = 0,
    /// Guarded stores that went through.
    allowed: u32 = 0,

    pub fn quiet(self: *const Lock) bool {
        return self.accepted == 0 and self.ignored == 0 and
            self.blocked == 0 and self.allowed == 0;
    }

    pub fn open(self: *const Lock) bool {
        return self.open_secure or self.open_non_secure;
    }

    /// A store to one of the two protection registers. A value whose key
    /// field is not 0xA5 leaves the lock exactly as it was.
    pub fn latch(self: *Lock, offset: u32, value: u32) Effect {
        const half = halfOf(offset) orelse return .elsewhere;
        const word: u16 = @truncate(value);
        if (word >> key.shift != key.word) {
            self.ignored +%= 1;
            return .ignored;
        }
        const opened = word & key.enable != 0;
        switch (half) {
            .secure => self.open_secure = opened,
            .non_secure => self.open_non_secure = opened,
        }
        self.accepted +%= 1;
        return .accepted;
    }

    /// A store anywhere else in the window. Only the registers SRAMPRCR
    /// names are held back.
    pub fn admit(self: *Lock, offset: u32) Verdict {
        if (!guards(offset)) return .unguarded;
        if (self.open()) {
            self.allowed +%= 1;
            return .allowed;
        }
        self.blocked +%= 1;
        return .blocked;
    }
};

/// Which protection register this offset is, if it is one.
pub fn halfOf(offset: u32) ?Half {
    return switch (offset) {
        off.prcr_s => .secure,
        off.prcr_ns => .non_secure,
        else => null,
    };
}

/// SRAMWTSC, the four SRAMCRn and the four SRAMECCRGNn, and nothing else.
pub fn guards(offset: u32) bool {
    if (offset == off.wtsc) return true;
    return inArray(offset, off.cr0) or inArray(offset, off.eccrgn0);
}

fn inArray(offset: u32, first: u32) bool {
    if (offset < first) return false;
    const span = guarded.stride * guarded.banks;
    return offset - first < span;
}
