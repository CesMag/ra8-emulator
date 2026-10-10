//! The CFIFO data port: which pipe it is aimed at, what is staged on either
//! side of it, and how many bytes are really there.
//!
//! dev indexed its staging arrays with `CURPIPE % 10`, so a port aimed at a
//! pipe the part does not have wrapped onto the control pipe, and it moved
//! bytes whatever the buffer said, so a host that never waited on FRDY read
//! zeros and counted them as a packet. Here the port is aimed or it is not,
//! and it only moves bytes a buffer actually holds.
const regs = @import("regs.zig");

/// One side of one pipe's staging.
pub const Staging = struct {
    data: [regs.staging.packet_cap]u8 = @splat(0),
    len: u16 = 0,
    cursor: u16 = 0,
    ready: bool = false,

    pub fn clear(self: *Staging) void {
        self.len = 0;
        self.cursor = 0;
        self.ready = false;
    }

    pub fn remaining(self: *const Staging) u16 {
        return self.len - self.cursor;
    }

    /// The bytes sitting in the buffer, without taking them. A caller that
    /// may yet refuse them looks here first and drains only once it has.
    pub fn staged(self: *const Staging) []const u8 {
        return self.data[0..self.len];
    }

    /// Take the staged bytes and hand them to a caller that owns them now.
    pub fn drain(self: *Staging, into: []u8) u16 {
        const len: usize = @min(self.len, into.len);
        @memcpy(into[0..len], self.data[0..len]);
        self.clear();
        return @intCast(len);
    }

    pub fn fill(self: *Staging, bytes: []const u8) void {
        const len: usize = @min(bytes.len, self.data.len);
        @memcpy(self.data[0..len], bytes[0..len]);
        self.len = @intCast(len);
        self.cursor = 0;
        self.ready = true;
    }
};

/// The CFIFO port and the staging behind every pipe.
pub const Port = struct {
    in: [regs.pipe.count]Staging = @splat(.{}),
    out: [regs.pipe.count]Staging = @splat(.{}),
    /// CFIFOSEL as written.
    sel: u16 = 0,
    /// True once a pipe in range has been selected.
    aimed: bool = false,

    /// Accesses refused, each for its own reason.
    bad_pipe: u32 = 0,
    not_ready: u32 = 0,
    overdrain: u32 = 0,
    oversize: u32 = 0,

    /// CFIFOSEL.CURPIPE. dev took it modulo the pipe count; a pipe the part
    /// does not have aims the port at nothing here.
    pub fn select(self: *Port, value: u16) void {
        const aimed_at = value & regs.fifo.curpipe_mask;
        if (aimed_at >= regs.pipe.count) {
            self.bad_pipe += 1;
            self.aimed = false;
            self.sel = value & ~regs.fifo.curpipe_mask;
            return;
        }
        self.sel = value;
        self.aimed = true;
    }

    pub fn pipe(self: *const Port) ?u32 {
        if (!self.aimed) return null;
        return self.sel & regs.fifo.curpipe_mask;
    }

    /// ISEL: the control pipe's port is aimed at the write side.
    pub fn writing(self: *const Port) bool {
        return self.sel & regs.fifo.isel != 0;
    }

    /// CFIFOCTR: whether the buffer is the host's to touch, and how much is
    /// in it. A port aimed at nothing is never ready.
    pub fn status(self: *Port) u16 {
        const index = self.pipe() orelse return 0;
        if (self.writing()) return regs.fifo.frdy;
        const staging = &self.in[index];
        if (!staging.ready) return 0;
        return regs.fifo.frdy | (staging.remaining() & regs.fifo.dtln_mask);
    }

    /// A host store into the data port. Bytes go out LSB first, the way the
    /// register is wired.
    pub fn writeData(self: *Port, value: u32, width: u3, maxp: u16) void {
        const index = self.pipe() orelse {
            self.bad_pipe += 1;
            return;
        };
        fillWord(&self.out[index], value, width, maxp, &self.oversize);
    }

    /// A host load from the data port. dev served zeros past the staged
    /// length forever, so a driver reading a short packet as a full one was
    /// handed a packet's worth of nothing and counted it.
    pub fn readData(self: *Port, width: u3) u32 {
        const index = self.pipe() orelse {
            self.bad_pipe += 1;
            return 0;
        };
        const staging = &self.in[index];
        if (!staging.ready) {
            self.not_ready += 1;
            return 0;
        }
        return drainWord(staging, width, &self.overdrain);
    }

    /// CFIFOCTR.BCLR: throw away whichever side the port is aimed at.
    pub fn clear(self: *Port) void {
        const index = self.pipe() orelse {
            self.bad_pipe += 1;
            return;
        };
        if (self.writing()) self.out[index].clear() else self.in[index].clear();
    }

    pub fn refusals(self: *const Port) u32 {
        return self.bad_pipe + self.not_ready + self.overdrain + self.oversize;
    }

    pub fn quiet(self: *const Port) bool {
        return self.refusals() == 0 and self.sel == 0;
    }
};

/// Take one access-width word out of a staging buffer, LSB first, the way the
/// data register is wired. Shared by the control port and the two data ports
/// so a byte crosses the same code whichever port it went through.
pub fn drainWord(staging: *Staging, width: u3, overdrain: *u32) u32 {
    if (staging.cursor >= staging.len) {
        overdrain.* += 1;
        staging.ready = false;
        return 0;
    }
    var value: u32 = 0;
    var i: u3 = 0;
    while (i < width) : (i += 1) {
        if (staging.cursor >= staging.len) break;
        value |= @as(u32, staging.data[staging.cursor]) << (@as(u5, i) * 8);
        staging.cursor += 1;
    }
    if (staging.cursor >= staging.len) staging.ready = false;
    return value;
}

/// Put one access-width word into a staging buffer, stopping at the packet
/// size the pipe was given rather than cutting the transfer silently.
pub fn fillWord(staging: *Staging, value: u32, width: u3, maxp: u16, oversize: *u32) void {
    var i: u3 = 0;
    while (i < width) : (i += 1) {
        if (staging.len >= maxp or staging.len >= staging.data.len) {
            oversize.* += 1;
            return;
        }
        staging.data[staging.len] = @truncate(value >> (@as(u5, i) * 8));
        staging.len += 1;
    }
    staging.ready = true;
}
