//! Covers tools/hil/conf.zig against the shapes the firmware's hil.conf
//! files use.
const std = @import("std");
const table = @import("example_table");
const hil_conf = table.hil_conf;

const uart =
    \\# touch_demo
    \\HIL_MODE=uart_scrape
    \\HIL_EXPECT="touch: open=OK"
    \\HIL_EXPECT_NEGATIVE="FAIL|HardFault|TIMEOUT|hw_init"
    \\HIL_TIMEOUT_S=15
    \\
;

const probe =
    \\HIL_MODE=jlink_memprobe
    \\HIL_PROBE_SYMBOL="g_threadx_blink_tick"
    \\HIL_PROBE_MIN_ADVANCE=3
    \\HIL_PROBE_SECONDS=4
    \\HIL_PROBE_FAILURE_SYMBOL=g_bad
    \\HIL_PROBE_MAX_FAILURE=0
;

test "a uart_scrape conf gives the expected text, the negatives and the timeout" {
    const conf = hil_conf.parse(uart);
    try std.testing.expectEqualStrings("uart_scrape", conf.mode.?);
    try std.testing.expectEqualStrings("touch: open=OK", conf.expect.?);
    try std.testing.expectEqualStrings("FAIL|HardFault|TIMEOUT|hw_init", conf.expect_negative.?);
    try std.testing.expectEqual(@as(?u32, 15), conf.timeout_s);
    try std.testing.expectEqual(@as(?[]const u8, null), conf.probe_symbol);
}

test "a memprobe conf gives the probe keys, quoted or not" {
    const conf = hil_conf.parse(probe);
    try std.testing.expectEqualStrings("g_threadx_blink_tick", conf.probe_symbol.?);
    try std.testing.expectEqual(@as(?u32, 3), conf.probe_min_advance);
    try std.testing.expectEqualStrings("g_bad", conf.probe_failure_symbol.?);
    try std.testing.expectEqual(@as(?u32, 0), conf.probe_max_failure);
}

test "expected and refused match the console the way the bench scrapes it" {
    const conf = hil_conf.parse(uart);
    try std.testing.expect(conf.expected("boot\ntouch: open=OK\n"));
    try std.testing.expect(!conf.expected("touch: open=ERR"));
    try std.testing.expect(conf.refused("x HardFault at 0"));
    try std.testing.expect(!conf.refused("touch: open=OK"));
}

test "comments, blanks, CRLF, unknown keys and bad numbers are ignored" {
    const conf = hil_conf.parse("# c\r\n\r\nHIL_SELF_BUILD=1\r\nHIL_TIMEOUT_S=soon\r\nnot a line\r\nHIL_MODE = x \r\n");
    try std.testing.expectEqualStrings("x", conf.mode.?);
    try std.testing.expectEqual(@as(?u32, null), conf.timeout_s);
    try std.testing.expect(!conf.refused("anything"));
    try std.testing.expect(!conf.expected("anything"));
}

const streamed =
    \\loaded 17056 bytes, vectors at 0x02000000
    \\console> touch-demo: boot
    \\console> touch: open=OK
    \\SCI console: 2 line(s), last "touch: open=OK"
    \\
;

test "judge passes on the expected text in any streamed console line" {
    try std.testing.expectEqual(@as(?hil_conf.Judgement, .pass), hil_conf.judge(hil_conf.parse(uart), streamed));
}

test "judge fails on a negative even when the expected text also printed" {
    const report = streamed ++ "console> HardFault: pc 0x02000100\n";
    try std.testing.expectEqual(@as(?hil_conf.Judgement, .fail), hil_conf.judge(hil_conf.parse(uart), report));
}

test "judge reads only console lines and decides nothing without a match" {
    const report = "stopped at 0x0: TIMEOUT in a report line\nconsole> touch-demo: boot\n";
    try std.testing.expectEqual(@as(?hil_conf.Judgement, null), hil_conf.judge(hil_conf.parse(uart), report));
    try std.testing.expectEqual(@as(?hil_conf.Judgement, null), hil_conf.judge(hil_conf.parse(probe), streamed));
}

