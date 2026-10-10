//! PVD: the programmable voltage monitors, so a rail check reports the rail.
//!
//! The RA8D2 carries four voltage-detection channels inside the SYSC window
//! (HUM Ch 8 "Programmable Voltage Detection", p 300-316). PVD1 and PVD2 are
//! the "m" series, with a status register and an interrupt path; PVD4 and PVD5
//! are the "n" series, reset-only, with no status register at all. The
//! registers are scattered across three stretches of SYSC rather than sitting
//! in one window, so this block claims three ranges and answers for all of
//! them (ra8_lvd_regs.h, offsets verified there against FSP R_SYSTEM_Type).
//!
//!   0x4001_E0E0 +4    PVD1CR1, PVD1SR, PVD2CR1, PVD2SR
//!   0x4001_EA58 +0x2C PVDmCMPCR and PVDmCR0 for all four channels
//!   0x4001_EB20 +0x18 PVDmFCR for all four, then PVDLR
//!
//! THE RESET BAND AND ITS NEGATION INTERLOCK. RHSEL = 1 needs PVDmCR0.RI
//! already set, and RN = 1 is prohibited while RHSEL = 1 (HUM Ch 8.2.8
//! p 308, Ch 8.2.4 p 305). Both rules, why only m channels are gated and
//! why a standing bit is left alone, live in src/chip/periph/lvd/interlock.zig.
//!
//! THE FILTER DIVIDER IS LOCKED WHILE THE FILTER RUNS. FSAMP only takes a
//! store while that channel's DFDIS is set (HUM Ch 8.2.4 p 305, Ch 8.2.5
//! p 306). The rule, its citation, why a read-modify-write that carries the
//! divider along unchanged is not a violation, and why the matching PVDLVL
//! rule is not modelled yet, all live in src/chip/periph/lvd/field_lock.zig.
//!
//! Ported from board_periph_lvd.c on dev, which models the four status bytes
//! and nothing else: it answers every PVDmSR read with MON = above and DET = 0
//! whatever the firmware programmed, and absorbs every status write. So on dev
//! a monitor that was never enabled still reports a healthy rail, a threshold
//! programmed above the supply still reports a healthy rail, and a DET flag can
//! never be observed to latch. The comparator is modelled here instead: the
//! board presents a fixed 3.3 V rail, MON is the comparison against the
//! programmed Vdet, and DET latches on a crossing the firmware caused.
const std = @import("std");
const periph = @import("../registry.zig");

/// The three stretches of SYSC this block claims (ra8_lvd_regs.h).
pub const status_base: u32 = 0x4001_E0E0;
pub const status_span: u32 = 0x4;
pub const control_base: u32 = 0x4001_EA58;
pub const control_span: u32 = 0x2C;
pub const filter_base: u32 = 0x4001_EB20;
pub const filter_span: u32 = 0x18;

/// The supply the board model presents to every comparator. The EK-RA8D2 runs
/// VCC at 3.3 V; there is no analog rail to sample in an instruction-stepped
/// emulator, so this is the one number the whole block is measured against.
pub const rail_millivolts: u16 = 3300;

/// The register fields and the Vdet table, in src/chip/periph/lvd/regs.zig.
pub const regs = @import("regs.zig");
pub const field_lock = @import("field_lock.zig");

pub const compare = regs.compare;
pub const control = regs.control;
pub const irq = regs.irq;
pub const status = regs.status;
pub const hysteresis = regs.hysteresis;
pub const lock = regs.lock;
pub const Edge = regs.Edge;
pub const level_min = regs.level_min;
pub const level_max = regs.level_max;
pub const detect_millivolts = regs.detect_millivolts;
pub const detectVoltage = regs.detectVoltage;
pub const interlock = @import("interlock.zig");

pub const Series = regs.Series;

