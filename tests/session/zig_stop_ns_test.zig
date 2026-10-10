//! RA8EMU-651: `--stop-sym` finds a counter the `--ns` image carries, as
//! `--dump-sym` does. Uses the TrustZone pair in tests/fixtures/trustzone,
//! whose Non-secure image keeps g_tz_nsc_cgc_usb_match at 0x3210DE10.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const zig_stop = cli_app.zig_run.stop_sym;
const secure_bytes = @embedFile("../fixtures/trustzone/tz_nsc_cgc_usb.elf");
const ns_bytes = @embedFile("../fixtures/trustzone/tz_nsc_cgc_usb_ns.elf");
const counter = "g_tz_nsc_cgc_usb_match";

test "a --stop-sym name only the --ns image carries resolves there" {
    const image = try ra8.board.image.elf.Image.init(secure_bytes);
    const non_secure = try ra8.board.image.elf.Image.init(ns_bytes);
    const watch = zig_stop.resolve(image, non_secure, counter, 50) orelse return error.TestExpectedStop;
    try std.testing.expectEqual(@as(u32, 0x3210_DE10), watch.address);
    try std.testing.expectEqual(@as(u32, 50), watch.reaches);
}

test "without --ns a Non-secure name stays unresolved" {
    const image = try ra8.board.image.elf.Image.init(secure_bytes);
    try std.testing.expect(zig_stop.resolve(image, null, counter, 50) == null);
}
