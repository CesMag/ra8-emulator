//! The address and length registers a Vela program sets before it runs an
//! operation or a DMA: where the feature maps, weights and scales live, and
//! what the DMA moves.
//!
//! vela.zig splits a stream into commands; this file is what a cmd1
//! command does to the NPU's state. Only the address and length registers
//! are kept so far (feature-map shape, padding, quantisation and the rest
//! of the cmd1 set come in later slices); any other cmd1 is reported as
//! not modelled rather than silently dropped.
//!
//! Opcode values, from Arm's Vela 3.12.0 (Apache-2.0) ethos_u55_regs.py
//! `cmd1`. An address is up to 40 bits: Vela's cmd1_with_address puts the
//! low 32 bits in the payload and the bits above them in the command's
//! 16-bit parameter, so an address register is payload | param << 32.
const std = @import("std");
const vela = @import("vela.zig");

pub const set_ifm_base0: u10 = 0x000;
pub const set_ofm_base0: u10 = 0x010;
pub const set_weight_base: u10 = 0x020;
pub const set_weight_length: u10 = 0x021;
pub const set_scale_base: u10 = 0x022;
pub const set_scale_length: u10 = 0x023;
pub const set_dma0_src: u10 = 0x030;
pub const set_dma0_dst: u10 = 0x031;
pub const set_dma0_len: u10 = 0x032;
pub const set_dma0_skip0: u10 = 0x033;
pub const set_dma0_skip1: u10 = 0x034;
pub const set_ifm2_base0: u10 = 0x080;

/// The four tile bases a feature map is split across.
pub const Tiles = [4]u64;

pub const Dma = struct {
    src: u64 = 0,
    dst: u64 = 0,
    len: u64 = 0,
    skip0: u64 = 0,
    skip1: u64 = 0,
};

pub const State = struct {
    ifm: Tiles = .{ 0, 0, 0, 0 },
    ifm2: Tiles = .{ 0, 0, 0, 0 },
    ofm: Tiles = .{ 0, 0, 0, 0 },
    weight_base: u64 = 0,
    weight_length: u64 = 0,
    scale_base: u64 = 0,
    scale_length: u64 = 0,
    dma0: Dma = .{},
};

pub const Outcome = enum { applied, not_modelled };

/// The 40-bit value a cmd1 carries: payload low, parameter above it.
pub fn value(word: u32, payload: u32) u64 {
    return @as(u64, payload) | (@as(u64, vela.param(word)) << 32);
}

fn tile(tiles: *Tiles, code: u10, first: u10, v: u64) bool {
    if (code < first or code > first + 3) return false;
    tiles[code - first] = v;
    return true;
}

fn dmaField(dma: *Dma, code: u10) ?*u64 {
    return switch (code) {
        set_dma0_src => &dma.src,
        set_dma0_dst => &dma.dst,
        set_dma0_len => &dma.len,
        set_dma0_skip0 => &dma.skip0,
        set_dma0_skip1 => &dma.skip1,
        else => null,
    };
}

fn field(state: *State, code: u10) ?*u64 {
    return switch (code) {
        set_weight_base => &state.weight_base,
        set_weight_length => &state.weight_length,
        set_scale_base => &state.scale_base,
        set_scale_length => &state.scale_length,
        else => dmaField(&state.dma0, code),
    };
}

/// Apply one cmd1 (its command word and payload) to `state`.
pub fn apply(state: *State, word: u32, payload: u32) Outcome {
    const code: u10 = @truncate(word & vela.opcode_mask);
    const v = value(word, payload);
    if (tile(&state.ifm, code, set_ifm_base0, v)) return .applied;
    if (tile(&state.ofm, code, set_ofm_base0, v)) return .applied;
    if (tile(&state.ifm2, code, set_ifm2_base0, v)) return .applied;
    const slot = field(state, code) orelse return .not_modelled;
    slot.* = v;
    return .applied;
}
