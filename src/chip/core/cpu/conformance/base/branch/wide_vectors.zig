//! Conformance vectors for the decode group `branch_wide` (RA8EMU-278):
//! B<cond>.W (T3), B.W (T4) and BL (T1). Expected values are worked from the
//! Arm ARM (DDI0553): the target is the instruction's address plus 4 plus
//! the sign-extended S:I1:I2:imm10:imm11:0 (T4 and BL, In = NOT(Jn XOR S))
//! or S:J2:J1:imm6:imm11:0 (T3); BL leaves the return address with bit 0
//! set in LR; a T3 branch whose condition fails leaves the PC alone. T3
//! conditions 111x (the miscellaneous control space), the BLX and other
//! hw2[15:14,12] forms, hw1 bit 11 and the 16-bit space are unclaimed.
const vector = @import("../../vector.zig");

/// What the PC and LR hold before the instruction.
pub const unmoved: u32 = 0xAAAA_0000;
pub const lr_seed: u32 = 0xBBBB_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The instruction's address.
    address: u32 = 0x1000,
    /// NZCV before the instruction.
    flags: u32 = 0,
};

/// Whether the group claims the encoding, then the PC and LR after.
pub const Out = struct {
    claimed: bool = true,
    pc: u32 = unmoved,
    lr: u32 = lr_seed,
};

const V = vector.Vector(In, Out);
const group = "branch_wide";
const none: Out = .{ .claimed = false, .pc = 0, .lr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn go(name: []const u8, hw1: u16, hw2: u16, pc: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, .{ .pc = pc });
}

fn call(name: []const u8, hw1: u16, hw2: u16, pc: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, .{ .pc = pc, .lr = 0x1005 });
}

fn cond(name: []const u8, hw1: u16, hw2: u16, flags: u32, pc: u32) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2, .flags = flags }, .{ .pc = pc });
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = unconditional ++ conditional ++ unclaimed;

const unconditional = [_]V{
    go("b.w +0", 0xF000, 0xB800, 0x1004),
    go("b.w +2", 0xF000, 0xB801, 0x1006),
    go("b.w -4 loops", 0xF7FF, 0xBFFE, 0x1000),
    go("b.w to the far end", 0xF3FF, 0x97FF, 0x1001002),
    go("b.w to the near end", 0xF400, 0x9000, 0xFF001004),
    go("b.w with I2 alone", 0xF000, 0xB000, 0x401004),
    go("b.w with I1 alone", 0xF000, 0x9800, 0x801004),
    go("b.w back with I1 and I2 clear", 0xF7FF, 0xB7FF, 0xFFC01002),
    call("bl +0", 0xF000, 0xF800, 0x1004),
    call("bl -4", 0xF7FF, 0xFFFE, 0x1000),
    call("bl to the far end", 0xF3FF, 0xD7FF, 0x1001002),
    call("bl to the near end", 0xF400, 0xD000, 0xFF001004),
    call("bl with I1 alone", 0xF000, 0xD800, 0x801004),
    vec("bl from RAM sets LR there", .{ .hw1 = 0xF7FF, .hw2 = 0xFFFF, .address = 0x2000_0000 }, .{ .pc = 0x2000_0002, .lr = 0x2000_0005 }),
};

const conditional = [_]V{
    cond("beq.w taken with Z", 0xF000, 0x8080, 0x40000000, 0x1104),
    cond("beq.w not taken", 0xF000, 0x8080, 0x00000000, unmoved),
    cond("bne.w taken", 0xF040, 0x8080, 0x00000000, 0x1104),
    cond("bne.w not taken with Z", 0xF040, 0x8080, 0x40000000, unmoved),
    cond("bcs.w taken", 0xF080, 0x8080, 0x20000000, 0x1104),
    cond("bcc.w taken", 0xF0C0, 0x8080, 0x00000000, 0x1104),
    cond("bcc.w not taken with C", 0xF0C0, 0x8080, 0x20000000, unmoved),
    cond("bmi.w taken", 0xF100, 0x8080, 0x80000000, 0x1104),
    cond("bpl.w not taken with N", 0xF140, 0x8080, 0x80000000, unmoved),
    cond("bvs.w taken", 0xF180, 0x8080, 0x10000000, 0x1104),
    cond("bvc.w not taken with V", 0xF1C0, 0x8080, 0x10000000, unmoved),
    cond("bhi.w taken", 0xF200, 0x8080, 0x20000000, 0x1104),
    cond("bhi.w not taken with Z", 0xF200, 0x8080, 0x60000000, unmoved),
    cond("bls.w taken", 0xF240, 0x8080, 0x40000000, 0x1104),
    cond("bge.w taken with N and V", 0xF280, 0x8080, 0x90000000, 0x1104),
    cond("blt.w taken", 0xF2C0, 0x8080, 0x80000000, 0x1104),
    cond("bgt.w not taken with Z", 0xF300, 0x8080, 0x40000000, unmoved),
    cond("ble.w taken", 0xF340, 0x8080, 0x40000000, 0x1104),
    cond("bne.w to the far end", 0xF07F, 0xAFFF, 0, 0x101002),
    cond("bne.w to the near end", 0xF440, 0x8000, 0, 0xFFF01004),
    cond("bne.w with J1 alone", 0xF040, 0xA000, 0, 0x41004),
    cond("bne.w with J2 alone", 0xF040, 0x8800, 0, 0x81004),
    cond("bne.w -4 loops", 0xF47F, 0xAFFE, 0, 0x1000),
};

const unclaimed = [_]V{
    bad("condition 1110 is the control space", 0xF380, 0x8000),
    bad("condition 1111 is the control space", 0xF3C0, 0x8000),
    bad("blx (hw2 1100) is unclaimed", 0xF000, 0xC000),
    bad("hw2 00x0 is unclaimed", 0xF000, 0x0000),
    bad("hw2 01x0 is unclaimed", 0xF000, 0x4000),
    bad("hw2 01x1 is unclaimed", 0xF000, 0x5000),
    bad("hw1 bit 11 set is unclaimed", 0xF800, 0xF800),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF000, .hw2 = 0xB800, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
