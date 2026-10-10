//! One GPT channel: the counter, what it counts in, and the window it
//! answers on.
//!
//! The bank in src/chip/periph/gpt/gpt.zig owns fourteen of these and routes an access
//! to one of them; everything below the routing is here. That split is the
//! house rule rather than a size exercise, but size is what forced it: gpt.zig
//! sat at exactly the 400-line gate ceiling, so the next slice touching the
//! most-used block in the corpus had nowhere to put a line.
//!
//! The channel is one thing with three faces and they are deliberately kept
//! together, because each is written in terms of the same fields. `tick`
//! advances the count in the shape GTCR.MD selects and raises what that
//! crossing raised. `readByte` and `writeByte` are the window: which of the
//! split halves owns the offset an access landed on, and the shadow for every
//! register this model does not interpret. And `quiet` is what the report asks
//! to decide whether this channel is worth a line.
//!
//! WHAT IS NOT HERE. The bank's own three action registers (GTSTR, GTSTP,
//! GTCLR) name channels by bit rather than by the window an access came
//! through, so they are dispatched a level up in gpt.zig and reach the channel
//! already resolved; `writeByte` ignores them for that reason. GTWP is
//! likewise taken whole at the bank, because the key is judged on the word a
//! store leaves behind rather than on a byte of it.
//!
//! The registers this file interprets directly are GTCNT, GTCR and GTST. Every
//! other one it understands belongs to a half of its own, and this file only
//! says which: compare.zig (GTCCRA/B), buffer.zig (GTBER and the two
//! compare buffers), period.zig (GTPR/GTPBR), lock.zig (GTWP),
//! mode.zig (GTCR.MD), clock.zig (GTCR.TPCS and CST) and
//! window.zig (the addressing itself).

const buf = @import("buffer.zig");
const clk = @import("clock.zig");
const compare = @import("compare.zig");
const lk = @import("lock.zig");
const win = @import("window.zig");
const md = @import("mode.zig");
const prd = @import("period.zig");

/// Where each register this model interprets sits in a channel. The map is
/// the window's; this is the name the code here reaches it by.
const off = win.off;

/// How far apart two channel windows sit (ra8_gpt_regs.h), which is also the
/// size of the shadow a channel keeps for what it does not interpret.
pub const stride: u32 = 0x100;

/// GTCR: the count-start bit. The rest of the register's fields live in
/// clock.zig, which reads the prescaler out of it.
pub const control = struct {
    pub const cst: u32 = clk.field.cst;
};

/// GTST: the status bits dev's enumeration names.
pub const status = struct {
    pub const tcfa: u32 = compare.flag.tcfa;
    pub const tcfb: u32 = compare.flag.tcfb;
    pub const tcfpo: u32 = 0x0000_0040;
    pub const tcfpu: u32 = 0x0000_0080;
};

/// The advance one chunk boundary stands for at the UNDIVIDED clock, carried
/// from dev with its
/// reason: it is ODD, so it is coprime to the 2^16 and 2^32 saw periods the
/// drivers use. A power-of-two advance divides those periods evenly, GTCNT
/// then visits a handful of values, and a demo sampling on a power-of-two
/// millisecond cadence reads the same count every time and calls the timer
/// wedged.
pub const step_per_tick: u32 = 0x0000_4001;

/// GTPR = 0 counts to the 16-bit wrap, as dev does. The rule lives with the
/// register in period.zig.
pub const default_period: u32 = prd.default;

