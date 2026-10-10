//! SSIE: the I2S serial sound interface, and the transmit FIFO that decides
//! when a sample written to it is actually on the wire.
//!
//! SSIE0 sits at 0x4025_D000 and SSIE1 0x100 above it (ra8_ssie_regs.h). A
//! driver brings a channel up by checking SSISR.IIRQ, programming SSICR and
//! SSIFCR, setting TEN, and then storing one sample per SSIFTDR write. There
//! is no audio clock and no I2S frame here: what a headless run can observe
//! is that handshake and the sample stream it produces, which is what the
//! `ssie_audio_loop` example is worth checking.
//!
//! Ported from board_periph_ssie.c on dev, with three things that model does
//! not do.
//!
//! THE TRANSMIT FIFO IS REAL, NOT A HOLE IN THE FLOOR. dev pins SSIFSR.TDE
//! set and drops every SSIFTDR store straight into a tally, so the register
//! never fills, never stalls, and never loses anything. Here it is a FIFO of
//! the part's own depth: TDE reads clear while it holds a sample, TDC reports
//! how many, and a store past the last stage is dropped and counted rather
//! than silently becoming a transmitted sample.
//!
//! A SAMPLE IS TRANSMITTED WHEN THE TRANSMITTER IS ON. dev counts every
//! SSIFTDR store whatever SSICR says, so an image whose TEN never took
//! reports a stream it never shifted out. Here a store with TEN clear stages
//! the sample, exactly as silicon fills the FIFO ahead of the enable, and
//! setting TEN drains what is staged; a run that never sets it reports the
//! samples as staged, which is the failure the tally was meant to catch.
//!
//! SSISR IS STATUS, NOT A SHADOW. dev stores a write to SSISR into the same
//! flat register array that its read path then ignores, so firmware can
//! neither set a flag nor clear one and cannot tell which happened. Here the
//! register is computed on read and a write to it changes nothing.
//!
//! THE FIFO ITSELF lives in src/chip/periph/ssie/ssie_fifo.zig: the part's 32 stages,
//! SSIFSR's TDC count, and the SSIFCR resets that empty it. That file carries
//! the register fields and what is deliberately left alone in them.
//!
//! SSIFTDR IS A DATA PORT, NOT A BAG OF ADDRESSABLE LANES. A sample is one
//! 32-bit register write, and the stage behind it moves whole. dev, and this
//! model until now, clocked a sample on ANY store landing anywhere in the
//! register and built it out of the lanes that store named, so a driver
//! pushing one sample in two halfword stores staged TWO samples, each
//! carrying half the word with the other half zero, and a byte store to the
//! three bytes above the register staged a sample made of a byte. Here an
//! access narrower than the register carries no sample: it is refused and
//! counted, and the FIFO keeps what it already had. SSICR, SSIFCR and the
//! shadow are untouched by this: their lanes really are the bits a narrow
//! store names, which is what step 5 of fw/real/ssie.c does to SSICR.
//!
//! SSIFCR.SSIRST IS A COMMAND, NOT A STORED BIT. Bit 16 of SSIFCR is the
//! module's own software reset, the one HUM Table 46.9 is named after, and
//! both dev and this model until now merged it into the shadow and did
//! nothing else with it. The driver leans on it twice: at bring-up, and on
//! every error recovery, where ra8_ssie_start_recovery pulses it and then
//! does nothing but clear the SSISR error flags by hand. So a channel that
//! underran kept its transmitter on and kept the samples staged behind it,
//! and the run shifted out a stream the part would have thrown away. Worse,
//! SSICR.TEN stayed set, so SSISR.IIRQ read low forever and ra8_ssie_start
//! answered k_ra8_err_busy at the idle check on every later attempt to
//! restart the channel. Here the rising edge empties the transmit FIFO and
//! takes REN and TEN down, leaving the mode bits above them alone, which is
//! what ra8_ssie.h states as the post-condition of that call. The rule and
//! its evidence live in src/chip/periph/ssie/ssie_reset.zig.
//!
//! NOT MODELLED, AND NOT GUESSED: SSIFSR's receive flags, and the write-0-to
//! -clear the header describes for RDF and TDE. TDE is computed from what the
//! FIFO is holding rather than latched, so a store to SSIFSR still changes
//! nothing; latching it would need the clear rule stated somewhere in one of
//! these trees, and it is not. The rest of the window is shadowed so a
//! read-modify-write survives, and never read. There is no receive source, so
//! SSIFRDR reads zero and RDC reads zero, as they do on dev.
const std = @import("std");

