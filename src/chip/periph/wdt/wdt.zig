//! WDT0: the window watchdog, so a missed refresh actually times out.
//!
//! The Window Watchdog Timer at 0x4020_2600 (HUM Ch 27) is a down-counter the
//! firmware has to keep reloading. Two things end a run on silicon: letting it
//! reach zero, and refreshing it *too early*. The second is the one that gets
//! missed. The counter has a permitted refresh window, and a reload issued
//! before the window opens is a refresh error, which with WDTRCR.RSTIRQS set
//! resets the part exactly as an underflow does. A watchdog service routine
//! called from a fast loop trips it, and the failure looks like a spontaneous
//! reboot rather than a watchdog fault.
//!
//!   WDTRR  (+0x00, 8b)   refresh register: 0x00 then 0xFF reloads the counter
//!   WDTCR  (+0x02, 16b)  TOPS timeout, CKS divider, RPSS/RPES window edges
//!   WDTSR  (+0x04, 16b)  CNTVAL[13:0] live counter, UNDFF[14], REFEF[15]
//!   WDTRCR (+0x06, 8b)   RSTIRQS: 1 = reset on underflow, 0 = NMI/IRQ
//!
//! Ported from board_periph_wdt.c on dev, with three departures from it, all
//! of them places where firmware that fails on the bench passes there.
//!
//! One: dev models no refresh window at all, so a refresh is always accepted
//! ("the model does not synthesise the refresh-error path"). Here the counter
//! position is checked against RPSS/RPES and an early reload latches REFEF and
//! refuses to reload, which is what the hardware does.
//!
//! Two: dev clears UNDFF on the next refresh, so a driver that never reads the
//! flag still sees a clean status register. HUM Ch 27.2.3 p 1076 gives both
//! flags one way down, a write of ZERO to the bit, so they are sticky here and
//! only a write-zero takes them off. Write-one clears nothing, the same
//! opposite polarity that bit the ICU (IR) and the voltage monitors (DET).
//!
//! Three: dev maps every timeout to one constant number of chunks, so a
//! firmware that shortens its timeout period sees no change and a firmware
//! that lengthens it sees no change either. Here the counter holds watchdog
//! counts, TOPS cycles less one after a reload the way CNTVAL reads on
//! silicon, so a driver comparing CNTVAL against its own window bounds
//! (wdt_window_demo checks 256..768 of 1024) reads the units it expects.
//! How many ticks one count takes comes from src/chip/periph/wdt/clock.zig,
//! which carries the bench's measured rate.
//!
//! Four: the three control registers take one write each after reset and are
//! deaf afterwards (HUM Ch 27.3.2, and see src/chip/periph/wdt/write_once.zig).
//! dev took every write, so a firmware reconfiguring its watchdog mid-run got
//! the new settings here and keeps the old ones on the bench. WDTCSTPR is the
//! register that makes it bite: ra8_wdt_init programmes it, and then
//! ra8_wdt_deinit, ra8_wdt_enter_stop and ra8_wdt_exit_stop each write it
//! again expecting the Sleep-stop posture to follow them. On silicon none of
//! those three land. The register did not exist in this model at all before,
//! so it reads its programmed value now rather than zero.
//!
//! Deliberately untouched: WDTRCR keeps returning every bit it was given even
//! though only RSTIRQS is implemented, and the odd byte above each 8-bit
//! control register still reaches it the way it always has here. Both are the
//! narrow-access vein, not this rule.
pub const clock = @import("clock.zig");
const periph = @import("../registry.zig");
const write_once = @import("write_once.zig");
const event_queue = @import("../time/event_queue.zig");

/// WDT0 geometry (ra8_wdt_regs.h, r_wdt_regs_t; HUM Ch 27.2 p 1070).
pub const win_base: u32 = 0x4020_2600;
pub const win_span: u32 = 0x10;

pub const off = struct {
    pub const wdtrr: u32 = 0x00;
    pub const wdtcr: u32 = 0x02;
    pub const wdtsr: u32 = 0x04;
    pub const wdtrcr: u32 = 0x06;
    pub const wdtcstpr: u32 = 0x08;
};

/// The refresh register takes a two-byte sequence, not a value.
pub const refresh = struct {
    pub const first: u8 = 0x00;
    pub const second: u8 = 0xFF;
};

