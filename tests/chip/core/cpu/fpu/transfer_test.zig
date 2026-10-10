const std = @import("std");
const ra8 = @import("ra8");
const fpu = ra8.chip.core.cpu.fpu;
const transfer = fpu.transfer;
const Bank = fpu.bank.Bank;

test "a VPUSH then VPOP of D8-D15 restores the registers" {
    var bank: Bank = .{};
    for (16..32) |i| bank.s[i] = @intCast(i * 0x0101_0101);
    const push = transfer.multiple(.{ .p = 1, .u = 0, .w = 1, .rn = 13, .base = 0x2000_8000, .d = 8, .imm8 = 16, .double = true });
    var stack: [16]u32 = undefined;
    transfer.store(push, &bank, &stack);
    var fresh: Bank = .{};
    const pop = transfer.multiple(.{ .p = 0, .u = 1, .w = 1, .rn = 13, .base = push.wback.?, .d = 8, .imm8 = 16, .double = true });
    try std.testing.expectEqual(push.start, pop.start);
    transfer.load(pop, &fresh, &stack);
    try std.testing.expectEqualSlices(u32, bank.s[16..32], fresh.s[16..32]);
    try std.testing.expectEqual(@as(u32, 0x2000_8000), pop.wback.?);
}

test "a VLDR.64 puts the lower address in the low word" {
    var bank: Bank = .{};
    const plan = transfer.single(.{ .u = 1, .rn = 0, .base = 0x100, .d = 3, .imm8 = 0, .double = true });
    transfer.load(plan, &bank, &.{ 0x5566_7788, 0x1122_3344 });
    try std.testing.expectEqual(@as(u64, 0x1122_3344_5566_7788), bank.readD(3));
}

test "a store copies exactly the planned words" {
    var bank: Bank = .{};
    bank.s[4] = 0xAAAA_AAAA;
    bank.s[5] = 0xBBBB_BBBB;
    const plan = transfer.single(.{ .u = 1, .rn = 0, .base = 0, .d = 4, .imm8 = 0, .double = false, .store = true });
    var out = [_]u32{ 0, 0 };
    transfer.store(plan, &bank, &out);
    try std.testing.expectEqualSlices(u32, &.{ 0xAAAA_AAAA, 0 }, &out);
}
