//! Covers src/interfaces/cli/report/json_ether.zig, json_usb.zig and
//! json_usbfs.zig: the `ethernet` and `usb` objects of `--report json`,
//! parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const json_run = cli_app.report.json_run;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

fn render(board: *ra8.board.board.Board, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1 });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

fn has(object: Value, keys: []const []const u8) !void {
    for (keys) |key| {
        if (object.object.get(key) == null) {
            std.debug.print("missing key {s}\n", .{key});
            return error.MissingKey;
        }
    }
}

test "a quiet board has every ethernet key and no ports" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const eth = doc.value.object.get("ethernet").?;
    try has(eth, &.{ "eswm", "ports", "gateway", "rings" });
    try std.testing.expectEqual(@as(usize, 0), eth.object.get("ports").?.array.items.len);
    try has(eth.object.get("eswm").?, &.{ "powered", "power_ons", "power_offs", "dropped_locked" });
    try has(eth.object.get("gateway").?, &.{ "mode", "commands", "axi_inits", "pool_inits", "refused_steps", "last_refused" });
    const rings = eth.object.get("rings").?;
    try has(rings, &.{ "tx_kicks", "tx_frames", "rx_frames", "refused_base_late", "refused" });
    try has(rings.object.get("refused").?, &.{ "gateway_stopped", "off_ram", "too_big", "far_end_full", "looped", "runt", "oversize", "fragment", "ring_full" });
}

test "a quiet board has every usb key, no cable and no descriptors" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const usb = doc.value.object.get("usb").?;
    try has(usb, &.{ "hs_host", "fs_host" });
    const hs = usb.object.get("hs_host").?;
    try has(hs, &.{ "powered", "host_role", "port_resets", "speed", "blind_line_reads", "pll_locks", "pll_unlocked_reads", "setups", "device_state", "device_address", "stalls", "refused_out", "refused_out_bytes", "cable", "refused" });
    try std.testing.expect(hs.object.get("cable").? == .null);
    try has(hs.object.get("refused").?, &.{ "odd_offset", "module_off", "status_writes", "device_role", "bad_pipe", "packet_size", "data_bad_pipe", "data_contended", "data_bad_width", "data_wrong_way", "no_device", "stray_ccpl", "fifo_not_ready", "overdrain", "out_of_order" });
    const fs = usb.object.get("fs_host").?;
    try has(fs, &.{ "step", "waited", "device_descriptor", "config_descriptor", "product", "configuration_value", "status", "set_interface", "halt_set", "halt_clear" });
    try std.testing.expectEqualStrings("waiting", fs.object.get("step").?.string);
    try std.testing.expect(fs.object.get("device_descriptor").? == .null);
}

test "a port that took mode commands is listed with its MAC and MDIO" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    fix.board.rswitch.ports[1].mode.commands = 2;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &buf);
    defer doc.deinit();
    const list = doc.value.object.get("ethernet").?.object.get("ports").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(i64, 1), list[0].object.get("index").?.integer);
    try std.testing.expectEqual(@as(i64, 2), list[0].object.get("commands").?.integer);
    try has(list[0], &.{ "mode", "changes", "refused_steps", "last_refused", "dropped_unpowered", "dark_reads", "mac", "mdio" });
    try has(list[0].object.get("mac").?, &.{ "address", "stores", "refused_not_config" });
    try has(list[0].object.get("mdio").?, &.{ "reads", "writes", "phy_resets", "no_phy", "refused_read_only", "refused_clause45", "refused_bad_op" });
}