const fifo = @import("ssie_fifo.zig");
const lanes = @import("../lanes.zig");
const periph = @import("../registry.zig");
const soft_reset = @import("ssie_reset.zig");
const audio_tap = @import("ssie_tap.zig");

/// The staging FIFO, reached as `ssie.stage` the way the other split blocks
/// in this tree re-export their halves.
pub const stage = fifo;

/// The SSIRST rule, reached as `ssie.reset` the same way.
pub const reset = soft_reset;

/// The shifted-out sample listener and SSICR's stream shape (RA8EMU-648).
pub const tap = audio_tap;

/// SSIE geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4025_D000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// The registers this model interprets. Everything else in the window is
/// shadow.
pub const off_ssicr: u32 = 0x00;
pub const off_ssisr: u32 = 0x04;
pub const off_ssifcr: u32 = 0x10;
pub const off_ssifsr: u32 = 0x14;
pub const off_ssiftdr: u32 = 0x18;
pub const off_ssifrdr: u32 = 0x1C;

/// The fields dev's own masks name.
pub const field = struct {
    /// SSICR.REN, the receiver enable.
    pub const ren: u32 = 0x0000_0001;
    /// SSICR.TEN, the transmitter enable.
    pub const ten: u32 = 0x0000_0002;
    /// SSISR.IIRQ, the idle flag the driver waits on before enabling.
    pub const iirq: u32 = 0x0200_0000;
    /// SSIFSR.TDE, transmit FIFO empty.
    pub const tde: u32 = fifo.status.tde;
};

/// Stages in the transmit FIFO, from the part's own header.
pub const tx_depth: usize = fifo.depth.stages;

