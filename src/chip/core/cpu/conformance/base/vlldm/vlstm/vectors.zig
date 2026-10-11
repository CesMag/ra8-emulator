//! Conformance vectors for the decode group `vlldm_vlstm` (RA8EMU-278),
//! the T1 VLLDM/VLSTM. Expected values are worked from the Arm ARM
//! (DDI0553): Non-secure state is UNDEFINED; CONTROL.SFPA clear is a NOP;
//! a CPACR refusal is NOCP; VLSTM with FPCCR.LSPACT set is a SecureFault
//! (LSERR); a base not 8-byte aligned is UNALIGNED. VLSTM with LSPEN clear
//! stores S0-S15 at Rn, FPSCR at +0x40 and VPR at +0x44 (S16-S31 from
//! +0x48 and a full clear when FPCCR.TS is set); with LSPEN set it only
//! records FPCAR = Rn and LSPACT. Both clear CONTROL.FPCA. VLLDM loads the
//! same frame back, or with LSPACT set only clears it, and sets FPCA.
//! Rn = PC, the T2 form, hw2 bits outside T and the 16-bit space are
//! left unclaimed.
const vector = @import("../../../vector.zig");

pub const base: u32 = 0x2000_0000;
pub const a: u32 = base + 0x80;
pub const fpca: u32 = 1 << 2;
pub const sfpa: u32 = 1 << 3;
pub const fpscr_in: u32 = 0x0004_0001;
pub const vpr_in: u32 = 0x00AB_1234;
/// The FPSCR and VPR words the runner leaves in the frame at `a`.
pub const frame_fpscr: u32 = 0x8004_0010;
pub const frame_vpr: u32 = 0x0000_5678;
pub const cp_full: u32 = 0x00F0_0000;

/// Every RAM word starts as 0xC000_0000 | address[15:0].
pub fn memAt(address: u32) u32 {
    return 0xC000_0000 | (address & 0xFFFF);
}
/// Si starts as 0x5A00_0001 + i * 0x0101.
pub fn bankAt(i: u5) u32 {
    return 0x5A00_0001 + @as(u32, i) * 0x0101;
}

pub const In = struct {
    hw1: u16,
    hw2: u16 = 0x0A00,
    size: u8 = 4,
    r0: u32 = a,
    control: u32 = fpca | sfpa,
    lspen: u1 = 0,
    ts: u1 = 0,
    lspact: u1 = 0,
    cpacr: u32 = cp_full,
    secure: bool = true,
};

pub const Fault = enum { none, undefined_instr, nocp, lserr, unaligned, other };

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    s0: u32 = bankAt(0),
    s16: u32 = bankAt(16),
    fpscr: u32 = fpscr_in,
    vpr: u32 = vpr_in,
    m0: u32 = memAt(a),
    m16: u32 = memAt(a + 0x48),
    mfpscr: u32 = frame_fpscr,
    mvpr: u32 = frame_vpr,
    control: u32 = fpca | sfpa,
    lspact: u1 = 0,
    fpcar: u32 = 0,
};

pub const V = vector.Vector(In, Out);
pub const none: Out = .{ .claimed = false, .s0 = 0, .s16 = 0, .fpscr = 0, .vpr = 0, .m0 = 0, .m16 = 0, .mfpscr = 0, .mvpr = 0, .control = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = "vlldm_vlstm", .name = name, .input = input, .expect = expect };
}

pub const all = vlstm ++ vlldm ++ unclaimed;

const stored: Out = .{ .m0 = bankAt(0), .mfpscr = fpscr_in, .mvpr = vpr_in, .control = sfpa };

const vlstm = [_]V{
    vec("vlstm r0 stores s0-s15, fpscr and vpr", .{ .hw1 = 0xEC20 }, stored),
    vec("vlstm r4 uses r4 as the base", .{ .hw1 = 0xEC24 }, stored),
    vec("vlstm with ts stores s16-s31 and clears", .{ .hw1 = 0xEC20, .ts = 1 }, .{ .m0 = bankAt(0), .m16 = bankAt(16), .mfpscr = fpscr_in, .mvpr = vpr_in, .control = sfpa, .s0 = 0, .s16 = 0, .fpscr = 0, .vpr = 0 }),
    vec("vlstm with lspen arms lazy preservation", .{ .hw1 = 0xEC20, .lspen = 1 }, .{ .control = sfpa, .lspact = 1, .fpcar = a }),
    vec("vlstm with sfpa clear is a nop", .{ .hw1 = 0xEC20, .control = fpca }, .{ .control = fpca }),
    vec("vlstm from non-secure is undefined", .{ .hw1 = 0xEC20, .secure = false }, .{ .fault = .undefined_instr }),
    vec("vlstm with cp10 off is nocp", .{ .hw1 = 0xEC20, .cpacr = 0 }, .{ .fault = .nocp }),
    vec("vlstm with lspact set is lserr", .{ .hw1 = 0xEC20, .lspact = 1 }, .{ .fault = .lserr, .lspact = 1 }),
    vec("vlstm from a misaligned base faults", .{ .hw1 = 0xEC20, .r0 = a + 4 }, .{ .fault = .unaligned }),
};

const vlldm = [_]V{
    vec("vlldm r0 loads s0-s15, fpscr and vpr", .{ .hw1 = 0xEC30, .control = sfpa }, .{ .s0 = memAt(a), .fpscr = frame_fpscr, .vpr = frame_vpr }),
    vec("vlldm with ts loads s16-s31", .{ .hw1 = 0xEC30, .control = sfpa, .ts = 1 }, .{ .s0 = memAt(a), .s16 = memAt(a + 0x48), .fpscr = frame_fpscr, .vpr = frame_vpr }),
    vec("vlldm with lspact set only clears it", .{ .hw1 = 0xEC30, .control = sfpa, .lspact = 1, .r0 = a + 4 }, .{}),
    vec("vlldm from a misaligned base faults", .{ .hw1 = 0xEC30, .control = sfpa, .r0 = a + 4 }, .{ .fault = .unaligned, .control = sfpa }),
    vec("vlldm with sfpa clear is a nop", .{ .hw1 = 0xEC30, .control = 0 }, .{ .control = 0 }),
    vec("vlldm from non-secure is undefined", .{ .hw1 = 0xEC30, .secure = false }, .{ .fault = .undefined_instr }),
    vec("vlldm with cp10 off is nocp", .{ .hw1 = 0xEC30, .cpacr = 0 }, .{ .fault = .nocp }),
};

const unclaimed = [_]V{
    vec("rn = pc is unclaimed", .{ .hw1 = 0xEC2F }, none),
    vec("the t2 form is not t1's", .{ .hw1 = 0xEC20, .hw2 = 0x0A80 }, none),
    vec("hw2[0] set is unclaimed", .{ .hw1 = 0xEC20, .hw2 = 0x0A01 }, none),
    vec("hw2 0x0b00 is unclaimed", .{ .hw1 = 0xEC20, .hw2 = 0x0B00 }, none),
    vec("hw1 0xec40 is unclaimed", .{ .hw1 = 0xEC40 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xEC20, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
