//! The feature-map registers a Vela program sets with cmd0 commands: the
//! shape, precision, zero point and region of the input (IFM), the second
//! input (IFM2) and the output (OFM).
//!
//! The operators need these to know what they are reading and writing; the
//! bases come from vela_regs.zig. Values are kept raw, as the 16-bit
//! parameter each command carries; the _m1 fields are the size minus one,
//! and the shape helpers add the one back. Opcodes from Arm's Vela 3.12.0
//! (Apache-2.0) ethos_u55_regs.py `cmd0`. Any other cmd0 set is reported
//! as not modelled.
const std = @import("std");

/// One feature map's registers, raw.
pub const Map = struct {
    width0_m1: u16 = 0,
    height0_m1: u16 = 0,
    height1_m1: u16 = 0,
    depth_m1: u16 = 0,
    precision: u16 = 0,
    zero_point: u16 = 0,
    region: u16 = 0,
};

/// Height, width and depth of a feature map, sizes not minus-one.
pub const Shape = struct { height: u32, width: u32, depth: u32 };

pub const Pad = struct { top: u16 = 0, left: u16 = 0, right: u16 = 0, bottom: u16 = 0 };

pub const State = struct {
    ifm: Map = .{},
    ifm2: Map = .{},
    ofm: Map = .{},
    ifm_pad: Pad = .{},
    /// OFM_WIDTH_M1 / OFM_HEIGHT_M1: the whole output, not one tile.
    ofm_width_m1: u16 = 0,
    ofm_height_m1: u16 = 0,
    ifm2_broadcast: u16 = 0,
    ifm2_scalar: u16 = 0,

    /// The output's full shape.
    pub fn ofmShape(self: State) Shape {
        return .{
            .height = @as(u32, self.ofm_height_m1) + 1,
            .width = @as(u32, self.ofm_width_m1) + 1,
            .depth = @as(u32, self.ofm.depth_m1) + 1,
        };
    }
};

/// The first tile's shape of a map (tile 0, the one Vela always uses).
pub fn tileShape(map: Map) Shape {
    return .{
        .height = @as(u32, map.height0_m1) + 1,
        .width = @as(u32, map.width0_m1) + 1,
        .depth = @as(u32, map.depth_m1) + 1,
    };
}

pub const Outcome = enum { applied, not_modelled };

fn ifmField(state: *State, code: u10) ?*u16 {
    return switch (code) {
        0x100 => &state.ifm_pad.top,
        0x101 => &state.ifm_pad.left,
        0x102 => &state.ifm_pad.right,
        0x103 => &state.ifm_pad.bottom,
        0x104 => &state.ifm.depth_m1,
        0x105 => &state.ifm.precision,
        0x109 => &state.ifm.zero_point,
        0x10A => &state.ifm.width0_m1,
        0x10B => &state.ifm.height0_m1,
        0x10C => &state.ifm.height1_m1,
        0x10F => &state.ifm.region,
        else => null,
    };
}

fn ofmField(state: *State, code: u10) ?*u16 {
    return switch (code) {
        0x111 => &state.ofm_width_m1,
        0x112 => &state.ofm_height_m1,
        0x113 => &state.ofm.depth_m1,
        0x114 => &state.ofm.precision,
        0x118 => &state.ofm.zero_point,
        0x11A => &state.ofm.width0_m1,
        0x11B => &state.ofm.height0_m1,
        0x11C => &state.ofm.height1_m1,
        0x11F => &state.ofm.region,
        else => null,
    };
}

fn ifm2Field(state: *State, code: u10) ?*u16 {
    return switch (code) {
        0x180 => &state.ifm2_broadcast,
        0x181 => &state.ifm2_scalar,
        0x185 => &state.ifm2.precision,
        0x189 => &state.ifm2.zero_point,
        0x18A => &state.ifm2.width0_m1,
        0x18B => &state.ifm2.height0_m1,
        0x18C => &state.ifm2.height1_m1,
        0x18F => &state.ifm2.region,
        else => null,
    };
}

/// Apply one cmd0 register set (its opcode and parameter) to `state`.
pub fn apply(state: *State, code: u10, param: u16) Outcome {
    const slot = ifmField(state, code) orelse ofmField(state, code) orelse
        ifm2Field(state, code) orelse return .not_modelled;
    slot.* = param;
    return .applied;
}
