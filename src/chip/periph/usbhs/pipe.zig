//! The host's pipe table: the DCP and PIPE1..PIPE9, and what the host
//! programs into each through the PIPESEL window.
//!
//! dev kept the table as flat arrays indexed by `selected % 10`, so PIPESEL
//! naming a pipe the part does not have wrapped onto the control pipe and a
//! bulk endpoint's config landed on the DCP. Here a selection out of range is
//! refused and the window answers zero until a real pipe is selected.
const regs = @import("regs.zig");

/// One pipe's configuration, as the host programmed it.
pub const Pipe = struct {
    endpoint: u8 = 0,
    /// The host receives on this pipe (PIPECFG.DIR clear).
    in: bool = false,
    /// PIPECFG.DIR as written, for the readback.
    dir: u16 = 0,
    maxp: u16 = 0,
    pid: u16 = regs.pipe.pid_nak,

    pub fn armed(self: Pipe) bool {
        return self.pid & regs.pipe.pid_mask == regs.pipe.pid_buf;
    }
};

/// The table and the PIPESEL cursor over it.
pub const Table = struct {
    pipes: [regs.pipe.count]Pipe = @splat(.{}),
    /// PIPESEL as written; zero means no pipe window is open.
    selected: u16 = 0,

    /// Selections and configurations refused, each for its own reason.
    bad_pipe: u32 = 0,
    too_big: u32 = 0,
    dcp_config: u32 = 0,

    /// The pipe the PIPESEL window is open on, if any. PIPESEL 0 opens no
    /// window: the DCP has its own registers (DCPCFG, DCPMAXP, DCPCTR).
    pub fn current(self: *Table) ?*Pipe {
        if (self.selected == 0 or self.selected >= regs.pipe.count) return null;
        return &self.pipes[self.selected];
    }

    /// PIPESEL. A pipe number the part does not have selects nothing, rather
    /// than wrapping onto the control pipe.
    pub fn select(self: *Table, value: u16) void {
        if (value >= regs.pipe.count) {
            self.bad_pipe += 1;
            self.selected = 0;
            return;
        }
        self.selected = value;
    }

    /// PIPECFG: the endpoint this pipe talks to and which way it runs. DIR
    /// names the way the controller sends, so on the host a set bit is an OUT
    /// pipe. dev read it as the device would and took IN pipes for OUT ones,
    /// so a bulk IN answer was never offered on the pipe the host armed.
    pub fn configure(self: *Table, value: u16) bool {
        const pipe = self.current() orelse {
            if (self.selected == 0) self.dcp_config += 1;
            return false;
        };
        pipe.endpoint = @intCast(value & regs.pipe.epnum_mask);
        pipe.dir = value & regs.pipe.dir_transmit;
        pipe.in = pipe.dir == 0;
        return true;
    }

    /// PIPEMAXP. A packet size past what the bus can carry is refused: dev
    /// took any value and then silently cut every transfer at its own 512
    /// byte staging cap, so the host saw a size the wire never honoured.
    pub fn setMaxPacket(self: *Table, value: u16) bool {
        const size = value & regs.pipe.maxp_mask;
        const pipe = self.current() orelse {
            if (self.selected == 0) self.dcp_config += 1;
            return false;
        };
        if (size == 0 or size > regs.pipe.maxp_limit) {
            self.too_big += 1;
            return false;
        }
        pipe.maxp = size;
        return true;
    }

    pub fn maxPacket(self: *Table) u16 {
        const pipe = self.current() orelse return 0;
        return pipe.maxp;
    }

    pub fn config(self: *Table) u16 {
        const pipe = self.current() orelse return 0;
        return @as(u16, pipe.endpoint) | pipe.dir;
    }

    /// PIPECTR[n], addressed by its own offset rather than through PIPESEL.
    pub fn setControl(self: *Table, index: u32, value: u16) bool {
        if (index == 0 or index >= regs.pipe.count) {
            self.bad_pipe += 1;
            return false;
        }
        self.pipes[index].pid = value;
        return true;
    }

    pub fn control(self: *Table, index: u32) u16 {
        if (index == 0 or index >= regs.pipe.count) {
            self.bad_pipe += 1;
            return 0;
        }
        return self.pipes[index].pid;
    }

    pub fn refusals(self: *const Table) u32 {
        return self.bad_pipe + self.too_big + self.dcp_config;
    }

    pub fn quiet(self: *const Table) bool {
        if (self.refusals() != 0) return false;
        for (&self.pipes) |pipe| {
            if (pipe.maxp != 0 or pipe.endpoint != 0) return false;
        }
        return true;
    }
};
