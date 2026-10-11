//! Conformance vectors for the decode group `mve_gather64` (RA8EMU-278):
//! the 64-bit gather VLDRD.U64 and scatter VSTRD.64 [Rn, Qm{, uxtw #3}].
//! Expected values are worked from the Arm ARM (DDI0553) pseudocode: each
//! doubleword moves as two word beats, the low word of its Qm doubleword
//! (scaled by 8 under uxtw #3) offsets Rn, the high beat sits four bytes
//! above, and only the low 32 bits of the offset reach the address. Each
//! beat is a word MemA access that faults (unaligned, or unmapped outside
//! the RAM) before reaching memory: a faulting load leaves Qd and VPR
//! alone, and a faulting scatter keeps what it already wrote. Each beat
//! runs under its own predicate bit (VPT, the loop tail, EPSR.ECI); a load
//! zeroes inactive beats and keeps the ones ECI says already ran, a store
//! skips them, and an inactive beat never faults. Rn is never written. The
//! RAM window at 0x2000_0200 starts as `fill`. A load whose Qd is Qm, a PC
//! base, a load with U clear, a store with U set, Q8 and above, flipped
//! fixed bits and the 16-bit space are unclaimed.
const vector = @import("../../vector.zig");

pub const Fault = enum { none, unaligned, unmapped, other };

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    base: u32,
    qd: u128 = 0,
    qm: u128 = 0,
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
const group = "mve_gather64";
pub const none: Out = .{ .claimed = false, .qd = 0, .rn = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = forms ++ predicated ++ unclaimed;

const forms = [_]V{
    vec("vldrd.u64 unscaled gathers two doublewords", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018 }, .{ .qd = 0xFADDC0A3_86694C2F_CAAD9073_56391CFF, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 ignores the odd word of each offset", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0xFFFFFFFF_00000010_0000DEAD_00000030 }, .{ .qd = 0xE2C5A88B_6E513417_8265482B_0EF1D4B7, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 uxtw #3 scales each offset by 8", .{ .hw1 = 0xFC94, .hw2 = 0x4FD7, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000002_00000000_00000007 }, .{ .qd = 0xE2C5A88B_6E513417_6A4D3013_F6D9BC9F, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 from an sp base into q7, offsets in q0", .{ .hw1 = 0xFC9D, .hw2 = 0xEFD0, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000000_00000000_00000020 }, .{ .qd = 0xE2C5A88B_6E513417_8265482B_0EF1D4B7, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 at a word-aligned offset is allowed", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_0000002C_00000000_00000004 }, .{ .qd = 0x0EF1D4B7_9A7D6043_86694C2F_12F5D8BB, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 at an odd offset faults unaligned and changes nothing", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_0000000A_00000000_00000000 }, .{ .fault = .unaligned, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 whose odd beat runs past the window faults unmapped", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_3FFFFDFC_00000000_00000000 }, .{ .fault = .unmapped, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vldrd.u64 uxtw #3 offset that wraps past 4 GiB", .{ .hw1 = 0xFC91, .hw2 = 0x4FD7, .base = 0x20000210, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_1FFFFFFF_00000000_20000000 }, .{ .qd = 0xFADDC0A3_86694C2F_E2C5A88B_6E513417, .rn = 0x20000210, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrd.64 unscaled scatters two doublewords", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000000_00000000_00000028 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_8899AABB_CCDDEEFF, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x11223344_55667788_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrd.64 uxtw #3", .{ .hw1 = 0xEC82, .hw2 = 0x4FD7, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000006_00000000_00000001 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0x11223344_55667788_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8899AABB_CCDDEEFF }, .vpr = 0x00000000 }),
    vec("vstrd.64 faults on the second doubleword and keeps the first", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000022_00000000_00000010 }, .{ .fault = .unaligned, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_11223344_55667788, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrd.64 with qd equal to qm stores its own offsets", .{ .hw1 = 0xEC81, .hw2 = 0xAFDA, .base = 0x20000200, .qd = 0x00000022_00000030_00000011_00000018 }, .{ .qd = 0x00000000_00000000_00000000_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_00000000_00000000, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("vstrd.64 the second doubleword overwrites the first", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000008 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0x8899AABB_CCDDEEFF_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const predicated = [_]V{
    vec("vpt mask keeps only the upper doubleword of a gather", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018, .vpr = 0x0088FF00 }, .{ .qd = 0xFADDC0A3_86694C2F_00000000_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000FF00 }),
    vec("a doubleword with only its low beat predicated loads one word", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018, .vpr = 0x00880F0F }, .{ .qd = 0x00000000_86694C2F_00000000_56391CFF, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000F0F }),
    vec("a doubleword with only its high beat predicated loads one word", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018, .vpr = 0x0088F0F0 }, .{ .qd = 0xFADDC0A3_00000000_CAAD9073_00000000, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x0000F0F0 }),
    vec("an inactive doubleword with a misaligned offset cannot fault", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_0000000A_00000000_00000018, .vpr = 0x008800FF }, .{ .qd = 0x00000000_00000000_CAAD9073_56391CFF, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x000000FF }),
    vec("a scatter with the low beat of each doubleword predicated", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000028, .vpr = 0x00880F0F }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_CCDDEEFF_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_55667788_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000F0F }),
    vec("the loop tail on vldrd at ltpsize 3 stops after the first doubleword", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018, .lr = 1, .fpscr = 0x00030000 }, .{ .qd = 0x00000000_00000000_CAAD9073_56391CFF, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("the loop tail on vstrd at ltpsize 2 stops after beat 2", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000028, .lr = 3, .fpscr = 0x00020000 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_CCDDEEFF_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x11223344_55667788_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("eci a0a1 keeps the first doubleword of qd", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000018, .it = 0x20 }, .{ .qd = 0xFADDC0A3_86694C2F_11223344_55667788, .rn = 0x20000200, .mem = .{ 0xFADDC0A3_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
    vec("eci a0a1a2 scatters only beat 3", .{ .hw1 = 0xEC81, .hw2 = 0x4FD6, .base = 0x20000200, .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .qm = 0x00000000_00000008_00000000_00000028, .it = 0x40 }, .{ .qd = 0x8899AABB_CCDDEEFF_11223344_55667788, .rn = 0x20000200, .mem = .{ 0x8899AABB_86694C2F_12F5D8BB_9E816447, 0xCAAD9073_56391CFF_E2C5A88B_6E513417, 0x9A7D6043_2609ECCF_B295785B_3E2104E7, 0x6A4D3013_F6D9BC9F_8265482B_0EF1D4B7 }, .vpr = 0x00000000 }),
};

const unclaimed = [_]V{
    vec("a load whose qd is qm is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FD4, .base = 0x20000200 }, none),
    vec("a pc base is unclaimed", .{ .hw1 = 0xFC9F, .hw2 = 0x4FD6, .base = 0x00000000 }, none),
    vec("a load with u clear has no signed form", .{ .hw1 = 0xEC91, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("a store with u set is unclaimed", .{ .hw1 = 0xFC81, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("d set would name q8 and is unclaimed", .{ .hw1 = 0xFCD1, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("m set would name q8 and is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FF6, .base = 0x20000200 }, none),
    vec("hw1 bit 5 set is unclaimed", .{ .hw1 = 0xFCB1, .hw2 = 0x4FD6, .base = 0x20000200 }, none),
    vec("hw2 bit 12 set is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x5FD6, .base = 0x20000200 }, none),
    vec("hw2 bit 4 clear is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FC6, .base = 0x20000200 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xFC91, .hw2 = 0x4FD6, .base = 0x20000200, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
