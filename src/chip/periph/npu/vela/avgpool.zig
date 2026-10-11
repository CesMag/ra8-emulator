//! NPU_OP_POOL in AVERAGE mode (pooling_mode 1) for int8.
//!
//! Unpadded:
//! The Ethos-U55 TRM (102420_0200_02, table 4-124 and cmd1 0x024) gives
//! average pool with pad=0 an int32 accumulator and the global OFM_SCALE.
//! Each output is the window sum of (ifm - IFM_ZERO_POINT), scaled by
//! OFM_SCALE under the OFM_PRECISION rounding mode, plus OFM_ZERO_POINT,
//! clamped to ACTIVATION_MIN/MAX. Vela 3.12.0 writes OFM_SCALE as
//! quantise_pooling_scale(kernel elements); for every kernel size from 1 to
//! 256 elements and every int8 window sum, that scale under TFL rounding
//! equals TFLite Micro's rounded division, and the tests replay a real Vela
//! stream against TFLM's bytes.
//!
//! Padded: table 4-124 runs average pool with padding without scaling, for
//! kernels up to 8x8 with 0-3 pad before and 0-4 after, and Vela 3.12.0
//! emits it with no OFM_SCALE and OFM_PRECISION b8 clear. Vela is tested
//! bit exact against TensorFlow Lite's reference kernels, whose int8
//! AveragePool divides each window sum by the number of in-bounds taps
//! (padding left out) and rounds half away from zero, so that is the result
//! modelled here, and the tests replay real Vela SAME streams against those
//! bytes.
//!
//! Modelled: signed int8 IFM and OFM in one layout, no dilation and no
//! activation function; unpadded with a shared zero point and the global
//! scale (OFM_PRECISION b8); padded with both zero points 0, the global
//! scale off and the table 4-124 kernel and pad limits. Anything else is
//! error.OperatorNotModelled.
const std = @import("std");
const dma = @import("dma.zig");
const addr = @import("addr.zig");
const minmax = @import("minmax.zig");
const pool = @import("pool.zig");
const round = @import("round.zig");

pub const mode_average: u16 = 1;

pub const Error = minmax.Error;

const global_scale: u16 = 1 << 8;
const dilation_bits: u16 = (1 << 3) | (1 << 4);

/// The TRM's limits for padded average pool (table 4-124).
pub const padded_kernel_max: u32 = 8;
pub const padded_pad_before_max: u16 = 3;
pub const padded_pad_after_max: u16 = 4;

fn padded(inputs: pool.Inputs) bool {
    const pad = inputs.maps.ifm_pad;
    return pad.top != 0 or pad.left != 0 or pad.right != 0 or pad.bottom != 0;
}

fn common(inputs: pool.Inputs) Error!void {
    const maps = inputs.maps;
    if (inputs.quant.activation != 0 or inputs.kernel.stride & dilation_bits != 0) return error.OperatorNotModelled;
    const s = pool.step(inputs.kernel.stride);
    if (s.x > pool.max_step or s.y > pool.max_step) return error.OperatorNotModelled;
    if (maps.ifm.zero_point != maps.ofm.zero_point) return error.OperatorNotModelled;
    const ifm = addr.ifmFormat(maps.ifm.precision) orelse return error.OperatorNotModelled;
    const ofm = addr.ofmFormat(maps.ofm.precision) orelse return error.OperatorNotModelled;
    if (!ifm.signed or !ofm.signed or ifm.size != 1 or ofm.size != 1) return error.OperatorNotModelled;
    if (ifm.layout != ofm.layout) return error.OperatorNotModelled;
}

fn supported(inputs: pool.Inputs) Error!round.Rounding {
    const maps = inputs.maps;
    try common(inputs);
    if (maps.ofm.precision & global_scale == 0 or inputs.quant.ofm_scale.shift > 63) return error.OperatorNotModelled;
    return round.Rounding.fromBits(addr.rounding(maps.ofm.precision)) orelse error.OperatorNotModelled;
}

fn supportedPadded(inputs: pool.Inputs) Error!void {
    const maps = inputs.maps;
    const pad = maps.ifm_pad;
    const k = inputs.kernel;
    try common(inputs);
    if (maps.ofm.precision & global_scale != 0 or maps.ifm.zero_point != 0) return error.OperatorNotModelled;
    if (@as(u32, k.height_m1) + 1 > padded_kernel_max or @as(u32, k.width_m1) + 1 > padded_kernel_max) return error.OperatorNotModelled;
    if (pad.top > padded_pad_before_max or pad.left > padded_pad_before_max) return error.OperatorNotModelled;
    if (pad.bottom > padded_pad_after_max or pad.right > padded_pad_after_max) return error.OperatorNotModelled;
}

