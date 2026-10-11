//! The shell opens another image from its window (RA8EMU-959): on a shell
//! whose session is served in-process, the way ra8_gui's is, the shortcut
//! asks the window for the picker, and a path the picker sends back is
//! loaded over the image in use. The new image comes up halted at its reset
//! vector, with Run dark even when it was lit; a file the session refuses,
//! or one that never reaches it, leaves the image in use running.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Live = @import("live_shell.zig").Live;

const proto = ra8.rpc.session.rpc;
const Refusal = gui_app.status.bar.Refusal;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
const first = "tests/fixtures/gpio/blink.elf";
/// The image picked over it; it comes up out of reset somewhere else.
const second = "tests/fixtures/sections/fault_crashlog_hil.elf";
const second_name = "fault_crashlog_hil.elf";
/// Not an image at all.
const not_elf = "tests/fixtures/sections/README.md";
const slow: u64 = 1;

/// Where `image` comes up out of reset, read from a shell opened on it.
fn resetPc(image: []const u8) !u32 {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    return live.pc();
}

/// Step until the status bar names `name` and the core has been read
/// again after batch `serial`.
fn untilNamed(live: *Live, name: []const u8, serial: u32) !void {
    for (0..30) |_| {
        if (live.shell.status.image) |*image| if (std.mem.eql(u8, image.name(), name)) return live.untilRead(serial);
        try live.step();
    }
    return error.NeverLoaded;
}

fn statusLine(live: *const Live, buf: []u8) ![]const u8 {
    return live.shell.status.text(live.link.state, buf);
}

test "the shortcut puts the OS's picker up, and the title names the image in use" {
    var live: Live = undefined;
    try live.open(first, slow);
    defer live.deinit();
    try std.testing.expectEqualStrings("blink.elf - ra8 emulator", live.window.title());
    try live.window.feed(.{ .key = .{ .code = 'o', .down = true } });
    try live.step();
    try std.testing.expectEqual(@as(u32, 0), live.window.pickers);
    try live.window.feed(.{ .key = .{ .code = 'o', .down = true, .primary = true } });
    try live.step();
    try live.step();
    try std.testing.expectEqual(@as(u32, 1), live.window.pickers);
}

test "a picked image replaces the one in use and comes up halted at its reset vector" {
    const want = try resetPc(second);
    var live: Live = undefined;
    try live.open(first, slow);
    defer live.deinit();
    try std.testing.expect(live.pc() != want);
    const serial = live.registers.cores[0].serial;
    try live.window.feed(.{ .picked = second });
    try untilNamed(&live, second_name, serial);
    try std.testing.expectEqual(want, live.pc());
    const halt = live.shell.status.run.halted;
    try std.testing.expectEqual(want, halt.address);
    try std.testing.expectEqual(@as(?proto.StopReason, null), halt.reason);
    try std.testing.expectEqual(@as(?Refusal, null), live.shell.status.refused);
    try std.testing.expectEqualStrings(second_name ++ " - ra8 emulator", live.window.title());
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try statusLine(&live, &buf), "| " ++ second_name ++ " ") != null);
    // It runs from Run like the first one did.
    try live.click(.run);
    try live.step();
    try std.testing.expect(live.shell.status.run == .running and live.time.run.lit);
}

test "an image picked while Run is lit stops the run at the new image's reset vector" {
    const want = try resetPc(second);
    var live: Live = undefined;
    try live.open(first, slow);
    defer live.deinit();
    try live.click(.run);
    for (0..3) |_| try live.step();
    try std.testing.expect(live.time.run.lit);
    const serial = live.registers.cores[0].serial;
    try live.window.feed(.{ .picked = second });
    try untilNamed(&live, second_name, serial);
    try std.testing.expect(!live.time.run.lit);
    try std.testing.expectEqual(want, live.pc());
    try std.testing.expectEqual(want, live.shell.status.run.halted.address);
    // Nothing runs behind the load: the new image has not left its vector.
    const at = live.boardTime();
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(at, live.boardTime());
    try std.testing.expectEqual(want, live.pc());
}

test "a file the session refuses is said so and the image in use keeps running" {
    var live: Live = undefined;
    try live.open(first, slow);
    defer live.deinit();
    try live.click(.run);
    for (0..2) |_| try live.step();
    try live.window.feed(.{ .picked = not_elf });
    for (0..4) |_| try live.step();
    try std.testing.expectEqual(@as(?Refusal, .load), live.shell.status.refused);
    try std.testing.expectEqualStrings("blink.elf", live.shell.status.image.?.name());
    try std.testing.expectEqualStrings("blink.elf - ra8 emulator", live.window.title());
    try std.testing.expect(live.time.run.lit and live.shell.status.run == .running);
    const at = live.boardTime();
    for (0..3) |_| try live.step();
    try std.testing.expect(live.boardTime() > at);
    var buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.endsWith(u8, try statusLine(&live, &buf), "| the session refused the image"));
}

test "a file that cannot be read leaves the session and the run untouched" {
    var live: Live = undefined;
    try live.open(first, slow);
    defer live.deinit();
    try live.click(.run);
    for (0..2) |_| try live.step();
    try live.window.feed(.{ .picked = "/nonexistent/ra8-open/missing.elf" });
    for (0..3) |_| try live.step();
    try std.testing.expectEqual(@as(?Refusal, .unread), live.shell.status.refused);
    try std.testing.expect(live.link.state == .connected);
    try std.testing.expect(live.time.run.lit);
    try std.testing.expectEqualStrings("blink.elf", live.shell.status.image.?.name());
}
