//! Covers src/chip/core/cpu/mve/gather/gather.zig.
const std = @import("std");
const ra8 = @import("ra8");
const gather = ra8.chip.core.cpu.mve.gather;

fn form(msize: anytype, esize: anytype, signed: bool, store: bool, os: bool) gather.Form {
    return .{ .msize = msize, .esize = esize, .signed = signed, .store = store, .os = os };
}

test "unsigned loads and stores take memory no wider than the element" {
    try std.testing.expect(gather.valid(form(.byte, .byte, false, false, false)));
    try std.testing.expect(gather.valid(form(.half, .word, false, true, true)));
    try std.testing.expect(gather.valid(form(.word, .word, false, false, true)));
    try std.testing.expect(!gather.valid(form(.word, .half, false, false, false)));
}

test "os with byte memory is not defined" {
    try std.testing.expect(!gather.valid(form(.byte, .half, false, false, true)));
    try std.testing.expect(!gather.valid(form(.byte, .byte, false, true, true)));
}

test "a signed access must be a widening load" {
    try std.testing.expect(gather.valid(form(.byte, .half, true, false, false)));
    try std.testing.expect(gather.valid(form(.half, .word, true, false, true)));
    try std.testing.expect(!gather.valid(form(.half, .half, true, false, false)));
    try std.testing.expect(!gather.valid(form(.byte, .word, true, true, false)));
}

test "os scales the offset by the memory size" {
    try std.testing.expectEqual(@as(u32, 0x2000_000C), gather.address(.{ .base = 0x2000_0000, .offset = 3, .msize = .word, .os = true }));
    try std.testing.expectEqual(@as(u32, 0x2000_0003), gather.address(.{ .base = 0x2000_0000, .offset = 3, .msize = .word, .os = false }));
}

test "the odd beat of a doubleword sits four bytes above the even one" {
    try std.testing.expectEqual(@as(u32, 0x2000_001C), gather.beatAddress(.{ .base = 0x2000_0000, .offset = 3, .os = true, .odd = true }));
    try std.testing.expectEqual(@as(u32, 0x2000_0003), gather.beatAddress(.{ .base = 0x2000_0000, .offset = 3, .os = false, .odd = false }));
}

test "a vector base scales imm7 by the access size" {
    try std.testing.expectEqual(@as(u32, 0x2000_0008), gather.vectorAddress(.{ .element = 0x2000_0000, .imm7 = 1, .add = true, .double = true }));
    try std.testing.expectEqual(@as(u32, 0x2000_0000), gather.vectorAddress(.{ .element = 0x2000_0004, .imm7 = 1, .add = false, .double = false }));
}
