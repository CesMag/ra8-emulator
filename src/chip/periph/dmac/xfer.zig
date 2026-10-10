//! The DMAC channel plan: what one channel's registers say a request should
//! move, decoded in one place so src/chip/periph/dmac/dmac.zig stays a register window
//! and a trigger path. Same split drw/drw.zig and drw/blend.zig, and
//! dtc/dtc.zig and dtc/xfer.zig, have.
//!
//! Unlike the DTC, the DMAC keeps its whole descriptor in its own registers:
//! DMSAR, DMDAR, DMCRA, DMCRB, DMTMD and DMAMD are the transfer, so nothing
//! here reads memory. What a request actually copies is decided by three
//! fields: DMTMD.MD says how much one request is worth, DMTMD.SZ says how
//! wide a unit is, and DMAMD.SM/DM say what happens to each address after a
//! unit goes past.

/// Register field positions (ra8_dmac_regs.h, board_periph_dmac.c on dev).
pub const field = struct {
    /// DMTMD.MD[15:14]: normal, repeat or block.
    pub const md_shift: u5 = 14;
    /// DMTMD.SZ[9:8]: the unit width.
    pub const sz_shift: u5 = 8;
    /// DMAMD.SM[15:14]: source address update.
    pub const sm_shift: u5 = 14;
    /// DMAMD.DM[7:6]: destination address update.
    pub const dm_shift: u5 = 6;
    /// Every one of the four is two bits wide.
    pub const two: u32 = 0x3;
};

/// DMCRA holds two counts: DMCRAL[9:0] is the running count and DMCRAH[25:16]
/// is the block size. DMCRB is the block count.
pub const count = struct {
    pub const low_mask: u32 = 0x3FF;
    pub const high_shift: u5 = 16;
    pub const block_mask: u32 = 0xFFFF;
    /// A ten-bit count field of zero means the whole field, not none.
    pub const wrap: u32 = 1024;
};

/// DMTMD.MD: how much one transfer request is worth.
pub const Mode = enum(u2) { normal, repeat, block, reserved };

/// DMTMD.SZ: the unit a transfer moves.
pub const Width = enum(u2) { byte, half, word, reserved };

/// DMAMD.SM / DMAMD.DM: what happens to an address after each unit.
pub const Addressing = enum(u2) { fixed, offset, increment, decrement };

/// A channel configuration this model will not invent a transfer for. Each is
/// declined out loud rather than approximated, so an app relying on one goes
/// visibly nowhere here instead of passing on bytes a bench would not move.
pub const Unsupported = enum {
    /// MD = 01. Repeat mode reloads its count and its address forever; which
    /// side reloads depends on the repeat area, and that is not modelled.
    repeat_mode,
    /// MD = 11 is reserved.
    reserved_mode,
    /// SZ = 11 is reserved: there is no unit width to move.
    reserved_width,
    /// SM or DM = 01 adds DMOFR to the address after each unit, and DMOFR is
    /// stored here and never applied.
    offset_addressing,
};

/// One channel's decoded transfer shape.
pub const Plan = struct {
    mode: Mode,
    width: Width,
    source: Addressing,
    destination: Addressing,

    pub fn decode(dmtmd: u16, dmamd: u16) Plan {
        return .{
            .mode = @fromBackingInt(@intCast(@as(u2, @truncate(dmtmd >> field.md_shift)))),
            .width = @fromBackingInt(@intCast(@as(u2, @truncate(dmtmd >> field.sz_shift)))),
            .source = @fromBackingInt(@intCast(@as(u2, @truncate(dmamd >> field.sm_shift)))),
            .destination = @fromBackingInt(@intCast(@as(u2, @truncate(dmamd >> field.dm_shift)))),
        };
    }

    /// Bytes in one unit. Zero only for the reserved width, which is refused
    /// before anything moves.
    pub fn unit(self: Plan) u32 {
        return switch (self.width) {
            .byte => 1,
            .half => 2,
            .word => 4,
            .reserved => 0,
        };
    }

    /// Units ONE request is worth. This is the line dev gets wrong: it copies
    /// the whole count on the first trigger whatever the mode says, so a
    /// normal-mode channel that silicon drains one unit per request lands its
    /// entire buffer there off a single DMREQ.SWREQ store.
    pub fn burst(self: Plan, block_size: u32) u32 {
        return if (self.mode == .block) block_size else 1;
    }

    /// What an address does after a unit. dev only recognises increment, so a
    /// descending copy writes the same address every unit there.
    pub fn step(self: Plan, which: Addressing) i64 {
        const width: i64 = @intCast(self.unit());
        return switch (which) {
            .increment => width,
            .decrement => -width,
            .fixed, .offset => 0,
        };
    }

    pub fn unsupported(self: Plan) ?Unsupported {
        if (self.mode == .repeat) return .repeat_mode;
        if (self.mode == .reserved) return .reserved_mode;
        if (self.width == .reserved) return .reserved_width;
        if (self.source == .offset or self.destination == .offset) return .offset_addressing;
        return null;
    }
};

/// DMCRAL as the channel latches it when DMCNT.DTE goes up.
pub fn latchedCount(dmcra: u32) u32 {
    const low = dmcra & count.low_mask;
    return if (low == 0) count.wrap else low;
}

/// DMCRAH, the block size in block mode. Zero means the whole field here too.
pub fn blockSize(dmcra: u32) u32 {
    const high = (dmcra >> count.high_shift) & count.low_mask;
    return if (high == 0) count.wrap else high;
}

/// DMCRB, the number of blocks. Zero blocks is one block: a channel armed in
/// block mode without DMCRB still transfers once.
pub fn latchedBlocks(dmcrb: u32) u32 {
    const blocks = dmcrb & count.block_mask;
    return if (blocks == 0) 1 else blocks;
}

/// DMCRA with a new running count in the low field, the high half untouched.
pub fn withCount(dmcra: u32, remaining: u32) u32 {
    return (dmcra & ~count.low_mask) | (remaining & count.low_mask);
}

/// Walk an address by a signed step, wrapping the way a 32-bit register does.
pub fn walk(address: u32, delta: i64) u32 {
    const signed: i64 = @as(i64, address) + delta;
    return @truncate(@as(u64, @bitCast(signed)));
}
