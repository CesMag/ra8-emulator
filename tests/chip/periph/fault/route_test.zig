//! Tests for src/chip/periph/fault_route.zig.

const std = @import("std");
const ra8 = @import("ra8");
const route = ra8.chip.periph.fault_status.route;

const all_enabled: u32 = (1 << 16) | (1 << 17) | (1 << 18);
/// MemManage at 0x20, BusFault at 0x40, UsageFault at 0x60.
const shpr1: u32 = 0x0060_4020;

test "each configurable fault has its own vector, enable and priority byte" {
    try std.testing.expectEqual(@as(u16, 4), route.exception(.mem_manage));
    try std.testing.expectEqual(@as(u16, 5), route.exception(.bus_fault));
    try std.testing.expectEqual(@as(u16, 6), route.exception(.usage_fault));
    try std.testing.expectEqual(@as(u32, 1 << 16), route.enable(.mem_manage));
    try std.testing.expectEqual(@as(u32, 1 << 17), route.enable(.bus_fault));
    try std.testing.expectEqual(@as(u32, 1 << 18), route.enable(.usage_fault));
    try std.testing.expectEqual(@as(u8, 0x20), route.priority(.mem_manage, shpr1));
    try std.testing.expectEqual(@as(u8, 0x40), route.priority(.bus_fault, shpr1));
    try std.testing.expectEqual(@as(u8, 0x60), route.priority(.usage_fault, shpr1));
}

test "an enabled fault takes its own vector at its own priority" {
    const taken = route.route(.bus_fault, all_enabled, shpr1, null);
    try std.testing.expectEqual(@as(u16, 5), taken.number);
    try std.testing.expectEqual(@as(u8, 0x40), taken.priority);
    try std.testing.expect(!taken.escalated);
}

test "a disabled fault escalates to HardFault" {
    // UsageFault's enable is the one left clear.
    const taken = route.route(.usage_fault, (1 << 16) | (1 << 17), shpr1, null);
    try std.testing.expectEqual(route.hard_fault, taken.number);
    try std.testing.expectEqual(route.hard_fault_priority, taken.priority);
    try std.testing.expect(taken.escalated);
}

test "each enable gates only its own fault" {
    try std.testing.expect(!route.route(.mem_manage, 1 << 16, shpr1, null).escalated);
    try std.testing.expect(route.route(.bus_fault, 1 << 16, shpr1, null).escalated);
    try std.testing.expect(route.route(.usage_fault, 1 << 17, shpr1, null).escalated);
}

test "a fault no more urgent than what is running escalates" {
    // Running at 0x40: BusFault (0x40) cannot preempt its equal, UsageFault
    // (0x60) is lower, MemManage (0x20) is above and is taken.
    try std.testing.expect(route.route(.bus_fault, all_enabled, shpr1, 0x40).escalated);
    try std.testing.expect(route.route(.usage_fault, all_enabled, shpr1, 0x40).escalated);
    const taken = route.route(.mem_manage, all_enabled, shpr1, 0x40);
    try std.testing.expect(!taken.escalated);
    try std.testing.expectEqual(@as(u16, 4), taken.number);
}
