//! Conformance vectors for the decode group `mve_vldr_wide` (RA8EMU-278):
//! the widening VLDRB.S16/U16/S32/U32 and VLDRH.S32/U32 and the narrowing
//! VSTRB.16/32 and VSTRH.32. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode: offset = imm7 scaled by the memory size,
//! offset_addr = Rn +/- offset, address = P ? offset_addr : Rn, and Rn =
//! offset_addr when W; element e sits at address + e * the memory size. A
//! load sign- or zero-extends the memory value to the element, a store
//! writes the element's low bytes. Each access is a MemA access that faults
//! (unaligned, or unmapped outside the RAM) before it reaches memory: a
//! faulting load leaves Qd, Rn and VPR alone. An element is active when its
//! first byte is (VPT, the loop tail, EPSR.ECI); a load zeroes inactive
//! elements and keeps the beats ECI says already ran, a store skips them.
//! The RAM window at 0x2000_0200 starts as `fill`. P and W both clear, a
//! store with U set, H with a halfword element, element sizes 00 and 11,
//! Q8 and above, flipped fixed bits and the 16-bit space are unclaimed.
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
const group = "mve_vldr_wide";
pub const none: Out = .{ .claimed = false, .qd = 0, .rn = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vldrb.s16 pre offset add sign-extends", .{ .hw1 = 0xED91, .hw2 = 0x4E83, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x0069004C_002F0012_FFF5FFD8_FFBBFF9E, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.u16 post index with writeback zero-extends", .{ .hw1 = 0xFCB1, .hw2 = 0x4EFF, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x00E200C5_00A8008B_006E0051_00340017, .rn = 0x2000028F, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.s32 pre index subtract with writeback", .{ .hw1 = 0xED32, .hw2 = 0x4F04, .base = 0x20000228, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0xFFFFFFB2_FFFFFF95_00000078_0000005B, .rn = 0x20000224, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.u32 at an odd address needs no alignment", .{ .hw1 = 0xFD93, .hw2 = 0x4F00, .base = 0x20000233, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x00000065_00000048_0000002B_0000000E, .rn = 0x20000233, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.s32 pre offset add sign-extends", .{ .hw1 = 0xED9C, .hw2 = 0x4F02, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0xFFFF8669_00004C2F_000012F5_FFFFD8BB, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.u32 post index subtract with writeback", .{ .hw1 = 0xFC3D, .hw2 = 0x4F10, .base = 0x20000230, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x00008265_0000482B_00000EF1_0000D4B7, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.s32 into q7 from r7", .{ .hw1 = 0xED9F, .hw2 = 0xEF00, .base = 0x20000218, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0xFFFFCAAD_FFFF9073_00005639_00001CFF, .rn = 0x20000218, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrh.s32 at an odd address faults unaligned and changes nothing", .{ .hw1 = 0xEDB9, .hw2 = 0x4F00, .base = 0x20000201, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .fault = .unaligned, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000201, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrb.s16 with a subtract that wraps faults unmapped", .{ .hw1 = 0xED31, .hw2 = 0x4E88, .base = 0x00000004, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .fault = .unmapped, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x00000004, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.16 pre offset add keeps the low byte of each half", .{ .hw1 = 0xED81, .hw2 = 0x4E81, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C99_BBDDFF22_44668847, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.32 pre index subtract with writeback", .{ .hw1 = 0xED22, .hw2 = 0x4F08, .base = 0x20000230, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000228, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_BBFF4488_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrh.32 post index add with writeback keeps the low half of each word", .{ .hw1 = 0xECAE, .hw2 = 0x4F7F, .base = 0x20000220, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x2000031E, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_AABBEEFF_33447788, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrh.32 at an odd address faults unaligned and writes nothing", .{ .hw1 = 0xED89, .hw2 = 0x4F00, .base = 0x20000203, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .fault = .unaligned, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000203, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.32 from q7 through r0", .{ .hw1 = 0xED80, .hw2 = 0xEF14, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_BBFF4488_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps word lanes 2 and 3 of vldrh.s32", .{ .hw1 = 0xED99, .hw2 = 0x4F00, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x0088FF00 }, .{ .qd = 0x000012F5_FFFFD8BB_00000000_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000FF00 }),
    vec("every other half lane of vldrb.u16 predicated", .{ .hw1 = 0xFD91, .hw2 = 0x4E80, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x00883333 }, .{ .qd = 0x000000C5_0000008B_00000051_00000017, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00003333 }),
    vec("a half predicated past its first byte is not loaded", .{ .hw1 = 0xED91, .hw2 = 0x4E80, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x0088AAAA }, .{ .qd = 0x00000000_00000000_00000000_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000AAAA }),
    vec("every lane off reaches no memory, so a misaligned base cannot fault", .{ .hw1 = 0xEDB9, .hw2 = 0x4F00, .base = 0x20000201, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x00880000 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .rn = 0x20000201, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrb.16 with half lanes 0, 2, 4 and 6 predicated", .{ .hw1 = 0xED81, .hw2 = 0x4E80, .base = 0x20000220, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x00883333 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000220, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B2BB78FF_3E440488, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00003333 }),
    vec("vstrh.32 with lanes 0 and 3 predicated, writeback still happens", .{ .hw1 = 0xECA9, .hw2 = 0x4F04, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .vpr = 0x0088F00F }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000218, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_AABBA88B_6E517788, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000F00F }),
    vec("the loop tail on vldrb.s32 stops after lane 2", .{ .hw1 = 0xED91, .hw2 = 0x4F00, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .lr = 3, .fpscr = 0x00020000 }, .{ .qd = 0x00000000_00000051_00000034_00000017, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("the loop tail on vstrb.16 stops after lane 5", .{ .hw1 = 0xED81, .hw2 = 0x4E80, .base = 0x20000230, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .lr = 5, .fpscr = 0x00010000 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000230, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_826548FF_22446688 }, .vpr = 0x00000000 }),
    vec("eci a0a1 keeps the done beats of qd on vldrb.u16", .{ .hw1 = 0xFCB1, .hw2 = 0x4E84, .base = 0x20000220, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .it = 0x20 }, .{ .qd = 0x00B20095_0078005B_11223344_55667788, .rn = 0x20000224, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("eci a0a1a2 stores only beat 3 of vstrh.32", .{ .hw1 = 0xED89, .hw2 = 0x4F00, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .it = 0x40 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_AABBD8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("p and w both clear is another encoding", .{ .hw1 = 0xEC91, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("a store with u set is unclaimed", .{ .hw1 = 0xFD81, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("h with a halfword element is unclaimed", .{ .hw1 = 0xED99, .hw2 = 0x4E80, .base = 0x20000200 }, none),
    vec("element size 00 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4E00, .base = 0x20000200 }, none),
    vec("element size 11 is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4F80, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xEDD1, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("hw1 bit 9 clear is unclaimed", .{ .hw1 = 0xEB91, .hw2 = 0x4F00, .base = 0x20000200 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x5F00, .base = 0x20000200 }, none),
    vec("hw2 bit 9 clear is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4D00, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xED91, .hw2 = 0x4F00, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
