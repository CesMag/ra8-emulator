//! Elementwise ADD and SUB (NPU_OP_ELEMENTWISE modes 1 and 2, Ethos-U55
//! TRM 102420_0200_02 cmd0 0x006) for int8 tensors.
//!
//! Vela 3.12.0 emits one of two operand scalings
//! (register_command_stream_generator.generate_scaling_for_elementwise):
//! - simplified, for equal input scales: IFM_PRECISION b[9:8] is 0, and
//!   each zero-point-adjusted operand is multiplied by its own OPA_SCALE /
//!   OPB_SCALE (cmd1 0x025 / 0x026) scale;
//! - advanced, otherwise: IFM_PRECISION b[9:8] names the operand with the
//!   smaller input scale (1 IFM, 2 IFM2). That operand is shifted left 20
//!   and scaled by OPA_SCALE with TFLite Micro's double rounding (OPA_SCALE
//!   shift - 11 is TFLM's right shift); the other is shifted left 19.
//! The sum or difference is then scaled by OFM_SCALE under the OFM_PRECISION
//! rounding mode, offset by OFM_ZERO_POINT and clamped to
//! ACTIVATION_MIN/MAX. That is TFLM's int8 ADD/SUB (left_shift 20, twice
//! the larger input scale) written in Vela's registers. The TRM does not
//! spell out this datapath; what is pinned is TFLM's result for Vela's
//! registers, which matched byte for byte on every int8 input pair at
//! eleven scale ratios per mode, and the tests here check real streams.
//!
//! Modelled: signed int8 IFM, IFM2 and OFM in one layout, the global scale,
//! no activation function, IFM2 broadcast as vela_minmax.zig reads it.
//! Anything else is error.OperatorNotModelled.
const std = @import("std");
const dma = @import("vela_dma.zig");
const addr = @import("vela_addr.zig");
const minmax = @import("vela_minmax.zig");
const round = @import("vela_round.zig");

pub const mode_add: u16 = 1;
pub const mode_sub: u16 = 2;

pub const Error = minmax.Error;
pub const Inputs = minmax.Inputs;

const global_scale: u16 = 1 << 8;

/// How each operand is brought to the common scale before the add.
pub const Operands = union(enum) {
    /// Each operand times its own scale.
    simplified: struct { a: u32, b: u32 },
    /// One operand scaled (OPA_SCALE), the other shifted left 19.
    advanced: struct { scale_a: bool, scale: u32, shift: u6 },

    /// Read from IFM_PRECISION b[9:8] and the OPA/OPB scale registers.
    pub fn decode(ifm_precision: u16, opa: anytype, opb: anytype) ?Operands {
        return switch ((ifm_precision >> 8) & 3) {
            0 => if (opa.shift != 0 or opb.shift != 0) null else .{ .simplified = .{ .a = opa.scale, .b = opb.scale } },
            1, 2 => |which| if (opa.shift < 11 or opa.shift > 43) null else .{ .advanced = .{
                .scale_a = which == 1,
                .scale = opa.scale,
                .shift = @intCast(opa.shift + 20),
            } },
            else => null,
        };
    }

    fn scaled(self: Operands, value: i32, is_a: bool) i64 {
        return switch (self) {
            .simplified => |s| @as(i64, value) * (if (is_a) s.a else s.b),
            .advanced => |s| if (s.scale_a == is_a)
                @intCast(round.apply(@as(i64, value) << 20, s.scale, s.shift, .double))
            else
                @as(i64, value) << 19,
        };
    }
};

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
pub fn element(mode: u16, operands: Operands, a: i32, b: i32, scale: u32, shift: u6, rounding: round.Rounding, ofm_zero_point: i32, low: i32, high: i32) i32 {
    const left = operands.scaled(a, true);
    const right = operands.scaled(b, false);
    const raw = if (mode == mode_sub) left - right else left + right;
    const out = round.apply(raw, scale, shift, rounding) + ofm_zero_point;
    return @intCast(std.math.clamp(out, low, high));
}

/// Run one ADD or SUB over the whole OFM. Returns the elements written.
pub fn run(memory: anytype, regions: *const dma.Regions, mode: u16, inputs: Inputs) Error!u64 {
    if (mode != mode_add and mode != mode_sub) return error.OperatorNotModelled;
    const rounding = try supported(inputs);
    const maps = inputs.maps;
    const q = inputs.quant;
    const operands = Operands.decode(maps.ifm.precision, q.opa_scale, q.opb_scale) orelse return error.OperatorNotModelled;
    const f = addr.ifmFormat(maps.ifm.precision).?;
    const zp_a = minmax.signExtend(maps.ifm.zero_point, f);
    const zp_b = minmax.signExtend(maps.ifm2.zero_point, f);
    const zp_o = minmax.signExtend(maps.ofm.zero_point, f);
    const low = @max(minmax.signExtend(q.activation_min, f), -128);
    const high = @min(minmax.signExtend(q.activation_max, f), 127);
    if (low > high) return error.OperatorNotModelled;
    const shape = maps.ofmShape();
    const shift: u6 = @intCast(q.ofm_scale.shift);
    var written: u64 = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const yy: u32 = @intCast(y);
        const xx: u32 = @intCast(x);
        const cc: u32 = @intCast(c);
        const a_at = addr.address(inputs.bases.ifm, maps.ifm, q.ifm_stride, f, yy, xx, cc);
        const o_at = addr.address(inputs.bases.ofm, maps.ofm, q.ofm_stride, f, yy, xx, cc);
        const a = try minmax.load(memory, try minmax.location(regions, maps.ifm.region, a_at, 1), f);
        const b = try minmax.second(memory, regions, inputs, f, yy, xx, cc);
        const out = element(mode, operands, a - zp_a, b - zp_b, q.ofm_scale.scale, shift, rounding, zp_o, low, high);
        try minmax.store(memory, try minmax.location(regions, maps.ofm.region, o_at, 1), out, f);
        written += 1;
    };
    return written;
}
