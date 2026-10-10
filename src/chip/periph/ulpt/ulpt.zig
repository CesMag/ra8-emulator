//! ULPT: the low-power timer a sleeping part wakes itself on.
//!
//! Two channels of a 32-bit reloading down-counter at 0x4022_0000, clocked
//! from the LOCO-derived ULPTLCLK so they keep running through Software
//! Standby (HUM Ch 25 p 1187). That is the whole point of the block: the
//! deep-idle images arm a channel, drop into standby on WFI, and rely on the
//! underflow to cancel standby through the ICU. Without a model the underflow
//! never happens, the registered ISR never runs, and the wake count stays
//! zero while the run burns its budget in the wait loop.
//!
//!   ULPTCNT (+0x00, 32b)  counter; a write seeds the count and the reload
//!   ULPTCMA (+0x04, 32b)  compare match A
//!   ULPTCMB (+0x08, 32b)  compare match B
//!   ULPTCR  (+0x0C, 8b)   TSTART b0, TCSTF b1 (RO), TSTOP b2 (W), TUNDF b5
//!   ULPTMR1 (+0x0D, 8b)   TMOD, TEDGPL, TCK count source
//!   ULPTMR2 (+0x0E, 8b)   the prescaler in front of the counter
//!   ULPTIOC (+0x10, 8b)   I/O control
//!
//! ULPTCR shares the AGT's AGTCR layout (HUM Ch 25.2.1 p 1190, mirroring
//! Ch 24.2.6 p 1175), so a TCSTF poll and a TUNDF poll both read real state.
//!
//! Ported from board_periph_ulpt.c on dev, with three departures, all of them
//! places where firmware that misbehaves on the bench passes there.
//!
//! One: dev drops TSTOP on the floor. Its ULPTCR write keeps the TSTART bit
//! and nothing else, so the forced stop the driver issues as TSTART|TSTOP
//! (0x05) leaves the channel running there and stops it on silicon: the
//! emulator keeps waking a part the firmware believes it parked. Here TSTOP
//! wins over TSTART in the same write, clears TCSTF, and holds the count.
//!
//! Two: dev raises the underflow event on the RISING EDGE of TUNDF only, so a
//! periodic image that never clears the flag gets exactly one wake there and
//! wakes every period on the bench: the run hangs in the emulator and the
//! failure looks like the ISR, not the flag. The interrupt is requested at
//! every underflow here, and TUNDF is separately sticky until written zero.
//!
//! Three: dev steps every channel by one constant per chunk whatever the mode
//! registers say, so shortening or lengthening the configured period changes
//! nothing. There is no absolute time here either, but ULPTMR2's prescaler is
//! at least ORDERED: the step is scaled down by the selected divider, so a
//! slower configured source really does underflow less often.
//!
//! Four: neither tree compared the compare values. ULPTCMA and ULPTCMB were
//! storage on both, so a count could run straight past one and nothing said
//! so. The comparison lives in compare.zig now, and the flags it raises
//! are AGTCR's TCMAF and TCMBF, which ULPTCR mirrors.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

const bytelanes = @import("../bytelanes.zig");
const periph = @import("../registry.zig");
pub const compare = @import("compare.zig");
pub const regs = @import("regs.zig");

/// The compare pair, re-exported so a caller reaches it through the block.
pub const match = compare;

/// ULPT geometry (ra8_ulpt_regs.h; HUM Ch 25.1 p 1187).
pub const win_base: u32 = 0x4022_0000;
pub const stride: u32 = 0x100;
pub const channels: usize = 2;
pub const win_span: u32 = stride * channels;

/// Register offsets inside a channel. The map owns them, because the map is
/// what an access is resolved against.
pub const off = regs.at;

/// ULPTCR (HUM Ch 25.2.1 p 1190). TSTART is RW, TCSTF read-only, TSTOP
/// write-only, TUNDF write-ZERO-to-clear like the watchdog's status flags.
pub const control = struct {
    pub const tstart: u8 = 0x01;
    pub const tcstf: u8 = 0x02;
    pub const tstop: u8 = 0x04;
    pub const tundf: u8 = compare.flag.undf;
    pub const tcmaf: u8 = compare.flag.cmaf;
    pub const tcmbf: u8 = compare.flag.cmbf;
    /// The bits a control write keeps rather than sets.
    pub const flags: u8 = compare.flag.all;
};

