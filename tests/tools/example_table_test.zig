//! The example table reads emulator reports the way they print today.
const std = @import("std");
const table = @import("example_table");

const console_report =
    \\loaded 56980 bytes, vectors at 0x02000000, sp 0x220FFF00, pc 0x02003570
    \\peripheral accesses: 80 read, 142 written, 1 distinct unmodelled registers
    \\SCI console: 2 line(s), last "pp: profile OK"
    \\GPIO LEDs: [LED1 BLUE  P600 ON x1] [LED2 GREEN P303 OFF x0] [LED3 RED   PA07 OFF x0]
    \\
;

const fault_report =
    \\peripheral accesses: 48 read, 182 written, 0 distinct unmodelled registers
    \\GPIO LEDs: none driven
    \\stopped at pc 0x00000000: Invalid memory fetch (UC_ERR_FETCH_UNMAPPED)
    \\  fetch of 4 bytes at 0x00000000
    \\
;

test "a console OK line passes and its fields are read" {
    const row = table.parse(console_report);
    try std.testing.expectEqualStrings("pp: profile OK", row.console.?);
    try std.testing.expectEqual(@as(?u32, 1), row.unmodelled);
    try std.testing.expectEqual(@as(usize, 1), row.leds().len);
    try std.testing.expectEqualStrings("LED1", row.leds()[0]);
    try std.testing.expectEqual(table.Verdict.pass, row.verdict());
}

test "a run that stopped on a fault fails" {
    const row = table.parse(fault_report);
    try std.testing.expectEqualStrings("pc 0x00000000", row.stopped.?);
    try std.testing.expectEqual(@as(usize, 0), row.leds().len);
    try std.testing.expectEqual(@as(?u32, 0), row.unmodelled);
    try std.testing.expectEqual(table.Verdict.fail, row.verdict());
}

test "LEDs with no console line are unknown, and FAIL fails" {
    const leds = table.parse("GPIO LEDs: [LED1 BLUE  P600 ON x1] [LED2 GREEN P303 ON x1]\n");
    try std.testing.expectEqual(@as(usize, 2), leds.leds().len);
    try std.testing.expectEqual(table.Verdict.unknown, leds.verdict());
    const failed = table.parse("SCI console: 1 line(s), last \"aes: FAIL\"\n");
    try std.testing.expectEqual(table.Verdict.fail, failed.verdict());
}

test "an LED that toggled twice with no console passes as a blink" {
    const blink = table.parse("GPIO LEDs: [LED1 BLUE  P600 ON x3] [LED2 GREEN P303 OFF x0] [LED3 RED   PA07 OFF x0]\n");
    try std.testing.expect(blink.blinking);
    try std.testing.expectEqual(table.Verdict.pass, blink.verdict());
    const turned_off = table.parse("GPIO LEDs: [LED1 BLUE  P600 OFF x2]\n");
    try std.testing.expectEqual(table.Verdict.pass, turned_off.verdict());
}

test "an LED set once and left stays unknown, and a blink that faulted fails" {
    const stuck = table.parse("GPIO LEDs: [LED1 BLUE  P600 ON x1] [LED2 GREEN P303 OFF x0]\n");
    try std.testing.expect(!stuck.blinking);
    try std.testing.expectEqual(table.Verdict.unknown, stuck.verdict());
    const faulted = table.parse("GPIO LEDs: [LED1 BLUE  P600 ON x5]\nstopped at pc 0x00000000: fetch\n");
    try std.testing.expectEqual(table.Verdict.fail, faulted.verdict());
    try std.testing.expectEqual(table.Verdict.unknown, table.parse("GPIO LEDs: none driven\n").verdict());
}

test "a row prints in table order" {
    var buffer: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buffer);
    try table.writeRow(&stream, "power_profiler.elf", table.parse(console_report));
    try std.testing.expectEqualStrings(
        "| power_profiler.elf | pass | budget | pp: profile OK | LED1 | 1 |\n",
        stream.buffered(),
    );
}

const dir = [_][]const u8{ "blink.elf", "cpu1_pingpong.elf", "cpu1_pingpong_cpu1.elf", "orphan_cpu1.elf" };

test "a CPU0 image's CPU1 half is the same stem with _cpu1" {
    const name = try table.cpu1Name(std.testing.allocator, "cpu1_pingpong.elf");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("cpu1_pingpong_cpu1.elf", name);
}

