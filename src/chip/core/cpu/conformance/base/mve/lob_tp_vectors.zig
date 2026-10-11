//! Conformance vectors for the decode group `mve_lob_tp` (RA8EMU-278):
//! DLSTP, WLSTP, LETP and LCTP. Expected values are worked from the Arm ARM
//! (DDI0553) pseudocode. DLSTP sets LR to Rn and LTPSIZE to the element
//! size; WLSTP does the same unless Rn is zero, when it branches forward
//! and leaves both alone. LETP takes one vector of elements
//! (1 << (4 - LTPSIZE)) off LR and branches back while more than that
//! remained, and otherwise falls through with LTPSIZE back to 4. LCTP sets
//! LTPSIZE to 4. The instruction sits at 0x100, so falling through is
//! 0x104. Rn of SP, the plain DLS/WLS/LE encodings, a clear branch bit and
//! the 16-bit space are left unclaimed.
const vector = @import("../../vector.zig");

pub const In = struct {
    hw1: u16,
    hw2: u16 = 0xE001,
    size: u8 = 4,
    /// The value put in Rn (hw1[3:0]) when it is a general register.
    rn: u32 = 0,
    lr: u32 = 0xAAAA_AAAA,
    ltpsize: u3 = 4,
};

pub const Out = struct {
    claimed: bool = true,
    pc: u32 = 0x104,
    lr: u32 = 0xAAAA_AAAA,
    ltpsize: u3 = 4,
};

const V = vector.Vector(In, Out);
const group = "mve_lob_tp";
pub const none: Out = .{ .claimed = false, .pc = 0, .lr = 0, .ltpsize = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

pub const all = setup ++ letp ++ unclaimed;

const setup = [_]V{
    vec("dlstp.8 lr, r0", .{ .hw1 = 0xF000, .rn = 100 }, .{ .lr = 100, .ltpsize = 0 }),
    vec("dlstp.32 lr, r3", .{ .hw1 = 0xF023, .rn = 7 }, .{ .lr = 7, .ltpsize = 2 }),
    vec("dlstp.64 lr, r12 enters even at zero", .{ .hw1 = 0xF03C, .rn = 0 }, .{ .lr = 0, .ltpsize = 3 }),
    vec("wlstp.16 lr, r1 enters", .{ .hw1 = 0xF011, .hw2 = 0xC011, .rn = 9 }, .{ .lr = 9, .ltpsize = 1 }),
    vec("wlstp.16 lr, r1 at zero skips the loop", .{ .hw1 = 0xF011, .hw2 = 0xC011, .rn = 0 }, .{ .pc = 0x124 }),
    vec("wlstp takes hw2[11] as the low halfword", .{ .hw1 = 0xF011, .hw2 = 0xC801, .rn = 0 }, .{ .pc = 0x106 }),
    vec("wlstp at its longest distance", .{ .hw1 = 0xF011, .hw2 = 0xCFFF, .rn = 0 }, .{ .pc = 0x1102 }),
    vec("lctp clears ltpsize", .{ .hw1 = 0xF00F, .ltpsize = 2 }, .{}),
};

const letp = [_]V{
    vec("letp.32 takes four and loops", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 20, .ltpsize = 2 }, .{ .pc = 0xE4, .lr = 16, .ltpsize = 2 }),
    vec("letp.32 with four left exits", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 4, .ltpsize = 2 }, .{ .lr = 4 }),
    vec("letp.32 with nothing left exits", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 0, .ltpsize = 2 }, .{ .lr = 0 }),
    vec("letp.8 takes sixteen", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 17, .ltpsize = 0 }, .{ .pc = 0xE4, .lr = 1, .ltpsize = 0 }),
    vec("letp.64 takes two", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 3, .ltpsize = 3 }, .{ .pc = 0xE4, .lr = 1, .ltpsize = 3 }),
    vec("letp with ltpsize 4 takes one", .{ .hw1 = 0xF01F, .hw2 = 0xC011, .lr = 5 }, .{ .pc = 0xE4, .lr = 4 }),
    vec("letp at its longest distance", .{ .hw1 = 0xF01F, .hw2 = 0xCFFF, .lr = 9, .ltpsize = 2 }, .{ .pc = 0xFFFF_F106, .lr = 5, .ltpsize = 2 }),
};

const unclaimed = [_]V{
    vec("dlstp with rn = sp is unclaimed", .{ .hw1 = 0xF00D }, none),
    vec("wlstp with rn = sp is unclaimed", .{ .hw1 = 0xF01D, .hw2 = 0xC011 }, none),
    vec("dlstp.16 with rn = pc is unclaimed", .{ .hw1 = 0xF01F }, none),
    vec("dlstp with hw2[0] clear is unclaimed", .{ .hw1 = 0xF000, .hw2 = 0xE000 }, none),
    vec("wlstp with hw2[0] clear is unclaimed", .{ .hw1 = 0xF011, .hw2 = 0xC010 }, none),
    vec("letp with hw2[0] clear is unclaimed", .{ .hw1 = 0xF01F, .hw2 = 0xC010 }, none),
    vec("lctp with hw2[0] clear is unclaimed", .{ .hw1 = 0xF00F, .hw2 = 0xE000 }, none),
    vec("dls is lob's", .{ .hw1 = 0xF040 }, none),
    vec("wls is lob's", .{ .hw1 = 0xF040, .hw2 = 0xC011 }, none),
    vec("le is lob's", .{ .hw1 = 0xF00F, .hw2 = 0xC011 }, none),
    vec("vctp is not a loop", .{ .hw1 = 0xF000, .hw2 = 0xE801 }, none),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF000, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