/// ULPTMR2 (HUM Ch 25.2.3 p 1192): the low-order field selects the divider in
/// front of the counter. Ordered, not calibrated: what matters is that a
/// bigger divider counts slower.
pub const mode2 = struct {
    pub const divider: u8 = 0x07;
};

/// The events channel 0 can raise (RA8D2 ELC signal table). ULPT1 has no
/// distinct event in this codebase and no image drives it, so only channel 0
/// raises anything.
pub const event = struct {
    pub const underflow: u16 = 0x080;
};

/// Counter ticks one run-loop chunk stands for, before the ULPTMR2 divider.
/// Sized above the largest period the deep-idle images load (0x8000) so an
/// armed channel underflows on its first idle tick: the emulator fast
/// forwards a standby WFI one tick at a time, and the underflow has to land
/// inside that single tick to be the source that cancels standby.
pub const ticks_per_chunk: u32 = 0x4_0000;

/// At most one event is due per boundary, from channel 0.
pub const Due = Bounded(u16, 1);

/// One channel: a reloading down-counter plus its mode and status bytes.
pub const Channel = struct {
    counter: u32 = 0,
    reload: u32 = 0,
    /// ULPTCMA and ULPTCMB, and what they have matched.
    compares: compare.Pair = .{},
    cr: u8 = 0,
    mr1: u8 = 0,
    mr2: u8 = 0,
    mr3: u8 = 0,
    ioc: u8 = 0,
    /// Underflows reached, which is also the number of events raised.
    underflows: u32 = 0,
    /// Forced stops taken through TSTOP, the bit dev discards.
    forced_stops: u32 = 0,

    pub fn running(self: Channel) bool {
        return self.cr & control.tstart != 0;
    }

    /// The ULPTMR2 divider, as a power of two. A count source this model does
    /// not know still divides by something ordered rather than by one.
    pub fn divider(self: Channel) u32 {
        return @as(u32, 1) << @intCast(self.mr2 & mode2.divider);
    }

    /// One chunk of counting. Returns true when this chunk underflowed, which
    /// is one interrupt request on silicon whatever TUNDF already reads. A
    /// compare value the chunk passed raises its own flag either way.
    pub fn tick(self: *Channel) bool {
        if (!self.running()) return false;
        const step = @max(1, ticks_per_chunk / self.divider());
        const before = self.counter;
        if (before >= step) {
            // Reaching exactly zero is not an underflow yet: the borrow
            // happens on the next decrement past it. dev's port takes the
            // underflow branch here and then wraps `step - counter - 1`
            // through zero, which lands the counter on a junk reload.
            self.counter = before - step;
            self.cr |= self.compares.step(before, self.counter, false, self.reload);
            return false;
        }
        // Periodic: reload and carry the overshoot, so a period shorter than
        // one chunk still lands on a sane count rather than wrapping.
        const span = @as(u64, self.reload) + 1;
        const deficit = step - before;
        self.counter = self.reload - @as(u32, @intCast((deficit - 1) % span));
        self.cr |= control.tundf;
        self.underflows +%= 1;
        self.cr |= self.compares.step(before, self.counter, true, self.reload);
        return true;
    }

    /// TSTOP beats TSTART in the same write: the driver stops a channel with
    /// both bits set, and silicon takes the stop. TCSTF follows the state the
    /// write leaves, and a status flag only survives a write that carried its
    /// own bit set, which is how AGTCR's flags clear too.
    fn writeControl(self: *Channel, value: u8) void {
        const keep = self.cr & value & control.flags;
        if (value & control.tstop != 0) {
            if (self.running()) self.forced_stops +%= 1;
            self.cr = keep;
            return;
        }
        const start = value & control.tstart;
        self.cr = start | (if (start != 0) control.tcstf else 0) | keep;
    }
};