/// The sum of (ifm - zero point) over the window whose output is (y, x, c).
fn windowSum(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs, f: addr.Format, zero_point: i32, y: u32, x: u32, c: u32) Error!i64 {
    const maps = inputs.maps;
    const k = inputs.kernel;
    const s = pool.step(k.stride);
    var sum: i64 = 0;
    for (0..@as(u32, k.height_m1) + 1) |ky| for (0..@as(u32, k.width_m1) + 1) |kx| {
        const iy = y * s.y + @as(u32, @intCast(ky));
        const ix = x * s.x + @as(u32, @intCast(kx));
        const at = addr.address(inputs.bases.ifm, maps.ifm, inputs.quant.ifm_stride, f, iy, ix, c);
        sum += try minmax.load(memory, try minmax.location(regions, maps.ifm.region, at, 1), f) - zero_point;
    };
    return sum;
}

/// One output element from a window sum.
pub fn average(sum: i64, scale: u32, shift: u6, rounding: round.Rounding, zero_point: i32, low: i32, high: i32) i32 {
    const scaled = round.apply(sum, scale, shift, rounding) + zero_point;
    return @intCast(std.math.clamp(scaled, low, high));
}

/// The sum of the in-bounds IFM elements in the padded window whose output
/// is (y, x, c), and how many there are.
const Taps = struct { sum: i64 = 0, count: u32 = 0 };

fn paddedWindow(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs, f: addr.Format, y: u32, x: u32, c: u32) Error!Taps {
    const maps = inputs.maps;
    const k = inputs.kernel;
    const s = pool.step(k.stride);
    const extent = pool.ifmExtent(inputs);
    var taps = Taps{};
    for (0..@as(u32, k.height_m1) + 1) |ky| for (0..@as(u32, k.width_m1) + 1) |kx| {
        const iy = @as(i64, y * s.y) + @as(i64, @intCast(ky)) - maps.ifm_pad.top;
        const ix = @as(i64, x * s.x) + @as(i64, @intCast(kx)) - maps.ifm_pad.left;
        if (iy < 0 or ix < 0 or iy >= extent.y or ix >= extent.x) continue;
        const at = addr.address(inputs.bases.ifm, maps.ifm, inputs.quant.ifm_stride, f, @intCast(iy), @intCast(ix), c);
        taps.sum += try minmax.load(memory, try minmax.location(regions, maps.ifm.region, at, 1), f);
        taps.count += 1;
    };
    return taps;
}

/// TensorFlow Lite's int8 AveragePool rounding: the sum divided by the tap
/// count, a half rounded away from zero, clamped.
pub fn divide(sum: i64, count: u32, low: i32, high: i32) i32 {
    const n: i64 = count;
    const q = if (sum > 0) @divTrunc(sum + @divTrunc(n, 2), n) else -@divTrunc(-sum + @divTrunc(n, 2), n);
    return @intCast(std.math.clamp(q, low, high));
}

fn runPadded(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs) Error!u64 {
    try supportedPadded(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const f = addr.ifmFormat(maps.ifm.precision).?;
    const low = @max(minmax.signExtend(q.activation_min, f), -128);
    const high = @min(minmax.signExtend(q.activation_max, f), 127);
    if (low > high) return error.OperatorNotModelled;
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const taps = try paddedWindow(memory, regions, inputs, f, yy, xx, cc);
        if (taps.count == 0) return error.OperatorNotModelled;
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, 1), divide(taps.sum, taps.count, low, high), f);
        written += 1;
    };
    return written;
}

/// Run one AVERAGE pool over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, inputs: pool.Inputs) Error!u64 {
    if (padded(inputs)) return runPadded(memory, regions, inputs);
    const rounding = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const f = addr.ifmFormat(maps.ifm.precision).?;
    const zp = minmax.signExtend(maps.ifm.zero_point, f);
    const low = @max(minmax.signExtend(q.activation_min, f), -128);
    const high = @min(minmax.signExtend(q.activation_max, f), 127);
    if (low > high) return error.OperatorNotModelled;
    const shape = maps.ofmShape();
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const sum = try windowSum(memory, regions, inputs, f, zp, yy, xx, cc);
        const out = average(sum, q.ofm_scale.scale, @intCast(q.ofm_scale.shift), rounding, zp, low, high);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, 1), out, f);
        written += 1;
    };
    return written;
}
