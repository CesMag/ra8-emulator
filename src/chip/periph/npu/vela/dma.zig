//! What NPU_OP_DMA_START does with the DMA0 registers: a linear copy from
//! one memory region to another.
//!
//! The addresses a Vela program puts in DMA0_SRC/DST are offsets into a
//! region, not bus addresses. NPU_SET_DMA0_SRC_REGION and _DST_REGION (cmd0
//! 0x130 and 0x131) pick the region in their parameter's low byte, flag the
//! NPU's internal memory in bit 8 and pick the stride mode in bits [10:9];
//! the driver gives each region its bus base in the BASEP registers. Layout
//! from Arm's Vela 3.12.0 (Apache-2.0) ethos_u55_regs.py
//! (npu_set_dma0_src_region_t, STRIDE_MODE_1D = 0).
//!
//! Only the 1D stride mode and external regions are modelled; the 2D and 3D
//! modes and the internal memory are refused by name rather than copied
//! wrong. That refusal is the U55's own shape, not a gap: the Ethos-U55 TRM
//! (102420_0200_02) gives SKIP0/SKIP1 (cmd1 0x033/0x034) a 2D/3D meaning
//! but lists cmd0 0x132-0x17F, where the 2D/3D sizes would go, as
//! reserved, and Vela 3.12.0 only emits 1D DMA for the U55. `memory` is anything with read/write(address, bytes), so the
//! copy holds on either engine and in tests.
const std = @import("std");
const regs = @import("regs.zig");

pub const set_dma0_src_region: u10 = 0x130;
pub const set_dma0_dst_region: u10 = 0x131;
pub const region_count = 8;
pub const stride_1d: u2 = 0;
/// Bytes moved per access, so one refusal says roughly where it stopped.
pub const chunk = 256;

/// The BASEP bus base of each region.
pub const Regions = [region_count]u64;

pub const Region = struct {
    index: u8 = 0,
    internal: bool = false,
    stride: u2 = stride_1d,

    /// Decode a SRC_REGION/DST_REGION command's 16-bit parameter.
    pub fn fromParam(param: u16) Region {
        return .{
            .index = @truncate(param),
            .internal = (param >> 8) & 1 == 1,
            .stride = @truncate(param >> 9),
        };
    }
};

pub const Error = error{
    StrideNotModelled,
    InternalNotModelled,
    RegionOutOfRange,
    AddressTooHigh,
    Refused,
};

fn busAddress(regions: *const Regions, region: Region, offset: u64, len: u64) Error!u32 {
    if (region.stride != stride_1d) return error.StrideNotModelled;
    if (region.internal) return error.InternalNotModelled;
    if (region.index >= region_count) return error.RegionOutOfRange;
    const start = regions[region.index] +% offset;
    if (start < offset or start + len > @as(u64, std.math.maxInt(u32)) + 1) {
        return error.AddressTooHigh;
    }
    return @intCast(start);
}

/// Copy dma.len bytes from dma.src in `src` to dma.dst in `dst`. Returns
/// the byte count moved; a refused access stops the copy with
/// error.Refused, leaving the chunks before it in place.
pub fn copy(memory: anytype, regions: *const Regions, src: Region, dst: Region, dma: regs.Dma) Error!u64 {
    const from = try busAddress(regions, src, dma.src, dma.len);
    const to = try busAddress(regions, dst, dma.dst, dma.len);
    var buffer: [chunk]u8 = undefined;
    var done: u64 = 0;
    while (done < dma.len) {
        const step: usize = @intCast(@min(dma.len - done, chunk));
        const at: u32 = @intCast(done);
        memory.read(from + at, buffer[0..step]) catch return error.Refused;
        memory.write(to + at, buffer[0..step]) catch return error.Refused;
        done += step;
    }
    return done;
}
