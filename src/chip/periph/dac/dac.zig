//! DAC_B: the two 12-bit D/A channels, and the enable bit that decides
//! whether a code written to one of them is an output at all.
//!
//! DAC_B0 sits at 0x4023_3000 and DAC_B1 0x100 above it (ra8_dac_b_regs.h,
//! FSP R_DAC_B0_Type). Each channel is a {DADR, DACR0, DACR1, DACR2} set, and
//! the part has no conversion-result readback: a driver writes a 12-bit code
//! to DADR and that is the whole output path. So what firmware can observe
//! here is its own control state read back, and what a headless run can
//! observe is the code stream itself.
//!
//! Ported from board_periph_dac.c on dev, with four things that model does
//! not do.
//!
//! A NARROW WRITE ONLY TOUCHES THE BYTES IT NAMES. dev ignores the access
//! size and drops the whole 32-bit value into the word, so a byte store to
//! DACR0.DACEN, which is how `ra8_dac_b_set_output_enable` flips the channel
//! on without disturbing the rest of the register, wipes the bytes above it.
//!
//! DADR IS TWELVE BITS WIDE, NOT THIRTY-TWO. dev latches the raw value and
//! reads it straight back, so an image that stores 0xF123 reads 0xF123 and
//! believes bits silicon does not have. Here the stored code is masked to the
//! data field, so a read-back is the code the channel would actually convert.
//!
//! A CODE WRITTEN TO A DISABLED CHANNEL IS NOT AN OUTPUT. dev counts every
//! DADR store into the same last/peak/writes trio whatever DACR0.DACEN says,
//! so a run that never enabled the channel still reports a waveform it never
//! drove. Here a store with DACEN clear is counted separately as `dark`, and
//! the report says so, because an image whose enable never took is exactly
//! the failure the count was supposed to catch.
//!
//! A DISABLED OUTPUT CONVERTS NOTHING, ENABLE OR NO ENABLE. DACR0.DAOUTDIS
//! is how a driver opened without the internal route, and how the block's own
//! deinit, shuts a channel; a code stored to one is staged, not driven. The
//! placement of those twelve bits inside DADR is DACR1.DPSEL's call, not a
//! fixed low-twelve. Both live in src/chip/periph/dac/output.zig, which carries
//! the bit map and what is deliberately left alone in it.
//!
//! THE HALFWORD ABOVE DADR IS NOT DADR. The register is sixteen bits wide at
//! +0x00 and the sixteen bits above it are the reserved gap FSP carries as
//! `reserved_dadr` and ra8_dac_b_regs.h marks "RESERVED (must read as 0)".
//! Every access landing in that upper half used to run the DADR prong, so a
//! store there was taken for a code: it walked the enable gate and bumped
//! `outputs`, `dark` or `blocked` and could move `peak`, reporting a waveform
//! the firmware never wrote. It cannot move the code itself (the merge lands
//! above the sixteen bits DADR keeps), so the register readback was right all
//! along and only the count was wrong. Now the gap reads zero the way the
//! header says and a store to it latches nothing, counted in `above_data`.
//! An access that STARTS in DADR still carries, whatever its width: a word
//! store at +0x00 is the whole pair and its upper half is dropped, and the
//! driver's own single 16-bit store to DADR (ra8_dac_b.c:182) is untouched.
//!
//! NOT MODELLED, AND NOT GUESSED: DACR0.DAE and DACR2.OFSSEL, for the reasons
//! that file gives. The rest of the window is shadowed so a read-modify-write
//! survives, and never read.
const std = @import("std");
pub const output = @import("output.zig");
const periph = @import("../registry.zig");

/// The output gate and the data placement, reached as `dac.gate` the way the
/// other split blocks in this tree re-export their halves.
pub const gate = output;

/// DAC_B geometry. The Non-secure alias is folded onto this base by the bus.
pub const win_base: u32 = 0x4023_3000;
pub const channel_stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = channel_stride * @as(u32, channel_count);

/// The two registers this model interprets.
pub const off_dadr: u32 = 0x00;
/// How many bytes of the DADR word are the data register. The halfword above
/// it is the reserved gap, not part of DADR.
pub const data_bytes: u32 = 2;
pub const off_dacr0: u32 = 0x04;
pub const off_dacr1: u32 = output.off.dacr1;

/// The fields dev's own masks name.
pub const field = struct {
    /// DADR's data field. The channel converts these twelve bits.
    pub const data: u32 = 0x0000_0FFF;
    /// DACR0.DACEN, the channel enable.
    pub const dacen: u32 = output.mask.dacen;
    /// DACR0.DAOUTDIS, the output disable.
    pub const daoutdis: u32 = output.mask.daoutdis;
};