/// One voltage monitor: its four register shadows and the comparator state
/// they add up to. An n-series channel has no CR1 and no SR, so `det` and
/// `above` stay untouched there.
pub const Channel = struct {
    series: Series,
    cmpcr: u8 = 0,
    cr0: u8 = 0,
    cr1: u8 = 0,
    fcr: u8 = 0,
    det: bool = false,
    above: bool = false,
    live: bool = false,
    crossings: u32 = 0,
    reserved_level: u32 = 0,
    refused_clears: u32 = 0,
    touched: bool = false,

    pub fn edge(self: *const Channel) Edge {
        return @fromBackingInt(@intCast(@as(u2, @truncate(self.cr1 & irq.idtsel))));
    }

    /// Whether a DET latch would reach the CPU: RIE armed on an m channel.
    pub fn armed(self: *const Channel) bool {
        return self.series == .monitor and self.cr0 & control.rie != 0;
    }

    /// Re-evaluate the comparator after a write that could have moved it, and
    /// latch DET when the result crossed in the direction IDTSEL asked for.
    ///
    /// Enabling the detector establishes a baseline rather than counting as a
    /// crossing: the comparator output becomes valid, it does not transition.
    /// Only a later change of the result is a crossing.
    fn evaluate(self: *Channel) void {
        const was_live = self.live;
        const was_above = self.above;
        if (self.cmpcr & compare.enable == 0) {
            self.live = false;
            return;
        }
        const threshold = detectVoltage(self.cmpcr) orelse {
            // HUM calls these encodings prohibited, so the comparator has no
            // defined output. Reporting "no monitor" beats inventing one.
            self.reserved_level +%= 1;
            self.live = false;
            return;
        };
        self.live = true;
        self.above = rail_millivolts >= threshold;
        if (!was_live or self.above == was_above) return;
        self.crossings +%= 1;
        const wanted = switch (self.edge()) {
            .rise => self.above,
            .fall => !self.above,
            .both => true,
            .prohibited => false,
        };
        if (wanted and self.series == .monitor) self.det = true;
    }

    fn readStatus(self: *const Channel) u8 {
        var value: u8 = 0;
        if (self.det) value |= status.det;
        if (self.live and self.above) value |= status.mon;
        return value;
    }

    /// PVDmSR.DET is write-0-to-clear (HUM Ch 8.2.7 p 307). A driver that
    /// "acknowledges" it by writing a 1, the way a W1C flag elsewhere on this
    /// part would want, clears nothing and is counted instead of ignored.
    fn writeStatus(self: *Channel, value: u8) void {
        if (!self.det) return;
        if (value & status.det == 0) {
            self.det = false;
        } else {
            self.refused_clears +%= 1;
        }
    }

    fn readControl(self: *const Channel) u8 {
        const marker: u8 = if (self.series == .monitor) control.m_marker else control.n_marker;
        return self.cr0 | marker;
    }

    pub fn quiet(self: *const Channel) bool {
        return !self.touched;
    }
};

/// Which register a window offset names, and the channel it belongs to.
const Slot = struct {
    index: u2,
    kind: Kind,

    const Kind = enum { cr1, sr, cmpcr, cr0, fcr, pvdlr };
};

/// PVD1, PVD2, PVD4, PVD5 in that order; channels 0 and 3 are not on this part
/// (HUM Ch 8.1 Table 8.1 p 300).
pub const series_of = [4]Series{ .monitor, .monitor, .reset_only, .reset_only };

