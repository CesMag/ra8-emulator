//! Covers src/interfaces/cli/report/watchdog.zig: the arithmetic behind the
//! cadence line. The printing itself takes a file writer, so what is pinned
//! here is the rate behind it, which is where the judgement lives: a run with
//! no refresh and a run with no SysTick period both have no cadence at all,
//! and the two readings this line was written to make legible read the way
//! the firmware's own declared period reads.
const std = @import("std");
const cli_app = @import("cli_app");

const report_watchdog = cli_app.report_watchdog;

test "a run that never refreshed has no cadence" {
    try std.testing.expectEqual(@as(?f64, null), report_watchdog.everyPeriods(0, 200));
}

test "a run whose SysTick never ran has no cadence, rather than dividing by zero" {
    try std.testing.expectEqual(@as(?f64, null), report_watchdog.everyPeriods(5, 0));
}

test "the wdt_supervisor_demo reading is one refresh every 0.7 periods" {
    const every = report_watchdog.everyPeriods(296, 200).?;
    try std.testing.expect(every > 0.67 and every < 0.68);
}

test "the cadence the firmware asks for reads as one every 50 periods" {
    const every = report_watchdog.everyPeriods(4, 200).?;
    try std.testing.expectEqual(@as(f64, 50.0), every);
}

test "a single refresh spans the whole run" {
    const every = report_watchdog.everyPeriods(1, 200).?;
    try std.testing.expectEqual(@as(f64, 200.0), every);
}
