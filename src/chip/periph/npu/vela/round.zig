//! OFM output scaling: an accumulator times a 32-bit scale, shifted right,
//! under one of the three rounding modes NPU_SET_OFM_PRECISION b[15:14]
//! selects (U55 TRM 102420_0200_02, p84: 0 double rounding, 1 truncate
//! towards zero, 2 natural rounding).
//!
//! WHAT: `scale` and `shift` are Vela's encoding (scaling.py
//! quantise_scale): value = acc * scale / 2^shift, with TFLite's exponent
//! equal to 31 - shift.
//! - double: TFLite Micro's default MultiplyByQuantizedMultiplier
//!   (tflite-micro tensorflow/lite/micro/kernels/internal/common.cc at
//!   1fae604): gemmlowp SaturatingRoundingDoublingHighMul then
//!   RoundingDivideByPOT, so a tie rounds away from zero.
//! - natural: the same file's TFLITE_SINGLE_ROUNDING form, one rounding
//!   with a tie going towards +infinity (the TRM's wording for IFM round
//!   mode 2).
//! - truncate: towards zero.
//! The arithmetic runs on i128, so the 32-bit saturation edge of the TFLM
//! form is not modelled; the U55's accumulator and 40-bit bias are wider
//! than int32 anyway.
const std = @import("std");

pub const Rounding = enum(u2) {
    double = 0,
    truncate = 1,
    natural = 2,

    /// Decode NPU_SET_OFM_PRECISION b[15:14]; 3 is reserved.
    pub fn fromBits(bits: u2) ?Rounding {
        return std.enums.fromInt(Rounding, bits);
    }
};

/// Scale one accumulator. The caller adds the OFM zero point and clamps.
pub fn apply(acc: i64, scale: u32, shift: u6, mode: Rounding) i128 {
    return switch (mode) {
        .double => double(acc, scale, shift),
        .natural => natural(acc, scale, shift),
        .truncate => @divTrunc(@as(i128, acc) * scale, @as(i128, 1) << shift),
    };
}

fn natural(acc: i64, scale: u32, shift: u6) i128 {
    const product = @as(i128, acc) * scale;
    if (shift == 0) return product;
    return (product + (@as(i128, 1) << (shift - 1))) >> shift;
}

fn double(acc: i64, scale: u32, shift: u6) i128 {
    const exponent = 31 - @as(i8, shift);
    const left: u7 = @intCast(@max(exponent, 0));
    const right: u7 = @intCast(@max(-exponent, 0));
    return divideByPot(doublingHighMul(@as(i128, acc) << left, scale), right);
}

/// gemmlowp SaturatingRoundingDoublingHighMul: (a * b * 2) / 2^32 with a
/// nudge, truncated towards zero.
fn doublingHighMul(a: i128, b: u32) i128 {
    const product = a * b;
    const nudge: i128 = if (product >= 0) 1 << 30 else 1 - (1 << 30);
    return @divTrunc(product + nudge, @as(i128, 1) << 31);
}

/// gemmlowp RoundingDivideByPOT: divide by 2^exponent, a tie away from zero.
fn divideByPot(x: i128, exponent: u7) i128 {
    const mask = (@as(i128, 1) << exponent) - 1;
    const remainder = x & mask;
    const threshold = (mask >> 1) + @intFromBool(x < 0);
    return (x >> exponent) + @intFromBool(remainder > threshold);
}
