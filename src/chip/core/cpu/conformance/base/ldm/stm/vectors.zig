//! Conformance vectors for the decode group `ldm.stm` (RA8EMU-279): STM
//! Rn!, {list} and LDM Rn{!}, {list} (T1), increment after, over r0..r7.
//! Expected values are worked from the Arm ARM (DDI0553): registers go
//! lowest-numbered at the lowest address, STM always writes back, LDM
//! writes back only when Rn is not in the list (when it is, the loaded
//! value wins), and STM with Rn lowest in the list stores Rn's original
//! value. A base that is not word-aligned faults, as does one outside
//! memory, and nothing changes. An empty list is UNPREDICTABLE and left
//! unclaimed, as is STM with Rn in the list but not lowest.
const vector = @import("../../../vector.zig");

/// Where the four words of memory the vectors read and write sit.
pub const window: u32 = 0x2000_0200;

/// Before the instruction rN holds `reg_base + N`, then Rn (bits [10:8])
/// is set to `base`, and the four words at `window` hold `initial`.
pub const reg_base: u32 = 0x1000_0000;
pub const initial: [4]u32 = .{ 0xC000_0000, 0xC000_0001, 0xC000_0002, 0xC000_0003 };

pub const In = struct {
    hw1: u16,
    size: u8 = 2,
    base: u32 = window,
};

/// How the instruction ended.
pub const Fault = enum { none, unaligned, unmapped, other };

/// Whether the group claims the encoding, how it ended, r0..r7 and the four
/// words at `window` afterwards.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    low: [8]u32,
    mem: [4]u32 = initial,
};

const V = vector.Vector(In, Out);
const group = "ldm_stm";
const none: Out = .{ .claimed = false, .low = .{ 0, 0, 0, 0, 0, 0, 0, 0 }, .mem = .{ 0, 0, 0, 0 } };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn r(n: u32) u32 {
    return reg_base + n;
}

/// r0..r7 as the run leaves them: Rn at `rn_value`, the registers in
/// `changes` at their new values, the rest untouched.
fn low(rn: u3, rn_value: u32, changes: []const struct { u3, u32 }) [8]u32 {
    var out: [8]u32 = undefined;
    for (0..8) |i| out[i] = r(@intCast(i));
    out[rn] = rn_value;
    for (changes) |c| out[c[0]] = c[1];
    return out;
}

fn mem(words: [4]u32) [4]u32 {
    return words;
}

pub const all = [_]V{
    vec("stm r4!, {r0}", .{ .hw1 = 0xC401 }, .{ .low = low(4, window + 4, &.{}), .mem = mem(.{ r(0), initial[1], initial[2], initial[3] }) }),
    vec("stm r4!, {r0-r3}", .{ .hw1 = 0xC40F }, .{ .low = low(4, window + 16, &.{}), .mem = mem(.{ r(0), r(1), r(2), r(3) }) }),
    vec("stm r4!, {r1, r3} packs in register order", .{ .hw1 = 0xC40A }, .{ .low = low(4, window + 8, &.{}), .mem = mem(.{ r(1), r(3), initial[2], initial[3] }) }),
    vec("stm r4!, {r7}", .{ .hw1 = 0xC480 }, .{ .low = low(4, window + 4, &.{}), .mem = mem(.{ r(7), initial[1], initial[2], initial[3] }) }),
    vec("stm r0!, {r0, r1} stores rn's original value", .{ .hw1 = 0xC003 }, .{ .low = low(0, window + 8, &.{}), .mem = mem(.{ window, r(1), initial[2], initial[3] }) }),
    vec("ldm r4!, {r0}", .{ .hw1 = 0xCC01 }, .{ .low = low(4, window + 4, &.{.{ 0, initial[0] }}) }),
    vec("ldm r4!, {r0-r3}", .{ .hw1 = 0xCC0F }, .{ .low = low(4, window + 16, &.{ .{ 0, initial[0] }, .{ 1, initial[1] }, .{ 2, initial[2] }, .{ 3, initial[3] } }) }),
    vec("ldm r4!, {r2, r5} fills in register order", .{ .hw1 = 0xCC24 }, .{ .low = low(4, window + 8, &.{ .{ 2, initial[0] }, .{ 5, initial[1] } }) }),
    vec("ldm r0!, {r1-r3} with rn r0", .{ .hw1 = 0xC80E }, .{ .low = low(0, window + 12, &.{ .{ 1, initial[0] }, .{ 2, initial[1] }, .{ 3, initial[2] } }) }),
    vec("ldm r4, {r4} loads rn with no writeback", .{ .hw1 = 0xCC10 }, .{ .low = low(4, initial[0], &.{}) }),
    vec("ldm r4, {r0, r4}: the loaded value wins", .{ .hw1 = 0xCC11 }, .{ .low = low(4, initial[1], &.{.{ 0, initial[0] }}) }),
    vec("stm to an unaligned base faults and writes nothing", .{ .hw1 = 0xC403, .base = window + 2 }, .{ .fault = .unaligned, .low = low(4, window + 2, &.{}) }),
    vec("ldm from an unaligned base faults and loads nothing", .{ .hw1 = 0xCC03, .base = window + 2 }, .{ .fault = .unaligned, .low = low(4, window + 2, &.{}) }),
    vec("stm past RAM faults and writes nothing", .{ .hw1 = 0xC401, .base = 0x2000_0400 }, .{ .fault = .unmapped, .low = low(4, 0x2000_0400, &.{}) }),
    vec("ldm past RAM faults and loads nothing", .{ .hw1 = 0xCC03, .base = 0x2000_0400 }, .{ .fault = .unmapped, .low = low(4, 0x2000_0400, &.{}) }),
    vec("an empty stm list is unclaimed", .{ .hw1 = 0xC400 }, none),
    vec("an empty ldm list is unclaimed", .{ .hw1 = 0xCC00 }, none),
    vec("push belongs to push_pop", .{ .hw1 = 0xB401 }, none),
    vec("b<c> belongs to branch", .{ .hw1 = 0xD000 }, none),
    vec("the 32-bit space is unclaimed", .{ .hw1 = 0xCC01, .size = 4 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