test "a CPU1 half with its CPU0 image beside it gets no row of its own" {
    const a = std.testing.allocator;
    try std.testing.expect(try table.isSecondHalf(a, "cpu1_pingpong_cpu1.elf", &dir));
    try std.testing.expect(!try table.isSecondHalf(a, "cpu1_pingpong.elf", &dir));
    try std.testing.expect(!try table.isSecondHalf(a, "orphan_cpu1.elf", &dir));
}

test "a CPU0 image runs with its CPU1 half, and a lone image runs alone" {
    const a = std.testing.allocator;
    const second = (try table.pairedWith(a, "cpu1_pingpong.elf", &dir)).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("cpu1_pingpong_cpu1.elf", second);
    try std.testing.expectEqual(@as(?[]const u8, null), try table.pairedWith(a, "blink.elf", &dir));
    try std.testing.expectEqual(@as(?[]const u8, null), try table.pairedWith(a, "orphan_cpu1.elf", &dir));
}

test "a CPU0 image whose stem ends in _cpu1 still finds its CPU1 half" {
    const a = std.testing.allocator;
    const names = [_][]const u8{ "threadx_cpu1.elf", "threadx_cpu1_cpu1.elf" };
    try std.testing.expect(!try table.isSecondHalf(a, "threadx_cpu1.elf", &names));
    try std.testing.expect(try table.isSecondHalf(a, "threadx_cpu1_cpu1.elf", &names));
    const second = (try table.pairedWith(a, "threadx_cpu1.elf", &names)).?;
    defer a.free(second);
    try std.testing.expectEqualStrings("threadx_cpu1_cpu1.elf", second);
}

const tz_dir = [_][]const u8{ "blink.elf", "tz_demo.elf", "tz_demo_ns.elf", "lone_ns.elf" };

test "a Secure image's Non-Secure half is the same stem with _ns" {
    const name = try table.nsName(std.testing.allocator, "tz_demo.elf");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("tz_demo_ns.elf", name);
}

test "a Non-Secure half with its Secure image beside it gets no row of its own" {
    const a = std.testing.allocator;
    try std.testing.expect(try table.isSecondHalf(a, "tz_demo_ns.elf", &tz_dir));
    try std.testing.expect(!try table.isSecondHalf(a, "tz_demo.elf", &tz_dir));
    try std.testing.expect(!try table.isSecondHalf(a, "lone_ns.elf", &tz_dir));
}

test "a Secure image runs with its Non-Secure half, and a lone image runs alone" {
    const a = std.testing.allocator;
    const ns = (try table.nsPairedWith(a, "tz_demo.elf", &tz_dir)).?;
    defer a.free(ns);
    try std.testing.expectEqualStrings("tz_demo_ns.elf", ns);
    try std.testing.expectEqual(@as(?[]const u8, null), try table.nsPairedWith(a, "blink.elf", &tz_dir));
    try std.testing.expectEqual(@as(?[]const u8, null), try table.nsPairedWith(a, "lone_ns.elf", &tz_dir));
    try std.testing.expectEqual(@as(?[]const u8, null), try table.pairedWith(a, "tz_demo.elf", &tz_dir));
}

// tools/hil/conf.zig has its own file; tests/all.zig is at 400 lines.
test {
    _ = @import("hil_conf_test.zig");
    _ = @import("hil_alive_test.zig");
}

test "untilFor stops a uart_scrape run on its expected line" {
    const conf = table.hil_conf.parse("HIL_MODE=uart_scrape\nHIL_EXPECT=\"sbns: verify+enter NS\"\n");
    try std.testing.expectEqualStrings("sbns: verify+enter NS", table.untilFor(conf, null).?);
    try std.testing.expect(table.untilFor(null, null) == null);
}

test "untilFor keeps the budget when a probe has to watch past the line" {
    const conf = table.hil_conf.parse("HIL_MODE=uart_scrape\nHIL_EXPECT=\"sbns: verify+enter NS\"\n");
    const probe = table.probes.fromConf("secure_boot_ns_hil.elf", "g_sbns_ns_alive", 50, "g_sbns_denied", 0);
    try std.testing.expect(probe != null);
    try std.testing.expect(table.untilFor(conf, probe) == null);
}
