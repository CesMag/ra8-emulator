//! The int8 convolution datapath: what NPU_OP_CONV computes for one OFM,
//! once the weights are back in OHWI order (order.zig) and the
//! per-channel scale-and-bias records are in hand (bias.zig).
//!
//! WHAT: for every OFM pixel and channel, acc = sum over the kernel taps of
//! (ifm - ifm_zero_point) * weight, plus the channel's bias; then the
//! channel's scale and shift under the OFM rounding mode
//! (round.zig), plus the OFM zero point, clamped to the
//! activation range. Taps that fall in the padding read the IFM zero point,
//! so they add nothing. Feature maps are packed NHWC, 8-bit signed.
//! A depthwise convolution (depth multiplier 1) sums only IFM channel c
//! into OFM channel c, with ofm.depth x kernel weights.
//! WHY: this is the arithmetic TFLite Micro's int8 per-channel CONV_2D and
//! DEPTHWISE_CONV_2D perform, which is what a Vela-compiled model has to reproduce.
const std = @import("std");
const bias = @import("bias.zig");
const round = @import("round.zig");

pub const Error = error{ BadShape, MissingRecord };

pub const Shape = struct {
    height: u32,
    width: u32,
    depth: u32,

    pub fn len(self: Shape) usize {
        return @as(usize, self.height) * self.width * self.depth;
    }
};

pub const Params = struct {
    ifm: Shape,
    ofm: Shape,
    kernel_height: u32,
    kernel_width: u32,
    stride_x: u32 = 1,
    stride_y: u32 = 1,
    pad_top: u32 = 0,
    pad_left: u32 = 0,
    ifm_zero_point: i32,
    ofm_zero_point: i32,
    rounding: round.Rounding = .double,
    activation_min: i32 = -128,
    activation_max: i32 = 127,
    depthwise: bool = false,
};

/// Run the convolution. `ohwi` holds ofm.depth x kernel x ifm.depth
/// weights (ofm.depth x kernel when depthwise); `records` holds one 10-byte scale-and-bias record per OFM
/// channel.
pub fn run(p: Params, ifm: []const i8, ohwi: []const i16, records: []const u8, ofm: []i8) Error!void {
    const taps = @as(usize, p.kernel_height) * p.kernel_width * (if (p.depthwise) 1 else p.ifm.depth);
    if (ifm.len != p.ifm.len() or ofm.len != p.ofm.len() or ohwi.len != taps * p.ofm.depth) return error.BadShape;
    if (p.stride_x == 0 or p.stride_y == 0 or p.activation_min > p.activation_max) return error.BadShape;
    if (p.depthwise and p.ifm.depth != p.ofm.depth) return error.BadShape;
    for (0..p.ofm.depth) |o| {
        const record = bias.at(records, o) orelse return error.MissingRecord;
        const weights = ohwi[o * taps ..][0..taps];
        for (0..p.ofm.height) |y| for (0..p.ofm.width) |x| {
            const acc = accumulate(p, ifm, weights, @intCast(y), @intCast(x), o) + record.bias;
            const scaled = round.apply(acc, record.scale, record.shift, p.rounding) + p.ofm_zero_point;
            const clamped = std.math.clamp(scaled, p.activation_min, p.activation_max);
            ofm[(y * p.ofm.width + x) * p.ofm.depth + o] = @intCast(std.math.clamp(clamped, -128, 127));
        };
    }
}

/// Sum one output pixel's taps for OFM channel `o`'s weights.
fn accumulate(p: Params, ifm: []const i8, weights: []const i16, y: u32, x: u32, o: usize) i64 {
    var acc: i64 = 0;
    for (0..p.kernel_height) |ky| for (0..p.kernel_width) |kx| {
        const iy = @as(i64, y) * p.stride_y + @as(i64, @intCast(ky)) - p.pad_top;
        const ix = @as(i64, x) * p.stride_x + @as(i64, @intCast(kx)) - p.pad_left;
        if (iy < 0 or ix < 0 or iy >= p.ifm.height or ix >= p.ifm.width) continue;
        const pixel: usize = @intCast((iy * p.ifm.width + ix) * p.ifm.depth);
        const k = ky * p.kernel_width + kx;
        if (p.depthwise) {
            acc += (@as(i64, ifm[pixel + o]) - p.ifm_zero_point) * weights[k];
            continue;
        }
        for (0..p.ifm.depth) |c| {
            acc += (@as(i64, ifm[pixel + c]) - p.ifm_zero_point) * weights[k * p.ifm.depth + c];
        }
    };
    return acc;
}
