//! Conformance vectors for the decode group `branch_future` (RA8EMU-278):
//! BF, BFL, BFCSEL, BFX and BFLX (Armv8.1-M). Expected values are worked
//! from the Arm ARM (DDI0553): a Branch Future only fills LO_BRANCH_INFO, a
//! cache the architecture lets an implementation leave out, and without it
//! every form is a NOP. So a claimed form changes no register and no flag;
//! the fallback branch at the branch point does the branch. A zero boff,
//! hw2[0] clear, hw2[15:12] other than 1100 or 1110, a register form with
//! hw2 other than 0xE001, hw1[11] set and the 16-bit space are unclaimed.
const vector = @import("../../vector.zig");

/// The state before every run; a claimed form must leave all of it alone.
pub const pc_in: u32 = 0x2000_0100;
pub const lr_in: u32 = 0x1000_000E;
pub const r3_in: u32 = 0x2000_0241;
/// Thumb with N and C set.
pub const xpsr_in: u32 = 0x0100_0000 | 0xA000_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
};

/// Whether the group claims the encoding, and PC, LR, R3 and xPSR after.
pub const Out = struct {
    claimed: bool = true,
    pc: u32 = pc_in,
    lr: u32 = lr_in,
    r3: u32 = r3_in,
    xpsr: u32 = xpsr_in,
};

const V = vector.Vector(In, Out);
const group = "branch_future";
const none: Out = .{ .claimed = false, .pc = 0, .lr = 0, .r3 = 0, .xpsr = 0 };

fn nop(name: []const u8, hw1: u16, hw2: u16) V {
    return .{ .encoding = group, .name = name, .input = .{ .hw1 = hw1, .hw2 = hw2 }, .expect = .{} };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return .{ .encoding = group, .name = name, .input = .{ .hw1 = hw1, .hw2 = hw2 }, .expect = none };
}

pub const all = claimed ++ unclaimed;

const claimed = [_]V{
    nop("bf with boff 1 changes nothing", 0xF080, 0xE001),
    nop("bf with boff 15 changes nothing", 0xF780, 0xE001),
    nop("bf with a far label changes nothing", 0xF09F, 0xEFFF),
    nop("bf with hw1[5] set changes nothing", 0xF0A0, 0xE003),
    nop("bfl keeps lr", 0xF080, 0xC001),
    nop("bfl with every label bit set keeps lr", 0xF7FF, 0xCFFF),
    nop("bfcsel changes nothing", 0xF0C0, 0xE001),
    nop("bfcsel with a condition and else offset changes nothing", 0xF0DE, 0xEF05),
    nop("bfx r3 keeps r3", 0xF0E3, 0xE001),
    nop("bflx r3 keeps lr", 0xF0F3, 0xE001),
    nop("bfx with boff 15 changes nothing", 0xF7E3, 0xE001),
};

const unclaimed = [_]V{
    bad("bf with boff 0 is unclaimed", 0xF000, 0xE001),
    bad("bfl with boff 0 is unclaimed", 0xF000, 0xC001),
    bad("hw2[0] clear is unclaimed", 0xF080, 0xE000),
    bad("bfl with hw2[0] clear is unclaimed", 0xF080, 0xC000),
    bad("hw2[15:12] = 1111 (bl) is unclaimed", 0xF080, 0xF001),
    bad("hw2[15:12] = 1000 (b<c>.w) is unclaimed", 0xF080, 0x8001),
    bad("hw2[15:12] = 1101 is unclaimed", 0xF080, 0xD001),
    bad("a register form with hw2 0xE003 is unclaimed", 0xF0E3, 0xE003),
    bad("a register form with hw2 0xE801 is unclaimed", 0xF0E3, 0xE801),
    bad("hw1[11] set is unclaimed", 0xF880, 0xE001),
    .{ .encoding = group, .name = "the 16-bit space is unclaimed", .input = .{ .hw1 = 0xF080, .hw2 = 0xE001, .size = 2 }, .expect = none },
};

pub const covered = vector.encodingsOf(In, Out, &all);
