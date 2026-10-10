//! Tests for src/chip/periph/mstp/drops.zig.
const std = @import("std");
const ra8 = @import("ra8");
const mod = ra8.chip.periph.mstp_drops;

const Log = mod.Log;

/// A gate the test drives directly: the addresses listed here are still
/// stopped, everything else has been ungated.
const Gate = struct {
    stopped: []const u32,

    fn ask(context: *const anyopaque, address: u32) bool {
        const self: *const Gate = @ptrCast(@alignCast(context));
        for (self.stopped) |one| {
            if (one == address) return true;
        }
        return false;
    }
};

const adc = 0x4033_8000;
const dac = 0x4023_3000;

test "a log with nothing in it is empty" {
    const log = Log{};
    try std.testing.expect(log.empty());
}

test "drops on one peripheral land in one entry" {
    var log = Log{};
    log.noteRead("ADC_B", adc);
    log.noteWrite("ADC_B", adc);
    log.noteRead("ADC_B", adc + 4);
    try std.testing.expect(!log.empty());
    try std.testing.expectEqual(@as(usize, 1), log.len);
    try std.testing.expectEqual(@as(u32, 2), log.entries[0].reads);
    try std.testing.expectEqual(@as(u32, 1), log.entries[0].writes);
    // The address kept is the first one refused, which is enough to ask the
    // gate about the peripheral later.
    try std.testing.expectEqual(@as(u32, adc), log.entries[0].address);
}

test "two peripherals get an entry each" {
    var log = Log{};
    log.noteRead("ADC_B", adc);
    log.noteRead("DAC_B", dac);
    try std.testing.expectEqual(@as(usize, 2), log.len);
}

test "a peripheral still stopped is the loud half of the verdict" {
    var log = Log{};
    log.noteRead("ADC_B", adc);
    log.noteWrite("ADC_B", adc);
    const gate = Gate{ .stopped = &.{adc} };
    const verdict = log.verdict(&gate, Gate.ask);
    try std.testing.expect(verdict.anyStopped());
    try std.testing.expect(!verdict.anyProbed());
    try std.testing.expectEqual(@as(u32, 1), verdict.stopped_reads);
    try std.testing.expectEqual(@as(u32, 1), verdict.stopped_writes);
    try std.testing.expectEqualStrings("ADC_B", verdict.last_stopped);
}

test "a peripheral ungated afterwards was probing, not forgetting" {
    var log = Log{};
    log.noteRead("ADC_B", adc);
    log.noteWrite("ADC_B", adc);
    const gate = Gate{ .stopped = &.{} };
    const verdict = log.verdict(&gate, Gate.ask);
    try std.testing.expect(!verdict.anyStopped());
    try std.testing.expect(verdict.anyProbed());
    try std.testing.expectEqual(@as(u32, 1), verdict.probed_reads);
    try std.testing.expectEqual(@as(u32, 1), verdict.probed_writes);
    try std.testing.expectEqualStrings("ADC_B", verdict.last_probed);
}

test "one run can hold both halves at once" {
    var log = Log{};
    log.noteRead("ADC_B", adc);
    log.noteWrite("DAC_B", dac);
    const gate = Gate{ .stopped = &.{dac} };
    const verdict = log.verdict(&gate, Gate.ask);
    try std.testing.expectEqual(@as(u32, 1), verdict.probed_reads);
    try std.testing.expectEqual(@as(u32, 1), verdict.stopped_writes);
    try std.testing.expectEqualStrings("ADC_B", verdict.last_probed);
    try std.testing.expectEqualStrings("DAC_B", verdict.last_stopped);
}

test "drops past the table are counted, and counted as stopped" {
    var log = Log{};
    var name_store: [mod.capacity + 2][8]u8 = undefined;
    var i: usize = 0;
    while (i < mod.capacity + 2) : (i += 1) {
        const name = std.fmt.bufPrint(&name_store[i], "P{d}", .{i}) catch unreachable;
        log.noteRead(name, @intCast(0x4000_0000 + i * 0x100));
    }
    try std.testing.expectEqual(@as(usize, mod.capacity), log.len);
    try std.testing.expectEqual(@as(u32, 2), log.overflow_reads);
    const gate = Gate{ .stopped = &.{} };
    const verdict = log.verdict(&gate, Gate.ask);
    // Nothing in the table is still stopped, so only the overflow is loud.
    try std.testing.expectEqual(@as(u32, 2), verdict.stopped_reads);
    try std.testing.expectEqual(@as(u32, mod.capacity), verdict.probed_reads);
}
