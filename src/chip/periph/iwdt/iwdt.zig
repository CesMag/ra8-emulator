//! IWDT: the watchdog OFS0 starts, that software cannot stop, and that only
//! the two-byte sequence keeps alive.
//!
//! The Independent Watchdog Timer at 0x4020_2200 (HUM Ch 28, FSP
//! R_IWDT_BASE) is a 14-bit down-counter on its own ~15 kHz oscillator,
//! outside the CPU clock tree, so it survives a MOCO or HOCO failure that
//! stops WDT0. Its period, window and reset-versus-NMI choice live in the
//! OFS0 option-setting register rather than in these registers: on the RA8D2
//! there is no register-start mode, and IWDTCR / IWDTRCR / IWDTCSTPR are
//! write-locked once the boot ROM has armed the timer. The runtime surface
//! is what `ra8_iwdt.c` uses: refresh, read the counter, read and clear the
//! status.
//!
//! Nothing answered here before this file; the window fell through to the
//! sparse register file, which keeps whatever it is handed. That made two
//! real firmware paths pass in the model and fail on the bench.
//!
//! One: a single write to IWDTRR looked like a refresh. It is not one; the
//! sequence rule lives in refresh.zig.
//!
//! Two: IWDTSR.CNTVAL never moved, so `iwdt_demo`, which refreshes only when
//! the counter has fallen inside its window, waits for a value that a cell
//! will never produce and burns its whole budget. The counter counts here,
//! and status.zig keeps it read-only against the driver's own status
//! clear, which writes the counter bits back.
//!
//! What is deliberately NOT modelled. The IWDTCR TOPS and CKS encodings are
//! not written down in either tree (the header gives their bit positions and
//! says OFS0 is the effective control surface), so no period table is
//! invented: the counter runs the full 14-bit range and the fields ride in
//! the register. `counts_per_tick` below is an emulator-time choice in the
//! same spirit as wdt.zig's, not a silicon number. IWDTCSTPR.SLCSTP halts
//! the counter in Sleep, and Sleep is not modelled, so it rides too.
const iwdt_ofs0 = @import("ofs0.zig");
const iwdt_refresh = @import("refresh.zig");
const iwdt_status = @import("status.zig");
const periph = @import("../registry.zig");
const wdt_clock = @import("../wdt/clock.zig");
const event_queue = @import("../time/event_queue.zig");

pub const ofs0 = iwdt_ofs0;
pub const refresh = iwdt_refresh;
pub const status = iwdt_status;

/// IWDT geometry (ra8_iwdt_regs.h, r_iwdt_regs_t; HUM Ch 28.2 p 1273).
pub const win_base: u32 = 0x4020_2200;
pub const win_span: u32 = 0x0C;

pub const off = struct {
    pub const rr: u32 = 0x00;
    pub const cr: u32 = 0x02;
    pub const sr: u32 = 0x04;
    pub const rcr: u32 = 0x06;
    pub const cstpr: u32 = 0x08;
};

/// IWDTCR fields (HUM Ch 28.2.3 p 1276). Held, never acted on: the
/// encodings behind them are not in this tree and OFS0 owns the period.
pub const control = struct {
    pub const tops: u16 = 0x0003;
    pub const cks: u16 = 0x00F0;
    pub const rpes: u16 = 0x0300;
    pub const rpss: u16 = 0x3000;
};

/// IWDTRCR (HUM Ch 28.2.4 p 1277): what an underflow does.
pub const reset_control = struct {
    /// RSTIRQS, bit 7: 1 = reset the part, 0 = NMI.
    pub const rstirqs: u8 = 0x80;
};

/// IWDTCSTPR (HUM Ch 28.2.5 p 1278).
pub const count_stop = struct {
    /// SLCSTP, bit 7: halt the counter in Sleep. Sleep is not modelled.
    pub const slcstp: u8 = 0x80;
};

/// The counter's full reload: its own width, since no period table exists
/// here to pick a shorter one.
pub const full_scale: u16 = iwdt_status.field.cntval;

