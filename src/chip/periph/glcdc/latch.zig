//! The GLCDC register-update latches: the VEN bits, which are commands
//! rather than settings.
//!
//! Three of the block's control registers carry a VEN bit, and the driver
//! writes all three (ra8_glcdc_layer.c, which names each bit in its own
//! local enum because the HUM page is not in that tree either):
//!
//!   BG_EN   (+0x1000) VEN b8  the background plane's update enable
//!   GR1_EN  (+0x1100) VEN b0  graphics layer 1's
//!   GR2_EN  (+0x1200) VEN b0  graphics layer 2's
//!
//! A VEN write asks the controller to take the register values firmware has
//! been staging and use them from the next frame. It is not a setting: the
//! bit auto-clears when that frame boundary passes, which ra8_glcdc.h states
//! for both layers ("GR1.VEN is asserted (auto-clears at next VS)" and the
//! same for GR2, ra8_glcdc.h line 295 and ra8_glcdc_layer.c lines 229, 279,
//! 335) and which ra8_glcdc_bg_color_set then POLLS ON, because the fall of
//! the bit is how it knows a vsync just went by and the vblank window is
//! open (ra8_glcdc_layer.c lines 199-210):
//!
//!     bg_en |= k_bg_en_ven;
//!     *ra8_glcdc_reg32(k_ra8_glcdc_off_bg_en) = bg_en;
//!     for (uint32_t i = 0U; i < k_ven_timeout; i++) {
//!       if ((*ra8_glcdc_reg32(k_ra8_glcdc_off_bg_en) & k_bg_en_ven) == 0U) {
//!
//! So the bit is spent on the write and never stored. A model that keeps it
//! answers that poll with 1 for its whole 0x40000-iteration budget and then
//! hands back a timeout, and the background colour the call exists to set is
//! never written.
//!
//! WHY SPENT ON THE WRITE, and not held until a frame passes: there is no
//! vsync in this model. A frame is composited whole inside one `scanOut`
//! call, so there is no moment between the store and the frame boundary for
//! the bit to legitimately read back as 1. Spending it is the only answer
//! that lets the driver's poll finish, and it is the same rule crc.zig
//! keeps for CRCCR0.DORCLR and rtc/reset.zig for RCR2.RESET.
//!
//! NOT MODELLED, AND NOT GUESSED: a shadow/active register pair behind the
//! layers. On silicon VEN is what makes staged values take effect; here a
//! write to a layer register is applied as it arrives, so there is nothing
//! for the latch to promote and the count is what the run reports. The one
//! stage that does keep a shadow and a live copy is the output stage, and it
//! already commits on its own OUT_VLATCH.VEN inside out.zig. Widening
//! this to double-buffer the layers would be a model change, not a bit rule,
//! and it belongs in its own slice.

/// The registers that carry a VEN, and which bit it is in each.
pub const latch = struct {
    pub const bg_en: u32 = 0x1000;
    pub const bg_ven: u32 = 0x0000_0100;
    pub const gr1_en: u32 = 0x1100;
    pub const gr2_en: u32 = 0x1200;
    pub const gr_ven: u32 = 0x0000_0001;
};

/// The VEN bit of the register at this offset, or zero when the register
/// does not have one.
pub fn bitAt(offset: u32) u32 {
    return switch (offset) {
        latch.bg_en => latch.bg_ven,
        latch.gr1_en, latch.gr2_en => latch.gr_ven,
        else => 0,
    };
}

/// Whether this store asks for a register update.
pub fn requested(offset: u32, value: u32) bool {
    return value & bitAt(offset) != 0;
}

/// What the store leaves behind. The command is spent, so it is never part
/// of the value firmware reads back; every other bit of the register, BG_EN.EN
/// among them, lands as it always did.
pub fn stored(offset: u32, value: u32) u32 {
    return value & ~bitAt(offset);
}
