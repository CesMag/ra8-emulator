//! NPU_OP_CONV and NPU_OP_DEPTHWISE for int8 per-channel convolutions: the
//! registers a Vela program sets, turned into a call to the datapath in
//! conv.zig.
//!
//! The weight stream is read from WEIGHT_REGION at WEIGHT_BASE for
//! WEIGHT_LENGTH bytes, decoded (weights.zig) and put back in OHWI
//! order (order.zig). KERNEL_STRIDE b2 picks the traversal it was
//! packed in (Ethos-U55 TRM 102420_0200_02, cmd0 0x122), or the depthwise
//! order for NPU_OP_DEPTHWISE (depth multiplier 1), and
//! OFM_BLK_DEPTH_M1 (0x117) the OFM block depth. The scale-and-bias records
//! come from SCALE_REGION at SCALE_BASE for SCALE_LENGTH bytes.
//!
//! Only what the arithmetic is known for runs: signed 8-bit IFM and OFM,
//! the per-channel scale (OFM_PRECISION b8 clear), a 32-bit accumulator,
//! no activation function, no dilation, 8x8 kernel decomposition, and
//! the three rounding modes of OFM_PRECISION b[15:14]. Anything else is
//! error.OperatorNotModelled.
const std = @import("std");
const regs = @import("regs.zig");
const dma = @import("dma.zig");
const fm = @import("fm.zig");
const quant = @import("quant.zig");
const addr = @import("addr.zig");
const minmax = @import("minmax.zig");
const pool = @import("pool.zig");
const conv = @import("conv.zig");
const weights = @import("weights.zig");
const order = @import("order.zig");
const round = @import("round.zig");

pub const Error = minmax.Error || error{ BadWeights, BadScales, OutOfMemory };

/// The registers only the convolution reads, raw.
pub const State = struct {
    weight_region: u16 = 0,
    ofm_blk_depth_m1: u16 = 0,
};

pub const Outcome = enum { applied, not_modelled };

/// Apply one cmd0 register set to `state`.
pub fn apply(state: *State, code: u10, param: u16) Outcome {
    const slot: *u16 = switch (code) {
        0x117 => &state.ofm_blk_depth_m1,
        0x128 => &state.weight_region,
        else => return .not_modelled,
    };
    slot.* = param;
    return .applied;
}

/// Everything the operator reads, as the program left it.
pub const Inputs = struct {
    bases: regs.State,
    maps: fm.State,
    quant: quant.State,
    kernel: pool.State,
    conv: State,
};

const part_kernel_first: u16 = 1 << 2;
const unmodelled_kernel_bits: u16 = (1 << 3) | (1 << 4) | (1 << 5);
const global_scale: u16 = 1 << 8;

fn supported(inputs: Inputs) Error!round.Rounding {
    const maps = inputs.maps;
    const q = inputs.quant;
    if (q.activation != 0 or q.acc_format != 0) return error.OperatorNotModelled;
    if (inputs.kernel.stride & unmodelled_kernel_bits != 0) return error.OperatorNotModelled;
    if (maps.ofm.precision & global_scale != 0) return error.OperatorNotModelled;
    const ifm = addr.ifmFormat(maps.ifm.precision) orelse return error.OperatorNotModelled;
    const ofm = addr.ofmFormat(maps.ofm.precision) orelse return error.OperatorNotModelled;
    if (ifm.size != 1 or !ifm.signed or ofm.size != 1 or !ofm.signed) return error.OperatorNotModelled;
    return round.Rounding.fromBits(addr.rounding(maps.ofm.precision)) orelse error.OperatorNotModelled;
}

/// The datapath's view of the registers: shapes, padding, stride, zero
/// points and the activation range.
fn params(inputs: Inputs, rounding: round.Rounding, depthwise: bool) conv.Params {
    const maps = inputs.maps;
    const k = inputs.kernel;
    const s = pool.step(k.stride);
    const ofm = maps.ofmShape();
    const kh = @as(u32, k.height_m1) + 1;
    const kw = @as(u32, k.width_m1) + 1;
    const pad = maps.ifm_pad;
    const f8 = addr.Format{ .signed = true, .size = 1, .layout = .nhwc };
    return .{
        .ifm = .{
            .height = ((ofm.height - 1) * s.y + kh) -| (@as(u32, pad.top) + pad.bottom),
            .width = ((ofm.width - 1) * s.x + kw) -| (@as(u32, pad.left) + pad.right),
            .depth = @as(u32, maps.ifm.depth_m1) + 1,
        },
        .ofm = .{ .height = ofm.height, .width = ofm.width, .depth = ofm.depth },
        .kernel_height = kh,
        .kernel_width = kw,
        .stride_x = s.x,
        .stride_y = s.y,
        .pad_top = pad.top,
        .pad_left = pad.left,
        .ifm_zero_point = minmax.signExtend(maps.ifm.zero_point, f8),
        .ofm_zero_point = minmax.signExtend(maps.ofm.zero_point, f8),
        .rounding = rounding,
        .activation_min = minmax.signExtend(inputs.quant.activation_min, f8),
        .activation_max = minmax.signExtend(inputs.quant.activation_max, f8),
        .depthwise = depthwise,
    };
}

