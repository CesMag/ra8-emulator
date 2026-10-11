//! Elementwise MUL (NPU_OP_ELEMENTWISE mode 0, Ethos-U55 TRM
//! 102420_0200_02 cmd0 0x006) for int8 tensors.
//!
//! For each OFM element: (ifm - IFM_ZERO_POINT) * (ifm2 - IFM2_ZERO_POINT),
//! scaled by OFM_SCALE (cmd1 0x024: the 32-bit scale in the payload, the
//! 6-bit shift in the parameter) under the OFM_PRECISION rounding mode,
//! plus OFM_ZERO_POINT, clamped to ACTIVATION_MIN/MAX. This is TFLite
//! Micro's int8 MUL, and Vela 3.12.0 writes OFM_SCALE as
//! quantise_scale(ifm_scale * ifm2_scale / ofm_scale), the same multiplier
//! TFLM derives. The TRM lists OFM_SCALE among the registers elementwise
//! MUL uses but does not spell out its datapath, so what is pinned here is
//! TFLM's result for Vela's registers, which tests check byte for byte.
//!
//! Modelled: signed int8 IFM, IFM2 and OFM in one layout, the global scale
//! (OFM_PRECISION b8 set, as Vela emits for elementwise), no activation
//! function, and IFM2 broadcast as minmax.zig reads it. Anything
//! else is error.OperatorNotModelled.
const std = @import("std");
const dma = @import("dma.zig");
const addr = @import("addr.zig");
const minmax = @import("minmax.zig");
const round = @import("round.zig");

pub const mode_mul: u16 = 0;

pub const Error = minmax.Error;
pub const Inputs = minmax.Inputs;

const global_scale: u16 = 1 << 8;

fn int8(f: ?addr.Format) bool {
    const v = f orelse return false;
    return v.signed and v.size == 1;
}

fn supported(inputs: Inputs) Error!round.Rounding {
    const maps = inputs.maps;
    const q = inputs.quant;
    if (q.activation != 0) return error.OperatorNotModelled;
    if (maps.ofm.precision & global_scale == 0 or q.ofm_scale.shift > 63) return error.OperatorNotModelled;
    const ifm = addr.ifmFormat(maps.ifm.precision);
    const ifm2 = addr.ifmFormat(maps.ifm2.precision);
    const ofm = addr.ofmFormat(maps.ofm.precision);
    if (!int8(ifm) or !int8(ifm2) or !int8(ofm)) return error.OperatorNotModelled;
    if (ifm.?.layout != ofm.?.layout or ifm2.?.layout != ofm.?.layout) return error.OperatorNotModelled;
    return round.Rounding.fromBits(addr.rounding(maps.ofm.precision)) orelse error.OperatorNotModelled;
}

/// One output element from the two zero-point-adjusted operands.
pub fn product(a: i32, b: i32, scale: u32, shift: u6, rounding: round.Rounding, ofm_zero_point: i32, low: i32, high: i32) i32 {
    const scaled = round.apply(@as(i64, a) * b, scale, shift, rounding) + ofm_zero_point;
    return @intCast(std.math.clamp(scaled, low, high));
}

/// Run one MUL over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, inputs: Inputs) Error!u64 {
    const rounding = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const f = addr.ifmFormat(maps.ifm.precision).?;
    const zp_a = minmax.signExtend(maps.ifm.zero_point, f);
    const zp_b = minmax.signExtend(maps.ifm2.zero_point, f);
    const zp_o = minmax.signExtend(maps.ofm.zero_point, f);
    const low = @max(minmax.signExtend(q.activation_min, f), -128);
    const high = @min(minmax.signExtend(q.activation_max, f), 127);
    if (low > high) return error.OperatorNotModelled;
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const a_at = addr.address(inputs.bases.ifm, maps.ifm, q.ifm_stride, f, yy, xx, cc);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        const a = try minmax.load(memory, try minmax.location(regions, maps.ifm.region, a_at, 1), f);
        const b = try minmax.second(memory, regions, inputs, f, yy, xx, cc);
        const out = product(a - zp_a, b - zp_b, q.ofm_scale.scale, @intCast(q.ofm_scale.shift), rounding, zp_o, low, high);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, 1), out, f);
        written += 1;
    };
    return written;
}
