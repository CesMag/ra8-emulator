//! RIIC: the classic Renesas I2C Bus Interface (HUM Ch 39), the controller a
//! polling driver clocks through ICCR2 / ICDRT / ICDRR / ICSR2.
//!
//! Three channels, one transfer machine each: START, the address byte, the
//! payload either way, then STOP. What answers on the line comes from the
//! device registry in bus.zig, so this file is only about transfers.
//!
//! The thing dev never checked is the interface itself, so a block nobody
//! enabled ran a whole transaction here and nothing at all on the bench.
//! Which accesses ICE and IICRST allow is its own rule in reset.zig.
//!
//! The restart window, where an address written too early is dropped, is its
//! own rule in restart.zig.
//!
//! ICMR3's ACKBT write protection, the one bit in the file that needs its
//! enable in force first, is its own rule in ack.zig.
const std = @import("std");
const periph = @import("../registry.zig");
pub const bus = @import("bus.zig");
pub const flags = @import("flags.zig");
pub const target = @import("target.zig");
const access = @import("../bytelanes.zig");
pub const restart = @import("restart.zig");
pub const stop = @import("stop.zig");
pub const rx = @import("rx.zig");
pub const ack = @import("ack.zig");
const riic_reset = @import("reset.zig");
pub const reset = riic_reset;

pub const win_base = flags.win_base;
pub const win_span = flags.win_span;
pub const channel_stride = flags.channel_stride;
pub const channel_count = flags.channel_count;
pub const line_channel = flags.line_channel;
pub const reg = flags.reg;

