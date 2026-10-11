//! Covers tools/example/budgets.zig: which budget each image runs at.
const std = @import("std");
const table = @import("example_table");

const budgets = table.budgets;

test "an image with no override keeps the caller's budget" {
    try std.testing.expectEqualStrings("5000000", budgets.pick("power_profiler.elf", "5000000").?);
    try std.testing.expectEqual(@as(?[]const u8, null), budgets.pick("power_profiler.elf", null));
}

test "a listed image gets its own budget at the default" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("ra8_io_swap_demo.elf", null).?);
}

test "a listed image never runs at less than its own budget" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("ra8_io_swap_demo.elf", "4000000").?);
}

test "a caller asking for more than the override wins" {
    try std.testing.expectEqualStrings("50000000", budgets.pick("ra8_io_swap_demo.elf", "50000000").?);
}

test "a caller budget that does not parse is passed through" {
    try std.testing.expectEqualStrings("lots", budgets.pick("ra8_io_swap_demo.elf", "lots").?);
}

test "every override parses and is named by its ELF" {
    for (budgets.overrides) |entry| {
        try std.testing.expect(std.mem.endsWith(u8, entry.image, ".elf"));
        _ = try std.fmt.parseInt(u64, entry.instructions, 10);
    }
}

test "threadx_cpu1 runs long enough for ten CPU1 kernel ticks" {
    try std.testing.expectEqualStrings("40000000", budgets.pick("threadx_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("40000000", budgets.pick("threadx_cpu1.elf", "2000000").?);
}

test "txm_manager_cpu1 runs long enough for ten module runs" {
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_manager_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_manager_cpu1.elf", "2000000").?);
}

test "txm_fault_cpu1 runs long enough for the fault and ten manager ticks after it" {
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_fault_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_fault_cpu1.elf", "2000000").?);
}

test "the M85 module manager images run long enough for ten runs and the fault" {
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_manager_m85.elf", null).?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_fault_m85.elf", "2000000").?);
}

test "txm_helium_m85 runs long enough for ten Helium switches" {
    try std.testing.expectEqualStrings("30000000", budgets.pick("txm_helium_m85.elf", null).?);
    try std.testing.expectEqualStrings("30000000", budgets.pick("txm_helium_m85.elf", "2000000").?);
}

test "txm_reload_cpu1 runs long enough for two loads of ten runs each" {
    try std.testing.expectEqualStrings("120000000", budgets.pick("txm_reload_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("120000000", budgets.pick("txm_reload_cpu1.elf", "2000000").?);
}

test "the rebasing ThreadX modules run long enough for their verdict" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("txm_table_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("20000000", budgets.pick("txm_table_cpu1.elf", "2000000").?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_rpc_cpu1.elf", null).?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_rpc_cpu1.elf", "2000000").?);
}

test "txm_dual_mailbox runs long enough for the calls, the fault and ten ticks after it" {
    try std.testing.expectEqualStrings("120000000", budgets.pick("txm_dual_mailbox.elf", null).?);
    try std.testing.expectEqualStrings("120000000", budgets.pick("txm_dual_mailbox.elf", "2000000").?);
}

test "the SD examples run long enough to read back their card" {
    try std.testing.expectEqualStrings("20000000", budgets.pick("epub_open.elf", null).?);
    try std.testing.expectEqualStrings("80000000", budgets.pick("epub_toc.elf", "2000000").?);
    try std.testing.expectEqualStrings("10000000", budgets.pick("ra8_io_sd_demo.elf", null).?);
    try std.testing.expectEqualStrings("20000000", budgets.pick("tz_secure_only_sd.elf", null).?);
    try std.testing.expectEqualStrings("20000000", budgets.pick("import_reader.elf", null).?);
    try std.testing.expectEqualStrings("20000000", budgets.pick("import_reader.elf", "2000000").?);
}

test "rot_verify_hil runs long enough for its software signature check" {
    try std.testing.expectEqualStrings("200000000", budgets.pick("rot_verify_hil.elf", null).?);
}

test "psa_crypto_hil runs long enough for its software KATs" {
    try std.testing.expectEqualStrings("400000000", budgets.pick("psa_crypto_hil.elf", null).?);
}

test "the LED-only blinks run long enough to toggle twice" {
    try std.testing.expectEqualStrings("10000000", budgets.pick("blink_hal.elf", null).?);
    try std.testing.expectEqualStrings("10000000", budgets.pick("blink_ra8p1.elf", null).?);
}

test "threadx_blink runs long enough for thread A's second toggle" {
    try std.testing.expectEqualStrings("600000000", budgets.pick("threadx_blink.elf", null).?);
    try std.testing.expectEqualStrings("600000000", budgets.pick("threadx_blink.elf", "2000000").?);
}

test "txm_sd_hello_m85 gets the module images' budget" {
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_sd_hello_m85.elf", null).?);
    try std.testing.expectEqualStrings("60000000", budgets.pick("txm_sd_hello_m85.elf", "2000000").?);
}
