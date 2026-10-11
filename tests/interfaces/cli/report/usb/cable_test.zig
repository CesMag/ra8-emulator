//! Tests for src/interfaces/cli/report/usb_cable.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const usb_cable = cli_app.report.usb_cable;
const usbfs = ra8.chip.periph.usbfs;
const Loop = ra8.components.usb_loop_cable.Loop;

/// The rendered section: up to 512 bytes, kept by value.
const Text = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn constSlice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn render(cable: ?*const Loop) !Text {
    var text: Text = .{};
    var out: std.Io.Writer = .fixed(&text.buffer);
    try usb_cable.section(cable, &out);
    text.len = out.end;
    return text;
}

test "nothing while no cable is in" {
    const text = try render(null);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "a cable names the device's state and what crossed it" {
    var device = usbfs.Device{};
    var cable = Loop{ .device = &device, .setups = 3, .ins = 2, .bulk_outs = 1 };
    const text = try render(&cable);
    try std.testing.expectEqualStrings(
        "  cabled to the board's FS device, which is powered: 3 SETUP(s), " ++
            "2 control IN, 0 control OUT, 1 bulk OUT, 0 bulk IN\n",
        text.constSlice(),
    );
}

test "bulk tokens with no pipe open get their own line" {
    var device = usbfs.Device{};
    var cable = Loop{ .device = &device, .unopened = 4 };
    const text = try render(&cable);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "4 bulk token(s) for an endpoint") != null);
}

test "DVSQ names" {
    try std.testing.expectEqualStrings("configured", usb_cable.stateName(usbfs.intsts0.dvsq_configured));
    try std.testing.expectEqualStrings("addressed", usb_cable.stateName(usbfs.intsts0.dvsq_address));
    try std.testing.expectEqualStrings("suspended", usb_cable.stateName(0x0040));
}
