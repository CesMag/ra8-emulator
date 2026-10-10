//! The GWCA descriptor: the eight bytes a ring entry is made of, and what
//! each field in them means.
//!
//! A queue on the CPU agent is a chain of these in guest RAM, and the LINKFIX
//! table the gateway is pointed at is a table of the same eight bytes. That
//! vocabulary is all this file is; the walking of the chains and the moving
//! of frames live in dma.zig.
//!
//! Ported from the descriptor helpers in board_periph_eth.c on dev.
const std = @import("std");

/// A basic descriptor and a LINKFIX entry are both eight bytes.
pub const size: u32 = 8;

/// Where the fields sit in those eight bytes (HUM Ch 34.5.1.2): byte 0 is
/// DS[7:0], byte 1's low nibble DS[11:8], byte 2's high nibble DT, and bytes
/// 4..7 the pointer, little-endian.
pub const layout = struct {
    pub const ds_low: u32 = 0;
    pub const ds_high: u32 = 1;
    pub const dt: u32 = 2;
    pub const ptr: u32 = 4;
    pub const nibble: u8 = 0x0F;
    pub const dt_shift: u3 = 4;
};

/// The descriptor types the gateway understands. Three of the sixteen codes
/// are not types, which is why this is open.
pub const Dt = enum(u4) {
    linkfix = 0,
    fempty_is = 1,
    fempty_ic = 2,
    fempty_nd = 3,
    fempty = 4,
    fsingle = 8,
    fstart = 9,
    fmid = 10,
    fend = 11,
    lempty = 12,
    eempty = 13,
    link = 14,
    eos = 15,
    _,
};

pub const limits = struct {
    /// Longest frame this model marshals, which is dev's buffer cap and
    /// comfortably over a tagged 802.3 frame.
    pub const frame_max: u32 = 1536;
    /// Shortest thing that can be a frame: six bytes of destination, six of
    /// source, and the type. THIS MODEL'S floor, not a silicon one. dev takes
    /// any DS from a single byte up and hands it to the peer as a frame.
    pub const frame_min: u32 = 14;
    /// Descriptors a ring walk looks at before it calls the ring malformed.
    pub const walk: u32 = 64;
    /// Frames staged into one ring in one chunk boundary.
    pub const inject: u32 = 8;
};

/// One descriptor, decoded.
pub const Desc = struct {
    ds: u32,
    dt: Dt,
    ptr: u32,

    pub fn decode(raw: [size]u8) Desc {
        const high: u32 = raw[layout.ds_high] & layout.nibble;
        return .{
            .ds = @as(u32, raw[layout.ds_low]) | (high << 8),
            .dt = @fromBackingInt(@intCast(@as(u4, @truncate(raw[layout.dt] >> layout.dt_shift)))),
            .ptr = std.mem.readInt(u32, raw[layout.ptr..][0..4], .little),
        };
    }
};

/// A descriptor whose pointer is the next link of the chain rather than a
/// frame buffer.
pub fn chains(dt: Dt) bool {
    return dt == .link or dt == .linkfix;
}

/// A slot the gateway may fill: FEMPTY is the full-frame reception slot, the
/// only one the CPU agent's RX path stages into.
pub fn free(dt: Dt) bool {
    return dt == .fempty;
}

/// Byte 2 carrying `dt`, with the bits below it kept.
pub fn dtByte(old: u8, dt: Dt) u8 {
    const code: u8 = @backingInt(dt);
    return (old & layout.nibble) | (code << layout.dt_shift);
}

/// Bytes 0 and 1 carrying `ds`, with byte 1's high nibble kept.
pub fn dsBytes(old_high: u8, ds: u32) [2]u8 {
    const high: u8 = @truncate((ds >> 8) & layout.nibble);
    return .{ @truncate(ds), (old_high & ~layout.nibble) | high };
}