test "a row's hil verdict wins over the last-line rule but not over a stop" {
    var row: table.Row = .{ .console = "boot OK", .hil = .fail };
    try std.testing.expectEqual(table.Verdict.fail, row.verdict());
    row = .{ .hil = .pass };
    try std.testing.expectEqual(table.Verdict.pass, row.verdict());
    row = .{ .hil = .pass, .stopped = "0x02000100" };
    try std.testing.expectEqual(table.Verdict.fail, row.verdict());
}

test "foo.elf's conf sits beside it as foo.hil.conf" {
    const name = try table.confName(std.testing.allocator, "/c/touch_demo.elf");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("/c/touch_demo.hil.conf", name);
}

test "floorMs is the probe's boot dwell plus window, else the scrape timeout, capped" {
    try std.testing.expectEqual(@as(?u32, 15_000), hil_conf.parse(uart).floorMs());
    try std.testing.expectEqual(@as(?u32, 4_000), hil_conf.parse(probe).floorMs());
    const epub = hil_conf.parse("HIL_PROBE_SECONDS=5\nHIL_PROBE_BOOT_S=12\nHIL_TIMEOUT_S=60\n");
    try std.testing.expectEqual(@as(?u32, 17_000), epub.floorMs());
    const wdt = hil_conf.parse("HIL_MODE=uart_scrape\nHIL_TIMEOUT_S=60\n");
    try std.testing.expectEqual(@as(?u32, 60_000), wdt.floorMs());
    const long = hil_conf.parse("HIL_TIMEOUT_S=240\n");
    try std.testing.expectEqual(@as(?u32, hil_conf.Conf.max_floor_ms), long.floorMs());
    try std.testing.expectEqual(@as(?u32, null), hil_conf.parse("HIL_MODE=alive\n").floorMs());
}

test "floorMs falls back to the bench window for the conf's mode" {
    const scrape = hil_conf.parse("HIL_MODE=uart_scrape\nHIL_EXPECT=\"ok\"\n");
    try std.testing.expectEqual(@as(?u32, 10_000), scrape.floorMs());
    const watch = hil_conf.parse("HIL_MODE=jlink_memprobe\nHIL_PROBE_SYMBOL=\"g\"\n");
    try std.testing.expectEqual(@as(?u32, 3_000), watch.floorMs());
    const booted = hil_conf.parse("HIL_MODE=jlink_memprobe\nHIL_PROBE_BOOT_S=4\n");
    try std.testing.expectEqual(@as(?u32, 7_000), booted.floorMs());
    const named = hil_conf.parse("HIL_MODE=uart_scrape\nHIL_TIMEOUT_S=15\n");
    try std.testing.expectEqual(@as(?u32, 15_000), named.floorMs());
}

test "a uart_scrape conf ends its run on the expected line, other modes on none" {
    const scrape = hil_conf.parse(uart);
    try std.testing.expectEqualStrings("touch: open=OK", scrape.untilLine().?);
    try std.testing.expectEqual(@as(?[]const u8, null), hil_conf.parse(probe).untilLine());
    const bare = hil_conf.parse("HIL_MODE=uart_scrape\n");
    try std.testing.expectEqual(@as(?[]const u8, null), bare.untilLine());
}

test "HIL_PROVISION_WIFI=1 asks for the bench's Wi-Fi reply" {
    const wifi = hil_conf.parse("HIL_MODE=uart_scrape\nHIL_PROVISION_WIFI=1\n");
    try std.testing.expect(wifi.provision_wifi);
    try std.testing.expectEqualStrings(hil_conf.Conf.bench_wifi_reply, wifi.consoleReply().?);
    try std.testing.expect(hil_conf.parse(uart).consoleReply() == null);
    try std.testing.expect(hil_conf.parse("HIL_PROVISION_WIFI=0\n").consoleReply() == null);
}