/// How far the counter falls at one run-loop boundary. Chosen so the full
/// range is crossed in sixteen boundaries, well inside a normal run budget:
/// firmware waits on this counter by polling it, and a rate the run cannot
/// cross is a wait that never ends, which is the bug this file exists to
/// stop modelling. An emulator-time number in the same spirit as wdt.zig's,
/// not a silicon one: the real period comes from OFS0 and IWDTCLK.
pub const counts_per_tick: u16 = 1024;

pub const Iwdt = struct {
    pub const EventHook = struct {
        context: *anyopaque,
        underflowFn: *const fn (*anyopaque) void,
    };

    iwdtcr: u16 = 0,
    iwdtrcr: u8 = 0,
    iwdtcstpr: u8 = 0,
    sequence: iwdt_refresh.Sequence = .{},
    counter: u16 = full_scale,
    /// Whether the counter is running. Once the board has read OFS0
    /// (applyOptionWord), OFS0 alone decides: auto-start arms it at reset,
    /// and IWDTSTRT set leaves it stopped for good. A unit that was never
    /// handed an option word, as in a bare test, still starts on its first
    /// refresh.
    armed: bool = false,
    /// The option word the board read at OFS0, once it has read one.
    option_word: ?u32 = null,
    /// Refresh sequences that arrived while OFS0 held the counter stopped.
    /// On silicon they do nothing, so they start nothing here either.
    stopped_refreshes: u32 = 0,
    flags: u16 = 0,
    /// Completed two-byte sequences that reloaded the counter.
    refreshes: u32 = 0,
    /// Writes to IWDTRR that were not part of a sequence and did nothing.
    dropped: u32 = 0,
    /// Times the counter reached zero.
    underflows: u32 = 0,
    /// Virtual ns toward the next tick, left over from the last boundary.
    carry_ns: u64 = 0,
    /// Underflows that asked for an NMI rather than a reset, which this
    /// model has nowhere to deliver.
    nmis: u32 = 0,
    /// Set when an underflow asked for a reset in RSTIRQS mode. The board
    /// takes it and hands it to the reset unit.
    reset_requested: bool = false,
    /// Stores to IWDTSR that wrote a one at a standing flag, clearing
    /// nothing.
    bad_acks: u32 = 0,
    /// Stores to IWDTSR that carried counter bits, which never land.
    frozen_writes: u32 = 0,
    event_hook: ?EventHook = null,

    pub fn init() Iwdt {
        return .{};
    }

    pub fn quiet(self: *const Iwdt) bool {
        return !self.armed and self.refreshes == 0 and self.dropped == 0 and
            self.flags == 0 and self.bad_acks == 0 and self.frozen_writes == 0 and
            self.stopped_refreshes == 0;
    }

    /// Take the OFS0 word the image carries, the way the boot ROM does at
    /// reset: auto-start arms a full counter, and IWDTSTRT set stops it.
    pub fn applyOptionWord(self: *Iwdt, word: u32) void {
        self.option_word = word;
        self.armed = iwdt_ofs0.autoStarts(word);
        self.counter = full_scale;
    }

    /// OFS0 was read and selected the stopped counter.
    pub fn stoppedByOptions(self: *const Iwdt) bool {
        const word = self.option_word orelse return false;
        return !iwdt_ofs0.autoStarts(word);
    }

    /// The ticks `elapsed_ns` of virtual time stands for, so the counter
    /// follows the time base rather than the number of boundaries.
    pub fn tickFor(self: *Iwdt, elapsed_ns: u64) void {
        var n = wdt_clock.ticksIn(&self.carry_ns, elapsed_ns);
        while (n > 0) : (n -= 1) self.tick();
    }

    /// One run-loop chunk of counting. The counter cannot be stopped by
    /// software, so it reloads and keeps going past an underflow. In RSTIRQS
    /// mode the board then performs the reset this asks for as a warm
    /// reboot, the same seam a software reset takes.
    pub fn tick(self: *Iwdt) void {
        if (!self.armed) return;
        if (self.counter > counts_per_tick) {
            self.counter -= counts_per_tick;
            return;
        }
        self.counter = full_scale;
        self.underflows +%= 1;
        if (self.event_hook) |hook| hook.underflowFn(hook.context);
        self.flags |= iwdt_status.field.undff;
        if (self.iwdtrcr & reset_control.rstirqs != 0) {
            self.reset_requested = true;
        } else {
            self.nmis +%= 1;
        }
    }

    /// The virtual ns the next underflow lands at, from `now_ns`: the tick
    /// that finds the counter at or under `counts_per_tick`, so
    /// ceil(counter / counts_per_tick) ticks and never fewer than one. Null
    /// while the counter is not running.
    pub fn underflowDueAt(self: *const Iwdt, now_ns: u64) ?u64 {
        if (!self.armed) return null;
        const ticks = @max(1, (@as(u64, self.counter) + counts_per_tick - 1) / counts_per_tick);
        return now_ns + ticks * wdt_clock.ns_per_tick - self.carry_ns;
    }

    /// Put the next underflow on `queue` under `wdt_clock.queue_id.iwdt`,
    /// the same every-boundary re-arm the WDT makes.
    pub fn arm(self: *const Iwdt, queue: *event_queue.EventQueue, now_ns: u64) event_queue.Error!void {
        _ = queue.cancel(wdt_clock.queue_id.iwdt);
        const at = self.underflowDueAt(now_ns) orelse return;
        try queue.schedule(at, wdt_clock.queue_id.iwdt);
    }

    fn refreshWrite(self: *Iwdt, value: u8) void {
        switch (self.sequence.accept(value)) {
            .reloaded => {
                if (self.stoppedByOptions()) {
                    self.stopped_refreshes +%= 1;
                    return;
                }
                self.armed = true;
                self.counter = full_scale;
                self.refreshes +%= 1;
            },
            .primed => {},
            .ignored => self.dropped +%= 1,
        }
    }

    fn ackWrite(self: *Iwdt, written: u16) void {
        if (iwdt_status.refused(self.flags, written)) self.bad_acks +%= 1;
        if (iwdt_status.carriesCount(written)) self.frozen_writes +%= 1;
        self.flags = iwdt_status.ack(self.flags, written);
    }

    pub fn read(self: *Iwdt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const word: u16 = switch (offset & ~@as(u32, 1)) {
            off.rr => @intFromBool(self.sequence.pending()) * iwdt_refresh.byte.second,
            off.cr => self.iwdtcr,
            off.sr => iwdt_status.value(self.counter, self.flags),
            off.rcr => self.iwdtrcr,
            off.cstpr => self.iwdtcstpr,
            else => 0,
        };
        if (width >= 2 and offset & 1 == 0) return word;
        const shift: u4 = @intCast((offset & 1) * 8);
        return (@as(u32, word) >> shift) & 0xFF;
    }

    pub fn write(self: *Iwdt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        switch (offset & ~@as(u32, 1)) {
            off.rr => self.refreshWrite(@truncate(value)),
            off.cr => self.iwdtcr = merge(self.iwdtcr, offset, width, value),
            off.sr => self.ackWrite(merge(iwdt_status.value(self.counter, self.flags), offset, width, value)),
            off.rcr => self.iwdtrcr = @truncate(merge(self.iwdtrcr, offset, width, value)),
            off.cstpr => self.iwdtcstpr = @truncate(merge(self.iwdtcstpr, offset, width, value)),
            else => {},
        }
    }

    pub fn block(self: *Iwdt) periph.Block {
        return .{
            .name = "IWDT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// A halfword store carries the whole register; a byte store replaces one
/// half of it and leaves the other standing.
fn merge(current: u16, offset: u32, width: u3, value: u32) u16 {
    if (width >= 2 and offset & 1 == 0) return @truncate(value);
    const shift: u4 = @intCast((offset & 1) * 8);
    const keep: u16 = if (shift == 0) 0xFF00 else 0x00FF;
    return (current & keep) | (@as(u16, @truncate(value & 0xFF)) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Iwdt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Iwdt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
