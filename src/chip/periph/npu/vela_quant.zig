//! The quantisation, activation and stride registers a Vela program sets:
//! what the operators need to scale, clamp and step through a feature map.
//!
//! cmd0 sets carry their value in the 16-bit parameter. The cmd1 scale sets
//! carry the 32-bit scale in the payload word and the shift in the
//! parameter, which is how Vela's `cmd1_with_offset` emits them; the stride
//! sets carry the stride in the payload. Values are kept raw. Opcodes from
//! Arm's Vela 3.12.0 (Apache-2.0) ethos_u55_regs.py `cmd0` and `cmd1`.
const std = @import("std");

/// A scale the operators multiply by, then shift right.
pub const Scale = struct { scale: u32 = 0, shift: u16 = 0 };

/// Byte strides between columns (x), rows (y) and channel blocks (c).
pub const Stride = struct { x: u32 = 0, y: u32 = 0, c: u32 = 0 };

pub const State = struct {
    acc_format: u16 = 0,
    activation: u16 = 0,
    activation_min: u16 = 0,
    activation_max: u16 = 0,
    scale_region: u16 = 0,
    ofm_scale: Scale = .{},
    opa_scale: Scale = .{},
    opb_scale: Scale = .{},
    ifm_stride: Stride = .{},
    ofm_stride: Stride = .{},
    ifm2_stride: Stride = .{},
};

pub const Outcome = enum { applied, not_modelled };

/// Apply one cmd0 register set to `state`.
pub fn applyCmd0(state: *State, code: u10, param: u16) Outcome {
    const slot: *u16 = switch (code) {
        0x124 => &state.acc_format,
        0x125 => &state.activation,
        0x126 => &state.activation_min,
        0x127 => &state.activation_max,
        0x129 => &state.scale_region,
        else => return .not_modelled,
    };
    slot.* = param;
    return .applied;
}

fn scaleField(state: *State, code: u10) ?*Scale {
    return switch (code) {
        0x024 => &state.ofm_scale,
        0x025 => &state.opa_scale,
        0x026 => &state.opb_scale,
        else => null,
    };
}

fn strideField(state: *State, code: u10) ?*u32 {
    return switch (code) {
        0x004 => &state.ifm_stride.x,
        0x005 => &state.ifm_stride.y,
        0x006 => &state.ifm_stride.c,
        0x014 => &state.ofm_stride.x,
        0x015 => &state.ofm_stride.y,
        0x016 => &state.ofm_stride.c,
        0x084 => &state.ifm2_stride.x,
        0x085 => &state.ifm2_stride.y,
        0x086 => &state.ifm2_stride.c,
        else => null,
    };
}

/// Apply one cmd1 register set (its opcode, parameter and payload word).
pub fn applyCmd1(state: *State, code: u10, param: u16, payload: u32) Outcome {
    if (scaleField(state, code)) |slot| {
        slot.* = .{ .scale = payload, .shift = param };
        return .applied;
    }
    const slot = strideField(state, code) orelse return .not_modelled;
    slot.* = payload;
    return .applied;
}
