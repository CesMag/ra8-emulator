//! The self-loop cable between the HS host jack and the board's own FS
//! device jack: what crossed it, and where the device's state got to. A
//! host with no cable in says nothing here; the echo device's lines
//! cover it.
pub const Loop = @import("../../../components/usb_loop_cable/cable.zig").Loop;
const usbfs = @import("ra8_chip").periph.usbfs;

pub fn section(plugged: ?*const Loop, out: anytype) !void {
    const cable = plugged orelse return;
    try out.print(
        "  cabled to the board's FS device, which is {s}: {d} SETUP(s), " ++
            "{d} control IN, {d} control OUT, {d} bulk OUT, {d} bulk IN\n",
        .{
            stateName(cable.deviceState()),
            cable.setups,
            cable.ins,
            cable.outs,
            cable.bulk_outs,
            cable.bulk_ins,
        },
    );
    if (cable.unopened != 0) {
        try out.print(
            "  {d} bulk token(s) for an endpoint the device driver opened no pipe for\n",
            .{cable.unopened},
        );
    }
}

/// INTSTS0.DVSQ, as the device driver would read it.
pub fn stateName(dvsq: u16) []const u8 {
    return switch (dvsq) {
        usbfs.intsts0.dvsq_powered => "powered",
        usbfs.intsts0.dvsq_default => "default",
        usbfs.intsts0.dvsq_address => "addressed",
        usbfs.intsts0.dvsq_configured => "configured",
        else => "suspended",
    };
}
