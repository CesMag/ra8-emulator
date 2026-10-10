//! GPT: the PWM timer, with a period that wraps and a count that stays inside it.
//!
//! Fourteen channels of a 32-bit saw up-counter at 0x4032_2000
//! (ra8_gpt_regs.h). Firmware loads GTPR, starts the channel through GTSTR
//! or GTCR.CST, and then either samples GTCNT to prove the timer is moving or
//! waits on the GPT0 overflow interrupt. Both need a count that really
//! advances, so the channel carries live state rather than a shadow.
//!
//!   GTSTR (+0x04)  software start, bit 0
//!   GTSTP (+0x08)  software stop, bit 0
//!   GTCLR (+0x0C)  software clear, bit 0
//!   GTCR  (+0x2C)  CST bit 0 gates the count
//!   GTST  (+0x3C)  status; TCFPO bit 6 is the overflow
//!   GTCNT (+0x48)  the counter
//!   GTPR  (+0x64)  the period the counter wraps at
//!
//! Ported from board_periph_timer.c on dev, which models the GPT and AGT
//! families together. Three things that model does not do.
//!
//! A FULL-RANGE PERIOD STILL OVERFLOWS. dev tests `(cnt + step) <= period` in
//! 32-bit arithmetic, so a channel with GTPR = 0xFFFF_FFFF has the sum wrap
//! before the comparison and takes the in-range branch every time: TCFPO is
//! never set and the GPT0 event is never raised, so an image using the whole
//! 32-bit range polls a flag that cannot arrive. The sum is computed wide
//! here and a wrap is a wrap at any period.
//!
//! THE COUNT STAYS INSIDE THE PERIOD. dev wraps by subtracting the period
//! once, so a period shorter than one chunk's advance (0x4001) leaves GTCNT
//! reading a value LARGER than GTPR, which silicon cannot produce, and counts
//! one overflow where the hardware had dozens. A driver computing duty from
//! GTCNT against GTPR gets a ratio above one. The advance is reduced modulo
//! the period span here and every wrap inside the chunk is counted.
//!
//! THE WINDOW KEEPS WHAT WAS WRITTEN. dev answers 0 to every offset outside
//! the seven it interprets and drops the stores, so GTIOR, GTSSR, GTBER and
//! the rest read back zero and a driver that verifies its own output setup
//! fails on the readback. Everything uninterpreted is shadowed per channel,
//! and every register takes a narrow store on its own byte lane instead of
//! dev's whole-word assignment, where a halfword store to the low half of
//! GTPR wrote the period and a store to the high half vanished.
//!
//! KEPT FROM DEV DELIBERATELY: GTPR = 0 counts to 0xFFFF rather than standing
//! still, so a channel started before its period is loaded still moves;
//! GTST clears by writing the value back with the target bits zero, so
//! firmware can only clear a flag, never raise one; and only channel 0 raises
//! an event, because GPT0's overflow is the one number this tree carries.
//!
//! ONE EVENT PER BOUNDARY: several wraps inside one chunk are one interrupt
//! here. The count of them is reported, but they are not stacked into a
//! backlog that would fire long after the counter moved on.
//!
//! THE COUNT SOURCE lives in src/chip/periph/gpt/clock.zig: GTCR's TPCS field
//! picks the divider a channel counts at, so a channel slowed to PCLKD/1024
//! really is a thousand times slower than an undivided one instead of every
//! channel counting at the same rate.
//!
//! COMPARE MATCH lives in src/chip/periph/gpt/compare.zig: GTCCRA (+0x4C) and
//! GTCCRB (+0x50) are compared against the count rather than shadowed, and a
//! crossing raises GTST.TCFA or TCFB. Everything that file does not claim is
//! still shadowed.
//!
//! THE COUNTER MODE lives in src/chip/periph/gpt/mode.zig: GTCR's MD field picks
//! the shape a channel counts in, so a triangle channel rises to the period
//! and falls back to zero instead of sawing, and a one-shot channel stops
//! itself at the period instead of wrapping forever.
//!
//! THE BUFFERED COMPARE lives in src/chip/periph/gpt/buffer.zig: GTBER (+0x40)
//! says whether a channel reloads GTCCRA and GTCCRB from their buffer
//! registers at the end of a cycle, so a duty the HAL parks through
//! `ra8_gpt_duty_cycle_set` arrives on the next cycle instead of never
//! arriving at all. This file's note used to say a buffered duty took effect
//! at once; it did not take effect, because nothing read the buffer.
//!
//! THE WRITE PROTECTION lives in src/chip/periph/gpt/lock.zig: GTWP (+0x00)
//! carries a password in its upper byte and WP in bit 0, and the HAL
//! brackets every channel it touches between the two keys, so a channel the
//! HAL has finished with is shut and a store that skips the key is dropped
//! instead of landing.
//!
//! NOT MODELLED, AND NOT GUESSED: the per-source interrupt enables in
//! GTINTAD, so channel 0's overflow always raises and a compare match never
//! does.
const std = @import("std");
const Bounded = @import("../../core/bounded.zig").Bounded;