/// Words of a channel's window this model shadows rather than interprets.
const shadow_words: usize = channel_stride / 4;

/// One DAC_B channel: the code it holds, its control state, and what the run
/// should be told about the codes it was given.
pub const Channel = struct {
    /// DADR, masked on every store to the bits the placement has.
    dadr: u16 = 0,
    /// DACR0. DACEN and DAOUTDIS are read; the rest rides along untouched.
    dacr0: u32 = 0,
    /// DACR1. DPSEL is read; the rest rides along untouched.
    dacr1: u32 = 0,
    shadow: [shadow_words]u32 = @splat(0),
    /// Codes accepted while the channel was enabled.
    outputs: u32 = 0,
    /// The largest code written while enabled.
    peak: u16 = 0,
    /// Codes written while DACEN was clear: stored, but not an output.
    dark: u32 = 0,
    /// Codes written to an enabled channel whose output was disabled.
    blocked: u32 = 0,
    /// Stores that landed wholly in the reserved halfword above DADR. They
    /// carry no code, so they are counted rather than latched.
    above_data: u32 = 0,

    pub fn enabled(self: *const Channel) bool {
        return self.dacr0 & field.dacen != 0;
    }

    /// Enabled, and the output not disabled: the only state that converts.
    pub fn driving(self: *const Channel) bool {
        return output.driving(self.dacr0);
    }

    pub fn placement(self: *const Channel) output.Placement {
        return output.Placement.of(self.dacr1);
    }

    /// The code DADR is carrying, wherever DPSEL put it.
    pub fn code(self: *const Channel) u16 {
        return self.placement().code(self.dadr);
    }

    pub fn quiet(self: *const Channel) bool {
        return self.outputs == 0 and self.dark == 0 and
            self.blocked == 0 and self.above_data == 0;
    }

    /// Whether an access at this byte offset in the DADR word names the data
    /// register at all. An access starting inside it carries, however wide.
    fn namesData(byte: u32) bool {
        return byte < data_bytes;
    }

    /// Take a code. Whether it converts is the output gate's call, but the
    /// register latches either way: firmware can stage a code and enable the
    /// channel afterwards, and reading DADR back has to show what it staged.
    fn latch(self: *Channel, value: u32) void {
        self.dadr = @as(u16, @truncate(value)) & self.placement().held();
        if (self.driving()) {
            self.outputs +%= 1;
            const now = self.code();
            if (now > self.peak) self.peak = now;
        } else if (self.enabled()) {
            self.blocked +%= 1;
        } else {
            self.dark +%= 1;
        }
    }
};

pub const Dac = struct {
    channels: [channel_count]Channel = @splat(Channel{}),

    pub fn init() Dac {
        return .{};
    }

    pub fn quiet(self: *const Dac) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Dac, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return 0;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        return switch (inner & ~@as(u32, 3)) {
            off_dadr => if (Channel.namesData(inner % 4)) part(unit.dadr, inner % 4, width) else 0,
            off_dacr0 => part(unit.dacr0, inner % 4, width),
            off_dacr1 => part(unit.dacr1, inner % 4, width),
            else => part(unit.shadow[inner / 4], inner % 4, width),
        };
    }

    pub fn write(self: *Dac, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const index = offset / channel_stride;
        if (index >= channel_count) return;
        const unit = &self.channels[index];
        const inner = offset % channel_stride;
        const byte = inner % 4;
        switch (inner & ~@as(u32, 3)) {
            off_dadr => if (Channel.namesData(byte))
                unit.latch(merge(unit.dadr, byte, width, value))
            else {
                unit.above_data +%= 1;
            },
            off_dacr0 => unit.dacr0 = merge(unit.dacr0, byte, width, value),
            off_dacr1 => unit.dacr1 = merge(unit.dacr1, byte, width, value),
            else => {
                const word = inner / 4;
                unit.shadow[word] = merge(unit.shadow[word], byte, width, value);
            },
        }
    }

    pub fn block(self: *Dac) periph.Block {
        return .{
            .name = "DAC_B",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The part of a 32-bit register a narrow access names.
fn part(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = value >> shift;
    return if (width == 1) shifted & 0xFF else shifted & 0xFFFF;
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits: u32 = if (width == 1) 0xFF else 0xFFFF;
    const window: u32 = bits << shift;
    return (current & ~window) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dac = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dac = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The base address of one channel, so a test or a later slice does not do
/// the arithmetic itself.
pub fn channelAddress(index: usize) u32 {
    return win_base + @as(u32, @intCast(index)) * channel_stride;
}
