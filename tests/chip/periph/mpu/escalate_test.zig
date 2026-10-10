//! Which exception a refused access is taken as: MemManage while
//! SHCSR.MEMFAULTENA stands, an escalated HardFault when it does not.
const std = @import("std");
const ra8 = @import("ra8");
const escalate = ra8.chip.periph.mpu_escalate;

test "MEMFAULTENA set takes MemManage" {
    try std.testing.expectEqual(
        escalate.Target.mem_manage,
        escalate.targetFor(escalate.shcsr.memfaultena),
    );
}

test "MEMFAULTENA clear escalates to HardFault" {
    try std.testing.expectEqual(escalate.Target.hard_fault, escalate.targetFor(0));
}

test "the other SHCSR enables do not decide it" {
    // BusFault and UsageFault enables sit beside MEMFAULTENA; neither says
    // anything about whether MemManage runs.
    const others: u32 = (1 << 17) | (1 << 18);
    try std.testing.expectEqual(escalate.Target.hard_fault, escalate.targetFor(others));
    try std.testing.expectEqual(
        escalate.Target.mem_manage,
        escalate.targetFor(others | escalate.shcsr.memfaultena),
    );
}

test "a whole SHCSR word with MEMFAULTENA in it still takes MemManage" {
    try std.testing.expectEqual(
        escalate.Target.mem_manage,
        escalate.targetFor(0xFFFF_FFFF),
    );
}

test "only an escalation marks HFSR" {
    try std.testing.expect(escalate.marks(.hard_fault));
    try std.testing.expect(!escalate.marks(.mem_manage));
}

test "the fields sit where the architecture puts them" {
    try std.testing.expectEqual(@as(u32, 0x0001_0000), escalate.shcsr.memfaultena);
    try std.testing.expectEqual(@as(u32, 0x4000_0000), escalate.hfsr.forced);
    try std.testing.expectEqual(@as(u16, 3), escalate.hard_fault);
}

test "an escalated HardFault runs above everything configurable" {
    // The priority field is unsigned, so zero is the most urgent it can
    // hold; nothing this model pends sits above it.
    try std.testing.expectEqual(@as(u8, 0), escalate.hard_fault_priority);
}