const buf = @import("buffer.zig");
const ch = @import("channel.zig");
const clk = @import("clock.zig");
const compare = @import("compare.zig");
const lk = @import("lock.zig");
const win = @import("window.zig");
const md = @import("mode.zig");
const prd = @import("period.zig");
const sync = @import("sync.zig");

/// The PWM output delay generator: pdg.zig.
pub const pdg = @import("pdg.zig");
const periph = @import("../registry.zig");

/// The compare pair, reached as `gpt.match` the way the other split blocks in
/// this tree re-export their halves.
pub const match = compare;

/// The count source, reached as `gpt.clock` the same way.
pub const clock = clk;

/// The counter mode, reached as `gpt.mode`.
pub const mode = md;

/// The compare buffers, reached as `gpt.buffers`.
pub const buffers = buf;

/// The write protection, reached as `gpt.protection`.
pub const protection = lk;

/// The channel window's addressing, reached as `gpt.window`.
pub const window = win;

/// One channel, reached as `gpt.Channel` the way it was when it lived here.
pub const Channel = ch.Channel;

/// GPT geometry (ra8_gpt_regs.h).
pub const win_base: u32 = 0x4032_2000;
pub const stride: u32 = ch.stride;
pub const channels: usize = 14;
pub const win_span: u32 = stride * @as(u32, channels);

/// Where each register this model interprets sits in a channel, re-exported
/// from the window so callers reach it as `gpt.off` the way they always did.
pub const off = win.off;

/// GTPR and its buffer GTPBR live in src/chip/periph/gpt/period.zig.
pub const periods = prd;

/// GTCR's count-start bit and GTST's status bits, re-exported from the
/// channel that interprets them.
pub const control = ch.control;
pub const status = ch.status;

/// GPT0's counter-overflow event (RA8D2 ELC signal table; FSP bsp_elc.h).
pub const event = struct {
    pub const gpt0_overflow: u16 = 0x0C1;
};

/// The advance one chunk boundary stands for, and the period GTPR = 0 counts
/// to, both re-exported from the channel so callers reach them where they
/// always did.
pub const step_per_tick: u32 = ch.step_per_tick;
pub const default_period: u32 = ch.default_period;

/// At most one event per boundary, from channel 0.
pub const Due = Bounded(u16, 1);

pub const Gpt = struct {
    channels: [channels]Channel = @splat(.{}),
    /// Whether channel 0 wrapped this boundary.
    pending: bool = false,
    /// What the bank's three action registers did. See sync.zig.
    sync: sync.Sync = .{},

    pub fn init() Gpt {
        return .{};
    }

    pub fn tick(self: *Gpt) void {
        for (&self.channels, 0..) |*channel, index| {
            if (channel.tick() != 0 and index == 0) self.pending = true;
        }
    }

    pub fn dueEvents(self: *Gpt) Due {
        var due = Due{};
        if (!self.pending) return due;
        self.pending = false;
        due.appendAssumeCapacity(event.gpt0_overflow);
        return due;
    }

    pub fn quiet(self: *const Gpt) bool {
        if (!self.sync.quiet()) return false;
        for (self.channels) |channel| {
            if (!channel.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Gpt, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        if (local == off.gtcnt) channel.sampleRead();
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, channel.readByte(local + index)) << shift;
        }
        return value;
    }

    pub fn write(self: *Gpt, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const channel = &self.channels[offset / stride];
        const local = offset % stride;
        // GTWP takes the whole access at once, so the key is judged on the
        // word the store leaves behind rather than on a byte of it.
        if (local < lk.off.gtwp + 4) {
            channel.guard.store(local - lk.off.gtwp, width, value);
            return;
        }
        // One store, one refusal: the protection turns the access away, not
        // each of its byte lanes.
        if (!channel.guard.admits(local, win.protected(local))) return;
        // The bits are channel-indexed, so the access acts on the channels it
        // names rather than on the window it came through.
        if (sync.which(local)) |action| {
            const bits = sync.carried(local - sync.base(action), width, value);
            sync.dispatch(&self.sync, action, bits, offset / stride, &self.channels);
            return;
        }
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            channel.writeByte(local + index, @truncate(value >> shift));
        }
    }

    pub fn block(self: *Gpt) periph.Block {
        return .{
            .name = "GPT",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Gpt = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Gpt = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
