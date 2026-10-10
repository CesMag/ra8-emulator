//! SRAMPRCR: the key, the registers it guards, and what a locked store does.
const std = @import("std");
const testing = std.testing;

const ra8 = @import("ra8");
const lock = ra8.chip.periph.sram_lock;

test "a fresh controller is locked" {
    const guard = lock.Lock{};
    try testing.expect(!guard.open());
    try testing.expect(guard.quiet());
}

test "the unlock value opens the secure half" {
    var guard = lock.Lock{};
    try testing.expectEqual(lock.Effect.accepted, guard.latch(lock.off.prcr_s, lock.key.unlock));
    try testing.expect(guard.open_secure);
    try testing.expect(guard.open());
    try testing.expectEqual(@as(u32, 1), guard.accepted);
}

test "the lock value shuts it again" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, lock.key.unlock);
    try testing.expectEqual(lock.Effect.accepted, guard.latch(lock.off.prcr_s, lock.key.lock));
    try testing.expect(!guard.open());
    try testing.expectEqual(@as(u32, 2), guard.accepted);
}

test "a wrong key leaves the lock exactly as it was" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, lock.key.unlock);
    try testing.expectEqual(lock.Effect.ignored, guard.latch(lock.off.prcr_s, 0x0000));
    try testing.expect(guard.open_secure);
    try testing.expectEqual(@as(u32, 1), guard.ignored);
}

test "a wrong key cannot open a locked controller either" {
    var guard = lock.Lock{};
    try testing.expectEqual(lock.Effect.ignored, guard.latch(lock.off.prcr_s, 0x5A01));
    try testing.expect(!guard.open());
}

test "the non-secure copy is its own lock" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_ns, lock.key.unlock);
    try testing.expect(!guard.open_secure);
    try testing.expect(guard.open_non_secure);
    try testing.expect(guard.open());
}

test "either half open is enough" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, lock.key.unlock);
    _ = guard.latch(lock.off.prcr_ns, lock.key.unlock);
    _ = guard.latch(lock.off.prcr_s, lock.key.lock);
    try testing.expect(guard.open());
}

test "an offset that is not a protection register latches nothing" {
    var guard = lock.Lock{};
    try testing.expectEqual(lock.Effect.elsewhere, guard.latch(lock.off.wtsc, lock.key.unlock));
    try testing.expect(!guard.open());
    try testing.expect(guard.quiet());
}

test "the key is read from the low half-word" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, 0xDEAD_A501);
    try testing.expect(guard.open_secure);
}

test "the guarded list is the wait-state register, the four CRn and the four ECCRGNn" {
    try testing.expect(lock.guards(lock.off.wtsc));
    for (0..lock.guarded.banks) |bank| {
        const step: u32 = @intCast(bank * lock.guarded.stride);
        try testing.expect(lock.guards(lock.off.cr0 + step));
        try testing.expect(lock.guards(lock.off.eccrgn0 + step));
    }
}

test "the error side of the block is not guarded" {
    try testing.expect(!lock.guards(lock.off.prcr_s));
    try testing.expect(!lock.guards(lock.off.prcr_ns));
    try testing.expect(!lock.guards(0x40));
    try testing.expect(!lock.guards(0x48));
    try testing.expect(!lock.guards(0x50));
}

test "one past each guarded array is outside it" {
    const span = lock.guarded.stride * lock.guarded.banks;
    try testing.expect(!lock.guards(lock.off.cr0 + span));
    try testing.expect(!lock.guards(lock.off.eccrgn0 + span));
    try testing.expect(!lock.guards(lock.off.cr0 - 4));
}

test "a guarded store is blocked while locked" {
    var guard = lock.Lock{};
    try testing.expectEqual(lock.Verdict.blocked, guard.admit(lock.off.cr0));
    try testing.expectEqual(@as(u32, 1), guard.blocked);
    try testing.expectEqual(@as(u32, 0), guard.allowed);
}

test "a guarded store goes through once the key is in" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, lock.key.unlock);
    try testing.expectEqual(lock.Verdict.allowed, guard.admit(lock.off.cr0));
    try testing.expectEqual(@as(u32, 1), guard.allowed);
}

test "an unguarded store is neither allowed nor blocked" {
    var guard = lock.Lock{};
    try testing.expectEqual(lock.Verdict.unguarded, guard.admit(0x40));
    try testing.expect(guard.quiet());
}

test "the driver's unlock, write, re-lock leaves the controller shut" {
    var guard = lock.Lock{};
    _ = guard.latch(lock.off.prcr_s, lock.key.unlock);
    try testing.expectEqual(lock.Verdict.allowed, guard.admit(lock.off.eccrgn0));
    _ = guard.latch(lock.off.prcr_s, lock.key.lock);
    try testing.expectEqual(lock.Verdict.blocked, guard.admit(lock.off.eccrgn0));
}

test "halfOf names the two protection registers and nothing else" {
    try testing.expectEqual(lock.Half.secure, lock.halfOf(lock.off.prcr_s).?);
    try testing.expectEqual(lock.Half.non_secure, lock.halfOf(lock.off.prcr_ns).?);
    try testing.expect(lock.halfOf(lock.off.wtsc) == null);
}
