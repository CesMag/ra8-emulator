//! What enforcement caught, and what it did with it.
const std = @import("std");
const ra8 = @import("ra8");
const mpu_fault = ra8.chip.periph.mpu_fault;

test "a latch with nothing armed and nothing refused stays out of the report" {
    const latch = mpu_fault.Latch{};
    try std.testing.expect(latch.quiet());
    try std.testing.expectEqual(@as(?mpu_fault.Violation, null), latch.pending);
}

test "arming alone is enough to be reported" {
    var latch = mpu_fault.Latch{};
    latch.arms += 1;
    try std.testing.expect(!latch.quiet());
}

test "the first refused store is the one the run stops on" {
    var latch = mpu_fault.Latch{};
    try std.testing.expect(latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 }));
    try std.testing.expectEqual(@as(u64, 1), latch.violations);
    try std.testing.expectEqual(@as(u64, 0), latch.coalesced);
}

test "the rest of an access already latched is not a second violation" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    // A store multiple puts one word per hook call: the words after the
    // first belong to the access that already stopped the run.
    try std.testing.expect(!latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0044 }));
    try std.testing.expect(!latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0048 }));
    try std.testing.expectEqual(@as(u64, 1), latch.violations);
    try std.testing.expectEqual(@as(u64, 2), latch.coalesced);
}

test "taking the violation gives back the store that made it" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    const hit = latch.take().?;
    try std.testing.expectEqual(@as(u32, 0x0200_1234), hit.pc);
    try std.testing.expectEqual(@as(u32, 0x2200_0040), hit.address);
}

test "a violation is taken once" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    _ = latch.take();
    try std.testing.expectEqual(@as(?mpu_fault.Violation, null), latch.take());
}

test "the next access after one was taken latches again" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x0200_1234, .address = 0x2200_0040 });
    _ = latch.take();
    try std.testing.expect(latch.record(.{ .pc = 0x0200_2000, .address = 0x2200_0100 }));
    try std.testing.expectEqual(@as(u64, 2), latch.violations);
    try std.testing.expectEqual(@as(u64, 0), latch.coalesced);
}

test "MMFSR names a data access violation with MMFAR standing" {
    const status = mpu_fault.mmfsr.daccviol | mpu_fault.mmfsr.mmarvalid;
    try std.testing.expectEqual(@as(u32, 0x82), status);
    // A fetch refused by the MPU is a different bit, and this model does not
    // check one: nothing here sets IACCVIOL.
    try std.testing.expectEqual(@as(u32, 1), mpu_fault.mmfsr.iaccviol);
}

test "MemManage is exception 4" {
    try std.testing.expectEqual(@as(u16, 4), mpu_fault.exception);
}

test "a refused fetch is counted apart from a refused store" {
    var latch = mpu_fault.Latch{};
    try std.testing.expect(latch.record(.{ .pc = 0x2200_0100, .address = 0x2200_0100, .kind = .fetch }));
    try std.testing.expectEqual(@as(u64, 1), latch.violations);
    try std.testing.expectEqual(@as(u64, 1), latch.fetches);
    _ = latch.take();
    try std.testing.expect(latch.record(.{ .pc = 0x2200_0200, .address = 0x220A_0000 }));
    try std.testing.expectEqual(@as(u64, 2), latch.violations);
    try std.testing.expectEqual(@as(u64, 1), latch.fetches);
}

test "a violation is a store unless it says otherwise" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x2200_0004, .address = 0x220A_0000 });
    try std.testing.expectEqual(mpu_fault.Kind.store, latch.pending.?.kind);
    try std.testing.expectEqual(@as(u64, 0), latch.fetches);
}

test "a refused fetch carries the same address as its PC" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x220A_0000, .address = 0x220A_0000, .kind = .fetch });
    const hit = latch.take().?;
    try std.testing.expectEqual(hit.pc, hit.address);
}

test "enforcement has not stood down until a fetch has nowhere to go" {
    var latch = mpu_fault.Latch{};
    try std.testing.expect(!latch.stood_down);
    _ = latch.record(.{ .pc = 0x220A_0000, .address = 0x220A_0000, .kind = .fetch });
    try std.testing.expect(!latch.stood_down);
}

test "a privilege refusal is counted apart from a permission one" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x2200_0004, .address = 0x220A_0000, .reason = .privilege });
    try std.testing.expectEqual(@as(u64, 1), latch.privilege);
    _ = latch.take();
    _ = latch.record(.{ .pc = 0x2200_0008, .address = 0x220A_0000 });
    try std.testing.expectEqual(@as(u64, 2), latch.violations);
    try std.testing.expectEqual(@as(u64, 1), latch.privilege);
}

test "a violation is a permission one unless it says otherwise" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 0x2200_0004, .address = 0x220A_0000 });
    try std.testing.expectEqual(mpu_fault.Reason.permission, latch.pending.?.reason);
}

test "a refused load is counted apart from a refused store" {
    var latch = mpu_fault.Latch{};
    _ = latch.record(.{ .pc = 4, .address = 0x220B_2000, .kind = .load, .reason = .privilege });
    _ = latch.take();
    _ = latch.record(.{ .pc = 8, .address = 0x220B_2000, .reason = .privilege });
    try std.testing.expectEqual(@as(u64, 1), latch.loads);
    try std.testing.expectEqual(@as(u64, 0), latch.fetches);
    try std.testing.expectEqual(@as(u64, 2), latch.violations);
    try std.testing.expectEqual(@as(u64, 2), latch.privilege);
}
