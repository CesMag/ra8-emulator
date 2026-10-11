//! Conformance vectors for the decode group `mve.vldr` (RA8EMU-278): the
//! contiguous VLDRB.8, VLDRH.16, VLDRW.32 and their stores. Expected values
//! are worked from the Arm ARM (DDI0553) pseudocode: offset = imm7 << size,
//! offset_addr = Rn +/- offset, address = P ? offset_addr : Rn, and Rn =
//! offset_addr when W. Elements go lowest first, each a MemA access that
//! faults (unaligned, or unmapped outside the RAM) before it reaches memory:
//! a faulting load leaves Qd, Rn and VPR alone, and a faulting store keeps
//! what it already wrote. An element is active when its first byte is
//! (VPT, the loop tail, EPSR.ECI); a load zeroes inactive elements, keeps
//! the beats ECI says already ran, and a store skips inactive elements.
//! Rn is written back after every access is done. The RAM window at
//! 0x2000_0200 starts as `fill`. P and W both clear, a PC base, an SP base
//! with writeback, size 11, Q8 and above, flipped fixed bits and the 16-bit
//! space are unclaimed.
const vector = @import("../../../vector.zig");

pub const Fault = enum { none, unaligned, unmapped, other };

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    base: u32,
    qd: u128 = 0,
    vpr: u32 = 0,
    it: u8 = 0,
    lr: u32 = 0,
    fpscr: u32 = 0x0004_0000,
};

pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    qd: u128,
    rn: u32,
    mem: [4]u128 = .{ 0, 0, 0, 0 },
    vpr: u32 = 0,
};

/// Where the observed RAM window starts, and what each of its 64 bytes holds
/// before a vector runs.
pub const window: u32 = 0x2000_0200;
pub fn fill(i: usize) u8 {
    return @truncate(i *% 0x1D +% 0x47);
}

