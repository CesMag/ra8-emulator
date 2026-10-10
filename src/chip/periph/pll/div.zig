//! The code-to-ratio maps PLL1's configuration registers carry: PLLCCR's
//! input divider and multiplier packing, and PLLCCR2's three output dividers.
//!
//! Each field encodes its ratio differently and none of them is a plain
//! binary ratio, so the tables live here and the block that answers on the
//! bus holds bytes and counters only.

/// PLLCCR.PLIDIV[1:0], the input divider (ra8_cgc_regs.h, from the FSP CMSIS
/// header and bsp_clocks.c). Code is ratio - 1 for the three ratios the part
/// supports; code 3 is not one of them.
pub fn inputRatio(code: u2) ?u8 {
    return switch (code) {
        0 => 1,
        1 => 2,
        2 => 3,
        3 => null,
    };
}

/// PLLCCR2.PLODIVP/Q/R, an output divider. Code is ratio - 1 for ratios 1
/// through 6, then three discrete codes for /8, /9 and /16. Code 0 is listed
/// as "Setting prohibited" in HUM Ch 9.2.7, which is why it answers null
/// rather than /1: the hardware rejects the whole register write when any
/// field carries it.
pub fn outputRatio(code: u4) ?u8 {
    return switch (code) {
        0 => null,
        1 => 2,
        2 => 3,
        3 => 4,
        4 => 5,
        5 => 6,
        7 => 8,
        8 => 9,
        15 => 16,
        else => null,
    };
}

/// The multiplier PLLCCR packs across PLLMULNF[7:6] and PLLMUL[16:8]: one
/// eleven-bit field of quarter steps, written as (integer * 4 + quarters)
/// shifted up by 6. Kept as quarters rather than a float so nothing here
/// rounds; the report does the division when it prints.
pub const Multiplier = struct {
    quarters: u16,

    pub fn whole(self: Multiplier) u16 {
        return self.quarters / 4;
    }

    pub fn hundredths(self: Multiplier) u8 {
        return @intCast((self.quarters % 4) * 25);
    }
};

pub const pllccr = struct {
    pub const plidiv_mask: u32 = 0x0000_0003;
    pub const plsrcsel_bit: u32 = 0x0000_0010;
    pub const quarters_shift: u5 = 6;
    pub const quarters_mask: u32 = 0x0000_07FF;
};

pub const pllccr2 = struct {
    pub const field_mask: u16 = 0x000F;
    pub const plodivp_shift: u4 = 0;
    pub const plodivq_shift: u4 = 4;
    pub const plodivr_shift: u4 = 8;
};

/// PLLCCR.PLSRCSEL, bit 4: what feeds the PLL.
pub const Source = enum {
    main,
    hoco,

    pub fn name(self: Source) []const u8 {
        return switch (self) {
            .main => "main",
            .hoco => "HOCO",
        };
    }
};

pub fn sourceOf(word: u32) Source {
    return if (word & pllccr.plsrcsel_bit != 0) .hoco else .main;
}

pub fn multiplierOf(word: u32) Multiplier {
    return .{ .quarters = @intCast((word >> pllccr.quarters_shift) & pllccr.quarters_mask) };
}

pub fn inputCodeOf(word: u32) u2 {
    return @intCast(word & pllccr.plidiv_mask);
}

/// The three output divider codes, P then Q then R.
pub fn outputCodesOf(word: u16) [3]u4 {
    return .{
        @intCast((word >> pllccr2.plodivp_shift) & pllccr2.field_mask),
        @intCast((word >> pllccr2.plodivq_shift) & pllccr2.field_mask),
        @intCast((word >> pllccr2.plodivr_shift) & pllccr2.field_mask),
    };
}

/// Whether every output field carries a code the part defines. A single
/// prohibited field is what makes silicon drop the whole 16-bit write.
pub fn outputsAllowed(word: u16) bool {
    for (outputCodesOf(word)) |code| {
        if (outputRatio(code) == null) return false;
    }
    return true;
}
