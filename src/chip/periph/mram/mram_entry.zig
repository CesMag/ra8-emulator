//! MENTRYR: the program/erase mode gate, the key that opens it, and the
//! pause bit that halts programming without leaving the mode.
//!
//! Split out of src/chip/periph/mram/mram.zig the way mram_init.zig holds MSUINITR:
//! the block file keeps the sequencer's rules, this one keeps the one
//! register those rules turn on. What it decides is the whole register: an
//! access narrower than the register carries no key, a value whose high half
//! is not 0xAA carries the wrong one, and only a keyed access moves the
//! state. The caller still owns the shadow word and what leaving the mode
//! releases, because those belong to the controller rather than to MENTRYR.
//!
//! THE KEY IS WRITE-ONLY. status() answers the mode bit and the pause bit
//! and never the key, which is what lets the driver's own read-modify-write
//! of MENTRYR work: it reads back what it may legally write again.

const lanes = @import("../lanes.zig");
const mram_regs = @import("mram_regs.zig");

const regs = mram_regs.regs;
const field = mram_regs.field;

/// What a store to MENTRYR did.
pub const Outcome = enum {
    /// It carried no key, so nothing moved.
    refused,
    /// It left program/erase mode set, pause bit included.
    entered,
    /// It left program/erase mode.
    left,
};

pub const Entry = struct {
    in_pe_mode: bool = false,
    /// MENTRYR.PCKA: the keyed pause pattern halted programming.
    paused: bool = false,
    /// Stores whose high half was not the 0xAA key.
    keyless: u32 = 0,
    /// Stores naming less than the whole register.
    narrow_writes: u32 = 0,

    pub fn quiet(self: *const Entry) bool {
        return self.keyless == 0 and self.narrow_writes == 0;
    }

    /// MENTRYR as it reads back: the mode bit, plus the pause gate when one
    /// is standing. The key is never among them.
    pub fn status(self: *const Entry) u32 {
        if (!self.in_pe_mode) return 0;
        return field.mentry | (if (self.paused) field.pcka else 0);
    }

    /// Take a store. The key has to be carried by the access itself, never
    /// read out of what an earlier keyed store left behind.
    pub fn write(self: *Entry, byte: u32, width: u3, value: u32) Outcome {
        if (!namesRegister(byte, width)) {
            self.narrow_writes +%= 1;
            return .refused;
        }
        const carried = value & lanes.named(byte, width);
        if (carried & field.key_mask != field.key) {
            self.keyless +%= 1;
            return .refused;
        }
        self.in_pe_mode = carried & field.mentry != 0;
        if (self.in_pe_mode) {
            self.paused = carried & field.pcka != 0;
            return .entered;
        }
        self.paused = false;
        return .left;
    }
};

/// An access carries the key only when it starts at lane 0 and is at least
/// as wide as the register. Wider is still fine: a word store of a halfword
/// register carries it.
pub fn namesRegister(byte: u32, width: u3) bool {
    return byte == 0 and width >= regs.mentryr_bytes;
}
