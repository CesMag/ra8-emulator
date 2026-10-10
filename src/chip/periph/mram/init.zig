//! MSUINITR: the kick that makes the extra-MRAM sequencer re-fetch the
//! option-function select words.
//!
//! ra8_flash_regs.h puts it at k_ra8_mram_off_msuinitr = 0x2086 + 6, which
//! is 0x8C inside the MRMS program-mode sub-window this block already
//! answers for, and gives it two fields: KEY = 0xAA in the high half and
//! SUINIT in bit 0 (k_ra8_msuinitr_full_init = 0xAA01,
//! k_ra8_msuinitr_mask_suinit = 0x0001).
//!
//! SUINIT IS A COMMAND, NOT A SETTING, and it is the sequencer that takes
//! it back down. ra8_flash_msuinitr_kick writes 0xAA01 and then loops up to
//! k_ra8_flash_pe_spin_limit times reading the register back, returning
//! k_ra8_ok the moment SUINIT reads clear and a timeout otherwise. Its own
//! off-target seam says why in so many words: "on real HW the sequencer
//! auto-clears SUINIT once the init completes; host RAM cannot"
//! (ra8_flash_config.c:527).
//!
//! Until now this register fell into mram.zig's generic shadow: a store
//! landed the whole 0xAA01 in a word and a read handed it straight back,
//! so SUINIT was still standing on every poll and the kick ALWAYS ran out
//! its spin limit and returned k_ra8_err_hw_timeout. Firmware that treats
//! the kick as fatal never gets its OFS re-fetch, and firmware that logs
//! and carries on reports a hardware timeout that no silicon would give.
//! Host RAM could not clear it, which is the exact seam the driver
//! documents; a model of the sequencer can, and should.
//!
//! So the init runs to completion inside the store that asked for one: a
//! keyed store with SUINIT set is counted and SUINIT is spent, leaving the
//! register reading clear on the first poll for the right reason. Same
//! shape as this tree's other completed-in-the-store commands (the CRC's
//! DORCLR, the DOTF self-test, the Simple LIN break field): there is no
//! sequencer clock here to wait out.
//!
//! THE KEY COMES OUT OF THE WRITE, the cut mram.zig's own MENTRYR rule
//! already makes: an access must name the whole sixteen-bit register, and
//! the 0xAA is read from the value the access carries rather than from
//! whatever an earlier keyed write left in the shadow. A store without the
//! key kicks nothing and is counted.
//!
//! NOT MODELLED, AND NOT GUESSED: the re-fetch itself. Nothing here reads
//! the option words back out of the OTP cells into a configuration shadow,
//! because this model has no such shadow to refresh: the option window is
//! read through directly (mram.zig's write-through to guest memory). The
//! kick therefore counts and completes rather than moving any data, and
//! the report says how many were asked for so a run cannot quietly look
//! like it re-fetched something.
const lanes = @import("../lanes.zig");
const mram_regs = @import("regs.zig");

/// MSUINITR's offset inside the MRMS sub-window.
pub const off: u32 = 0x8C;

pub const bit = struct {
    /// SUINIT, bit 0: start the set-up init. Cleared by the sequencer.
    pub const suinit: u32 = 0x0001;
};

/// MSUINITR is sixteen bits, like MENTRYR beside it.
pub const register_bytes: u32 = 2;

/// Whether an access names the whole register, so it can carry a key.
pub fn namesRegister(byte: u32, width: u3) bool {
    return byte == 0 and width >= register_bytes;
}

/// The set-up init state: what the register reads and what it has done.
pub const Init = struct {
    /// The settings bits a store left behind. SUINIT is never among them.
    shadow: u32 = 0,
    /// Set-up inits the sequencer ran.
    kicks: u32 = 0,
    /// Stores asking for an init without the 0xAA key.
    keyless: u32 = 0,
    /// Stores naming less than the register, which carry no key at all.
    narrow_writes: u32 = 0,

    pub fn quiet(self: *const Init) bool {
        return self.kicks == 0 and self.keyless == 0 and self.narrow_writes == 0;
    }

    /// SUINIT reads clear because the init finished, not because nothing
    /// happened.
    pub fn read(self: *const Init) u32 {
        return self.shadow;
    }

    pub fn write(self: *Init, byte: u32, width: u3, value: u32) void {
        if (byte >= register_bytes) return;
        if (!namesRegister(byte, width)) {
            self.narrow_writes +%= 1;
            return;
        }
        const carried = value & lanes.named(byte, width);
        if (carried & mram_regs.field.key_mask != mram_regs.field.key) {
            self.keyless +%= 1;
            return;
        }
        // The key is a write-only gate, so it is not kept either: a read
        // gives back the settings bits and nothing else.
        self.shadow = carried & ~(mram_regs.field.key_mask | bit.suinit);
        if (carried & bit.suinit != 0) self.kicks +%= 1;
    }
};
