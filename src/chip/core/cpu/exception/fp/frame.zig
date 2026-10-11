//! The extended exception frame (RA8EMU-124): the basic eight words, then
//! S0-S15, FPSCR and VPR, 0x68 bytes in all. Entry pushes it
//! when an FP context is active and clears EXC_RETURN.FType; a return with
//! FType clear pops it. With FPCCR.TS set a Secure context's frame also
//! carries S16-S31 after the VPR word, 0xA8 bytes (RA8EMU-165). With
//! FPCCR.LSPEN set, entry reserves the same space but writes only the basic
//! words (`reserve`); fpu/lazy.zig fills the rest later (RA8EMU-163). The word after FPSCR is VPR on a core with
//! MVE (RA8EMU-330) and reserved, stacked as 0, on one without.
const std = @import("std");
const bus = @import("../../bus.zig");
const frame = @import("../frame.zig");

pub const size: u32 = 0x68;
pub const words = 26;
/// The frame with the additional Secure FP state, S16-S31.
pub const size_ts: u32 = 0xA8;
pub const words_ts = words + 16;

/// The frame size for an FP context, with or without S16-S31.
pub fn sizeFor(ts: bool) u32 {
    return if (ts) size_ts else size;
}

/// Word offsets past the basic frame.
pub const slot = struct {
    pub const s0: usize = frame.words;
    pub const fpscr: usize = frame.words + 16;
    pub const vpr: usize = frame.words + 17;
    pub const s16: usize = frame.words + 18;
};

/// The FP half of the frame.
pub const Fp = struct {
    s: [16]u32,
    fpscr: u32,
    vpr: u32 = 0,
    /// S16-S31, stacked only for a Secure context with FPCCR.TS set.
    high: ?[16]u32 = null,
};

/// Push the basic `basic` frame and `fp` below `sp`; give back the new
/// stack pointer. Bit 9 of the stacked xPSR records any realignment.
pub fn push(to: bus.Bus, sp: u32, basic: frame.Frame, fp: Fp) bus.Error!u32 {
    const pad = sp & 4;
    const at = (sp -% sizeFor(fp.high != null)) & ~pad;
    var all: [words_ts]u32 = @splat(0);
    @memcpy(all[0..frame.words], &basic);
    all[frame.slot.xpsr] &= ~frame.realigned;
    if (pad != 0) all[frame.slot.xpsr] |= frame.realigned;
    @memcpy(all[slot.s0..slot.fpscr], &fp.s);
    all[slot.fpscr] = fp.fpscr;
    all[slot.vpr] = fp.vpr;
    const n: usize = if (fp.high) |high| blk: {
        @memcpy(all[slot.s16..words_ts], &high);
        break :blk words_ts;
    } else words;
    try writeWords(to, at, all[0..n]);
    return at;
}

/// Reserve the whole extended frame below `sp` but write only `basic`: the
/// lazy entry. Give back the new stack pointer.
pub fn reserve(to: bus.Bus, sp: u32, basic: frame.Frame, ts: bool) bus.Error!u32 {
    const pad = sp & 4;
    const at = (sp -% sizeFor(ts)) & ~pad;
    var stacked = basic;
    stacked[frame.slot.xpsr] &= ~frame.realigned;
    if (pad != 0) stacked[frame.slot.xpsr] |= frame.realigned;
    try writeWords(to, at, &stacked);
    return at;
}

fn writeWords(to: bus.Bus, at: u32, all: []const u32) bus.Error!void {
    for (all, 0..) |word, i| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, word, .little);
        try to.write(at +% @as(u32, @intCast(i * 4)), &bytes);
    }
}

pub const Popped = struct {
    frame: frame.Frame,
    fp: Fp,
    /// The stack pointer once the frame, and any realignment word, is gone.
    sp: u32,
};

/// Pop the extended frame at `at`, with S16-S31 when `ts`.
pub fn pop(from: bus.Bus, at: u32, ts: bool) bus.Error!Popped {
    var all: [words_ts]u32 = undefined;
    const n: usize = if (ts) words_ts else words;
    for (all[0..n], 0..) |*word, i| word.* = try from.readWord(at +% @as(u32, @intCast(i * 4)));
    var popped: Popped = .{ .frame = undefined, .fp = .{ .s = undefined, .fpscr = all[slot.fpscr], .vpr = all[slot.vpr] }, .sp = 0 };
    @memcpy(&popped.frame, all[0..frame.words]);
    @memcpy(&popped.fp.s, all[slot.s0..slot.fpscr]);
    if (ts) popped.fp.high = all[slot.s16..words_ts].*;
    const pad: u32 = if (all[frame.slot.xpsr] & frame.realigned != 0) 4 else 0;
    popped.sp = (at +% sizeFor(ts)) | pad;
    return popped;
}
