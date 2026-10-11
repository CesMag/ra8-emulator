//! Covers src/chip/core/cpu/exception/nvic_source.zig: the NVIC model reading and
//! writing its registers through the Zig core's bus.
const std = @import("std");
const ra8 = @import("ra8");
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const fixture = @import("ram.zig");

const icsr: u32 = 0xE000_ED04;
const shpr3: u32 = 0xE000_ED20;
const iser0: u32 = 0xE000_E100;
const ispr0: u32 = 0xE000_E200;
const iabr0: u32 = 0xE000_E300;
const ipr0: u32 = 0xE000_E400;
const icer0: u32 = 0xE000_E180;

test "nothing pending gives no winner" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    try std.testing.expect((try nvic.source().winner(ram.view())) == null);
}

test "PendSV comes with its SHPR3 priority and taking it clears the pend" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(icsr, 1 << 28);
    ram.putWord(shpr3, 0xE0F0_0000);
    const source = nvic.source();
    const found = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 14), found.number);
    try std.testing.expectEqual(@as(u8, 0xF0), found.priority);
    try source.taken(ram.view(), 14);
    try std.testing.expectEqual(@as(u32, 0), ram.word(icsr) & (1 << 28));
}

test "an enabled IRQ line wins over a less urgent PendSV and is marked active" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(icsr, 1 << 28);
    ram.putWord(shpr3, 0xF0F0_0000);
    ram.putWord(iser0, 1 << 3);
    ram.putWord(ispr0, 1 << 3);
    ram.putWord(ipr0, 0x4000_0000); // line 3 at 0x40
    const source = nvic.source();
    const found = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 16 + 3), found.number);
    try source.taken(ram.view(), found.number);
    try std.testing.expectEqual(@as(u32, 0), ram.word(ispr0));
    try std.testing.expectEqual(@as(u32, 1 << 3), ram.word(iabr0));
    try source.returned(ram.view(), found.number);
    try std.testing.expectEqual(@as(u32, 0), ram.word(iabr0));
}

test "a pending line that is not enabled is not a winner" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(ispr0, 1 << 3);
    try std.testing.expect((try nvic.source().winner(ram.view())) == null);
}

test "two lines in the same group are taken in subpriority order" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(iser0, (1 << 3) | (1 << 5));
    ram.putWord(ispr0, (1 << 3) | (1 << 5));
    ram.putWord(ipr0, 0x6000_0000); // line 3 at 0x60
    ram.putWord(ipr0 + 4, 0x0000_4000); // line 5 at 0x40
    const source = nvic.source();
    const first = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 16 + 5), first.number);
    try source.taken(ram.view(), first.number);
    const second = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 16 + 3), second.number);
    try std.testing.expectEqual(@as(u8, 0x60), second.priority);
}

test "equal priority and subpriority go to the lower exception number" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(iser0, (1 << 2) | (1 << 6));
    ram.putWord(ispr0, (1 << 2) | (1 << 6));
    ram.putWord(ipr0, 0x0040_0000); // line 2 at 0x40
    ram.putWord(ipr0 + 4, 0x0040_0000); // line 6 at 0x40
    const found = (try nvic.source().winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 16 + 2), found.number);
}

test "a Non-secure PendSV wins from its own copy and taking it clears only that copy" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(icsr, 1 << 28);
    ram.putWord(shpr3, 0x00F0_0000);
    ram.putWord(icsr + 0x2_0000, 1 << 28);
    ram.putWord(shpr3 + 0x2_0000, 0x0040_0000);
    const source = nvic.source();
    const found = (try source.winner(ram.view())).?;
    try std.testing.expectEqual(@as(u9, 14), found.number);
    try std.testing.expectEqual(@as(u8, 0x40), found.priority);
    try std.testing.expect(found.non_secure);
    try source.taken(ram.view(), 14);
    try std.testing.expectEqual(@as(u32, 0), ram.word(icsr + 0x2_0000));
    try std.testing.expectEqual(@as(u32, 1 << 28), ram.word(icsr));
    const next = (try source.winner(ram.view())).?;
    try std.testing.expect(!next.non_secure);
}

/// The fixture RAM behind a bus that banks the normal SCS window by the
/// running state, as the board's SCS routing does: Non-secure code there
/// lands on the Non-secure copy.
const Routed = struct {
    ram: *fixture.Ram,
    state: *ra8.chip.core.banked.Banked,

    fn view(self: *Routed) ra8.chip.core.cpu.bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn land(self: *Routed, address: u32) u32 {
        const normal = address >= fixture.scs and address < fixture.scs + 0x1000;
        return if (normal and self.state.current == .non_secure) address + 0x2_0000 else address;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Routed = @ptrCast(@alignCast(ctx));
        return self.ram.view().read(self.land(address), into);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) ra8.chip.core.cpu.bus.Error!void {
        const self: *Routed = @ptrCast(@alignCast(ctx));
        return self.ram.view().write(self.land(address), from);
    }
};

test "a Non-secure SysTick pended while Non-secure runs is taken Non-secure only" {
    var ram: fixture.Ram = .{};
    var state: ra8.chip.core.banked.Banked = .{};
    state.current = .non_secure;
    var routed: Routed = .{ .ram = &ram, .state = &state };
    var nvic: NvicSource = .{ .banked = &state };
    ram.putWord(icsr + 0x2_0000, 1 << 26);
    ram.putWord(shpr3 + 0x2_0000, 0x4000_0000);
    const source = nvic.source();
    const found = (try source.winner(routed.view())).?;
    try std.testing.expectEqual(@as(u9, 15), found.number);
    try std.testing.expect(found.non_secure);
    try std.testing.expectEqual(ra8.chip.core.banked.State.non_secure, state.current);
    try source.taken(routed.view(), 15);
    try std.testing.expectEqual(@as(u32, 0), ram.word(icsr + 0x2_0000));
    try std.testing.expect((try source.winner(routed.view())) == null);
}

test "the clear registers are folded only while marked due, and the fold clears the mark" {
    var ram: fixture.Ram = .{};
    var due = false;
    var nvic: NvicSource = .{ .clear_due = &due };
    ram.putWord(iser0, 1 << 3);
    ram.putWord(ispr0, 1 << 3);
    ram.putWord(icer0, 1 << 3);
    const source = nvic.source();
    // Not due: ICER is left alone, so line 3 is still enabled and wins.
    try std.testing.expectEqual(@as(u9, 16 + 3), (try source.winner(ram.view())).?.number);
    try std.testing.expectEqual(@as(u32, 1 << 3), ram.word(icer0));
    due = true;
    try std.testing.expect((try source.winner(ram.view())) == null);
    try std.testing.expectEqual(@as(u32, 0), ram.word(iser0));
    try std.testing.expectEqual(@as(u32, 0), ram.word(icer0));
    try std.testing.expect(!due);
}

test "a source with no mark folds the clear registers every pick" {
    var ram: fixture.Ram = .{};
    var nvic: NvicSource = .{};
    ram.putWord(iser0, 1 << 3);
    ram.putWord(ispr0, 1 << 3);
    ram.putWord(icer0, 1 << 3);
    try std.testing.expect((try nvic.source().winner(ram.view())) == null);
    try std.testing.expectEqual(@as(u32, 0), ram.word(iser0));
}
