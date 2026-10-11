//! Per-image emulator flags for the example table (RA8EMU-84).
//!
//! The LSM6DSO and the MAX17048 sit on a Click module, not on the EK-RA8D2,
//! so the emulator leaves 0x6B and 0x36 silent unless the run passes
//! `--click`, the same as a bench with no module fitted. The examples written
//! for that module (battery_monitor_demo, smbus_demo, imu_lsm6dso_demo) NAK
//! without it, which says nothing about the model, so the table fits the
//! module for them and only for them.
//!
//! import_reader differs from the EPUB demos: it reads a source file that
//! must already be on the card. Its EIL/matrix harness exports the baked
//! image as RA8_EMU_IMPORT_READER_IMG, which the example table also consumes.
//!
//! The SD card on the SPI line starts blank, like a card fresh out of its
//! packet, and a firmware that only mounts reports "FAIL mount" on it. The
//! examples that provision their own files onto an existing FAT volume
//! (epub_open, epub_toc, tz_secure_only_sd) get a card formatted FAT16, the
//! filesystem that fits the default 32 MB card (RA8EMU-82). sd_font_render
//! self-provisions its font onto "any FAT card" but never formats one, so it
//! gets the same card (RA8EMU-400).
//!
//! ra8_io_sd_demo formats the card FAT32 itself before it mounts, and its
//! formatter gives up without touching the card on anything under 4 GB, so it
//! gets a blank 4096 MB card, the smallest size it formats (RA8EMU-82).
//!
//! tz_nsc_cgc_usb's verdict is its NS host's USB self-loop round count, and
//! the bench gets there with the loop cable fitted and a boot dwell before
//! the probe window. The table fits the loop and runs two seconds of target
//! time: rounds start between 1.0 and 1.5 s and read 358 at 2.0 s
//! (RA8EMU-289). A caller budget passes --instructions, which wins
//! over --ms, so that row only reaches its verdict at the table's own budget.
//!
//! pagecache mounts with format-if-blank and its README asks for a blank
//! 64 MB FAT32 card; on the default blank card the mount fails (g_pc_err 3)
//! and the heartbeat never moves, so it gets that card (RA8EMU-400).
//!
//! cpu1_pingpong_ra8p1 is built for the RA8P1, whose map and CPU1 window the
//! default RA8D2 part does not carry, so it runs on `--device ra8p1`
//! (RA8EMU-135).
//!
//! widget_keyboard_demo brings its GLCDC panel up before the keyboard legs,
//! and the panel's power-on delays are counted in modelled milliseconds that
//! the 2M default never reaches: at 200M instructions it still reads only
//! "boot". A second of target time prints "keyboard widget PASS" on the
//! README's console-only run (500 ms was the shortest seen to, RA8EMU-400).
//!
//! blink_m33_hal and lowpower_holdpage hand LED1 to the M33,
//! which the M85 releases only after its own low-power set-up; at 10M
//! instructions no LED has moved. A second of target time shows the M33's
//! LED1 (RA8EMU-400). gpt_edge_capture_count's liveness word, the GPT
//! free-run tick its README names, reads 0 at the 2M default and about one
//! per 5 ms of target time, so it gets 200 ms. ereader_m33's mailbox shows
//! all three page turns done by 200 ms too. lcd_draw_x and
//! display_pal_animation get a second so their probes read a painted frame.
//! lcd_color_cycle gets two: its backdrop is red near 1.0 s, green by 1.6 s
//! and blue by 2.0 s (RA8EMU-489).
//! usb_host_file_ops mounts a drive on the HS host jack: a blank FAT12
//! stick there and two seconds let it finish all nine file steps.
//! txm_sd_hello_m85 reads a signed module off the SDHI card, so it runs
//! with `--sd-dir` on the directory beside it named in card_dirs; the
//! modules corpus copies txm_hello_m33.ra8app there (RA8EMU-158). With no
//! such directory it runs on the bare card and reports "FAIL open".
const std = @import("std");

pub const Extra = struct {
    image: []const u8,
    flags: []const []const u8,
};

pub const CardDir = struct {
    image: []const u8,
    dir: []const u8,
};

pub const CardImage = struct {
    image: []const u8,
    environment: []const u8,
};

const click = [_][]const u8{"--click"};
const formatted = [_][]const u8{ "--sd-new", "fat16" };
const large_card = [_][]const u8{ "--sd-size", "4096" };
const fat32_card = [_][]const u8{ "--sd-size", "64", "--sd-new", "fat32" };
const usb_loop = [_][]const u8{ "--usb-loop", "--ms", "2000" };
const ra8p1 = [_][]const u8{ "--device", "ra8p1" };
const one_second = [_][]const u8{ "--ms", "1000" };
const fifth_second = [_][]const u8{ "--ms", "200" };
const two_seconds = [_][]const u8{ "--ms", "2000" };
const usb_stick = [_][]const u8{ "--usb-disk", "blank", "--ms", "2000" };

pub const card_images = [_]CardImage{
    .{ .image = "import_reader.elf", .environment = "RA8_EMU_IMPORT_READER_IMG" },
};

/// Images whose SDHI card is built from a directory next to the image.
pub const card_dirs = [_]CardDir{
    .{ .image = "txm_sd_hello_m85.elf", .dir = "txm_sd_hello_m85.sd" },
};

/// Images that need hardware the default board does not fit, and the flags
/// that fit it.
pub const extras = [_]Extra{
    .{ .image = "battery_monitor_demo.elf", .flags = &click },
    .{ .image = "blink_m33_hal.elf", .flags = &one_second },
    .{ .image = "cpu1_pingpong_ra8p1.elf", .flags = &ra8p1 },
    .{ .image = "epub_open.elf", .flags = &formatted },
    .{ .image = "display_pal_animation.elf", .flags = &one_second },
    .{ .image = "epub_toc.elf", .flags = &formatted },
    .{ .image = "ereader_m33.elf", .flags = &fifth_second },
    .{ .image = "gpt_edge_capture_count.elf", .flags = &fifth_second },
    .{ .image = "imu_lsm6dso_demo.elf", .flags = &click },
    .{ .image = "lcd_draw_x.elf", .flags = &one_second },
    .{ .image = "lcd_color_cycle.elf", .flags = &two_seconds },
    .{ .image = "lowpower_holdpage.elf", .flags = &one_second },
    .{ .image = "pagecache.elf", .flags = &fat32_card },
    .{ .image = "ra8_io_sd_demo.elf", .flags = &large_card },
    .{ .image = "sd_font_render.elf", .flags = &formatted },
    .{ .image = "smbus_demo.elf", .flags = &click },
    .{ .image = "tz_nsc_cgc_usb.elf", .flags = &usb_loop },
    .{ .image = "tz_secure_only_sd.elf", .flags = &formatted },
    .{ .image = "usb_host_file_ops.elf", .flags = &usb_stick },
    .{ .image = "widget_keyboard_demo.elf", .flags = &one_second },
};

/// A required input card path for image, when its harness supplied one.
pub fn cardImage(image: []const u8, env: *const std.process.Environ.Map) ?[]const u8 {
    for (card_images) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return env.get(entry.environment);
    }
    return null;
}

/// The extra flags to run image with; empty for an image not listed.
pub fn flags(image: []const u8) []const []const u8 {
    for (extras) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry.flags;
    }
    return &.{};
}

/// The card directory name beside image, when it has one.
pub fn cardDir(image: []const u8) ?[]const u8 {
    for (card_dirs) |entry| {
        if (std.mem.eql(u8, entry.image, image)) return entry.dir;
    }
    return null;
}
