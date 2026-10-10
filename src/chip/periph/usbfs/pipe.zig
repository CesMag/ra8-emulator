//! The USBFS pipe registers: PIPE1 through PIPE9, the pipes a device driver
//! opens for its bulk and interrupt endpoints once SET_CONFIGURATION lands.
//!
//! PIPESEL is a window: it picks one pipe, and PIPECFG, PIPEMAXP and
//! PIPEPERI then read and write that pipe's settings. PIPEnCTR sits outside
//! the window, one register per pipe. With no pipe selected the window reads
//! zero and drops writes, which is what the driver relies on when it
//! deselects after configuring (ra8_usb_device.c).
//!
//! find() is the routing side: the board loop asks which pipe carries an
//! endpoint before it moves a packet.
const regs = @import("../usbhs/regs.zig");

pub const count: u4 = regs.reg.pipectr_count;

/// PIPECFG fields.
pub const cfg = struct {
    pub const epnum: u16 = 0x000F;
    pub const dir_in: u16 = 1 << 4;
    pub const kind_shift: u4 = 14;
};

/// PIPEnCTR fields.
pub const ctr = struct {
    pub const pid: u16 = 0x0003;
    pub const sqmon: u16 = 1 << 6;
    pub const sqset: u16 = 1 << 7;
    pub const sqclr: u16 = 1 << 8;
    pub const aclrm: u16 = 1 << 9;
    /// The bits that read back as written.
    pub const kept: u16 = pid | aclrm;
};

/// PIPECFG.TYPE. Zero means the pipe is not in use.
pub const Kind = enum(u2) { none, bulk, interrupt, isochronous };

/// PID as the SIE reads it.
pub const Pid = enum(u2) { nak, buf, stall, stall_too };

pub const Pipe = struct {
    config: u16 = 0,
    max_packet: u16 = 0,
    period: u16 = 0,
    control: u16 = 0,

    pub fn endpoint(self: Pipe) u4 {
        return @truncate(self.config & cfg.epnum);
    }

    pub fn in(self: Pipe) bool {
        return self.config & cfg.dir_in != 0;
    }

    pub fn kind(self: Pipe) Kind {
        return @fromBackingInt(@intCast(@as(u2, @truncate(self.config >> cfg.kind_shift))));
    }

    pub fn pid(self: Pipe) Pid {
        return @fromBackingInt(@intCast(@as(u2, @truncate(self.control & ctr.pid))));
    }

    /// The data toggle the next packet carries.
    pub fn toggle(self: Pipe) bool {
        return self.control & ctr.sqmon != 0;
    }

    fn setControl(self: *Pipe, value: u16) void {
        self.control = (self.control & ~ctr.kept) | (value & ctr.kept);
        if (value & ctr.sqclr != 0) self.control &= ~ctr.sqmon;
        if (value & ctr.sqset != 0) self.control |= ctr.sqmon;
    }
};

pub const Pipes = struct {
    sel: u16 = 0,
    pipes: [count]Pipe = @splat(Pipe{}),
    /// Window writes that landed with no pipe selected.
    unselected: u32 = 0,

    /// Whether an offset is one of the pipe registers.
    pub fn owns(offset: u32) bool {
        return switch (offset) {
            regs.reg.pipesel, regs.reg.pipecfg, regs.reg.pipemaxp, regs.reg.pipeperi => true,
            else => controlIndex(offset) != null,
        };
    }

    /// Pipe n, for n in 1..9.
    pub fn get(self: *Pipes, n: u4) ?*Pipe {
        if (n == 0 or n > count) return null;
        return &self.pipes[n - 1];
    }

    pub fn read(self: *Pipes, offset: u32) u16 {
        if (offset == regs.reg.pipesel) return self.sel;
        if (controlIndex(offset)) |i| return self.pipes[i].control;
        const pipe = self.selected() orelse return 0;
        return switch (offset) {
            regs.reg.pipecfg => pipe.config,
            regs.reg.pipemaxp => pipe.max_packet,
            regs.reg.pipeperi => pipe.period,
            else => 0,
        };
    }

    pub fn write(self: *Pipes, offset: u32, value: u16) void {
        if (offset == regs.reg.pipesel) {
            self.sel = value & 0x000F;
            return;
        }
        if (controlIndex(offset)) |i| return self.pipes[i].setControl(value);
        const pipe = self.selected() orelse {
            self.unselected += 1;
            return;
        };
        switch (offset) {
            regs.reg.pipecfg => pipe.config = value,
            regs.reg.pipemaxp => pipe.max_packet = value,
            regs.reg.pipeperi => pipe.period = value,
            else => {},
        }
    }

    /// The pipe the driver opened for an endpoint and direction.
    pub fn find(self: *const Pipes, endpoint: u4, in: bool) ?u4 {
        for (self.pipes, 1..) |pipe, n| {
            if (pipe.kind() == .none) continue;
            if (pipe.endpoint() == endpoint and pipe.in() == in) return @intCast(n);
        }
        return null;
    }

    fn selected(self: *Pipes) ?*Pipe {
        return self.get(@truncate(self.sel));
    }
};

fn controlIndex(offset: u32) ?usize {
    const first = regs.reg.pipectr;
    if (offset < first or offset >= first + 2 * @as(u32, count)) return null;
    if (offset % 2 != 0) return null;
    return (offset - first) / 2;
}
