//! USB/IP URBs on the board's FS device (RA8EMU-75 slice 4a), with no
//! socket in sight. A bulk URB moves through the pipe the firmware opened
//! for its endpoint, one packet per `advance`: an OUT URB hands each
//! max-packet chunk to the pipe once the driver has emptied it, and an IN
//! URB takes each packet the driver commits, ending on a short packet or
//! the URB's length. `null` means the pipe is not ready yet: run the
//! firmware and advance again. Endpoint 0 goes through control.zig;
//! endpoints the firmware never opened stall, as the kernel's -EPIPE.
const wire = @import("wire.zig");
const usbfs = @import("ra8_chip").periph.usbfs;
const control = @import("control.zig");

pub const epipe: i32 = -32;
pub const econnreset: i32 = -104;

/// What goes back in USBIP_RET_SUBMIT.
pub const Reply = struct { status: i32, actual: u32 };

pub const Transfer = struct {
    submit: wire.Submit,
    moved: u32 = 0,
    /// Where an endpoint 0 URB is in its control transfer.
    stage: control.Stage = .setup,

    /// Move at most one packet. `out_data` is the URB's OUT payload and
    /// `in_buf` where IN data lands; the other one is ignored.
    pub fn advance(self: *Transfer, device: *usbfs.Device, out_data: []const u8, in_buf: []u8) ?Reply {
        if (self.submit.ep == 0) return control.advance(self, device, out_data, in_buf);
        if (self.submit.ep > 15) return stalled();
        const in = self.submit.direction == .in;
        const n = device.pipes.find(@intCast(self.submit.ep), in) orelse return stalled();
        const size = packetSize(device, n);
        return if (in) self.take(device, n, size, in_buf) else self.give(device, n, size, out_data);
    }

    fn give(self: *Transfer, device: *usbfs.Device, n: u4, size: u32, data: []const u8) ?Reply {
        if (device.endpoints.out[n - 1].ready) return null;
        const end = @min(data.len, self.moved + size);
        if (!device.endpoints.hostOut(&device.pipes, n, data[self.moved..end])) return null;
        self.moved = @intCast(end);
        return if (self.moved == data.len) .{ .status = 0, .actual = self.moved } else null;
    }

    fn take(self: *Transfer, device: *usbfs.Device, n: u4, size: u32, buf: []u8) ?Reply {
        const want: u32 = @intCast(@min(buf.len, self.submit.length));
        if (want == 0) return .{ .status = 0, .actual = 0 };
        const end = @min(want, self.moved + size);
        const got = device.endpoints.hostTake(n, buf[self.moved..end]) orelse return null;
        self.moved += got;
        if (got < size or self.moved >= want) return .{ .status = 0, .actual = self.moved };
        return null;
    }
};

/// USBIP_CMD_UNLINK against the one URB in flight: -ECONNRESET when it
/// caught it (and it is dropped), 0 when that URB had already completed.
pub fn unlink(pending: *?Transfer, victim: u32) i32 {
    const transfer = pending.* orelse return 0;
    if (transfer.submit.seqnum != victim) return 0;
    pending.* = null;
    return econnreset;
}

fn stalled() Reply {
    return .{ .status = epipe, .actual = 0 };
}

fn packetSize(device: *usbfs.Device, n: u4) u32 {
    const size = device.pipes.get(n).?.max_packet;
    return if (size == 0) 64 else size;
}
