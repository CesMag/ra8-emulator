//! Conformance vectors for the decode group `long_shift` (RA8EMU-280):
//! LSLL, LSRL and ASRL by an immediate (T1). Expected values are worked
//! from the Arm ARM (DDI0553): RdaHi:RdaLo is shifted as one 64-bit value
//! and written back to the same pair; an encoded amount of 0 is a shift by
//! 32 for LSRL and ASRL. No flags change. LSLL by 0, type 11, RdaHi = 1111,
//! hw1 bit 0, hw2 bit 15, an even RdaHi and hw2[3:0] other than 1111 are
//! left unclaimed.
const vector = @import("../../../vector.zig");

/// The flags held before the instruction (N and C), which must survive.
pub const flags: u32 = 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// RdaLo, then RdaHi before the instruction.
    lo: u32 = 0,
    hi: u32 = 0,
};

/// Whether the group claims the encoding, then RdaLo, RdaHi and NZCV after.
pub const Out = struct {
    claimed: bool = true,
    lo: u32 = 0,
    hi: u32 = 0,
    flags: u32 = flags,
};

const V = vector.Vector(In, Out);
const group = "long_shift";
const none: Out = .{ .claimed = false, .flags = 0 };

/// RdaLo r0; `enc` builds hw2 for RdaHi `hi` (odd).
const lo0 = 0xEA50;
const lsll: u16 = 0;
const lsrl: u16 = 1;
const asrl: u16 = 2;

/// hw2 for `kind` shifting by `amount` (32 encodes as 0) into RdaHi `hi`.
fn enc(kind: u16, amount: u16, hi: u16) u16 {
    const a = amount & 0x1F;
    return ((a >> 2) << 12) | (hi << 8) | ((a & 3) << 6) | (kind << 4) | 0xF;
}

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// RdaLo r0, RdaHi r1.
fn sh(name: []const u8, kind: u16, amount: u16, hi: u32, lo: u32, out_hi: u32, out_lo: u32) V {
    const input: In = .{ .hw1 = lo0, .hw2 = enc(kind, amount, 1), .lo = lo, .hi = hi };
    return vec(name, input, .{ .lo = out_lo, .hi = out_hi });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = [_]V{
    sh("lsll #1 carries into RdaHi", lsll, 1, 0, 0x8000_0000, 1, 0),
    sh("lsll #16 crosses the halves", lsll, 16, 0x0000_1234, 0x5678_9ABC, 0x1234_5678, 0x9ABC_0000),
    sh("lsll #31 drops the top bits", lsll, 31, 1, 3, 0x8000_0001, 0x8000_0000),
    sh("lsrl #1 carries into RdaLo", lsrl, 1, 1, 0, 0, 0x8000_0000),
    sh("lsrl #4 crosses the halves", lsrl, 4, 0xF000_000F, 0x10, 0x0F00_0000, 0xF000_0001),
    sh("lsrl #32 from an encoded 0", lsrl, 32, 0x8000_0000, 5, 0, 0x8000_0000),
    sh("asrl #1 keeps the sign", asrl, 1, 0x8000_0000, 0, 0xC000_0000, 0),
    sh("asrl #8 crosses the halves", asrl, 8, 0xFF00_0000, 0x1234_5678, 0xFFFF_0000, 0x0012_3456),
    sh("asrl #31 of a positive value", asrl, 31, 0x4000_0000, 0, 0, 0x8000_0000),
    sh("asrl #32 from an encoded 0", asrl, 32, 0x8000_0001, 0, 0xFFFF_FFFF, 0x8000_0001),
    vec("lsll on r10:r11", .{ .hw1 = 0xEA5A, .hw2 = enc(lsll, 4, 11), .lo = 0x1000_0001, .hi = 2 }, .{ .lo = 0x0000_0010, .hi = 0x21 }),
    vec("lsrl on a non-adjacent pair r4:r1", .{ .hw1 = 0xEA54, .hw2 = enc(lsrl, 8, 1), .lo = 0xFF, .hi = 0xAB }, .{ .lo = 0xAB00_0000, .hi = 0 }),
    bad("lsll by 0 is unclaimed", lo0, enc(lsll, 0, 1)),
    bad("type 11 is unclaimed", lo0, enc(3, 4, 1)),
    bad("RdaHi of 1111 belongs to the saturating shifts", lo0, enc(lsll, 4, 0xF)),
    bad("RdaHi SP is constrained unpredictable for LSLL", lo0, enc(lsll, 4, 0xD)),
    bad("RdaHi SP is constrained unpredictable for LSRL", lo0, enc(lsrl, 4, 0xD)),
    bad("RdaHi SP is constrained unpredictable for ASRL", lo0, enc(asrl, 4, 0xD)),
    bad("hw1 bit 0 set is unclaimed", 0xEA51, enc(lsll, 4, 1)),
    bad("hw2 bit 15 set is unclaimed", lo0, 0x8000 | enc(lsll, 4, 1)),
    bad("an even RdaHi field is unclaimed", lo0, enc(lsll, 4, 0xE)),
    bad("hw2[3:0] other than 1111 is unclaimed", lo0, enc(lsll, 4, 1) & 0xFFFE),
    vec("the 16-bit space is unclaimed", .{ .hw1 = lo0, .hw2 = enc(lsll, 4, 1), .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
