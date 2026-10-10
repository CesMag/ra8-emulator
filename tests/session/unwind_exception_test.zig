//! Stepping out of an exception frame: which stack it is on, how big it
//! is, and the alignment pad.
const std = @import("std");
const ra8 = @import("ra8");

const exception = ra8.session.unwind.exception;

const Memory = struct {
    base: u32,
    words: []const u32,

    pub fn readWord(self: Memory, address: u32) !u32 {
        if (address < self.base or address % 4 != 0) return error.Unreadable;
        const index = (address - self.base) / 4;
        if (index >= self.words.len) return error.Unreadable;
        return self.words[index];
    }
};

/// r0-r3, r12, lr, pc, xPSR as entry stacks them.
fn frame(xpsr: u32) [8]u32 {
    return .{ 1, 2, 3, 4, 0xC, 0x1021, 0x1005, xpsr };
}

fn handler(sp: u32) [16]u32 {
    var registers = std.mem.zeroes([16]u32);
    registers[4] = 0x99;
    registers[13] = sp;
    return registers;
}

test "a basic frame on the Main stack gives back the stacked registers" {
    const words = frame(0x0100_0000);
    const next = try exception.interrupted(0xFFFF_FFF9, handler(0x200), 0, Memory{ .base = 0x200, .words = &words });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, next[0..4]);
    try std.testing.expectEqual(@as(u32, 0x99), next[4]);
    try std.testing.expectEqual(@as(u32, 0xC), next[12]);
    try std.testing.expectEqual(@as(u32, 0x220), next[13]);
    try std.testing.expectEqual(@as(u32, 0x1021), next[14]);
    try std.testing.expectEqual(@as(u32, 0x1004), next[15]);
}

test "the pad bit adds four bytes, and SPSEL reads the frame off PSP" {
    const words = frame(0x0100_0000 | exception.xpsr_pad);
    const memory = Memory{ .base = 0x300, .words = &words };
    const next = try exception.interrupted(0xFFFF_FFFD, handler(0x200), 0x300, memory);
    try std.testing.expectEqual(@as(u32, 0x324), next[13]);
    try std.testing.expectEqual(@as(u32, 1), next[0]);
}

test "an extended frame is 26 words, and DCRS clear skips the callee state below" {
    const words = frame(0x0100_0000);
    const extended = try exception.interrupted(0xFFFF_FFE9, handler(0x200), 0, Memory{ .base = 0x200, .words = &words });
    try std.testing.expectEqual(@as(u32, 0x200 + 104), extended[13]);
    const callee = try exception.interrupted(0xFFFF_FFD9, handler(0x200 - 40), 0, Memory{ .base = 0x200, .words = &words });
    try std.testing.expectEqual(@as(u32, 0x220), callee[13]);
    try std.testing.expectEqual(@as(u32, 0x1004), callee[15]);
}

test "a frame that cannot be read is an error" {
    const words = frame(0);
    const memory = Memory{ .base = 0x400, .words = &words };
    try std.testing.expectError(error.Unreadable, exception.interrupted(0xFFFF_FFF9, handler(0x200), 0, memory));
}
