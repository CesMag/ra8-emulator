//! Tests for DWT_CYCCNT counted per instruction between clock charges.
const std = @import("std");
const ra8 = @import("ra8");

const cycle_count = ra8.session.step_hook.cycle_count;
const dwt = ra8.chip.periph.dwt;

test "the count climbs one per instruction while the word stands still" {
    var count = cycle_count.Count{};
    try std.testing.expectEqual(@as(u32, 100), count.at(100));
    try std.testing.expectEqual(@as(u32, 101), count.at(100));
    try std.testing.expectEqual(@as(u32, 102), count.at(100));
}

test "a charge restarts the count from the new word instead of adding it twice" {
    var count = cycle_count.Count{};
    var index: u32 = 0;
    while (index < 5) : (index += 1) _ = count.at(0);
    // clocks.zig charged five instructions: the word now reads 5.
    try std.testing.expectEqual(@as(u32, 5), count.at(5));
    try std.testing.expectEqual(@as(u32, 6), count.at(5));
}

test "a halt hands back the count to write and the resumed instruction is not counted twice" {
    var count = cycle_count.Count{};
    _ = count.at(10);
    _ = count.at(10);
    try std.testing.expectEqual(@as(u32, 12), count.at(10));
    try std.testing.expectEqual(@as(?u32, 12), count.settle());
    // The engine re-runs the halted instruction's hook on resume.
    try std.testing.expectEqual(@as(u32, 12), count.at(12));
    try std.testing.expectEqual(@as(u32, 13), count.at(12));
}

test "a halt with nothing counted writes nothing back" {
    var count = cycle_count.Count{};
    try std.testing.expectEqual(@as(?u32, null), count.settle());
    _ = count.at(7);
    try std.testing.expectEqual(@as(?u32, null), count.settle());
}

test "forgetting the watch starts the next reading afresh" {
    var count = cycle_count.Count{};
    _ = count.at(3);
    _ = count.at(3);
    count.forget();
    try std.testing.expectEqual(@as(u32, 3), count.at(3));
}

test "a comparator fed the per-instruction count matches on COMP0, not at the charge" {
    var unit = dwt.Dwt{ .trcena = true };
    const halts = dwt.function_bits.action_debug << dwt.function_bits.action_shift;
    _ = unit.write(dwt.offsets.comp0, 400);
    _ = unit.write(dwt.offsets.function0, dwt.match.cycle_counter | halts);
    var count = cycle_count.Count{};
    var matched: ?u32 = null;
    var index: u32 = 0;
    while (index < 50_000) : (index += 1) {
        const now = count.at(0);
        if (unit.cycleCounted(now) != null) {
            matched = now;
            break;
        }
    }
    try std.testing.expectEqual(@as(?u32, 400), matched);
}
