//! The e-paper panel on the SPI line: the word protocol, and the five
//! things dev's model lets pass.
const std = @import("std");
const ra8 = @import("ra8");
const eink = ra8.components.eink;
const proto = ra8.components.eink.wire;

/// Clock one 16-bit word at the panel, MSB first, discarding what it drives.
fn word(panel: *eink.Panel, value: u16) void {
    _ = panel.exchange(@intCast(value >> 8));
    _ = panel.exchange(@intCast(value & 0xFF));
}

/// A command word behind its preamble.
fn command(panel: *eink.Panel, code: proto.Command) void {
    word(panel, proto.preamble.command);
    word(panel, @backingInt(code));
}

/// A data word behind its preamble.
fn data(panel: *eink.Panel, value: u16) void {
    word(panel, proto.preamble.write);
    word(panel, value);
}

/// A read burst: the preamble, the dummy word, then the value.
fn read(panel: *eink.Panel) u16 {
    word(panel, proto.preamble.read);
    _ = panel.exchange(0);
    _ = panel.exchange(0);
    const high = panel.exchange(0);
    const low = panel.exchange(0);
    return (@as(u16, high) << 8) | @as(u16, low);
}

/// The load a well-behaved image performs: one rectangle at 8 bpp.
fn openLoad(panel: *eink.Panel, width: u16, height: u16) void {
    command(panel, .load_area);
    data(panel, 0x0030); // 8 bpp in the format field
    data(panel, 0); // x
    data(panel, 0); // y
    data(panel, width);
    data(panel, height);
}

fn refresh(panel: *eink.Panel, x: u16, y: u16, width: u16, height: u16) void {
    command(panel, .display_area);
    data(panel, x);
    data(panel, y);
    data(panel, width);
    data(panel, height);
    data(panel, 0x0002);
}

test "4 bpp pixels reach a separate glass buffer on refresh" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .load_area);
    data(&panel, 0x0020);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 2);
    data(&panel, 2);
    data(&panel, 0xF321);

    try std.testing.expectEqual(@as(u8, 17), panel.planes.image.pixel(0, 0));
    try std.testing.expectEqual(@as(u8, 0), panel.planes.glass.pixel(0, 0));
    refresh(&panel, 0, 0, 2, 2);
    const expected = [_]u8{ 17, 34, 51, 255 };
    for (0..2) |y| {
        for (0..2) |x| {
            try std.testing.expectEqual(expected[y * 2 + x], panel.planes.glass.pixel(@intCast(x), @intCast(y)));
        }
    }
}

test "8 bpp pixels reach the glass plane pixel for pixel" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    openLoad(&panel, 2, 2);
    data(&panel, 0x2211);
    data(&panel, 0x4433);
    refresh(&panel, 0, 0, 2, 2);

    const expected = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    for (0..2) |y| {
        for (0..2) |x| {
            try std.testing.expectEqual(expected[y * 2 + x], panel.planes.glass.pixel(@intCast(x), @intCast(y)));
        }
    }
}

test "big endian rotated pixels map into the declared panel area" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .load_area);
    data(&panel, 0x0121); // big endian, 4 bpp, rotate 90 degrees
    data(&panel, 4);
    data(&panel, 5);
    data(&panel, 2);
    data(&panel, 2);
    data(&panel, 0x1234);
    refresh(&panel, 4, 5, 2, 2);

    const expected = [_]u8{ 51, 17, 68, 34 };
    for (0..2) |y| {
        for (0..2) |x| {
            try std.testing.expectEqual(expected[y * 2 + x], panel.planes.glass.pixel(@intCast(x + 4), @intCast(y + 5)));
        }
    }
}

test "a panel nothing touched stays out of the report" {
    var panel = eink.Panel.init();
    try std.testing.expect(panel.quiet());
    try std.testing.expect(panel.awake);
    try std.testing.expectEqual(proto.vcom.power_on_mv, panel.vcom_mv);
}

test "the panel drives the line low while the host clocks a command" {
    var panel = eink.Panel.init();
    try std.testing.expectEqual(@as(u8, 0), panel.exchange(0x60));
    try std.testing.expectEqual(@as(u8, 0), panel.exchange(0x00));
    try std.testing.expectEqual(@as(u8, 0), panel.exchange(0x00));
    try std.testing.expectEqual(@as(u8, 0), panel.exchange(0x01));
    try std.testing.expectEqual(@as(u32, 1), panel.commands);
}

test "a word is assembled MSB first, so a half-clocked word is not one" {
    var panel = eink.Panel.init();
    _ = panel.exchange(0x60);
    try std.testing.expectEqual(@as(u32, 0), panel.commands);
    command(&panel, .sys_run);
    try std.testing.expectEqual(@as(u32, 0), panel.commands);
}