/// Read `len` bytes at `offset` in `region` into a new buffer.
fn readBlock(gpa: std.mem.Allocator, memory: anytype, regions: *const dma.Regions, region: u16, offset: u64, len: u64) Error![]u8 {
    if (len > std.math.maxInt(u32)) return error.AddressTooHigh;
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    const at = try minmax.location(regions, region, offset, @intCast(len));
    memory.read(at, bytes) catch return error.Refused;
    return bytes;
}

/// Decode the weight stream into OHWI order for `p`.
fn loadWeights(gpa: std.mem.Allocator, memory: anytype, regions: *const dma.Regions, inputs: Inputs, p: conv.Params) Error![]i16 {
    const stream = try readBlock(gpa, memory, regions, inputs.conv.weight_region, inputs.bases.weight_base, inputs.bases.weight_length);
    defer gpa.free(stream);
    const decoded = weights.decode(gpa, stream) catch |why| return if (why == error.OutOfMemory) error.OutOfMemory else error.BadWeights;
    defer gpa.free(decoded);
    const ifm_depth: u32 = if (p.depthwise) 1 else p.ifm.depth;
    const layout = order.Layout{
        .ofm_depth = p.ofm.depth,
        .kernel_height = p.kernel_height,
        .kernel_width = p.kernel_width,
        .ifm_depth = ifm_depth,
        .ofm_block_depth = @as(u32, inputs.conv.ofm_blk_depth_m1) + 1,
        .traversal = if (p.depthwise) .depthwise else if (inputs.kernel.stride & part_kernel_first != 0) .part_kernel_first else .depth_first,
    };
    const ohwi = try gpa.alloc(i16, p.ofm.depth * p.kernel_height * p.kernel_width * ifm_depth);
    errdefer gpa.free(ohwi);
    order.unpack(layout, decoded, ohwi) catch return error.BadWeights;
    return ohwi;
}

/// Gather the IFM the convolution reads into packed NHWC, or scatter the
/// packed OFM back to its region (`write`).
fn move(memory: anytype, regions: *const dma.Regions, tiles: regs.Tiles, map: fm.Map, stride: quant.Stride, shape: conv.Shape, f: addr.Format, buffer: []i8, write: bool) Error!void {
    var index: usize = 0;
    for (0..shape.height) |y| for (0..shape.width) |x| for (0..shape.depth) |c| {
        const at = try minmax.location(regions, map.region, addr.address(tiles, map, stride, f, @intCast(y), @intCast(x), @intCast(c)), 1);
        if (write) try minmax.store(memory, at, buffer[index], f) else buffer[index] = @intCast(try minmax.load(memory, at, f));
        index += 1;
    };
}

/// Run one NPU_OP_CONV (or NPU_OP_DEPTHWISE, `depthwise`) over the whole
/// OFM. Returns the elements written.
pub fn run(gpa: std.mem.Allocator, memory: anytype, regions: *const dma.Regions, inputs: Inputs, depthwise: bool) Error!u64 {
    const p = params(inputs, try supported(inputs), depthwise);
    const maps = inputs.maps;
    const ifm_f = addr.ifmFormat(maps.ifm.precision).?;
    const ofm_f = addr.ofmFormat(maps.ofm.precision).?;
    const ohwi = try loadWeights(gpa, memory, regions, inputs, p);
    defer gpa.free(ohwi);
    const records = try readBlock(gpa, memory, regions, inputs.quant.scale_region, inputs.bases.scale_base, inputs.bases.scale_length);
    defer gpa.free(records);
    const ifm = try gpa.alloc(i8, p.ifm.len());
    defer gpa.free(ifm);
    const ofm = try gpa.alloc(i8, p.ofm.len());
    defer gpa.free(ofm);
    try move(memory, regions, inputs.bases.ifm, maps.ifm, inputs.quant.ifm_stride, p.ifm, ifm_f, ifm, false);
    conv.run(p, ifm, ohwi, records, ofm) catch |why| return if (why == error.MissingRecord) error.BadScales else error.OperatorNotModelled;
    try move(memory, regions, inputs.bases.ofm, maps.ofm, inputs.quant.ofm_stride, p.ofm, ofm_f, ofm, true);
    return ofm.len;
}