/// WDTCR fields (HUM Ch 27.2.2 p 1072).
pub const control = struct {
    pub const tops: u16 = 0x0003;
    pub const cks: u16 = 0x00F0;
    pub const cks_shift: u4 = 4;
    pub const rpes: u16 = 0x0300;
    pub const rpes_shift: u4 = 8;
    pub const rpss: u16 = 0x3000;
    pub const rpss_shift: u4 = 12;
};

/// WDTSR fields (HUM Ch 27.2.3 p 1076). Both flags are write-ZERO-to-clear.
pub const status = struct {
    pub const cntval: u16 = 0x3FFF;
    pub const undff: u16 = 0x4000;
    pub const refef: u16 = 0x8000;
    pub const flags: u16 = undff | refef;
};

/// WDTRCR (HUM Ch 27.2.4 p 1077): what an underflow or refresh error does.
pub const reset_control = struct {
    pub const rstirqs: u8 = 0x80;
};

/// WDTCSTPR (HUM Ch 27.2.5 p 1262): SLCSTP is the only bit there is, and it
/// halts the counter while the CPU is asleep.
pub const count_stop = struct {
    pub const slcstp: u8 = 0x80;
};

/// TOPS[1:0]: the counter's full reload, in watchdog cycles.
pub const tops_cycles = [4]u32{ 1024, 4096, 8192, 16384 };

/// RPSS[1:0]: where the permitted window opens, as a percentage of the count
/// still to run. 100% means the window is open from the reload.
pub const window_start_percent = [4]u8{ 25, 50, 75, 100 };

/// RPES[1:0]: where the window closes. 0% means it stays open to underflow.
pub const window_end_percent = [4]u8{ 75, 50, 25, 0 };

/// The largest count CNTVAL can hold.
pub const max_count: u32 = status.cntval;

