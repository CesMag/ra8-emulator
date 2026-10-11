//! Covers tools/example/options.zig: which images run with extra flags.
const std = @import("std");
const table = @import("example_table");

const options = table.options;

test "an image with no entry runs with no extra flags" {
    try std.testing.expectEqual(@as(usize, 0), options.flags("blink_hal.elf").len);
}

test "the RA8P1-built examples run on the ra8p1" {
    for ([_][]const u8{ "cpu1_pingpong_ra8p1.elf", "npu_vela_conv.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("--device", got[0]);
        try std.testing.expectEqualStrings("ra8p1", got[1]);
    }
}

test "the Click-module examples run with the module fitted" {
    for ([_][]const u8{ "battery_monitor_demo.elf", "imu_lsm6dso_demo.elf", "smbus_demo.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("--click", got[0]);
    }
}

test "a match is on the whole file name" {
    try std.testing.expectEqual(@as(usize, 0), options.flags("smbus_demo").len);
    try std.testing.expectEqual(@as(usize, 0), options.flags("xsmbus_demo.elf").len);
}

test "the examples that mount an existing volume get a FAT16 card" {
    for ([_][]const u8{ "epub_open.elf", "epub_toc.elf", "sd_font_render.elf", "tz_secure_only_sd.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("--sd-new", got[0]);
        try std.testing.expectEqualStrings("fat16", got[1]);
    }
}

test "the example that formats its own FAT32 volume gets a 4 GB card" {
    const got = options.flags("ra8_io_sd_demo.elf");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("--sd-size", got[0]);
    try std.testing.expectEqualStrings("4096", got[1]);
}

test "import_reader receives its fixture card from the emulator harness" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("RA8_EMU_IMPORT_READER_IMG", "/tmp/import_reader.img");
    try std.testing.expectEqualStrings(
        "/tmp/import_reader.img",
        options.cardImage("import_reader.elf", &env).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), options.cardImage("epub_open.elf", &env));
}

test "the TrustZone USB pair runs with the loop cable for two seconds" {
    const got = options.flags("tz_nsc_cgc_usb.elf");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("--usb-loop", got[0]);
    try std.testing.expectEqualStrings("--ms", got[1]);
    try std.testing.expectEqualStrings("2000", got[2]);
}

test "the RA8P1 dual-core pair runs on the RA8P1 part" {
    const extra = options.flags("cpu1_pingpong_ra8p1.elf");
    try std.testing.expectEqual(@as(usize, 2), extra.len);
    try std.testing.expectEqualStrings("--device", extra[0]);
    try std.testing.expectEqualStrings("ra8p1", extra[1]);
    try std.testing.expectEqual(@as(usize, 0), options.flags("cpu1_pingpong.elf").len);
}

test "pagecache gets the blank 64 MB FAT32 card its README asks for" {
    const got = options.flags("pagecache.elf");
    const want = [_][]const u8{ "--sd-size", "64", "--sd-new", "fat32" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "widget_keyboard_demo runs a second of target time for its panel bring-up" {
    const got = options.flags("widget_keyboard_demo.elf");
    const want = [_][]const u8{ "--ms", "1000" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "the M33 LED and display examples run a second of target time" {
    for ([_][]const u8{ "blink_m33_hal.elf", "lowpower_holdpage.elf", "lcd_draw_x.elf", "display_pal_animation.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("--ms", got[0]);
        try std.testing.expectEqualStrings("1000", got[1]);
    }
}

test "gpt_edge_capture_count and ereader_m33 run 200 ms" {
    for ([_][]const u8{ "gpt_edge_capture_count.elf", "ereader_m33.elf" }) |image| {
        const got = options.flags(image);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("200", got[1]);
    }
}

test "lcd_color_cycle runs two seconds of target time" {
    const flags = options.flags("lcd_color_cycle.elf");
    try std.testing.expectEqual(@as(usize, 2), flags.len);
    try std.testing.expectEqualStrings("--ms", flags[0]);
    try std.testing.expectEqualStrings("2000", flags[1]);
}

test "usb_host_file_ops gets a blank stick on the host jack" {
    const flags = options.flags("usb_host_file_ops.elf");
    try std.testing.expectEqual(@as(usize, 4), flags.len);
    try std.testing.expectEqualStrings("--usb-disk", flags[0]);
    try std.testing.expectEqualStrings("blank", flags[1]);
    try std.testing.expectEqualStrings("--ms", flags[2]);
    try std.testing.expectEqualStrings("2000", flags[3]);
}

test "the SD hello module image reads its card from the directory beside it" {
    try std.testing.expectEqualStrings("txm_sd_hello_m85.sd", options.cardDir("txm_sd_hello_m85.elf").?);
    try std.testing.expectEqual(@as(?[]const u8, null), options.cardDir("txm_manager_m85.elf"));
    try std.testing.expectEqual(@as(usize, 0), options.flags("txm_sd_hello_m85.elf").len);
}
