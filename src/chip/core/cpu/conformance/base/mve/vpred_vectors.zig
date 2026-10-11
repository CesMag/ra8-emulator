//! Conformance vectors for the decode group `mve_vpred` (RA8EMU-278):
//! VPNOT and VPSEL. Expected values follow the Arm ARM (DDI0553) and, where
//! it leaves the predicated write open, QEMU's helpers as the file under
//! test documents: VPNOT writes NOT P0 on the bytes the predicate in force
//! enables (VPT P0, the loop tail) and clears the rest of the beats it
//! runs; VPSEL takes each byte from Qn where raw P0 is set and from Qm
//! where it is clear. Beats EPSR.ECI says already ran keep their old
//! value, and the VPT block then advances. Q registers start as
//! S[4n..4n+3] with Si = 0x5A00_0001 + i * 0x0101; `q` is Qd (hw2[15:13]).
//! D, N or M set, hw2[0] clear, VPST's encodings and the 16-bit space are
//! left unclaimed.
const vector = @import("../../vector.zig");

pub fn bankAt(i: u5) u32 {
    return 0x5A00_0001 + @as(u32, i) * 0x0101;
}

pub fn qAt(n: u3) u128 {
    var q: u128 = 0;
    var k: u5 = 4;
    while (k > 0) : (k -= 1) q = q << 32 | bankAt(@as(u5, n) * 4 + (k - 1));
    return q;
}

pub const In = struct {
    hw1: u16 = 0xFE31,
    hw2: u16 = 0x0F4D,
    size: u8 = 4,
    vpr: u32 = 0,
    it: u8 = 0,
    ltpsize: u3 = 4,
    lr: u32 = 0,
};

pub const Out = struct {
    claimed: bool = true,
    q: u128 = qAt(0),
    vpr: u32,
    it: u8 = 0,
};

const V = vector.Vector(In, Out);
const group = "mve_vpred";
pub const none: Out = .{ .claimed = false, .q = 0, .vpr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = vpnot ++ vpsel ++ unclaimed;

const vpnot = [_]V{
    vec("vpnot inverts p0", .{ .vpr = 0x0000_00FF }, .{ .vpr = 0x0000_FF00 }),
    vec("vpnot of zero sets every byte", .{}, .{ .vpr = 0x0000_FFFF }),
    vec("vpnot in a 1000 block clears the off bytes and ends it", .{ .vpr = 0x0088_0F0F }, .{ .vpr = 0 }),
    vec("vpnot in a 1100 block then inverts for the else", .{ .vpr = 0x00CC_00FF }, .{ .vpr = 0x0088_FFFF }),
    vec("vpnot under the loop tail", .{ .ltpsize = 0, .lr = 4 }, .{ .vpr = 0x0000_000F }),
    vec("vpnot with eci a0a1 keeps the done beats", .{ .it = 0x20 }, .{ .vpr = 0x0000_FF00 }),
};

const vpsel = [_]V{
    vec("vpsel q0, q1, q2 by halves", .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .vpr = 0x0000_00FF }, .{ .q = 0x5A000B0C_5A000A0B_5A000506_5A000405, .vpr = 0x0000_00FF }),
    vec("vpsel with p0 all set takes qn", .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .vpr = 0x0000_FFFF }, .{ .q = qAt(1), .vpr = 0x0000_FFFF }),
    vec("vpsel with p0 clear takes qm", .{ .hw1 = 0xFE33, .hw2 = 0x0F05 }, .{ .q = qAt(2), .vpr = 0 }),
    vec("vpsel picks byte by byte", .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .vpr = 0x0000_5555 }, .{ .q = 0x5A000B08_5A000A07_5A000906_5A000805, .vpr = 0x0000_5555 }),
    vec("vpsel q7, q0, q7", .{ .hw1 = 0xFE31, .hw2 = 0xEF0F, .vpr = 0x0000_FF00 }, .{ .q = 0x5A000304_5A000203_5A001D1E_5A001C1D, .vpr = 0x0000_FF00 }),
    vec("vpsel in a block reads raw p0 and ends it", .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .vpr = 0x0088_00FF }, .{ .q = 0x5A000B0C_5A000A0B_5A000506_5A000405, .vpr = 0x0000_00FF }),
    vec("vpsel with eci a0a1 keeps the done beats", .{ .hw1 = 0xFE33, .hw2 = 0x0F05, .vpr = 0x0000_FFFF, .it = 0x20 }, .{ .q = 0x5A000708_5A000607_5A000102_5A000001, .vpr = 0x0000_FFFF }),
};

const unclaimed = [_]V{
    vec("vpsel with d set is unclaimed", .{ .hw1 = 0xFE73, .hw2 = 0x0F05 }, none),
    vec("vpsel with n set is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0F85 }, none),
    vec("vpsel with m set is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0F25 }, none),
    vec("vpsel with hw2[0] clear is unclaimed", .{ .hw1 = 0xFE33, .hw2 = 0x0F04 }, none),
    vec("vpst mask 1000 is not vpred's", .{ .hw1 = 0xFE71, .hw2 = 0x0F4D }, none),
    vec("vpst mask 0001 is not vpred's", .{ .hw2 = 0x2F4D }, none),
    vec("the 16-bit space is unclaimed", .{ .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
