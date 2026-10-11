//! Conformance vectors for the decode group `ldm_stm_wide` (RA8EMU-278):
//! LDM (IA) T2, STM (IA) T2, LDMDB T1 and STMDB T1, with POP.W and PUSH.W.
//! Expected values are worked from the Arm ARM (DDI0553): the lowest
//! register goes at the lowest address, IA starts at Rn and DB at Rn minus
//! four per register, writeback leaves Rn past the block, a load of Rn
//! without writeback takes the loaded value, a store of Rn stores the
//! original base, and a load of the PC interworks. A misaligned base is
//! MemA and faults with nothing changed; a read past RAM faults with every
//! register kept. Rn = PC, fewer than two registers, SP in the list, the
//! PC in a store list, PC with LR on a load and writeback with Rn in the
//! list are UNPREDICTABLE and left unclaimed, as are neighbouring spaces
//! and the 16-bit encodings.
const std = @import("std");
const vector = @import("../../../vector.zig");

/// RAM is 1 KiB at `ram_base`. Each word in it reads `pattern(address)`;
/// R0 to R12 start as `fill + n`, LR as `fill + 14`, SP as `sp_in`, and Rn
/// as In.base.
pub const ram_base: u32 = 0x2000_0000;
pub const ram_end: u32 = 0x2000_0400;
pub const fill: u32 = 0x1000_0000;
pub const sp_in: u32 = 0x2000_0300;
pub const pc_in: u32 = 0x2000_0100;
const b: u32 = 0x2000_0200;

/// The word RAM holds at `address` before the run; zero outside RAM.
pub fn pattern(address: u32) u32 {
    if (address < ram_base or address >= ram_end) return 0;
    return 0xC000_0001 + (address & 0xFFFF);
}

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    base: u32 = b,
};

/// How the instruction ended.
pub const Fault = enum { none, unmapped, unaligned, other };

/// Whether the group claims the encoding, how it ended, R0 to R3, SP, LR,
/// PC and the Thumb bit after, and the five words from eight below to eight
/// above In.base (rounded down to a word).
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    r0: u32,
    r1: u32,
    r2: u32,
    r3: u32,
    sp: u32,
    lr: u32,
    pc: u32 = pc_in,
    thumb: bool = true,
    wm8: u32,
    wm4: u32,
    w0: u32,
    w4: u32,
    w8: u32,
};

const V = vector.Vector(In, Out);
const group = "ldm_stm_wide";
pub const none: Out = .{ .claimed = false, .r0 = 0, .r1 = 0, .r2 = 0, .r3 = 0, .sp = 0, .lr = 0, .pc = 0, .thumb = false, .wm8 = 0, .wm4 = 0, .w0 = 0, .w4 = 0, .w8 = 0 };

/// The state a run that changes nothing leaves, with `base` in Rn.
fn idle(rn: u4, base: u32) Out {
    const w = base & ~@as(u32, 3);
    var out: Out = .{
        .r0 = fill,
        .r1 = fill + 1,
        .r2 = fill + 2,
        .r3 = fill + 3,
        .sp = sp_in,
        .lr = fill + 14,
        .wm8 = pattern(w -% 8),
        .wm4 = pattern(w -% 4),
        .w0 = pattern(w),
        .w4 = pattern(w +% 4),
        .w8 = pattern(w +% 8),
    };
    switch (rn) {
        0 => out.r0 = base,
        1 => out.r1 = base,
        2 => out.r2 = base,
        3 => out.r3 = base,
        13 => out.sp = base,
        else => {},
    }
    return out;
}

/// A claimed vector: the idle state for its Rn and base, with `changes`.
fn based(name: []const u8, hw1: u16, hw2: u16, base: u32, changes: anytype) V {
    var out = idle(@intCast(hw1 & 0xF), base);
    inline for (std.meta.fieldNames(@TypeOf(changes))) |field| @field(out, field) = @field(changes, field);
    return .{ .encoding = group, .name = name, .input = .{ .hw1 = hw1, .hw2 = hw2, .base = base }, .expect = out };
}

fn v(name: []const u8, hw1: u16, hw2: u16, changes: anytype) V {
    return based(name, hw1, hw2, b, changes);
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return .{ .encoding = group, .name = name, .input = .{ .hw1 = hw1, .hw2 = hw2 }, .expect = none };
}

pub const all = loads ++ stores ++ unclaimed;

