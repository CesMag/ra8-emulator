//! Covers src/chip/periph/nvic_banked.zig: SysTick and PendSV offered from both
//! of their banks.
const std = @import("std");
const ra8 = @import("ra8");
const nvic_banked = ra8.chip.periph.nvic.nvic_banked;

const icsr: u32 = 0xE000_ED04;
const shpr3: u32 = 0xE000_ED20;
const pendsvset: u32 = 1 << 28;
const pendstset: u32 = 1 << 26;

/// A core with both copies, the Non-secure one kept apart.
const Banked = struct {
    secure: [2]u32 = .{ 0, 0 },
    non_secure: [2]u32 = .{ 0, 0 },

    fn slot(address: u32) usize {
        return if (address == icsr) 0 else 1;
    }

    pub fn readWord(self: *Banked, address: u32) !u32 {
        return self.secure[slot(address)];
    }

    pub fn readNonSecure(self: *Banked, address: u32) !u32 {
        return self.non_secure[slot(address)];
    }

    pub fn writeNonSecure(self: *Banked, address: u32, value: u32) !void {
        self.non_secure[slot(address)] = value;
    }
};

/// A core with one copy.
const Single = struct {
    words: [2]u32 = .{ 0, 0 },

    pub fn readWord(self: *Single, address: u32) !u32 {
        return self.words[if (address == icsr) 0 else 1];
    }
};

test "a Non-secure PendSV is offered with its own priority and tagged" {
    var core: Banked = .{};
    core.non_secure = .{ pendsvset, 0x0060_0000 };
    const pends = try nvic_banked.read(&core);
    try std.testing.expectEqual(@as(usize, 1), pends.slice().len);
    const offered = nvic_banked.candidate(pends.slice()[0]);
    try std.testing.expectEqual(@as(u16, 14), offered.number);
    try std.testing.expectEqual(@as(u8, 0x60), offered.priority);
    try std.testing.expect(offered.non_secure);
}

test "SysTick is offered from both copies, each with its own priority" {
    var core: Banked = .{};
    core.secure = .{ pendstset, 0x2000_0000 };
    core.non_secure = .{ pendstset | pendsvset, 0x8040_0000 };
    const pends = try nvic_banked.read(&core);
    try std.testing.expectEqual(@as(usize, 3), pends.slice().len);
    try std.testing.expectEqual(@as(u16, 15), pends.slice()[0].number);
    try std.testing.expect(!nvic_banked.candidate(pends.slice()[0]).non_secure);
    try std.testing.expectEqual(@as(u16, 14), pends.slice()[1].number);
    try std.testing.expect(nvic_banked.candidate(pends.slice()[1]).non_secure);
    try std.testing.expectEqual(@as(u16, 15), pends.slice()[2].number);
    try std.testing.expectEqual(@as(u8, 0x80), pends.slice()[2].priority);
    try std.testing.expect(nvic_banked.candidate(pends.slice()[2]).non_secure);
}

test "a Non-secure PENDSVCLR clears itself and PENDSVSET in that copy only" {
    var core: Banked = .{};
    core.secure = .{ pendsvset, 0 };
    core.non_secure = .{ pendsvset | (1 << 27), 0 };
    try nvic_banked.fold(&core);
    try std.testing.expectEqual(@as(u32, 0), core.non_secure[0]);
    try std.testing.expectEqual(pendsvset, core.secure[0]);
    core.non_secure[0] = pendsvset;
    try nvic_banked.fold(&core);
    try std.testing.expectEqual(pendsvset, core.non_secure[0]);
}

test "a core without the Non-secure copy offers only the Secure one" {
    var core: Single = .{ .words = .{ pendsvset | pendstset, 0x4050_0000 } };
    try std.testing.expect(!nvic_banked.reaches(*Single));
    const pends = try nvic_banked.read(&core);
    try std.testing.expectEqual(@as(usize, 2), pends.slice().len);
    for (pends.slice()) |pend| try std.testing.expect(!nvic_banked.candidate(pend).non_secure);
}

test "clear drops one bit from the Non-secure copy only" {
    var core: Banked = .{};
    core.secure = .{ pendsvset, 0 };
    core.non_secure = .{ pendsvset | pendstset, 0 };
    try nvic_banked.clear(&core, 14);
    try std.testing.expectEqual(pendstset, core.non_secure[0]);
    try std.testing.expectEqual(pendsvset, core.secure[0]);
    try nvic_banked.clear(&core, 15);
    try std.testing.expectEqual(@as(u32, 0), core.non_secure[0]);
}
