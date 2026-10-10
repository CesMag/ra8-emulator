//! ACMPHS: the high-speed analog comparators, so a comparator poll ends.
//!
//! Six channels live at 0x4023_6000 with a 0x100 stride (ra8_acmphs_regs.h,
//! k_ra8_acmphs0_base_addr / k_ra8_acmphs_channel_count / _stride, cited
//! there against FSP R_ACMPHS0_BASE and HUM Ch 56). The block had no model
//! here at all: every access fell through to the sparse register file, which
//! stores whatever it is given and hands it back, so CMPMON was a byte
//! firmware could write and then read its own value out of, and a channel
//! that was never enabled monitored exactly as much as one that was.
//!
//!   CMPCTL   (+0x00, 8b)  CINV, COE, CSTEN, CEG[1:0], CDFS[1:0], HCMPON
//!   CMPSEL0  (+0x04, 8b)  plus-input selection
//!   CMPSEL1  (+0x08, 8b)  minus-input (reference) selection
//!   CMPMON   (+0x0C, 8b)  output monitor, read-only, derived here
//!   CPIOC    (+0x10, 8b)  output polarity / pin control
//!   CPINTCTL (+0x40, 8b)  interrupt control
//!   CPMSKCTL (+0x44, 8b)  interrupt mask control
//!
//! CMPMON IS READ-ONLY AND DERIVED. The sparse file let a store land in it;
//! here the store is refused and counted, the same line the RTC file draws
//! around R64CNT. What it reads comes from src/chip/periph/acmphs/output.zig,
//! which carries the monitor rule and states what it does not model.
//!
//! NOT MODELLED, AND NOT GUESSED: the ACMPHS interrupt. CPINTCTL and
//! CPMSKCTL gate an event whose ELC number nothing in this tree carries, so
//! they are stored and read back and raise nothing. Every offset in the
//! channel window besides the seven named above is shadowed so a
//! read-modify-write survives, and never interpreted.
const periph = @import("../registry.zig");
const output = @import("output.zig");

/// ACMPHS geometry. The bus folds the Non-secure alias onto this base.
pub const win_base: u32 = 0x4023_6000;
pub const stride: u32 = 0x100;
pub const channel_count: usize = 6;
pub const win_span: u32 = stride * @as(u32, channel_count);

/// The monitor rule, re-exported so callers reach it through this block.
pub const monitor = output;

pub const off = struct {
    pub const cmpctl: u32 = 0x00;
    pub const cmpsel0: u32 = 0x04;
    pub const cmpsel1: u32 = 0x08;
    pub const cmpmon: u32 = 0x0C;
    pub const cpioc: u32 = 0x10;
    pub const cpintctl: u32 = 0x40;
    pub const cpmskctl: u32 = 0x44;
};

/// One comparator: the registers this model interprets, a shadow for the
/// rest of its window, and what the run should be told about it.
pub const Channel = struct {
    cmpctl: u8 = 0,
    cmpsel0: u8 = 0,
    cmpsel1: u8 = 0,
    cpioc: u8 = 0,
    cpintctl: u8 = 0,
    cpmskctl: u8 = 0,
    shadow: [stride]u8 = @splat(0),
    /// Reads of CMPMON while the comparator was operating.
    polls: u32 = 0,
    /// Reads of CMPMON with HCMPON clear, which monitor nothing.
    dark_polls: u32 = 0,
    /// Stores aimed at CMPMON, which is read-only.
    refused: u32 = 0,

    pub fn quiet(self: *const Channel) bool {
        return self.polls == 0 and self.dark_polls == 0 and self.refused == 0 and self.cmpctl == 0;
    }

    pub fn operating(self: *const Channel) bool {
        return output.operating(self.cmpctl);
    }

    pub fn inverted(self: *const Channel) bool {
        return output.inverted(self.cmpctl);
    }

    pub fn driving(self: *const Channel) bool {
        return output.driving(self.cmpctl);
    }

    pub fn edge(self: *const Channel) output.Edge {
        return output.Edge.of(self.cmpctl);
    }

    /// CMPMON as firmware reads it, counting what kind of read it was.
    pub fn level(self: *Channel) u8 {
        if (self.operating()) self.polls +%= 1 else self.dark_polls +%= 1;
        return output.monitor(self.cmpctl);
    }

    fn readByte(self: *Channel, local: u32) u8 {
        return switch (local) {
            off.cmpctl => self.cmpctl,
            off.cmpsel0 => self.cmpsel0,
            off.cmpsel1 => self.cmpsel1,
            off.cmpmon => self.level(),
            off.cpioc => self.cpioc,
            off.cpintctl => self.cpintctl,
            off.cpmskctl => self.cpmskctl,
            else => self.shadow[local],
        };
    }

    fn writeByte(self: *Channel, local: u32, byte: u8) void {
        switch (local) {
            off.cmpctl => self.cmpctl = byte,
            off.cmpsel0 => self.cmpsel0 = byte,
            off.cmpsel1 => self.cmpsel1 = byte,
            // Read-only: the comparator owns this one.
            off.cmpmon => self.refused +%= 1,
            off.cpioc => self.cpioc = byte,
            off.cpintctl => self.cpintctl = byte,
            off.cpmskctl => self.cpmskctl = byte,
            else => self.shadow[local] = byte,
        }
    }
};

pub const Acmphs = struct {
    channels: [channel_count]Channel = @splat(Channel{}),

    pub fn init() Acmphs {
        return .{};
    }

    pub fn quiet(self: *const Acmphs) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Acmphs, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const unit = &self.channels[offset / stride];
        const local = offset % stride;
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, unit.readByte(local + index)) << shift;
        }
        return value;
    }

    pub fn write(self: *Acmphs, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const unit = &self.channels[offset / stride];
        const local = offset % stride;
        var index: u32 = 0;
        while (index < width and local + index < stride) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            unit.writeByte(local + index, @truncate(value >> shift));
        }
    }

    pub fn block(self: *Acmphs) periph.Block {
        return .{
            .name = "ACMPHS",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Acmphs = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Acmphs = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one channel's register window, so a test or a later slice
/// does not do the arithmetic itself.
pub fn channelAddress(channel: usize) u32 {
    return win_base + @as(u32, @intCast(channel)) * stride;
}