/// One RIIC channel: the register shadow, the transfer in flight, and what
/// the run should be told about the traffic it was given.
pub const Channel = struct {
    shadow: [flags.reg.count]u8 = @splat(0),
    /// ICSR2 in controller mode.
    status: u8 = 0,
    busy: bool = false,
    addressed: bool = false,
    acked: bool = false,
    reading: bool = false,
    target_7b: u7 = 0,
    /// The receive path: what the device staged and how much of it is out.
    rx: rx.Rx = .{},
    /// The restart window: RS standing, and the stores it swallowed.
    restart: restart.Restart = .{},
    stop: stop.Stop = .{},
    /// ACKBT's write protection, and the stores it held off.
    ack: ack.Ack = .{},

    /// The responder half, live once ICSER arms an own address.
    target: target.Target = .{},

    /// Transactions that reached STOP with a device ACKing.
    transfers: u32 = 0,
    /// Payload bytes each way.
    sent: u32 = 0,
    received: u32 = 0,
    /// Address bytes nothing on the bus answered. A scan is made of these, so
    /// they are traffic, not a fault.
    nacks: u32 = 0,
    /// Accesses made with ICE clear, so the register file was not powered.
    /// dev answered them all.
    uninit: u32 = 0,
    /// Bus-moving accesses made while IICRST held the machine in reset.
    /// Configuration stored in that window is not a fault and is not counted.
    held: u32 = 0,
    /// START requested while a transaction was already open. dev tore the
    /// open one down and started again, losing a transfer silently.
    st_busy: u32 = 0,
    /// Repeated START requested on an idle bus. There is no condition to
    /// repeat; dev treated it as a plain START.
    rs_idle: u32 = 0,
    /// ICDRT written with no transaction open. dev took the byte as an
    /// address and began a transfer nobody asked for.
    no_start: u32 = 0,
    /// ICDRR read past what the device had to say. dev kept RDRF asserted and
    /// served zeros, so a driver reading too far got data that looked real.
    overread: u32 = 0,

    pub fn quiet(self: *const Channel) bool {
        return self.transfers == 0 and self.nacks == 0 and self.uninit == 0 and
            self.held == 0 and
            self.st_busy == 0 and self.rs_idle == 0 and self.no_start == 0 and
            self.rx.quiet() and self.restart.quiet() and self.ack.quiet() and self.stop.quiet() and
            self.target.quiet();
    }

    /// ICE set and IICRST clear: the block is out of reset and clocked.
    pub fn enabled(self: *const Channel) bool {
        return riic_reset.running(self.shadow[flags.reg.iccr1]);
    }

    fn openTransfer(self: *Channel) void {
        self.busy = true;
        self.addressed = false;
        self.acked = false;
        self.reading = false;
        self.rx.open();
        // The transmit buffer is empty so the driver can put the address
        // byte in it, and the previous phase's flags are not this one's.
        self.status = flags.icsr2.tdre;
    }

    /// A requested STOP waits while the frame still has a byte to hand over
    /// or ICMR3.WAIT is still holding the clock.
    fn stopHeld(self: *const Channel) bool {
        return self.rx.holding() or
            self.shadow[flags.reg.icmr3] & flags.icmr3.wait != 0;
    }

    /// Fire a requested STOP once nothing is holding it any more.
    fn releaseStop(self: *Channel, registry: *bus.Registry) void {
        if (self.stop.release(self.stopHeld())) self.closeTransfer(registry);
    }

    fn closeTransfer(self: *Channel, registry: *bus.Registry) void {
        if (self.acked) {
            if (registry.find(self.target_7b)) |device| device.stop();
            self.transfers += 1;
        }
        self.stop.clear();
        self.busy = false;
        self.addressed = false;
        self.status = flags.icsr2.stop;
    }

    /// The address byte after a (re)START selects a device and it either
    /// answers or it does not.
    fn addressPhase(self: *Channel, registry: *bus.Registry, byte: u8) void {
        self.target_7b = bus.wire.addressOf(byte);
        self.reading = bus.wire.readingOf(byte);
        self.addressed = true;
        const device = registry.answering(self.target_7b) orelse {
            self.acked = false;
            self.nacks += 1;
            self.status |= flags.icsr2.nackf | flags.icsr2.tend | flags.icsr2.tdre;
            return;
        };
        self.acked = true;
        self.status |= flags.icsr2.tend | flags.icsr2.tdre;
        if (!self.reading) return;
        self.rx.stage(device.read(self.rx.staged[0..]), device.stretch());
        if (self.rx.holding()) self.status |= flags.icsr2.rdrf;
    }

    fn writeData(self: *Channel, registry: *bus.Registry, byte: u8) void {
        if (!self.busy) {
            self.no_start += 1;
            return;
        }
        if (self.restart.blocks()) {
            self.restart.note();
            return;
        }
        if (!self.addressed) {
            self.addressPhase(registry, byte);
            return;
        }
        if (!self.acked) return;
        if (registry.find(self.target_7b)) |device| device.write(byte);
        self.sent += 1;
        self.status |= flags.icsr2.tdre | flags.icsr2.tend;
    }

    fn readData(self: *Channel) u8 {
        const byte = self.rx.take(&self.status) orelse return 0;
        self.received += 1;
        return byte;
    }

    /// ICCR2 carries the three condition requests. A START needs an idle bus
    /// and a repeated START needs a busy one; the request bits auto-clear
    /// once the condition is issued, which is what the driver spins on.
    fn control(self: *Channel, registry: *bus.Registry, value: u8) void {
        // Any later touch of ICCR2 means the condition has long since been
        // issued, so the window closes here as well as on the readback.
        _ = self.restart.observe();
        var kept = value;
        if (value & flags.iccr2.st != 0) {
            if (self.busy or registry.held_low) self.st_busy += 1 else self.openTransfer();
            kept &= ~flags.iccr2.st;
        } else if (value & flags.iccr2.rs != 0) {
            if (self.busy) {
                self.openTransfer();
                self.restart.request();
            } else {
                self.rs_idle += 1;
                kept &= ~flags.iccr2.rs;
            }
        } else if (value & flags.iccr2.sp != 0) {
            self.rx.stopAfterNext();
            if (self.busy and !self.stop.request(self.stopHeld())) {
                self.closeTransfer(registry);
            }
            kept &= ~flags.iccr2.sp;
        }
        self.shadow[flags.reg.iccr2] = kept;
    }

    fn ownAddresses(self: *const Channel) [3]u8 {
        return .{
            self.shadow[flags.reg.sarl0],
            self.shadow[flags.reg.sarl1],
            self.shadow[flags.reg.sarl2],
        };
    }

    pub fn read(self: *Channel, registry: *bus.Registry, offset: u32) u8 {
        if (offset >= flags.reg.count) return 0;
        if (offset == flags.reg.iccr1) return self.shadow[offset];
        switch (riic_reset.verdict(self.shadow[flags.reg.iccr1], offset)) {
            .answer => {},
            .unpowered => {
                self.uninit += 1;
                return 0;
            },
            .held => {
                self.held += 1;
                return 0;
            },
        }
        if (self.target.armed) return self.targetRead(offset);
        return switch (offset) {
            flags.reg.icsr2 => self.rx.visible(self.status),
            flags.reg.icdrr => blk: {
                const byte = self.readData();
                // The last byte of the frame is what a requested STOP was
                // waiting for, unless WAIT is still holding the clock.
                self.releaseStop(registry);
                break :blk byte;
            },
            flags.reg.iccr2 => blk: {
                const base = self.shadow[offset] & ~flags.iccr2.bbsy;
                const answer = if (self.busy or registry.held_low) base | flags.iccr2.bbsy else base;
                // This is the look the driver spins on.
                if (self.restart.observe()) {
                    self.shadow[flags.reg.iccr2] =
                        restart.Restart.without(self.shadow[flags.reg.iccr2]);
                }
                break :blk answer;
            },
            else => self.shadow[offset],
        };
    }

    fn targetRead(self: *Channel, offset: u32) u8 {
        return switch (offset) {
            flags.reg.icsr1 => self.target.matched(),
            flags.reg.icsr2 => self.target.status,
            flags.reg.iccr2 => self.target.direction(self.shadow[offset]),
            flags.reg.icdrr => self.target.receive(),
            else => self.shadow[offset],
        };
    }

    pub fn write(self: *Channel, registry: *bus.Registry, offset: u32, value: u8) void {
        if (offset >= flags.reg.count) return;
        if (offset == flags.reg.iccr1) {
            self.shadow[offset] = value;
            if (!self.enabled()) self.reset();
            return;
        }
        switch (riic_reset.verdict(self.shadow[flags.reg.iccr1], offset)) {
            .answer => {},
            .unpowered => {
                self.uninit += 1;
                return;
            },
            .held => {
                self.held += 1;
                return;
            },
        }
        if (offset == flags.reg.icmr3) {
            self.shadow[offset] = self.ack.apply(self.shadow[offset], value);
            self.releaseStop(registry);
            return;
        }
        self.shadow[offset] = value;
        if (offset == flags.reg.icser) {
            self.target.open(value, self.ownAddresses());
            return;
        }
        if (self.target.armed) return self.targetWrite(offset, value);
        switch (offset) {
            flags.reg.iccr2 => self.control(registry, value),
            flags.reg.icdrt => self.writeData(registry, value),
            // Condition flags are write-0-to-clear.
            flags.reg.icsr2 => self.status &= value,
            else => {},
        }
    }

    fn targetWrite(self: *Channel, offset: u32, value: u8) void {
        switch (offset) {
            flags.reg.icdrt => self.target.transmit(value),
            flags.reg.icsr2 => self.target.acknowledge(value),
            else => {},
        }
    }

    /// An interface taken out of ICE, or held in IICRST, loses the transfer
    /// it was in the middle of. The counters are the run's record and stay.
    fn reset(self: *Channel) void {
        self.restart.clear();
        self.stop.clear();
        self.busy = false;
        self.addressed = false;
        self.acked = false;
        self.status = 0;
        self.rx.open();
        self.target = .{};
    }
};