pub const Wdt = struct {
    pub const EventHook = struct {
        context: *anyopaque,
        refreshErrorFn: *const fn (*anyopaque) void,
        underflowFn: *const fn (*anyopaque) void,
    };

    wdtcr: u16 = 0,
    wdtrcr: u8 = 0,
    wdtcstpr: u8 = 0,
    /// Which control registers have spent their one post-reset write.
    once: write_once.Once = .{},
    last_rr: u8 = 0xFF,
    armed: bool = false,
    counter: u32 = 0,
    /// Ticks run since the counter last moved.
    pace: u32 = 0,
    /// Virtual ns toward the next tick, left over from the last boundary.
    carry_ns: u64 = 0,
    flags: u16 = 0,
    /// Refreshes that reloaded the counter.
    refreshes: u32 = 0,
    /// Refreshes refused because the window was not open yet.
    early: u32 = 0,
    /// Underflows reached.
    underflows: u32 = 0,
    /// Set once an underflow or refresh error asked for a reset in RSTIRQS
    /// mode. The reset itself belongs to the reset block, which is not ported
    /// yet, so the request is latched and reported rather than performed.
    reset_requested: bool = false,
    /// Acks that cleared nothing because they wrote a one at a flag.
    bad_acks: u32 = 0,
    /// Control-register stores that landed nowhere because that register had
    /// already had its one write.
    locked_writes: u32 = 0,

    event_hook: ?EventHook = null,
    pub fn init() Wdt {
        return .{};
    }

    pub fn quiet(self: *const Wdt) bool {
        return !self.armed and self.refreshes == 0 and self.flags == 0 and
            self.early == 0 and self.bad_acks == 0 and self.locked_writes == 0;
    }

    /// The full reload for the programmed TOPS, in watchdog counts: a
    /// 1024-cycle period reloads to 1023 and counts down to zero.
    pub fn reload(self: *const Wdt) u32 {
        return @min(tops_cycles[self.wdtcr & control.tops] - 1, max_count);
    }

    /// True while the counter sits inside the refresh window RPSS/RPES marks
    /// out. Both edges are percentages of the FULL timeout, the TOPS cycle
    /// count, not of the reload one below it: ra8_wdt.h says so for both
    /// fields, and wdt_window_demo bounds its own refreshes at 25% and 75%
    /// of 1024, 256 and 768. Taken against the 1023 reload, 75% came out at
    /// 767 and the demo's refresh at 768 was refused. Both edges inclusive.
    pub fn windowOpen(self: *const Wdt) bool {
        const edges = self.windowCounts();
        return self.counter <= edges.opens and self.counter >= edges.closes;
    }

    /// The counter values the window opens and closes at, both inclusive.
    pub fn windowCounts(self: *const Wdt) struct { opens: u32, closes: u32 } {
        const full = tops_cycles[self.wdtcr & control.tops];
        return .{
            .opens = percentOf(full, window_start_percent[(self.wdtcr & control.rpss) >> control.rpss_shift]),
            .closes = percentOf(full, window_end_percent[(self.wdtcr & control.rpes) >> control.rpes_shift]),
        };
    }

    /// The virtual ns the window next opens and closes at, from `now_ns`.
    /// Null for an edge already passed, for a window that stays open to
    /// underflow (RPES 0%), and for both while disarmed. The counter
    /// reaches `v` after `counter - v` counts, less the ticks already paced.
    pub fn windowEdgesAt(self: *const Wdt, now_ns: u64) WindowEdges {
        if (!self.armed) return .{};
        const edges = self.windowCounts();
        const opens_at = if (self.counter > edges.opens) self.reachesAt(edges.opens, now_ns) else null;
        const closes_at = if (edges.closes > 0 and self.counter >= edges.closes) self.reachesAt(edges.closes - 1, now_ns) else null;
        return .{ .opens_at = opens_at, .closes_at = closes_at };
    }

    fn reachesAt(self: *const Wdt, value: u32, now_ns: u64) u64 {
        const per = clock.ticksPerCount(@truncate((self.wdtcr & control.cks) >> control.cks_shift));
        const ticks = @as(u64, self.counter - value) * per - self.pace;
        return now_ns + ticks * clock.ns_per_tick - self.carry_ns;
    }

    /// The ticks `elapsed_ns` of virtual time stands for, so the counter
    /// follows the time base rather than the number of boundaries.
    pub fn tickFor(self: *Wdt, elapsed_ns: u64) void {
        var n = clock.ticksIn(&self.carry_ns, elapsed_ns);
        while (n > 0) : (n -= 1) self.tick();
    }

    /// One run-loop chunk. The counter moves once every
    /// `clock.ticksPerCount` of these at the programmed divider.
    pub fn tick(self: *Wdt) void {
        if (!self.armed) return;
        self.pace += 1;
        if (self.pace < clock.ticksPerCount(@truncate((self.wdtcr & control.cks) >> control.cks_shift))) return;
        self.pace = 0;
        self.count();
    }

    /// The virtual ns the next underflow lands at, from `now_ns`, at the
    /// per-tick pacing: `counter + 1` counts, each `ticksPerCount` ticks, less
    /// the ticks already paced toward the first and the ns already carried
    /// toward the next tick. Null while disarmed.
    pub fn underflowDueAt(self: *const Wdt, now_ns: u64) ?u64 {
        if (!self.armed) return null;
        const per = clock.ticksPerCount(@truncate((self.wdtcr & control.cks) >> control.cks_shift));
        const ticks = (@as(u64, self.counter) + 1) * per - self.pace;
        return now_ns + ticks * clock.ns_per_tick - self.carry_ns;
    }

    /// Put the next underflow on `queue` under `clock.queue_id.wdt`, and the
    /// next window edge under `clock.queue_id.wdt_window`, dropping whatever
    /// was there. Called every boundary, so a refresh, a start and an
    /// underflow all re-arm, and a disarmed counter leaves nothing queued.
    pub fn arm(self: *const Wdt, queue: *event_queue.EventQueue, now_ns: u64) event_queue.Error!void {
        _ = queue.cancel(clock.queue_id.wdt);
        _ = queue.cancel(clock.queue_id.wdt_window);
        const at = self.underflowDueAt(now_ns) orelse return;
        try queue.schedule(at, clock.queue_id.wdt);
        const edges = self.windowEdgesAt(now_ns);
        if (edges.opens_at orelse edges.closes_at) |edge| try queue.schedule(edge, clock.queue_id.wdt_window);
    }

    /// One watchdog count. An armed counter that reaches zero underflows
    /// once: the flag latches, a reset is asked for in RSTIRQS mode, and the
    /// counter disarms so it cannot fire again unrefreshed.
    pub fn count(self: *Wdt) void {
        if (!self.armed) return;
        if (self.counter > 0) {
            self.counter -= 1;
            return;
        }
        self.armed = false;
        self.underflows +%= 1;
        if (self.event_hook) |hook| hook.underflowFn(hook.context);
        self.flags |= status.undff;
        if (self.wdtrcr & reset_control.rstirqs != 0) self.reset_requested = true;
    }

    /// The 0x00 then 0xFF sequence. The first one arms a stopped counter; any
    /// later one is a reload, and a reload before the window opens is a
    /// refresh error that reloads nothing.
    fn refreshWrite(self: *Wdt, byte: u8) void {
        defer self.last_rr = byte;
        if (self.last_rr != refresh.first or byte != refresh.second) return;
        if (self.armed and !self.windowOpen()) {
            self.early +%= 1;
            if (self.event_hook) |hook| hook.refreshErrorFn(hook.context);
            self.flags |= status.refef;
            if (self.wdtrcr & reset_control.rstirqs != 0) self.reset_requested = true;
            return;
        }
        self.armed = true;
        self.counter = self.reload();
        self.pace = 0;
        self.refreshes +%= 1;
    }

    /// WDTSR takes a write of zero at a flag to clear it. A write of one
    /// leaves it standing, and cannot set it either.
    fn ackWrite(self: *Wdt, value: u16) void {
        const held = self.flags & status.flags;
        const ones = value & held;
        if (ones != 0) self.bad_acks +%= 1;
        self.flags = ones;
    }

    /// Ask one of the three locked control registers for its one post-reset
    /// write. True means the store lands nowhere: HUM Ch 27.3.2 gives each of
    /// them a single write and nothing reopens them short of a reset. The
    /// width does not matter, so a driver that programmes WDTCR as two byte
    /// stores spends the register's one write on the first of them.
    fn locked(self: *Wdt, which: write_once.Register) bool {
        if (self.once.claim(which)) return false;
        self.locked_writes +%= 1;
        return true;
    }

    pub fn read(self: *Wdt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const word: u16 = switch (offset & ~@as(u32, 1)) {
            off.wdtcr => self.wdtcr,
            off.wdtsr => @as(u16, @intCast(self.counter & status.cntval)) | self.flags,
            off.wdtrcr => self.wdtrcr,
            off.wdtcstpr => self.wdtcstpr,
            // WDTRR reads 0 outside a refresh sequence (HUM Ch 27.2.1).
            else => 0,
        };
        if (width >= 2 and offset & 1 == 0) return word;
        const shift: u4 = @intCast((offset & 1) * 8);
        return (@as(u32, word) >> shift) & 0xFF;
    }

    pub fn write(self: *Wdt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        switch (offset & ~@as(u32, 1)) {
            off.wdtrr => self.refreshWrite(@truncate(value)),
            off.wdtcr => if (!self.locked(.control)) {
                self.wdtcr = self.merge(self.wdtcr, offset, width, value);
            },
            off.wdtsr => self.ackWrite(self.merge(self.flags | @as(u16, @intCast(self.counter & status.cntval)), offset, width, value)),
            off.wdtrcr => if (!self.locked(.reset_control)) {
                self.wdtrcr = @truncate(self.merge(self.wdtrcr, offset, width, value));
            },
            off.wdtcstpr => if (!self.locked(.count_stop)) {
                self.wdtcstpr = @truncate(self.merge(self.wdtcstpr, offset, width, value) & @as(u16, count_stop.slcstp));
            },
            else => {},
        }
    }

    /// A halfword store carries the whole register; a byte store replaces one
    /// half of it and leaves the other standing.
    fn merge(self: *const Wdt, current: u16, offset: u32, width: u3, value: u32) u16 {
        _ = self;
        if (width >= 2 and offset & 1 == 0) return @truncate(value);
        const shift: u4 = @intCast((offset & 1) * 8);
        const keep: u16 = if (shift == 0) 0xFF00 else 0x00FF;
        return (current & keep) | (@as(u16, @truncate(value & 0xFF)) << shift);
    }

    pub fn block(self: *Wdt) periph.Block {
        return .{
            .name = "WDT0",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// When the refresh window next opens and closes, in virtual ns.
pub const WindowEdges = struct {
    opens_at: ?u64 = null,
    closes_at: ?u64 = null,
};

fn percentOf(full: u32, percent: u8) u32 {
    return @intCast((@as(u64, full) * percent) / 100);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Wdt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Wdt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The WDTCR word for a timeout period, divider and window pair, so firmware
/// and tests say what they mean instead of assembling bit fields by hand.
pub fn controlWord(tops: u2, cks: u4, rpss: u2, rpes: u2) u16 {
    return @as(u16, tops) |
        (@as(u16, cks) << control.cks_shift) |
        (@as(u16, rpes) << control.rpes_shift) |
        (@as(u16, rpss) << control.rpss_shift);
}
