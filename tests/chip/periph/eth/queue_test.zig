//! The descriptor-control window: the base the gateway takes, the queues it
//! marks for reception, and the request that kicks one.
const std = @import("std");
const ra8 = @import("ra8");
const eth_mode = ra8.chip.periph.eth_mode;
const eth_queue = ra8.chip.periph.eth_queue;
const regs = ra8.chip.periph.eth_regs;

const gwca = regs.cluster.gwca0;

/// A window whose gateway can be put in any mode the test wants.
const Fixture = struct {
    machine: eth_mode.Machine = .{},
    window: eth_queue.Queues = .{},

    fn wire(self: *Fixture, mode: eth_mode.Mode) void {
        self.machine.mode = mode;
        self.window.mode = &self.machine;
    }
};

test "the ring base is taken in config" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.baseWrite(gwca + regs.gwca.gwdcbac1, 4, 0x2200_1000);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), fix.window.rings.linkfix);
}

test "a base written on a running gateway is refused and counted" {
    var fix = Fixture{};
    fix.wire(.operation);
    fix.window.baseWrite(gwca + regs.gwca.gwdcbac1, 4, 0x2200_1000);
    try std.testing.expectEqual(@as(u32, 0), fix.window.rings.linkfix);
    try std.testing.expectEqual(@as(u32, 1), fix.window.base_late);
}

test "a refused base still reads back: a register does" {
    var fix = Fixture{};
    fix.wire(.operation);
    fix.window.baseWrite(gwca + regs.gwca.gwdcbac1, 4, 0x2200_1000);
    const back = fix.window.baseRead(gwca + regs.gwca.gwdcbac1, 4);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), back);
}

test "the upper half of the base is remembered and unused" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.baseWrite(gwca + regs.gwca.gwdcbac0, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), fix.window.baseRead(gwca + regs.gwca.gwdcbac0, 4));
    try std.testing.expectEqual(@as(u32, 0), fix.window.rings.linkfix);
}

test "a queue with DQT clear is a reception queue" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.configWrite(gwca + regs.gwca.gwdcc + 8, 4, 0);
    try std.testing.expectEqual(@as(u64, 1) << 2, fix.window.rings.receiving);
}

test "a queue turned into a transmit queue stops receiving" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.configWrite(gwca + regs.gwca.gwdcc + 8, 4, 0);
    fix.window.configWrite(gwca + regs.gwca.gwdcc + 8, 4, regs.gwca.dqt);
    try std.testing.expectEqual(@as(u64, 0), fix.window.rings.receiving);
}

test "the reload bit is finished by the time it reads back" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.configWrite(gwca + regs.gwca.gwdcc, 4, regs.gwca.balr | 7);
    try std.testing.expectEqual(@as(u32, 7), fix.window.configRead(gwca + regs.gwca.gwdcc, 4));
}

test "the request register reads back consumed" {
    var fix = Fixture{};
    fix.wire(.operation);
    fix.window.requestWrite(gwca + regs.gwca.gwtrc0, 4, 1);
    try std.testing.expectEqual(@as(u32, 0), fix.window.requestRead(gwca + regs.gwca.gwtrc0, 4));
}

test "a kick with no rings behind it is still counted" {
    var fix = Fixture{};
    fix.wire(.operation);
    fix.window.requestWrite(gwca + regs.gwca.gwtrc0, 4, 0b11);
    try std.testing.expectEqual(@as(u32, 2), fix.window.rings.kicks);
}

test "the second request word starts at queue thirty-two" {
    var fix = Fixture{};
    fix.wire(.config);
    fix.window.requestWrite(gwca + regs.gwca.gwtrc1, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), fix.window.rings.kicks);
    try std.testing.expectEqual(@as(u32, 1), fix.window.rings.refused.stopped);
}

test "a window with no gateway behind it is never running" {
    var window = eth_queue.Queues{};
    window.requestWrite(gwca + regs.gwca.gwtrc0, 4, 1);
    try std.testing.expectEqual(@as(u32, 1), window.rings.refused.stopped);
}

test "the three windows sit where the gateway puts them" {
    var fix = Fixture{};
    fix.wire(.config);
    try std.testing.expectEqual(gwca + 0x194, fix.window.baseBlock().base);
    try std.testing.expectEqual(gwca + 0x200, fix.window.requestBlock().base);
    try std.testing.expectEqual(gwca + 0x400, fix.window.configBlock().base);
    try std.testing.expectEqual(@as(u32, 128), fix.window.configBlock().size);
}

test "a window nothing asked of is quiet" {
    var fix = Fixture{};
    fix.wire(.config);
    try std.testing.expect(fix.window.quiet());
    fix.wire(.operation);
    fix.window.baseWrite(gwca + regs.gwca.gwdcbac1, 4, 1);
    try std.testing.expect(!fix.window.quiet());
}

test "a ring base laid down in two halfword stores is taken whole" {
    var fix = Fixture{};
    fix.wire(.config);
    const at = gwca + regs.gwca.gwdcbac1;
    fix.window.baseWrite(at, 2, 0x1000);
    fix.window.baseWrite(at + 2, 2, 0x2200);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), fix.window.rings.linkfix);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), fix.window.baseRead(at, 4));
}

test "a halfword read of the base answers the half it names" {
    var fix = Fixture{};
    fix.wire(.config);
    const at = gwca + regs.gwca.gwdcbac1;
    fix.window.baseWrite(at, 4, 0x2200_1000);
    try std.testing.expectEqual(@as(u32, 0x2200), fix.window.baseRead(at + 2, 2));
}

test "a halfword at the top of GWTRC0 kicks the queues it names" {
    var fix = Fixture{};
    fix.wire(.operation);
    // Queue 16 is configured and queue 0 is not, so only a request that
    // reaches the top half of the word finds a chain to look for.
    fix.window.configWrite(gwca + regs.gwca.gwdcc + 16 * 4, 4, 0);
    fix.window.requestWrite(gwca + regs.gwca.gwtrc0 + 2, 2, 1);
    try std.testing.expectEqual(@as(u32, 1), fix.window.rings.kicks);
}

test "a narrow config store keeps the lanes it does not name" {
    var fix = Fixture{};
    fix.wire(.config);
    const at = gwca + regs.gwca.gwdcc;
    fix.window.configWrite(at, 4, regs.gwca.dqt | 0x00FF_0000);
    fix.window.configWrite(at, 1, 0x12);
    try std.testing.expectEqual(@as(u32, 0x00FF_0012 | regs.gwca.dqt), fix.window.configRead(at, 4));
    try std.testing.expectEqual(@as(u64, 0), fix.window.rings.receiving & 1);
}
