//! The `usb` object of `--report json` (RA8EMU-364): the USBHS host
//! controller with its self-loop cable, then the scripted host on the
//! USBFS jack (json_usbfs.zig), the same facts report/serial.zig usb() and
//! src/interfaces/cli/report/usb/usb.zig, usb_cable.zig print. Every key is always present; the
//! refusal counts are the same sums the human report prints.
const Board = @import("ra8_board").board.Board;
const Host = @import("ra8_chip").periph.usbhs.Host;
const Echo = @import("ra8_components").usb.echo.Device;
const usb_cable = @import("../usb/cable.zig");
const json_usbfs = @import("usbfs.zig");

/// The whole `usb` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    const host = &board.usb.host;
    try j.open("usb", '{');
    try j.open("hs_host", '{');
    try j.field("powered", host.phy.powered());
    try j.field("host_role", host.phy.host());
    try j.field("port_resets", host.phy.resets);
    try j.field("speed", @tagName(host.phy.speed));
    try j.field("blind_line_reads", host.phy.blind);
    try j.field("pll_locks", host.pll.locks);
    try j.field("pll_unlocked_reads", host.pll.stalled);
    try j.field("setups", host.xfer.setups);
    try j.field("device_state", @tagName(board.usb.echo.state));
    try j.field("device_address", board.usb.echo.address);
    try j.field("stalls", host.xfer.stalls);
    try j.field("refused_out", host.xfer.refused_out);
    try j.field("refused_out_bytes", host.xfer.refused_bytes);
    try cable(j, board);
    try refusals(j, host, &board.usb.echo);
    try j.close('}');
    try json_usbfs.section(j, &board.usb.script);
    try j.close('}');
}

fn cable(j: anytype, board: *const Board) !void {
    const loop = if (board.usb.cable) |*plugged| plugged else return j.field("cable", null);
    try j.open("cable", '{');
    try j.field("device_state", usb_cable.stateName(loop.deviceState()));
    try j.field("setups", loop.setups);
    try j.field("control_in", loop.ins);
    try j.field("control_out", loop.outs);
    try j.field("bulk_out", loop.bulk_outs);
    try j.field("bulk_in", loop.bulk_ins);
    try j.field("unopened_bulk_tokens", loop.unopened);
    try j.close('}');
}

fn refusals(j: anytype, host: *const Host, echo: *const Echo) !void {
    const data = &host.xfer.data;
    try j.open("refused", '{');
    try j.field("odd_offset", host.misaligned);
    try j.field("module_off", host.off);
    try j.field("status_writes", host.read_only + host.phy.read_only);
    try j.field("device_role", host.phy.not_host);
    try j.field("bad_pipe", host.pipes.bad_pipe + host.pipes.dcp_config + host.xfer.port.bad_pipe);
    try j.field("packet_size", host.pipes.too_big + host.xfer.port.oversize);
    try j.field("data_bad_pipe", data.ports[0].bad_pipe + data.ports[1].bad_pipe);
    try j.field("data_contended", data.ports[0].contended + data.ports[1].contended);
    try j.field("data_bad_width", data.ports[0].bad_width + data.ports[1].bad_width);
    try j.field("data_wrong_way", data.ports[0].wrong_way + data.ports[1].wrong_way);
    try j.field("no_device", host.xfer.no_device);
    try j.field("stray_ccpl", host.xfer.stray_ccpl);
    try j.field("fifo_not_ready", host.xfer.port.not_ready);
    try j.field("overdrain", host.xfer.port.overdrain);
    try j.field("out_of_order", echo.out_of_order);
    try j.close('}');
}
