//! Conformance vectors for the decode group `fp_mem` (RA8EMU-278): VLDR,
//! VSTR, VLDM, VSTM, VPUSH, VPOP, VLDR/VSTR.16 and the Armv8.1-M
//! system-register VLDR/VSTR. Expected values are worked from the Arm ARM
//! (DDI0553): VLDR/VSTR reach Rn +/- imm8 << 2 (a PC base reads
//! Align(PC, 4)); a double moves its low word first; .16 moves the
//! halfword at Rn +/- imm8 << 1, loading Zeros(16):value; VLDM/VSTM run
//! lowest address first, IA from Rn and DB from Rn - 4 * words, writing
//! Rn back only when every access succeeded; a misaligned base faults
//! with nothing changed; the system-register forms move FPSCR,
//! FPSCR_nzcvqc, VPR (top byte cleared) and P0, and FPCXT from
//! Non-secure is UNDEFINED. P:U:W = 000, P = U with W set, a PC base for
//! VLDM or any store, an empty list or one past S31, D16 and up, .16 with
//! W set, unnamed system registers, hw2[11:9] not 101 and the 16-bit
//! space are left unclaimed.
const vector = @import("../../vector.zig");

pub const base: u32 = 0x2000_0000;
/// R0's value unless a vector says otherwise.
pub const a: u32 = base + 0x80;
pub const code: u32 = base + 0x100;
pub const fpscr_reset: u32 = 0x0004_0000;

/// Every RAM word starts as 0xC000_0000 | address[15:0].
pub fn memAt(address: u32) u32 {
    return 0xC000_0000 | (address & 0xFFFF);
}
/// Si starts as 0x5A00_0000 | i * 0x0101.
pub fn bankAt(i: u5) u32 {
    return 0x5A00_0000 | @as(u32, i) * 0x0101;
}

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    address: u32 = code,
    r0: u32 = a,
    /// The base register reported as `base`; R13 gets `r0` too when 13.
    base_reg: u4 = 0,
    /// S[watch] and S[watch+1] are reported, and the words at `at`, at+4.
    watch: u5 = 0,
    at: u32 = a,
    fpscr: u32 = fpscr_reset,
    vpr: u32 = 0,
    secure: bool = true,
};

pub const Fault = enum { none, unaligned, undefined_instr, other };

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    base: u32 = a,
    s_a: u32 = bankAt(0),
    s_b: u32 = bankAt(1),
    mem_a: u32 = memAt(a),
    mem_b: u32 = memAt(a + 4),
    fpscr: u32 = fpscr_reset,
    vpr: u32 = 0,
};

