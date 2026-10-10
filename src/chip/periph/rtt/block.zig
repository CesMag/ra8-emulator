//! The SEGGER RTT control block, as a debug probe reads it out of target RAM.
//!
//! RTT is not a peripheral: it is a ring buffer the firmware puts in RAM and a
//! J-Link drains over SWD. The probe finds it by scanning target RAM for the
//! ten-byte ID the block begins with, then reads the up-buffer descriptors
//! that follow. This file is that vocabulary, and the sanity checks that
//! decide whether a candidate is a live block or ten bytes that happened to
//! spell the ID; the scanning and draining live in rtt.zig.
//!
//! Ported from board_periph_rtt.c on dev, with one check dev does not make:
//! the ring has to be in RAM. See `check`.
const std = @import("std");

const memmap = @import("../../core/memmap.zig");

/// The ID a block begins with. Spelled as bytes rather than a string literal
/// for the reason the firmware writes it a byte at a time: this tool's own
/// constant pool must never be mistaken for a control block.
pub const id = [_]u8{ 'S', 'E', 'G', 'G', 'E', 'R', ' ', 'R', 'T', 'T' };

/// Field offsets in the 32-bit target layout (SEGGER_RTT.h): `char id[16]`,
/// `u32 max_up`, `u32 max_down`, then `max_up` up-buffer descriptors of
/// `{ const char *name; u8 *buf; u32 size; u32 write; u32 read; u32 flags }`.
pub const layout = struct {
    pub const max_up: u32 = 16;
    pub const max_down: u32 = 20;
    pub const up0: u32 = 24;
    pub const desc_name: u32 = 0;
    pub const desc_buf: u32 = 4;
    pub const desc_size: u32 = 8;
    pub const desc_write: u32 = 12;
    pub const desc_read: u32 = 16;
    pub const desc_flags: u32 = 20;
};

/// What the model refuses to believe. A block still being built by
/// `SEGGER_RTT_Init` fails one of these and is simply re-tried later.
pub const limits = struct {
    /// More up-buffers than this is garbage, not a channel list.
    pub const max_up: u32 = 16;
    /// A ring bigger than this is a pointer, not a size.
    pub const ring: u32 = 1024 * 1024;
};

/// Up-buffer 0 as it stands this tick.
pub const Up = struct {
    buf: u32,
    size: u32,
    write: u32,
    read: u32,

    /// Bytes the firmware has written and the probe has not taken yet.
    pub fn pending(self: Up) u32 {
        if (self.write >= self.read) return self.write - self.read;
        return (self.size - self.read) + self.write;
    }

    /// The run of bytes readable without wrapping, given a drain of `want`.
    pub fn firstRun(self: Up, want: u32) u32 {
        const to_end = self.size - self.read;
        return if (to_end < want) to_end else want;
    }
};

/// Why a candidate is not a block worth draining.
pub const Reject = enum {
    no_up_buffer,
    too_many_up_buffers,
    empty_ring,
    huge_ring,
    offset_past_ring,
    ring_off_ram,
};

/// The checks a probe makes before it trusts a ring, plus the RAM one.
///
/// The RAM one is `memmap.debugHolds`, every region the loader maps as RAM,
/// and not the one window the scan happens to search. A probe follows the
/// storage pointer out of a block it has already found, so where the ring
/// sits is a question about what the debug port can reach, not about where
/// it was worth looking for the block. dev makes no such check at all and
/// follows the pointer into the peripheral window.
pub fn check(max_up_count: u32, up: Up) ?Reject {
    if (max_up_count == 0) return .no_up_buffer;
    if (max_up_count > limits.max_up) return .too_many_up_buffers;
    if (up.buf == 0 or up.size == 0) return .empty_ring;
    if (up.size > limits.ring) return .huge_ring;
    if (up.write >= up.size or up.read >= up.size) return .offset_past_ring;
    if (!memmap.debugHolds(up.buf, up.size)) return .ring_off_ram;
    return null;
}

/// True when the bytes at `at` begin a control block.
pub fn idAt(bytes: []const u8, at: usize) bool {
    if (at + id.len > bytes.len) return false;
    return std.mem.eql(u8, bytes[at..][0..id.len], &id);
}
