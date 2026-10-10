//! Tests for src/chip/periph/eth/agent.zig.
const std = @import("std");
const ra8 = @import("ra8");
const agent = ra8.chip.periph.eth.agent;

const base: u32 = 0x403C_A000;

fn reg(offset: u32) u32 {
    return base + offset;
}

test "a port nothing touched stays out of the report" {
    var unit = agent.Agent.init(base);
    try std.testing.expect(unit.quiet());
}

test "each class keeps its own queue depth word" {
    var unit = agent.Agent.init(base);
    for (0..agent.off.class_count) |i| {
        const at: u32 = @intCast(i);
        unit.write(reg(agent.off.eatdqdc0 + 4 * at), 4, 0x100 + at);
    }
    try std.testing.expectEqual(@as(u32, 0x100), unit.read(reg(agent.off.eatdqdc0), 4));
    try std.testing.expectEqual(@as(u32, 0x107), unit.read(reg(agent.off.eatdqdc0 + 0x1C), 4));
    try std.testing.expect(!unit.quiet());
}

test "enable sets bits, disable clears them, enable reads the mask" {
    var unit = agent.Agent.init(base);
    const group1 = agent.off.eaeis0 + agent.off.group_stride;
    unit.write(reg(group1 + agent.off.disable), 4, 0xFFFF_FFFF);
    unit.write(reg(group1 + agent.off.enable), 4, 0x0000_00F0);
    unit.write(reg(group1 + agent.off.enable), 4, 0x0000_0003);
    unit.write(reg(group1 + agent.off.disable), 4, 0x0000_0010);
    try std.testing.expectEqual(@as(u32, 0xE3), unit.read(reg(group1 + agent.off.enable), 4));
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(group1 + agent.off.disable), 4));
}

test "the three groups hold separate masks" {
    var unit = agent.Agent.init(base);
    for (0..agent.off.group_count) |g| {
        const at = agent.off.eaeis0 + agent.off.group_stride * @as(u32, @intCast(g));
        unit.write(reg(at + agent.off.enable), 4, @as(u32, 1) << @intCast(g));
    }
    const last = agent.off.eaeis0 + 2 * agent.off.group_stride;
    try std.testing.expectEqual(@as(u32, 1), unit.read(reg(agent.off.eaeis0 + agent.off.enable), 4));
    try std.testing.expectEqual(@as(u32, 4), unit.read(reg(last + agent.off.enable), 4));
}

test "error status reads 0 and ignores stores" {
    var unit = agent.Agent.init(base);
    unit.write(reg(agent.off.eaeis0), 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), unit.read(reg(agent.off.eaeis0), 4));
}

test "both windows sit on the bus at the port's base" {
    var bus = ra8.chip.periph.registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    var unit = agent.Agent.init(base);
    for (unit.blocks()) |block| try bus.add(block);
    bus.write(reg(agent.off.eatdqdc0 + 4), 4, 0x55);
    bus.write(reg(agent.off.eaeis0 + agent.off.enable), 4, 0x9);
    try std.testing.expectEqual(@as(u32, 0x55), unit.depth[1]);
    try std.testing.expectEqual(@as(u32, 0x9), unit.enabled[0]);
}