pub const Lvd = struct {
    channels: [4]Channel,
    /// PVDLR.LOCK resets to 1, so the n channels are locked out of reset.
    locked: bool = true,
    unlock_spent: bool = false,
    dropped: u32 = 0,
    /// FSAMP stores refused for the filter state they were made in.
    fields: field_lock.Locked = .{},
    /// RHSEL/RN stores refused for the combination they would have made.
    bands: interlock.Locked = .{},

    pub fn init() Lvd {
        var unit = Lvd{ .channels = undefined };
        for (&unit.channels, series_of) |*channel, series| channel.* = .{ .series = series };
        return unit;
    }

    pub fn quiet(self: *const Lvd) bool {
        for (&self.channels) |*channel| {
            if (!channel.quiet()) return false;
        }
        return self.dropped == 0 and self.fields.quiet() and self.bands.quiet();
    }

    pub fn read(self: *Lvd, address: u32, width: u3) u32 {
        var value: u32 = 0;
        var i: u3 = 0;
        while (i < width) : (i += 1) {
            const shift: u5 = @as(u5, i) * 8;
            value |= @as(u32, self.readByte(address +% i)) << shift;
        }
        return value;
    }

    pub fn write(self: *Lvd, address: u32, width: u3, value: u32) void {
        var i: u3 = 0;
        while (i < width) : (i += 1) {
            const shift: u5 = @as(u5, i) * 8;
            self.writeByte(address +% i, @truncate(value >> shift));
        }
    }

    fn readByte(self: *Lvd, address: u32) u8 {
        const slot = decode(address) orelse return 0;
        const channel = &self.channels[slot.index];
        return switch (slot.kind) {
            .cr1 => channel.cr1,
            .sr => channel.readStatus(),
            .cmpcr => channel.cmpcr,
            .cr0 => channel.readControl(),
            .fcr => channel.fcr,
            .pvdlr => if (self.locked) lock.bit else 0,
        };
    }

    fn writeByte(self: *Lvd, address: u32, value: u8) void {
        const slot = decode(address) orelse return;
        if (slot.kind == .pvdlr) return self.writeLock(value);
        const channel = &self.channels[slot.index];
        // The lock covers the n channels' control registers only; PVD1 and
        // PVD2 are never gated by it (HUM Ch 8.2.10 p 309).
        if (channel.series == .reset_only and self.locked) {
            self.dropped +%= 1;
            channel.touched = true;
            return;
        }
        channel.touched = true;
        switch (slot.kind) {
            .cr1 => channel.cr1 = value & irq.writable,
            .sr => channel.writeStatus(value),
            .cmpcr => {
                channel.cmpcr = value & (compare.level | compare.enable);
                channel.evaluate();
            },
            .cr0 => {
                const kept = self.fields.filter(channel.cr0, value);
                channel.cr0 = self.bands.negate(channel.series, channel.fcr, channel.cr0, kept);
                channel.evaluate();
            },
            .fcr => channel.fcr = self.bands.band(channel.series, channel.cr0, value),
            .pvdlr => unreachable,
        }
    }

    /// PVDLR takes exactly one 0 after reset to release the n channels, and
    /// any write after that re-locks them until the next power-on reset.
    fn writeLock(self: *Lvd, value: u8) void {
        if (self.unlock_spent) {
            self.locked = true;
            return;
        }
        if (value & lock.bit == 0) {
            self.locked = false;
            self.unlock_spent = true;
            return;
        }
        self.locked = true;
    }

    fn window(self: *Lvd, name: []const u8, base: u32, span: u32) periph.Block {
        return .{
            .name = name,
            .base = base,
            .size = span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    pub fn statusBlock(self: *Lvd) periph.Block {
        return self.window("SYSC-PVD-SR", status_base, status_span);
    }

    pub fn controlBlock(self: *Lvd) periph.Block {
        return self.window("SYSC-PVD-CR", control_base, control_span);
    }

    pub fn filterBlock(self: *Lvd) periph.Block {
        return self.window("SYSC-PVD-FCR", filter_base, filter_span);
    }
};

/// Where each channel's registers sit inside their window. The slots are not
/// evenly spaced: PVD3 has a slot on the die and is not brought out on this
/// part (HUM Ch 8.1 Table 8.1 p 300), so the gap between PVD2 and PVD4 is real.
pub const cmpcr_offsets = [4]u32{ 0x00, 0x04, 0x0C, 0x10 };
pub const cr0_offsets = [4]u32{ 0x18, 0x1C, 0x24, 0x28 };
pub const fcr_offsets = [4]u32{ 0x00, 0x04, 0x0C, 0x10 };

pub const Register = enum { cr1, sr, cmpcr, cr0, fcr };

/// The absolute address of a register, for a firmware fixture or a test. CR1
/// and SR only exist on the monitor channels, so asking an n channel for one
/// is a programming error rather than an address.
pub fn at(index: u2, register: Register) u32 {
    const i: u32 = index;
    return switch (register) {
        .cr1 => status_base + 2 * i,
        .sr => status_base + 2 * i + 1,
        .cmpcr => control_base + cmpcr_offsets[index],
        .cr0 => control_base + cr0_offsets[index],
        .fcr => filter_base + fcr_offsets[index],
    };
}

pub const pvdlr_at: u32 = filter_base + 0x14;

/// Map an absolute address onto a register. The gaps inside each window are
/// the channel-0 and channel-3 slots this part does not carry, and they read
/// zero rather than aliasing a neighbour.
fn decode(address: u32) ?Slot {
    if (address >= status_base and address < status_base + status_span) {
        const offset = address - status_base;
        const index: u2 = @intCast(offset / 2);
        return .{ .index = index, .kind = if (offset % 2 == 0) .cr1 else .sr };
    }
    if (address >= control_base and address < control_base + control_span) {
        return decodeControl(address - control_base);
    }
    if (address >= filter_base and address < filter_base + filter_span) {
        const offset = address - filter_base;
        if (offset == 0x14) return .{ .index = 0, .kind = .pvdlr };
        return switch (offset) {
            0x00 => .{ .index = 0, .kind = .fcr },
            0x04 => .{ .index = 1, .kind = .fcr },
            0x0C => .{ .index = 2, .kind = .fcr },
            0x10 => .{ .index = 3, .kind = .fcr },
            else => null,
        };
    }
    return null;
}

fn decodeControl(offset: u32) ?Slot {
    return switch (offset) {
        0x00 => .{ .index = 0, .kind = .cmpcr },
        0x04 => .{ .index = 1, .kind = .cmpcr },
        0x0C => .{ .index = 2, .kind = .cmpcr },
        0x10 => .{ .index = 3, .kind = .cmpcr },
        0x18 => .{ .index = 0, .kind = .cr0 },
        0x1C => .{ .index = 1, .kind = .cr0 },
        0x24 => .{ .index = 2, .kind = .cr0 },
        0x28 => .{ .index = 3, .kind = .cr0 },
        else => null,
    };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Lvd = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Lvd = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The channel names the end-of-run report uses, in `series_of` order.
pub const names = [4][]const u8{ "PVD1", "PVD2", "PVD4", "PVD5" };