const loads = [_]V{
    v("ldm r0, {r1, r2}", 0xE890, 0x0006, .{ .r1 = 0xC000_0201, .r2 = 0xC000_0205 }),
    v("ldm r0!, {r1, r2}", 0xE8B0, 0x0006, .{ .r0 = b + 8, .r1 = 0xC000_0201, .r2 = 0xC000_0205 }),
    v("ldm r0, {r0, r1} loads the base", 0xE890, 0x0003, .{ .r0 = 0xC000_0201, .r1 = 0xC000_0205 }),
    v("ldm r0, {r1-r3}", 0xE890, 0x000E, .{ .r1 = 0xC000_0201, .r2 = 0xC000_0205, .r3 = 0xC000_0209 }),
    v("ldm r0!, {r1-r3}", 0xE8B0, 0x000E, .{ .r0 = b + 12, .r1 = 0xC000_0201, .r2 = 0xC000_0205, .r3 = 0xC000_0209 }),
    v("ldmdb r0, {r1, r2}", 0xE910, 0x0006, .{ .r1 = 0xC000_01F9, .r2 = 0xC000_01FD }),
    v("ldmdb r0!, {r1, r2}", 0xE930, 0x0006, .{ .r0 = b - 8, .r1 = 0xC000_01F9, .r2 = 0xC000_01FD }),
    v("ldmdb r0!, {r1-r3}", 0xE930, 0x000E, .{ .r0 = b - 12, .r1 = 0xC000_01F5, .r2 = 0xC000_01F9, .r3 = 0xC000_01FD }),
    v("ldm r0, {r1, lr}", 0xE890, 0x4002, .{ .r1 = 0xC000_0201, .lr = 0xC000_0205 }),
    v("ldm r0, {r1, pc} interworks", 0xE890, 0x8002, .{ .r1 = 0xC000_0201, .pc = 0xC000_0204 }),
    v("ldm r1!, {r2, r3}", 0xE8B1, 0x000C, .{ .r1 = b + 8, .r2 = 0xC000_0201, .r3 = 0xC000_0205 }),
    v("pop.w {r1, r2}", 0xE8BD, 0x0006, .{ .sp = b + 8, .r1 = 0xC000_0201, .r2 = 0xC000_0205 }),
    v("pop.w {r1, pc}", 0xE8BD, 0x8002, .{ .sp = b + 8, .r1 = 0xC000_0201, .pc = 0xC000_0204 }),
    v("pop.w {r0-r3}", 0xE8BD, 0x000F, .{ .sp = b + 16, .r0 = 0xC000_0201, .r1 = 0xC000_0205, .r2 = 0xC000_0209, .r3 = 0xC000_020D }),
    based("ldm at a halfword address faults", 0xE8B0, 0x0006, b + 2, .{ .fault = .unaligned }),
    based("ldm past RAM faults", 0xE8B0, 0x0006, ram_end, .{ .fault = .unmapped }),
    based("ldm running off RAM keeps every register", 0xE8B0, 0x0006, ram_end - 4, .{ .fault = .unmapped }),
};

const stores = [_]V{
    v("stm r0, {r1, r2}", 0xE880, 0x0006, .{ .w0 = fill + 1, .w4 = fill + 2 }),
    v("stm r0!, {r1, r2}", 0xE8A0, 0x0006, .{ .r0 = b + 8, .w0 = fill + 1, .w4 = fill + 2 }),
    v("stm r0, {r0, r1} stores the base", 0xE880, 0x0003, .{ .w0 = b, .w4 = fill + 1 }),
    v("stm r0, {r1-r3}", 0xE880, 0x000E, .{ .w0 = fill + 1, .w4 = fill + 2, .w8 = fill + 3 }),
    v("stmdb r0, {r1, r2}", 0xE900, 0x0006, .{ .wm8 = fill + 1, .wm4 = fill + 2 }),
    v("stmdb r0!, {r1-r3}", 0xE920, 0x000E, .{ .r0 = b - 12, .wm8 = fill + 2, .wm4 = fill + 3 }),
    v("stm r0, {r1, lr}", 0xE880, 0x4002, .{ .w0 = fill + 1, .w4 = fill + 14 }),
    v("push.w {r1, lr}", 0xE92D, 0x4002, .{ .sp = b - 8, .wm8 = fill + 1, .wm4 = fill + 14 }),
    v("push.w {r0-r3}", 0xE92D, 0x000F, .{ .sp = b - 16, .wm8 = fill + 2, .wm4 = fill + 3 }),
    based("stm at a halfword address faults and writes nothing", 0xE880, 0x0006, b + 2, .{ .fault = .unaligned }),
    based("stm past RAM faults", 0xE8A0, 0x0006, ram_end, .{ .fault = .unmapped }),
    based("stmdb below RAM faults before writing", 0xE900, 0x0006, ram_base + 4, .{ .fault = .unmapped }),
};

const unclaimed = [_]V{
    bad("rn = pc is unclaimed", 0xE89F, 0x0006),
    bad("one register is unclaimed", 0xE890, 0x0002),
    bad("an empty list is unclaimed", 0xE890, 0x0000),
    bad("sp in the list is unclaimed", 0xE890, 0x2002),
    bad("pc in a store list is unclaimed", 0xE880, 0x8002),
    bad("pc with lr on a load is unclaimed", 0xE890, 0xC002),
    bad("ldm r0! with r0 in the list is unclaimed", 0xE8B0, 0x0003),
    bad("stm r0! with r0 in the list is unclaimed", 0xE8A0, 0x0003),
    bad("pop.w of one register is unclaimed", 0xE8BD, 0x0002),
    bad("the acq_rel space is not ldm", 0xE8D0, 0x1FAF),
    bad("the ldmib space is unclaimed", 0xE990, 0x0006),
    .{ .encoding = group, .name = "the 16-bit space is unclaimed", .input = .{ .hw1 = 0xE890, .hw2 = 0x0006, .size = 2 }, .expect = none },
};

pub const covered = vector.encodingsOf(In, Out, &all);
