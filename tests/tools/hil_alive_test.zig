//! Covers tools/hil/alive.zig and the alive mode in tools/hil/conf.zig.
const std = @import("std");
const table = @import("example_table");
const hil_conf = table.hil_conf;
const alive = hil_conf.alive;

test "refused matches check_alive's negatives as whole words only" {
    try std.testing.expect(alive.refused("mpu: HardFault at 0x0"));
    try std.testing.expect(alive.refused("i2c NAK"));
    try std.testing.expect(alive.refused("stack overflow in idle"));
    try std.testing.expect(!alive.refused("mpu: fault handled, recovered"));
    try std.testing.expect(!alive.refused("SNAKE ERRORS"));
    try std.testing.expect(!alive.refused("g_hardfault_count"));
}

const conf_text =
    \\HIL_MODE=alive
    \\HIL_BOOT_S=3
    \\HIL_FAULT_EXPECTED=1
;

test "an alive conf passes a run its console does not refuse" {
    const conf = hil_conf.parse(conf_text);
    try std.testing.expect(conf.isAlive());
    const quiet = "console> mpu: fault handled, recovered\n";
    try std.testing.expectEqual(@as(?hil_conf.Judgement, .pass), hil_conf.judge(conf, quiet));
    try std.testing.expectEqual(@as(?hil_conf.Judgement, .pass), hil_conf.judge(conf, ""));
    const loud = "console> boot\nconsole> UsageFault: undefined instruction\n";
    try std.testing.expectEqual(@as(?hil_conf.Judgement, .fail), hil_conf.judge(conf, loud));
}

test "a scrape conf is not alive and still needs its expected text" {
    const conf = hil_conf.parse("HIL_MODE=uart_scrape\nHIL_EXPECT=\"ok\"\n");
    try std.testing.expect(!conf.isAlive());
    try std.testing.expectEqual(@as(?hil_conf.Judgement, null), hil_conf.judge(conf, "console> boot\n"));
}
