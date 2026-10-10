//! Tests for src/interfaces/cli/report/usb.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const report_usb = cli_app.report.usb;
const Host = ra8.chip.periph.usbfs.host.Host;

/// The rendered section: up to 512 bytes, kept by value.
const Text = struct {
    buffer: [512]u8 = undefined,
    len: usize = 0,

    fn constSlice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }
};

fn render(host: *const Host) !Text {
    var text: Text = .{};
    var out: std.Io.Writer = .fixed(&text.buffer);
    try report_usb.section(host, &out);
    text.len = out.end;
    return text;
}

test "nothing while no device is on the jack" {
    const host = Host{};
    const text = try render(&host);
    try std.testing.expectEqual(@as(usize, 0), text.len);
}

test "a stalled step names itself and how long it waited" {
    var host = Host{ .step = .device_descriptor, .waited = 20 };
    const text = try render(&host);
    try std.testing.expectEqualStrings(
        "USBFS host: enumeration device_descriptor after 20 boundary(ies) on that step\n",
        text.constSlice(),
    );
}

test "a failed script names the step it gave up on" {
    var host = Host{ .step = .failed, .failed_on = .get_status, .waited = 21 };
    const text = try render(&host);
    try std.testing.expectEqualStrings(
        "USBFS host: enumeration failed on get_status after 21 boundary(ies) on that step\n",
        text.constSlice(),
    );
}

test "a configured device prints both descriptors" {
    var host = Host{ .step = .configured };
    host.device[0] = 0x12;
    host.device[1] = 0x01;
    host.config[0] = 0x09;
    host.config[1] = 0x02;
    const text = try render(&host);
    try std.testing.expect(std.mem.startsWith(u8, text.constSlice(), "USBFS host: enumeration configured\n"));
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "device descriptor 12 01 00") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "config descriptor 09 02 00") != null);
}

test "a configured device prints its configuration value and status" {
    var host = Host{ .step = .configured, .config_value = .{1}, .status = .{ 1, 0 }, .interface = .stall };
    host.device[0] = 0x12;
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "configuration value 1, status 01 00, SET_INTERFACE stall\n") != null);
}

test "a refused GET_CONFIGURATION and GET_STATUS print as stall" {
    var host = Host{ .step = .configured, .config_answer = .stall, .status_answer = .stall, .interface = .ack };
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "configuration value stall, status stall, SET_INTERFACE ack\n") != null);
}

test "a step short of configured prints no configuration value" {
    var host = Host{ .step = .get_status, .waited = 3 };
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "configuration value") == null);
}

test "the product string prints as text" {
    var host = Host{ .step = .configured };
    @memcpy(host.product[0..8], &[8]u8{ 8, 3, 'R', 0, 'A', 0, '8', 0 });
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "USBFS host: product \"RA8\"\n") != null);
}

test "a character outside printable ASCII prints as a question mark" {
    var host = Host{ .step = .configured };
    @memcpy(host.product[0..6], &[6]u8{ 6, 3, 'A', 0, 0xE9, 0 });
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "product \"A?\"") != null);
}

test "the halt answers print once the host sent them" {
    var host = Host{ .step = .configured, .halt_set = .ack, .halt_clear = .stall };
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "USBFS host: ENDPOINT_HALT set ack, clear stall\n") != null);
}

test "no halt line when the device listed no endpoint" {
    const host = Host{ .step = .configured };
    const text = try render(&host);
    try std.testing.expect(std.mem.indexOf(u8, text.constSlice(), "ENDPOINT_HALT") == null);
}

test {
    _ = @import("usb_cable_test.zig");
}