const V = vector.Vector(In, Out);
const group = "fp_mem";
pub const none: Out = .{ .claimed = false, .base = 0, .s_a = 0, .s_b = 0, .mem_a = 0, .mem_b = 0, .fpscr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = single ++ multiple ++ faults ++ system ++ unclaimed;

const single = [_]V{
    vec("vldr s0, [r0, #8]", .{ .hw1 = 0xED90, .hw2 = 0x0A02 }, .{ .s_a = memAt(a + 8) }),
    vec("vldr s1, [r0, #-4]", .{ .hw1 = 0xED50, .hw2 = 0x0A01 }, .{ .s_b = memAt(a - 4) }),
    vec("vstr s2, [r0, #4]", .{ .hw1 = 0xED80, .hw2 = 0x1A01 }, .{ .mem_b = bankAt(2) }),
    vec("vldr d1, [r0] puts the low word in s2", .{ .hw1 = 0xED90, .hw2 = 0x1B00, .watch = 2 }, .{ .s_a = memAt(a), .s_b = memAt(a + 4) }),
    vec("vstr d0, [r0] stores s0 first", .{ .hw1 = 0xED80, .hw2 = 0x0B00 }, .{ .mem_a = bankAt(0), .mem_b = bankAt(1) }),
    vec("vldr s0, [pc, #8] aligns pc", .{ .hw1 = 0xED9F, .hw2 = 0x0A02, .address = code + 2 }, .{ .s_a = memAt(code + 0xC) }),
    vec("vldr.16 s0, [r0, #2] zero-extends", .{ .hw1 = 0xED90, .hw2 = 0x0901 }, .{ .s_a = memAt(a) >> 16 }),
    vec("vstr.16 s1, [r0, #2] writes the low half", .{ .hw1 = 0xEDC0, .hw2 = 0x0901 }, .{ .mem_a = (bankAt(1) << 16) | (memAt(a) & 0xFFFF) }),
};

const multiple = [_]V{
    vec("vldm r0, {s0-s3}", .{ .hw1 = 0xEC90, .hw2 = 0x0A04 }, .{ .s_a = memAt(a), .s_b = memAt(a + 4) }),
    vec("vldmia r0!, {s0-s1}", .{ .hw1 = 0xECB0, .hw2 = 0x0A02 }, .{ .base = a + 8, .s_a = memAt(a), .s_b = memAt(a + 4) }),
    vec("vstmdb r0!, {s2-s3}", .{ .hw1 = 0xED20, .hw2 = 0x1A02, .at = a - 8 }, .{ .base = a - 8, .mem_a = bankAt(2), .mem_b = bankAt(3) }),
    vec("vldmdb r0!, {s0}", .{ .hw1 = 0xED30, .hw2 = 0x0A01 }, .{ .base = a - 4, .s_a = memAt(a - 4) }),
    vec("vldm r0, {d0-d1}", .{ .hw1 = 0xEC90, .hw2 = 0x0B04, .watch = 2 }, .{ .s_a = memAt(a + 8), .s_b = memAt(a + 12) }),
    vec("vpush {d0-d1}", .{ .hw1 = 0xED2D, .hw2 = 0x0B04, .base_reg = 13, .at = a - 16 }, .{ .base = a - 16, .mem_a = bankAt(0), .mem_b = bankAt(1) }),
    vec("vpop {s0-s1}", .{ .hw1 = 0xECBD, .hw2 = 0x0A02, .base_reg = 13 }, .{ .base = a + 8, .s_a = memAt(a), .s_b = memAt(a + 4) }),
};

const faults = [_]V{
    vec("vldr from a misaligned base faults", .{ .hw1 = 0xED90, .hw2 = 0x0A00, .r0 = a + 2 }, .{ .fault = .unaligned, .base = a + 2 }),
    vec("vldmia past ram faults with no writeback", .{ .hw1 = 0xECB0, .hw2 = 0x0A04, .r0 = base + 0x3F8 }, .{ .fault = .other, .base = base + 0x3F8 }),
};

const system = [_]V{
    vec("vstr fpscr, [r0, #4]", .{ .hw1 = 0xED80, .hw2 = 0x1F81, .fpscr = 0x6004_0001 }, .{ .mem_b = 0x6004_0001, .fpscr = 0x6004_0001 }),
    vec("vldr fpscr, [r0]", .{ .hw1 = 0xED90, .hw2 = 0x1F80 }, .{ .fpscr = memAt(a) & 0xFFCF_009F }),
    vec("vldr fpscr_nzcvqc, [r0]", .{ .hw1 = 0xED90, .hw2 = 0x2F80, .fpscr = 0x0004_0001 }, .{ .fpscr = 0xC004_0001 }),
    vec("vldr vpr, [r0] clears the top byte", .{ .hw1 = 0xEDD0, .hw2 = 0x4F80 }, .{ .vpr = memAt(a) & 0x00FF_FFFF }),
    vec("vstr p0, [r0]", .{ .hw1 = 0xEDC0, .hw2 = 0x5F80, .vpr = 0x00AB_1234 }, .{ .mem_a = 0x1234, .vpr = 0x00AB_1234 }),
    vec("vstr fpscr, [r0, #-4]!", .{ .hw1 = 0xED20, .hw2 = 0x1F81, .at = a - 4 }, .{ .base = a - 4, .mem_a = fpscr_reset, .mem_b = memAt(a) }),
    vec("vldr fpcxt_ns from non-secure is undefined", .{ .hw1 = 0xEDD0, .hw2 = 0x6F80, .secure = false }, .{ .fault = .undefined_instr }),
};

const unclaimed = [_]V{
    bad("p:u:w = 000 is fp_move's", 0xEC10, 0x0A02),
    bad("p = u with w set is unclaimed", 0xEDB0, 0x0A02),
    bad("vldm from pc is unclaimed", 0xEC9F, 0x0A02),
    bad("an empty list is unclaimed", 0xEC90, 0x0A00),
    bad("a list past s31 is unclaimed", 0xECD0, 0xFA02),
    bad("vstr to a pc base is unclaimed", 0xED8F, 0x0A01),
    bad("vldr d16 is unclaimed", 0xEDD0, 0x0B00),
    bad("vstr.16 to a pc base is unclaimed", 0xED8F, 0x0901),
    bad("vldr.16 with w set is unclaimed", 0xEDB0, 0x0901),
    bad("system register 0011 is unclaimed", 0xED90, 0x3F80),
    bad("hw2[11:9] = 110 is unclaimed", 0xED90, 0x0C02),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xED90, .hw2 = 0x0A02, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
