//! The USBHS transfer engine against whatever the board plugged into the far
//! end: the echo device, or the self-loop cable, where the answers the polled
//! host sees come from the USBFS driver on the other jack.
//!
//! A control transfer is asynchronous on the far. The SETUP goes across
//! at once, and every later answer appears only when the device driver has
//! run: a control-read packet once it commits one, a STALL once it sets
//! its DCP PID, a bulk-IN packet once it commits one on the endpoint's
//! pipe. BRDYSTS is the register the host spins on, so `ready` is called
//! from there and moves whatever the driver has committed since.
const regs = @import("../regs.zig");
const usbhs_far = @import("../far.zig");
const usbhs_fifo = @import("../fifo.zig");
const usbhs_pipe = @import("../pipe.zig");
const usbhs_setup = @import("../setup.zig");
const usbhs_xfer = @import("xfer.zig");

/// The SETUP packet's eight wire bytes, little-endian fields.
pub fn bytes(packet: usbhs_setup.Packet) [8]u8 {
    return .{
        packet.request_type,      packet.code,
        @truncate(packet.value),  @truncate(packet.value >> 8),
        @truncate(packet.index),  @truncate(packet.index >> 8),
        @truncate(packet.length), @truncate(packet.length >> 8),
    };
}

/// BRDYSTS: the control reply, a device STALL, and a bulk-IN
/// packet on every armed IN pipe, each moved once the driver committed it.
pub fn ready(t: *usbhs_xfer.Transfer, far: usbhs_far.Far, pipes: *usbhs_pipe.Table) u16 {
    if (t.in_flight and far.answer() == .stall) t.stall();
    if (t.in_flight and t.control_read and fill(&t.port.in[0], far, null)) {
        t.raiseReady(regs.status.dcp);
    }
    var index: u32 = 1;
    while (index < regs.pipe.count) : (index += 1) {
        const pipe = pipes.pipes[index];
        if (!pipe.armed() or !pipe.in) continue;
        if (!fill(&t.port.in[index], far, @truncate(pipe.endpoint))) continue;
        t.raiseReady(@as(u16, 1) << @intCast(index));
    }
    return t.brdy;
}

/// Move one packet off the far end into an empty host buffer: the DCP's when
/// endpoint is null, otherwise that endpoint's pipe.
fn fill(staging: *usbhs_fifo.Staging, far: usbhs_far.Far, endpoint: ?u4) bool {
    if (staging.ready) return false;
    const len = if (endpoint) |ep|
        far.bulkIn(ep, &staging.data)
    else
        far.takeIn(&staging.data);
    staging.len = len orelse return false;
    staging.cursor = 0;
    staging.ready = true;
    return true;
}

/// BEMPSTS: every armed OUT pipe still holding a packet the
/// device NAKed tries it again. Taken, the buffer empties and BEMP rises;
/// NAKed again, the bytes stay where the host put them.
pub fn empty(t: *usbhs_xfer.Transfer, far: usbhs_far.Far, pipes: *usbhs_pipe.Table) void {
    var index: u32 = 1;
    while (index < regs.pipe.count) : (index += 1) {
        const pipe = pipes.pipes[index];
        const staging = &t.port.out[index];
        if (pipe.in or !pipe.armed() or staging.len == 0) continue;
        if (!far.bulkOut(@truncate(pipe.endpoint), staging.staged())) continue;
        t.refused_bytes -|= staging.len;
        staging.clear();
        t.raiseEmpty(@as(u16, 1) << @intCast(index));
    }
}
