//! MVE interleaving loads and stores, VLD2x/VLD4x and VST2x/VST4x
//! (RA8EMU-25), from their pseudocode in the Arm ARM (DDI0553). A full
//! set of patterns (VLD20 + VLD21, or VLD40..VLD43) moves 32 or 64
//! contiguous bytes: memory element j belongs to register j mod n,
//! element j / n, for n = 2 or 4 registers. Each pattern instruction
//! moves four 32-bit words, one per beat, at the byte offsets below; the
//! tables are the same for every element size.
const qreg = @import("../qreg.zig");
pub const vectors = @import("vectors.zig");
const Size = qreg.Size;

const two = [2][4]u8{ .{ 0, 4, 24, 28 }, .{ 8, 12, 16, 20 } };
const four = [4][4]u8{ .{ 0, 4, 40, 44 }, .{ 8, 12, 48, 52 }, .{ 16, 20, 56, 60 }, .{ 24, 28, 32, 36 } };

/// One beat of one pattern: `regs` is 2 or 4, `pat` below `regs`.
pub const Beat = struct { regs: u3, pat: u2, beat: u2 };

/// The byte offset from Rn of the word a beat moves.
pub fn beatOffset(b: Beat) u32 {
    return if (b.regs == 2) two[b.pat][b.beat] else four[b.pat][b.beat];
}

/// Where a memory element lands among the registers.
pub const Slot = struct { reg: u2, elem: u8 };

/// The register and element of the element starting at byte `offset`.
pub fn slot(regs: u3, size: Size, offset: u32) Slot {
    const j = offset / (qreg.bits(size) / 8);
    return .{ .reg = @intCast(j % regs), .elem = @intCast(j / regs) };
}