pub const Ulpt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Channel 0 underflows that have not been handed to the event path yet.
    pending: u32 = 0,

    pub fn init() Ulpt {
        return .{};
    }

    /// The chunk boundary. Every underflow is an interrupt request, so they
    /// are counted rather than collapsed into a flag edge.
    pub fn tick(self: *Ulpt) void {
        for (&self.channels, 0..) |*channel, index| {
            if (channel.tick() and index == 0) self.pending +%= 1;
        }
    }

    /// One event per boundary at most. A backlog stays pending and drains on
    /// later boundaries instead of being dropped.
    pub fn dueEvents(self: *Ulpt) Due {
        var due = Due{};
        if (self.pending == 0) return due;
        self.pending -= 1;
        due.appendAssumeCapacity(event.underflow);
        return due;
    }

    pub fn quiet(self: *const Ulpt) bool {
        for (self.channels) |channel| {
            if (channel.underflows != 0 or channel.running()) return false;
            if (!channel.compares.quiet()) return false;
        }
        return true;
    }

    /// AN ACCESS IS THE BYTES IT NAMES, LOW LANE FIRST. The answer is
    /// assembled right-justified, which is what `registry.mask` hands back to
    /// the core, so a word read of the ULPTCR..ULPTMR3 group answers all four
    /// of those registers and a byte read of one answers that one.
    pub fn read(self: *Ulpt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return 0;
        const channel = &self.channels[index];
        const start = offset % stride;
        var answer: u32 = 0;
        var lane: u32 = 0;
        while (lane < bytelanes.span(width)) : (lane += 1) {
            answer = bytelanes.place(answer, readByte(channel, start +% lane), lane);
        }
        if (namesCompare(start, width)) channel.compares.touch();
        return answer;
    }

    /// The same rule for a store, in ascending lane order: a halfword store at
    /// ULPTCR carries the control byte in the low lane and the count source
    /// above it, and the driver that wrote it meant start, then mode. A byte
    /// no register owns holds nothing.
    pub fn write(self: *Ulpt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / stride;
        if (index >= channels) return;
        const channel = &self.channels[index];
        const start = offset % stride;
        var lane: u32 = 0;
        while (lane < bytelanes.span(width)) : (lane += 1) {
            writeByte(channel, start +% lane, bytelanes.byteAt(value, lane));
        }
        if (namesCompare(start, width)) channel.compares.touch();
    }

    pub fn block(self: *Ulpt) periph.Block {
        return .{
            .name = "ULPT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// One byte out of the register that owns it. A byte past ULPTIOC, or past
/// the end of a channel, belongs to nothing and reads zero.
fn readByte(channel: *const Channel, local: u32) u8 {
    const place = regs.owner(local) orelse return 0;
    const shift = bytelanes.shift(place.index);
    return switch (place.reg) {
        .cnt => @truncate(channel.counter >> shift),
        .cma => @truncate(channel.compares.a >> shift),
        .cmb => @truncate(channel.compares.b >> shift),
        .cr => channel.cr,
        .mr1 => channel.mr1,
        .mr2 => channel.mr2,
        .mr3 => channel.mr3,
        .ioc => channel.ioc,
    };
}

/// One byte into the register that owns it, leaving the rest of that register
/// where it was: a driver is free to load a 32-bit period in two halfword
/// stores, and both of them have to land.
fn writeByte(channel: *Channel, local: u32, byte: u8) void {
    const place = regs.owner(local) orelse return;
    switch (place.reg) {
        .cnt => {
            // A write seeds both the live count and the period the counter
            // reloads from (ra8_ulpt_start writes one value).
            const seeded = fold(channel.counter, place.index, byte);
            channel.counter = seeded;
            channel.reload = seeded;
        },
        .cma => channel.compares.a = fold(channel.compares.a, place.index, byte),
        .cmb => channel.compares.b = fold(channel.compares.b, place.index, byte),
        .cr => channel.writeControl(byte),
        .mr1 => channel.mr1 = byte,
        .mr2 => channel.mr2 = byte,
        .mr3 => channel.mr3 = byte,
        .ioc => channel.ioc = byte,
    }
}

/// Whether an access reaches either compare register. The pair counts the
/// accesses that reach it, so one access is one touch however many of its
/// bytes land there.
fn namesCompare(start: u32, width: u3) bool {
    var lane: u32 = 0;
    while (lane < bytelanes.span(width)) : (lane += 1) {
        const place = regs.owner(start +% lane) orelse continue;
        if (regs.isCompare(place.reg)) return true;
    }
    return false;
}

/// Put one byte back into a 32-bit register at its lane.
fn fold(current: u32, index: u32, byte: u8) u32 {
    const shift = bytelanes.shift(index);
    const window = @as(u32, 0xFF) << shift;
    return (current & ~window) | (@as(u32, byte) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ulpt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ulpt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