/// Words of a channel's window this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One SSIE channel: its control state, the samples queued behind it, and
/// what the run should be told about the stream it was given.
pub const Channel = struct {
    /// SSICR. Only REN and TEN are read; the rest rides along untouched.
    ssicr: u32 = 0,
    shadow: [shadow_words]u32 = @splat(0),
    /// Samples written while the transmitter was off, oldest first.
    tx: fifo.Stage = .{},
    /// Samples shifted out with TEN set.
    transmitted: u32 = 0,
    /// The last sample shifted out.
    last: u32 = 0,
    /// Stores to SSIFTDR that did not name the whole register.
    narrow_writes: u32 = 0,
    /// SSIRST pulses the channel took.
    resets: u32 = 0,
    /// Hears every sample shifted out (`--audio-out`).
    listener: ?audio_tap.Tap = null,

    pub fn transmitting(self: *const Channel) bool {
        return self.ssicr & field.ten != 0;
    }

    /// IIRQ asserts while neither direction is enabled. The driver reads it
    /// before setting REN/TEN and refuses to start without it.
    pub fn idle(self: *const Channel) bool {
        return self.ssicr & (field.ren | field.ten) == 0;
    }

    pub fn quiet(self: *const Channel) bool {
        return self.ssicr == 0 and self.transmitted == 0 and
            self.narrow_writes == 0 and self.resets == 0 and self.tx.quiet();
    }

    /// Samples still waiting behind a transmitter that never came on.
    pub fn staged(self: *const Channel) usize {
        return self.tx.held;
    }

    /// Samples a full FIFO refused.
    pub fn dropped(self: *const Channel) u32 {
        return self.tx.overruns;
    }

    /// Samples a FIFO reset threw away before they were shifted out.
    pub fn discarded(self: *const Channel) u32 {
        return self.tx.discarded;
    }

    /// Stores to SSIFTDR too narrow to carry a sample.
    pub fn refused(self: *const Channel) u32 {
        return self.narrow_writes;
    }

    /// Software resets the channel was put through.
    pub fn resetCount(self: *const Channel) u32 {
        return self.resets;
    }

    /// A store to SSIFTDR. Only an access that names the whole register
    /// carries a sample: the register is 32 bits wide and the stage behind it
    /// takes a word, so a narrower store has part of one and staging it would
    /// put a sample on the stream that firmware never wrote. The refusal is
    /// about the register's own width and not about SSICR.DWL, which this
    /// model does not read: a short sample still sits in a 32-bit SSIFTDR.
    fn store(self: *Channel, lane: u32, width: u3, value: u32) void {
        if (lane != 0 or width < 4) {
            self.narrow_writes +%= 1;
            return;
        }
        self.push(value);
    }

    /// Take a sample. With the transmitter on it goes out; with it off the
    /// FIFO holds it, because staging ahead of the enable is how a driver
    /// starts a stream without a gap, and a full FIFO is an overrun rather
    /// than one more sample on the wire.
    fn push(self: *Channel, sample: u32) void {
        if (self.transmitting()) return self.shift(sample);
        _ = self.tx.push(sample);
    }

    fn shift(self: *Channel, sample: u32) void {
        self.last = sample;
        self.transmitted +%= 1;
        if (self.listener) |heard| heard.call(sample);
    }

    /// Enabling the transmitter starts shifting whatever the FIFO already
    /// holds, oldest first.
    fn drain(self: *Channel) void {
        for (self.tx.pending()) |sample| self.shift(sample);
        self.tx.clear();
    }

    fn status(self: *const Channel) u32 {
        return if (self.idle()) field.iirq else 0;
    }

    /// SSIFSR: the empty flag a driver gates its first store on, and the
    /// count it does flow control with after that.
    fn fifoStatus(self: *const Channel) u32 {
        const empty: u32 = if (self.tx.empty()) field.tde else 0;
        return empty | fifo.transmitCount(self.tx.held);
    }

    /// A write to SSIFCR. A FIFO reset bit going up empties the FIFO it
    /// names, and SSIRST going up resets the channel; the word itself stays
    /// in the shadow either way, because the driver writes these bits back
    /// to zero itself and reads SSIFCR back in between.
    fn fifoControl(self: *Channel, before: u32, after: u32) void {
        if (fifo.asserted(before, after) & fifo.reset.transmit != 0) self.tx.flush();
        if (soft_reset.asserted(before, after)) self.softReset();
    }

    /// SSIRST. The channel comes back idle with nothing staged: the transmit
    /// FIFO is emptied, and REN and TEN go down while the mode bits above
    /// them ride through, which is what ra8_ssie.h states as the
    /// post-condition of the recovery call that does nothing else.
    fn softReset(self: *Channel) void {
        self.resets +%= 1;
        self.tx.flush();
        self.ssicr = soft_reset.control(self.ssicr);
    }
};

pub const Ssie = struct {
    channels: [channel_count]Channel = @splat(Channel{}),

    pub fn init() Ssie {
        return .{};
    }

    pub fn quiet(self: *const Ssie) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Ssie, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        return switch (inner & ~@as(u32, 3)) {
            off_ssicr => lanes.part(unit.ssicr, byte, width),
            off_ssisr => lanes.part(unit.status(), byte, width),
            off_ssifsr => lanes.part(unit.fifoStatus(), byte, width),
            // Write-only port, and no receive source behind the other one.
            off_ssiftdr, off_ssifrdr => 0,
            else => lanes.part(unit.shadow[inner / 4], byte, width),
        };
    }

    pub fn write(self: *Ssie, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_ssicr => control(unit, lanes.merge(unit.ssicr, byte, width, value)),
            off_ssifcr => {
                const word = inner / 4;
                const before = unit.shadow[word];
                unit.shadow[word] = lanes.merge(before, byte, width, value);
                unit.fifoControl(before, unit.shadow[word]);
            },
            off_ssiftdr => unit.store(byte, width, value),
            // Status, and a status register does not take a store.
            off_ssisr, off_ssifsr => {},
            else => {
                const word = inner / 4;
                unit.shadow[word] = lanes.merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    pub fn block(self: *Ssie) periph.Block {
        return .{
            .name = "SSIE",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Take a new SSICR. The transmitter coming on is the edge that matters:
/// everything staged behind it starts moving.
fn control(unit: *Channel, value: u32) void {
    const was = unit.transmitting();
    unit.ssicr = value;
    if (!was and unit.transmitting()) unit.drain();
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Ssie = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Ssie = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel, so a test or a later slice does not do
/// the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + @as(u32, @intCast(index)) * channel_stride;
}