test "a refresh is counted with the waveform it named" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .display_area);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 128);
    data(&panel, 128);
    data(&panel, 0x0002);
    try std.testing.expectEqual(@as(u32, 1), panel.refreshes);
    try std.testing.expectEqual(@as(u16, 2), panel.last_waveform);
}

test "a load accounts its pixels at the format the mode word declared" {
    var panel = eink.Panel.init();
    openLoad(&panel, 16, 2);
    data(&panel, 0xAAAA);
    data(&panel, 0x5555);
    try std.testing.expectEqual(@as(u64, 4), panel.pixels);
    try std.testing.expectEqual(@as(u32, 0), panel.overrun);
}

test "a load at 4 bpp puts four pixels in a word, not two" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .load_area);
    data(&panel, 0x0020); // 4 bpp
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 16);
    data(&panel, 2);
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u64, 4), panel.pixels);
}

// A LOAD IS BOUNDED BY THE RECTANGLE IT DECLARED.

test "a pixel word past the rectangle moves nothing and is counted" {
    var panel = eink.Panel.init();
    openLoad(&panel, 2, 1); // two pixels of room
    data(&panel, 0xFFFF); // takes both
    data(&panel, 0xFFFF); // past the end
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u64, 2), panel.pixels);
    try std.testing.expectEqual(@as(u32, 2), panel.overrun);
}

test "the last word in a rectangle takes only the pixels left in it" {
    var panel = eink.Panel.init();
    openLoad(&panel, 3, 1); // three pixels, two per word at 8 bpp
    data(&panel, 0xFFFF);
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u64, 3), panel.pixels);
    try std.testing.expectEqual(@as(u32, 0), panel.overrun);
}

test "an empty rectangle takes no pixels at all" {
    var panel = eink.Panel.init();
    openLoad(&panel, 0, 0);
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u64, 0), panel.pixels);
    try std.testing.expectEqual(@as(u32, 1), panel.overrun);
}

test "ending the load closes the rectangle" {
    var panel = eink.Panel.init();
    openLoad(&panel, 64, 64);
    data(&panel, 0xFFFF);
    command(&panel, .load_end);
    openLoad(&panel, 1, 1);
    data(&panel, 0xFFFF);
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u64, 3), panel.pixels);
    try std.testing.expectEqual(@as(u32, 1), panel.overrun);
}

// A COMMAND NEEDS AN AWAKE PANEL.

test "sleep stops the panel taking commands" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .sleep);
    try std.testing.expect(!panel.awake);
    openLoad(&panel, 8, 8);
    data(&panel, 0xFFFF);
    command(&panel, .display_area);
    data(&panel, 0);
    try std.testing.expectEqual(@as(u64, 0), panel.pixels);
    try std.testing.expectEqual(@as(u32, 0), panel.refreshes);
    try std.testing.expectEqual(@as(u32, 2), panel.asleep);
}

test "sys_run wakes it back up and the next command lands" {
    var panel = eink.Panel.init();
    defer panel.deinit();
    command(&panel, .sleep);
    command(&panel, .display_area);
    command(&panel, .sys_run);
    try std.testing.expect(panel.awake);
    command(&panel, .display_area);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 0);
    data(&panel, 0x0003);
    try std.testing.expectEqual(@as(u32, 1), panel.refreshes);
    try std.testing.expectEqual(@as(u32, 1), panel.asleep);
}

test "a read from a sleeping panel answers nothing" {
    var panel = eink.Panel.init();
    command(&panel, .sleep);
    command(&panel, .vcom);
    data(&panel, proto.vcom.get);
    try std.testing.expectEqual(@as(u16, 0), read(&panel));
}

test "a refused command's data words are not counted as strays" {
    var panel = eink.Panel.init();
    command(&panel, .sleep);
    openLoad(&panel, 8, 8);
    try std.testing.expectEqual(@as(u32, 0), panel.stray);
    try std.testing.expectEqual(@as(u32, 1), panel.asleep);
}

// A REGISTER KEEPS WHAT WAS WRITTEN.

test "a written register reads back" {
    var panel = eink.Panel.init();
    command(&panel, .reg_write);
    data(&panel, 0x1000);
    data(&panel, 0xABCD);
    command(&panel, .reg_read);
    data(&panel, 0x1000);
    try std.testing.expectEqual(@as(u16, 0xABCD), read(&panel));
}

