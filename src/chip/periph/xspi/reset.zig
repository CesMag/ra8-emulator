//! The software reset the IS25LX512M takes: RSTEN (0x66), then RST (0x99),
//! with nothing in between (datasheet Ch 8.20/8.21). ra8_xspi.c issues the
//! pair twice at bring-up, once as 8D opcode-plus-complement and once as a
//! plain 1S byte, because it cannot know which protocol the part woke in.
//!
//! RST ONLY COUNTS STRAIGHT AFTER RSTEN. Any other command between the two
//! disarms the enable, and a bare RST is ignored by the part. Before this
//! file both opcodes fell through as "touches nothing", so a reset never
//! dropped the write-enable latch and a driver that relied on RST to clear
//! a stale WREN worked here and not on silicon. The only volatile state this
//! model holds is that latch, so a taken reset clears it and nothing else.
pub const opcode = struct {
    /// Reset enable.
    pub const enable: u8 = 0x66;
    /// Reset, taken only when the previous command was `enable`.
    pub const reset: u8 = 0x99;
};

pub const Sequence = struct {
    /// The previous command was RSTEN.
    enabled: bool = false,
    /// Resets the part took.
    resets: u32 = 0,
    /// RSTs that arrived without RSTEN right before them.
    ignored: u32 = 0,

    /// Feed every command's opcode, in order. True when this one resets the
    /// part.
    pub fn step(self: *Sequence, code: u8) bool {
        if (code == opcode.reset) {
            const taken = self.enabled;
            self.enabled = false;
            if (taken) self.resets +%= 1 else self.ignored +%= 1;
            return taken;
        }
        self.enabled = code == opcode.enable;
        return false;
    }
};
