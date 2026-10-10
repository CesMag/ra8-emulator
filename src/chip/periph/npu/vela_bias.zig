//! The scale-and-bias records a Vela convolution reads, one per output
//! channel, from the region SCALE_REGION names.
//!
//! Each record is 10 bytes, packed exactly as Arm's Vela 3.12.0
//! (Apache-2.0) weight_compressor.py `encode_bias` writes it, low byte
//! first: a signed 40-bit bias in bytes 0 to 4, an unsigned 32-bit scale in
//! bytes 5 to 8, and a 6-bit shift in the low bits of byte 9. The top two
//! bits of byte 9 are always zero there; a record that sets them is not one
//! Vela wrote and is refused rather than decoded.
//!
//! This only unpacks the record. What the U55 does with the bias, scale and
//! shift (the accumulate, round and narrow) is the convolution's to model.
const std = @import("std");

/// Bytes per record.
pub const record_size: usize = 10;

/// One output channel's bias, scale and shift.
pub const Record = struct {
    bias: i40,
    scale: u32,
    shift: u6,
};

/// The record in `bytes`, or null when the two reserved bits are set.
pub fn decode(bytes: *const [record_size]u8) ?Record {
    if (bytes[9] & 0xC0 != 0) return null;
    return .{
        .bias = @bitCast(std.mem.readInt(u40, bytes[0..5], .little)),
        .scale = std.mem.readInt(u32, bytes[5..9], .little),
        .shift = @intCast(bytes[9] & 0x3F),
    };
}

/// Channel `channel`'s record in a run of records, or null past the end or
/// when that record is malformed.
pub fn at(records: []const u8, channel: usize) ?Record {
    const start = channel * record_size;
    if (start + record_size > records.len) return null;
    return decode(records[start..][0..record_size]);
}