/// The three channels and the one bus they share a device registry for. The
/// EK-RA8D2 routes the expander and the camera to channel 1; nothing in this
/// tree gives the other two channels a device, so they answer NACK.
pub const Riic = struct {
    channels: [flags.channel_count]Channel = @splat(Channel{}),
    devices: bus.Registry = .{},

    pub fn init() Riic {
        return .{};
    }

    pub fn attachDevice(self: *Riic, device: bus.Device) bus.Error!void {
        try self.devices.attach(device);
    }

    pub fn quiet(self: *const Riic) bool {
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    /// An access of any width is the bytes it names, low lane first: every
    /// register in this window is a byte, so a halfword or word access
    /// reaches two or four of them, not just the one it starts on.
    pub fn read(self: *Riic, address: u32, width: u3) u32 {
        var answer: u32 = 0;
        var index: u32 = 0;
        while (index < access.span(width)) : (index += 1) {
            answer = access.place(answer, self.readByte(address +% index), index);
        }
        return answer;
    }

    pub fn write(self: *Riic, address: u32, width: u3, value: u32) void {
        var index: u32 = 0;
        while (index < access.span(width)) : (index += 1) {
            self.writeByte(address +% index, access.byteAt(value, index));
        }
    }

    fn readByte(self: *Riic, address: u32) u8 {
        const offset = address -% flags.win_base;
        const index = offset / flags.channel_stride;
        if (index >= flags.channel_count) return 0;
        return self.channels[index].read(&self.devices, offset % flags.channel_stride);
    }

    fn writeByte(self: *Riic, address: u32, byte: u8) void {
        const offset = address -% flags.win_base;
        const index = offset / flags.channel_stride;
        if (index >= flags.channel_count) return;
        self.channels[index].write(&self.devices, offset % flags.channel_stride, byte);
    }

    pub fn block(self: *Riic) periph.Block {
        return .{
            .name = "RIIC",
            .base = flags.win_base,
            .size = flags.win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Riic = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Riic = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