const V = vector.Vector(In, Out);
const group = "mve_vldr";
pub const none: Out = .{ .claimed = false, .qd = 0, .rn = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vldrb.8 pre offset add", .{ .hw1 = 0xED91, .hw2 = 0x5E03, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x513417FA_DDC0A386_694C2F12_F5D8BB9E, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.8 post index with writeback", .{ .hw1 = 0xECB1, .hw2 = 0x5E7F, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0xCAAD9073_56391CFF_E2C5A88B_6E513417, .rn = 0x2000028F, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.8 at an odd address needs no alignment", .{ .hw1 = 0xED93, .hw2 = 0x5E00, .base = 0x20000221, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0xB79A7D60_432609EC_CFB29578_5B3E2104, .rn = 0x20000221, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.16 pre index subtract with writeback", .{ .hw1 = 0xED31, .hw2 = 0x5E84, .base = 0x20000230, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x8265482B_0EF1D4B7_9A7D6043_2609ECCF, .rn = 0x20000228, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.16 imm 0", .{ .hw1 = 0xED94, .hw2 = 0x5E80, .base = 0x20000202, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x3417FADD_C0A38669_4C2F12F5_D8BB9E81, .rn = 0x20000202, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrw.32 post index with writeback", .{ .hw1 = 0xECB1, .hw2 = 0x5F02, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x9A7D6043_2609ECCF_B295785B_3E2104E7, .rn = 0x20000228, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrw.32 from sp without writeback", .{ .hw1 = 0xED9D, .hw2 = 0x5F01, .base = 0x20000224, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x8265482B_0EF1D4B7_9A7D6043_2609ECCF, .rn = 0x20000224, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrw.32 into q7 from r12", .{ .hw1 = 0xED1C, .hw2 = 0xFF03, .base = 0x20000230, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x0EF1D4B7_9A7D6043_2609ECCF_B295785B, .rn = 0x20000230, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrw.32 with a subtract that wraps faults unmapped and changes nothing", .{ .hw1 = 0xED31, .hw2 = 0x5F03, .base = 0x00000004, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .fault = .unmapped, .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x00000004, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrw.32 at a halfword address faults unaligned and changes nothing", .{ .hw1 = 0xEDB1, .hw2 = 0x5F00, .base = 0x20000202, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .fault = .unaligned, .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000202, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.16 at an odd address faults unaligned", .{ .hw1 = 0xECB1, .hw2 = 0x5E81, .base = 0x20000201, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .fault = .unaligned, .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000201, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.8 pre index subtract", .{ .hw1 = 0xED01, .hw2 = 0x5E10, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000220, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0x11112222_33334444_55556666_77778888, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrh.16 pre offset add", .{ .hw1 = 0xED81, .hw2 = 0x5E81, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000200, .mem = .{ 0x22223333_44445555_66667777_88886447, 0xCAAD9073_56391CFF_E2C5A88B_6E511111, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrw.32 pre index subtract with writeback", .{ .hw1 = 0xED21, .hw2 = 0x5F02, .base = 0x20000238, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000230, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x11112222_33334444_55556666_77778888 }, .vpr = 0x00000000 }),
    vec("vstrw.32 post index add with writeback", .{ .hw1 = 0xECA5, .hw2 = 0x5F7F, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x2000040C, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0x11112222_33334444_55556666_77778888, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrw.32 at a byte address faults unaligned and writes nothing", .{ .hw1 = 0xED81, .hw2 = 0x5F00, .base = 0x20000203, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .fault = .unaligned, .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000203, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.8 from q7 through sp", .{ .hw1 = 0xED8D, .hw2 = 0xFE08, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000200, .mem = .{ 0x55556666_77778888_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_11112222_33334444, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps word lanes 2 and 3 and zeroes the rest", .{ .hw1 = 0xED91, .hw2 = 0x5F00, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x0088FF00 }, .{ .qd = 0xFADDC0A3_86694C2F_00000000_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000FF00 }),
    vec("every other byte predicated on vldrb zeroes the rest", .{ .hw1 = 0xED91, .hw2 = 0x5E00, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x00885555 }, .{ .qd = 0x00AD0073_003900FF_00C5008B_00510017, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00005555 }),
    vec("a word predicated past its first byte is not loaded", .{ .hw1 = 0xED91, .hw2 = 0x5F00, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x0088FEFE }, .{ .qd = 0xFADDC0A3_00000000_12F5D8BB_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000FEFE }),
    vec("every lane predicated off reaches no memory, so a misaligned base cannot fault", .{ .hw1 = 0xEDB1, .hw2 = 0x5F00, .base = 0x20000202, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x00880000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .rn = 0x20000202, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrh with half lanes 0, 2, 4 and 6 predicated", .{ .hw1 = 0xED81, .hw2 = 0x5E80, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x00883333 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000220, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D2222_26094444_B2956666_3E218888, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00003333 }),
    vec("vstrw with lanes 0 and 3 predicated, writeback still happens", .{ .hw1 = 0xECA1, .hw2 = 0x5F04, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888, .vpr = 0x0088F00F }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000220, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0x11112222_56391CFF_E2C5A88B_77778888, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000F00F }),
    vec("the loop tail on halfword loads stops after lane 2", .{ .hw1 = 0xED91, .hw2 = 0x5E80, .base = 0x20000210, .qd = 0x11112222_33334444_55556666_77778888, .lr = 3, .fpscr = 0x00010000 }, .{ .qd = 0x00000000_00000000_0000A88B_6E513417, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("the loop tail on byte stores stops after lane 4", .{ .hw1 = 0xED81, .hw2 = 0x5E00, .base = 0x20000230, .qd = 0x11112222_33334444_55556666_77778888, .lr = 5, .fpscr = 0x00000000 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000230, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_82654866_77778888 }, .vpr = 0x00000000 }),
    vec("eci a0a1 keeps the done beats of qd on a load", .{ .hw1 = 0xECB1, .hw2 = 0x5F04, .base = 0x20000220, .qd = 0x11112222_33334444_55556666_77778888, .it = 0x20 }, .{ .qd = 0x9A7D6043_2609ECCF_55556666_77778888, .rn = 0x20000230, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("eci a0a1a2 stores only beat 3", .{ .hw1 = 0xED81, .hw2 = 0x5E80, .base = 0x20000200, .qd = 0x11112222_33334444_55556666_77778888, .it = 0x40 }, .{ .qd = 0x11112222_33334444_55556666_77778888, .rn = 0x20000200, .mem = .{ 0x11112222_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("p and w both clear is another encoding", .{ .hw1 = 0xEC91, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("a pc base is unclaimed", .{ .hw1 = 0xED9F, .hw2 = 0x5E80, .base = 0x00000000 }, none),
    vec("an sp base with writeback is unclaimed", .{ .hw1 = 0xEDBD, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("size 11 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5F80, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEDD1, .hw2 = 0x5E80, .base = 0x20000200 }, none),
    vec("hw2 bit 12 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4E80, .base = 0x20000200 }, none),
    vec("hw2 bit 9 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5C80, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5E80, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
