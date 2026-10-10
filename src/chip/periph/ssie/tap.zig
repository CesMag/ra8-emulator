//! What `--audio-out` (RA8EMU-570) hears from an SSIE channel: every sample
//! the transmitter shifts out, handed to a listener as it goes, and the
//! stream's shape as SSICR states it.
//!
//! The tap sits on the shift, not on the store. A sample staged with TEN
//! clear reaches the listener when TEN drains it, and a store too narrow to
//! carry a sample never reaches it, matching what the report counts as
//! transmitted. The tap carries no time; the listener reads virtual time
//! from the board when it is called.
//!
//! SSICR fields, from ra8_ssie_regs.h and ra8_ssie.h on the firmware tree
//! (HUM Ch 46.2.1, p 3056 to 3058):
//! - DWL[21:19] is the data word: 8, 16, 18, 20, 22, 24 or 32 significant
//!   bits. 111b is prohibited, so it gives no shape.
//! - FRM[23:22] is words per frame: 2 for I2S, then 4, 6 or 8 for TDM.
//! - PDTA[9] set means the sample sits right-justified in the SSIFTDR word
//!   (the driver's right-justified format); clear means it sits at the top.
//!
//! NOT MODELLED: monaural mode. That is SSIOFR.OMOD, which this model only
//! shadows, so a monaural stream reads here as I2S with two words per frame.
const std = @import("std");

/// A listener for shifted-out samples.
pub const Tap = struct {
    context: *anyopaque,
    sample: *const fn (context: *anyopaque, word: u32) void,

    pub fn call(self: Tap, word: u32) void {
        self.sample(self.context, word);
    }
};

/// The stream as SSICR describes it.
pub const Shape = struct {
    data_bits: u6,
    channels: u4,
    right_justified: bool,

    /// The significant bits of one SSIFTDR word, moved down to bit 0.
    pub fn value(self: Shape, word: u32) u32 {
        if (self.data_bits == 32) return word;
        const bits: u5 = @intCast(self.data_bits);
        if (self.right_justified) return word & ((@as(u32, 1) << bits) - 1);
        return word >> @intCast(32 - @as(u6, bits));
    }
};

pub const dwl_shift: u5 = 19;
pub const frm_shift: u5 = 22;
pub const pdta: u32 = 1 << 9;

const data_bits = [_]u6{ 8, 16, 18, 20, 22, 24, 32 };
const frame_words = [_]u4{ 2, 4, 6, 8 };

/// The shape SSICR names, or null for the prohibited DWL encoding.
pub fn shape(ssicr: u32) ?Shape {
    const dwl: usize = (ssicr >> dwl_shift) & 0x7;
    if (dwl >= data_bits.len) return null;
    return .{
        .data_bits = data_bits[dwl],
        .channels = frame_words[(ssicr >> frm_shift) & 0x3],
        .right_justified = ssicr & pdta != 0,
    };
}