test "a register nothing wrote reads zero" {
    var panel = eink.Panel.init();
    command(&panel, .reg_read);
    data(&panel, 0x2000);
    try std.testing.expectEqual(@as(u16, 0), read(&panel));
}

test "LUTAFSR stays the controller's own" {
    var panel = eink.Panel.init();
    command(&panel, .reg_write);
    data(&panel, proto.reg.lutafsr);
    data(&panel, 0xFFFF);
    try std.testing.expectEqual(@as(u32, 1), panel.read_only);
    command(&panel, .reg_read);
    data(&panel, proto.reg.lutafsr);
    try std.testing.expectEqual(proto.reg.idle, read(&panel));
}

test "a register write rewrites the slot it already has" {
    var panel = eink.Panel.init();
    command(&panel, .reg_write);
    data(&panel, 0x1800);
    data(&panel, 1);
    command(&panel, .reg_write);
    data(&panel, 0x1800);
    data(&panel, 2);
    try std.testing.expectEqual(@as(usize, 1), panel.register_count);
    try std.testing.expectEqual(@as(u16, 2), panel.registerValue(0x1800));
}

test "a table with no room left drops the write and says so" {
    var panel = eink.Panel.init();
    var index: u16 = 0;
    while (index < eink.register_slots + 2) : (index += 1) {
        command(&panel, .reg_write);
        data(&panel, 0x3000 + index);
        data(&panel, index);
    }
    try std.testing.expectEqual(@as(usize, eink.register_slots), panel.register_count);
    try std.testing.expectEqual(@as(u32, 2), panel.spilled);
}

// THE DEVICE-INFO BLOCK ENDS.

test "the device-info block hands over geometry and then runs out" {
    var panel = eink.Panel.init();
    command(&panel, .device_info);
    try std.testing.expectEqual(proto.panel.width, read(&panel));
    try std.testing.expectEqual(proto.panel.height, read(&panel));
    var index: u16 = 2;
    while (index < proto.info.words) : (index += 1) {
        try std.testing.expectEqual(@as(u16, 0), read(&panel));
    }
    try std.testing.expectEqual(@as(u32, 0), panel.overdrain);
    try std.testing.expectEqual(@as(u16, 0), read(&panel));
    try std.testing.expectEqual(@as(u32, 1), panel.overdrain);
}

test "asking for the block again starts it over" {
    var panel = eink.Panel.init();
    command(&panel, .device_info);
    _ = read(&panel);
    command(&panel, .device_info);
    try std.testing.expectEqual(proto.panel.width, read(&panel));
}

// A DATA WORD NEEDS A COMMAND IN FLIGHT.

test "a data word before any command is counted" {
    var panel = eink.Panel.init();
    data(&panel, 0x1234);
    data(&panel, 0x5678);
    try std.testing.expectEqual(@as(u32, 2), panel.stray);
    try std.testing.expectEqual(@as(u32, 0), panel.commands);
}

// VCOM, kept from dev.

test "a vcom set is read back and a get takes no value word" {
    var panel = eink.Panel.init();
    command(&panel, .vcom);
    data(&panel, proto.vcom.set);
    data(&panel, 2000);
    try std.testing.expectEqual(@as(u16, 2000), panel.vcom_mv);
    command(&panel, .vcom);
    data(&panel, proto.vcom.get);
    data(&panel, 9999);
    try std.testing.expectEqual(@as(u16, 2000), panel.vcom_mv);
    try std.testing.expectEqual(@as(u16, 2000), read(&panel));
}

test "an unknown preamble word leaves the framing where it was" {
    var panel = eink.Panel.init();
    word(&panel, 0x4242);
    command(&panel, .sys_run);
    try std.testing.expectEqual(@as(u32, 1), panel.commands);
    try std.testing.expectEqual(@as(u32, 0), panel.stray);
}

test "the panel answers through the SPI device seam" {
    var panel = eink.Panel.init();
    const on_line = panel.device();
    _ = on_line.exchange(0x60);
    _ = on_line.exchange(0x00);
    _ = on_line.exchange(0x00);
    _ = on_line.exchange(0x01);
    try std.testing.expectEqual(@as(u32, 1), panel.commands);
}

test "the panel sits on SPI_B channel 0, where the epaper app drives it" {
    try std.testing.expectEqual(@as(usize, 0), eink.line_channel);
}

test "a resized panel reports its own geometry in the device-info block" {
    var panel = eink.Panel.init();
    panel.planes.resize(.{ .width = 1872, .height = 1404 });
    command(&panel, .device_info);
    try std.testing.expectEqual(@as(u16, 1872), read(&panel));
    try std.testing.expectEqual(@as(u16, 1404), read(&panel));
}
