//! The shell's board leaf against a running image (RA8EMU-1119): a headless
//! window runs tests/fixtures/gpio/buttons.elf, which mirrors SW1 onto LED1
//! and never touches the LCD, on a shell whose session is served in-process.
//! The board pane is drawn with no panel frame, a click on SW1 is drawn
//! pressed and reaches the firmware, and LED1 lights in the pane.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const colors_mod = @import("gui_app").colors;
const gui_app = @import("gui_app");
const Live = @import("live_shell.zig").Live;

const board_pane = gui_app.board_pane;

const image = "tests/fixtures/gpio/buttons.elf";
/// The image's clock is 1 GHz, so frames are paid at a thousandth of real time.
const slow: u64 = 1;

test "an image with no LCD output shows the board, its LEDs dark, and a pressed switch" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    const parts = board_pane.Layout.of(try live.boardBody());
    try std.testing.expect(!parts.board.empty());
    try live.step();
    try std.testing.expect(!live.board.hasFrame());
    try std.testing.expectEqual(colors_mod.unseen, live.middle(parts.panel));
    for (parts.leds) |led| try std.testing.expectEqual(dark.led_off, live.middle(led));
    try std.testing.expectEqual(dark.face, live.middle(parts.switches[0]));

    const sw1 = parts.switches[0];
    try live.button(true, sw1.x + 2, sw1.y + 2);
    try live.step();
    try std.testing.expectEqual(dark.pressed_face, live.middle(sw1));
    try std.testing.expectEqual(dark.face, live.middle(parts.switches[1]));
    // Let go off the switch: no click, and it is drawn up again.
    try live.button(false, sw1.x - 6, sw1.y - 6);
    try live.step();
    try std.testing.expectEqual(dark.face, live.middle(sw1));
}

test "with the image running, a click on SW1 lights LED1 in the board pane" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    const parts = board_pane.Layout.of(try live.boardBody());
    try live.click(.run);
    for (0..2) |_| try live.step();
    try std.testing.expect(live.shell.status.run == .running);
    try std.testing.expect(!live.board.leds.on[0]);
    try std.testing.expectEqual(dark.led_off, live.middle(parts.leds[0]));

    try live.clickIn(parts.switches[0]);
    for (0..40) |_| {
        if (live.board.leds.on[0]) break;
        try live.step();
    }
    try std.testing.expect(live.board.leds.on[0]);
    try live.step();
    try std.testing.expectEqual(board_pane.lampOf(board_pane.led_rgb565[0]), live.middle(parts.leds[0]));
    try std.testing.expectEqual(dark.led_off, live.middle(parts.leds[1]));
    try std.testing.expect(live.shell.status.run == .running);
}