/// One channel: the counter, its period, the control and status words, and a
/// shadow for every register this model does not interpret.
pub const Channel = struct {
    cnt: u32 = 0,
    period: prd.Period = .{},
    cr: u32 = 0,
    st: u32 = 0,
    shadow: [stride]u8 = @splat(0),
    overflows: u32 = 0,
    /// Times a triangle came back to zero. Always zero outside one.
    underflows: u32 = 0,
    /// PCLKD edges accumulated by counter-register reads since the last sample.
    read_divider_phase: u32 = 0,
    /// Which way the count is going. Only a triangle ever sets it false.
    rising: bool = true,
    compares: compare.Pair = .{},
    buffered: buf.Buffers = .{},
    guard: lk.Lock = .{},
    /// Which shapes GTCR.MD has selected, so a mode a later store
    /// took away is visible instead of silent.
    shapes: md.Log = .{},

    pub fn running(self: Channel) bool {
        return self.cr & control.cst != 0;
    }

    /// The clock this channel counts on, out of GTCR.TPCS.
    pub fn source(self: Channel) clk.Source {
        return clk.sourceOf(self.cr);
    }

    /// The shape this channel counts in, out of GTCR.MD.
    pub fn shape(self: Channel) md.Mode {
        return md.modeOf(self.cr);
    }

    /// The period a zero GTPR stands for.
    pub fn periodOrDefault(self: Channel) u32 {
        return self.period.span();
    }

    /// One chunk of counting, in the shape GTCR.MD selects. Returns how many
    /// times the count reached the period, which is zero for a stopped or
    /// in-range channel.
    pub fn tick(self: *Channel) u32 {
        return self.advance(clk.step(step_per_tick, self.source()));
    }

    /// A register read takes bus time too. Advance a divided source once the
    /// access has accumulated a full prescaler interval.
    pub fn sampleRead(self: *Channel) void {
        if (!self.running()) return;
        self.read_divider_phase += 1;
        const divider = self.source().divider();
        if (self.read_divider_phase < divider) return;
        self.read_divider_phase = 0;
        _ = self.advance(1);
    }

    /// Move the count by `amount` counts of its own clock. Public so the
    /// virtual time base can count a boundary by elapsed time (gpt_sched).
    pub fn advance(self: *Channel, amount: u32) u32 {
        if (!self.running()) return 0;
        const period = self.periodOrDefault();
        const before = self.cnt;
        const kind = self.shape();
        const moved = md.advance(kind, self.cnt, self.rising, period, amount);
        self.cnt = moved.cnt;
        self.rising = moved.rising;
        if (moved.peaks != 0) {
            self.st |= status.tcfpo;
            self.overflows +%= moved.peaks;
        }
        if (moved.troughs != 0) {
            self.st |= status.tcfpu;
            self.underflows +%= moved.troughs;
        }
        if (moved.halted) self.cr &= ~control.cst;
        self.st |= self.matched(kind, before, moved, period);
        if (md.endedCycle(kind, moved)) self.reload();
        return moved.peaks;
    }

    /// Hand the buffered compares over, the way GTBER's single-buffer
    /// selection says to. The chunk's own matches were judged above against
    /// the values that were live while it ran, so a duty arriving here
    /// governs the next cycle and not the one that just finished.
    fn reload(self: *Channel) void {
        if (self.buffered.take(.a)) |value| self.compares.load(.a, value);
        if (self.buffered.take(.b)) |value| self.compares.load(.b, value);
        self.period.reload();
    }

    /// The compare flags this chunk raised. A saw chunk is an up-count and is
    /// described by its wraps; a triangle one may have turned, so it is
    /// described by the span of counts it covered.
    fn matched(self: *Channel, kind: md.Mode, before: u32, moved: md.Step, period: u32) u32 {
        if (!kind.symmetric()) return self.compares.step(before, moved.cnt, moved.peaks, period);
        const span = md.visited(before, moved, period);
        return self.compares.stepSpan(before, span.lo, span.hi);
    }

    pub fn readByte(self: *const Channel, local: u32) u8 {
        if (local < lk.off.gtwp + 4) return win.lane(self.guard.value(), local - lk.off.gtwp);
        if (compare.which(local)) |side| {
            const base = if (side == .a) compare.off.gtccra else compare.off.gtccrb;
            return win.lane(self.compares.value(side), local - base);
        }
        if (buf.which(local)) |side| {
            const base = if (side == .a) buf.off.buffer_a else buf.off.buffer_b;
            return win.lane(self.buffered.value(side), local - base);
        }
        if (prd.which(local)) |part| {
            const base = if (part == .live) prd.off.gtpr else prd.off.gtpbr;
            return win.lane(self.period.value(part), local - base);
        }
        return switch (win.cellOf(local)) {
            buf.off.gtber => win.lane(self.buffered.ber, local - buf.off.gtber),
            off.gtcnt => win.lane(self.cnt, local - off.gtcnt),
            off.gtcr => win.lane(self.cr, local - off.gtcr),
            off.gtst => win.lane(self.st, local - off.gtst),
            else => self.shadow[local],
        };
    }

    pub fn writeByte(self: *Channel, local: u32, byte: u8) void {
        if (compare.which(local)) |side| {
            const base = if (side == .a) compare.off.gtccra else compare.off.gtccrb;
            self.compares.set(side, win.merge(self.compares.value(side), local - base, byte));
            return;
        }
        if (buf.which(local)) |side| {
            const base = if (side == .a) buf.off.buffer_a else buf.off.buffer_b;
            self.buffered.set(side, win.merge(self.buffered.value(side), local - base, byte));
            return;
        }
        if (prd.which(local)) |part| {
            const base = if (part == .live) prd.off.gtpr else prd.off.gtpbr;
            self.period.set(part, win.merge(self.period.value(part), local - base, byte));
            return;
        }
        switch (win.cellOf(local)) {
            buf.off.gtber => self.buffered.ber = win.merge(self.buffered.ber, local - buf.off.gtber, byte),
            off.gtcnt => self.cnt = win.merge(self.cnt, local - off.gtcnt, byte),
            off.gtcr => self.cr = self.shapes.note(self.cr, win.merge(self.cr, local - off.gtcr, byte)),
            // GTST is cleared by writing the word back with the target bits
            // zero, so a store can only take bits away.
            off.gtst => self.st &= win.merge(self.st, local - off.gtst, byte),
            // GTSTR, GTSTP and GTCLR name channels by bit, so the bank takes
            // them whole before an access is broken into lanes.
            off.gtstr, off.gtstp, off.gtclr => {},
            else => self.shadow[local] = byte,
        }
    }

    pub fn quiet(self: Channel) bool {
        if (!self.compares.quiet() or !self.buffered.quiet() or !self.guard.quiet()) return false;
        if (!self.shapes.quiet()) return false;
        return self.overflows == 0 and self.underflows == 0 and !self.running();
    }
};
