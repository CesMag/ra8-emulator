//! DOTF REG00: the AES control word, and the self-test bit that has to clear.
//!
//! REG00 is the one register the DOTF driver drives hard. Bit 9 enables the
//! AES core, bits 25:24 pick the key size and bits 29:28 the cipher mode,
//! which on this part is CTR and nothing else (HUM Ch 45.1 p 3048). Bit 20
//! is the self-test trigger, and it is the bit that matters to a model:
//! `ra8_dotf_self_test` writes it and then waits for the SAME bit to read
//! back clear, so a register that simply stores what it is given never
//! finishes the test. The driver spins out its budget and reports a hardware
//! timeout on a part that is working.
//!
//! Bit names are the FSP field names the header kept verbatim
//! (ra8_dotf_regs.h ra8_dotf_reg00_bit_t / ra8_dotf_reg00_mask_t, cited
//! there against R_DOTF_REG00_b). HUM Ch 45 documents REG00 only as the AES
//! control word and gives no symbolic names, so the positions come from the
//! header and this file says so rather than implying a HUM bit table.
//!
//! WHAT IS NOT MODELLED, AND MUST NOT BE INVENTED: the decryption itself.
//! There is no AES core here and no key: the key and IV words go in through
//! REG03 and are counted, never used, and a read through the XSPI window
//! returns the stored bytes exactly as it did before. Nothing in either tree
//! says what a failed self-test reports either, so the test always passes,
//! which is what the bit clearing means.

/// REG00 fields.
pub const mask = struct {
    pub const aes_enable: u32 = 0x0000_0200;
    pub const sca_enable: u32 = 0x0001_0000;
    pub const sca_mode: u32 = 0x0002_0000;
    pub const self_test: u32 = 0x0010_0000;
    pub const key_size: u32 = 0x0300_0000;
    pub const mode: u32 = 0x3000_0000;
};

/// The value FSP writes to turn a channel on, and the one it writes to stop.
pub const value = struct {
    pub const disable: u32 = 0x0000_0000;
    pub const default_field: u32 = 0x2200_0000;
    pub const enable: u32 = 0x2200_0200;
};

/// Bits 25:24. The encodings are the header's, including the one this part
/// leaves unassigned.
pub const KeySize = enum(u2) {
    unset = 0,
    bits192 = 1,
    bits128 = 2,
    bits256 = 3,

    pub fn of(reg00: u32) KeySize {
        return @fromBackingInt(@intCast(@as(u2, @truncate((reg00 & mask.key_size) >> 24))));
    }

    pub fn bits(self: KeySize) u16 {
        return switch (self) {
            .unset => 0,
            .bits128 => 128,
            .bits192 => 192,
            .bits256 => 256,
        };
    }

    pub fn name(self: KeySize) []const u8 {
        return switch (self) {
            .unset => "no key size selected",
            .bits128 => "AES-128",
            .bits192 => "AES-192",
            .bits256 => "AES-256",
        };
    }
};

/// Bits 29:28. CTR is the only mode HUM Ch 45.1 p 3048 allows, so every
/// other encoding is reported as what it is rather than given a meaning.
pub const Mode = enum(u2) {
    unset = 0,
    other1 = 1,
    ctr = 2,
    other3 = 3,

    pub fn of(reg00: u32) Mode {
        return @fromBackingInt(@intCast(@as(u2, @truncate((reg00 & mask.mode) >> 28))));
    }

    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .ctr => "CTR",
            .unset => "no mode selected",
            else => "a mode this part does not define",
        };
    }
};

/// True when the write asks for a self-test.
pub fn testRequested(written: u32) bool {
    return written & mask.self_test != 0;
}

/// What the register actually holds after that write. The self-test bit runs
/// to completion inside the write, so it never lands and a later read cannot
/// see it standing.
pub fn stored(written: u32) u32 {
    return written & ~mask.self_test;
}

/// True when the AES core is switched on.
pub fn enabled(reg00: u32) bool {
    return reg00 & mask.aes_enable != 0;
}

/// True when the side-channel countermeasure is switched on.
pub fn countermeasure(reg00: u32) bool {
    return reg00 & mask.sca_enable != 0;
}

/// True when the core is on and asked for the one cipher mode this part has.
pub fn decrypting(reg00: u32) bool {
    return enabled(reg00) and Mode.of(reg00) == .ctr;
}
