//! GPTP: the Ethernet PTP timer, two units that count and one window that
//! answers for them.
//!
//! The block sits at 0x403E_0000 in a 0x1000 aperture (ra8_ether_regs.h).
//! It carries no traffic: two free-running counters advance at the rate
//! PTPTIVCt programs, an additive 78-bit offset puts them on network time,
//! and the driver reads the pair back through a latched three-register
//! view. The arithmetic is next door in timer.zig; this file is the
//! register window, the enable bits, and what the run should be told
//! happened.
//!
//! Ported from board_periph_gptp.c on dev, with four things that model does
//! not do.
//!
//! A MONITORING REGISTER ANSWERS AT ANY WIDTH. dev compares the in-block
//! offset against the exact register offset, so a halfword read of the top
//! of PTPGPTPTMtL, the way a driver picking the upper half of the
//! nanosecond field reads it, misses the monitor entirely and falls through
//! to the config shadow, which nothing has written and which reads zero. A
//! byte read of the same register goes the other way and hands back all
//! thirty-two bits. Here a read is served from the addressed register at
//! the addressed byte and narrowed to the access, so a narrow read returns
//! that slice of the counter and nothing wider.
//!
//! THE COUNTER IS THE TIMER'S, NOT FIRMWARE'S. dev's write path drops every
//! store into the flat shadow, the five monitoring registers included, and
//! PTPIPV is dropped only at its first byte. The word read is served from
//! the model so the store looks harmless, but a narrow read of the same
//! register hands firmware back its own invention as a timestamp. Stores
//! into the monitoring registers and into PTPIPV are refused and counted
//! here.
//!
//! THE CARRY IS COMPLETED. dev takes at most one second out of the summed
//! nanoseconds and masks what is left to thirty bits, so an offset whose
//! nanoseconds sit above one second, which the field's range allows and
//! which dev commits unchanged, reads back as a nanoseconds value of a
//! second or more. The offset is normalized on commit here and counted.
//!
//! A TIMER THIS PART DOES NOT HAVE CANNOT BE STARTED. dev walks the two
//! units it models and ignores every other bit of PTPTMEC and PTPTMDC in
//! silence, so a driver that starts the block with a blanket mask gets two
//! units running and no sign the rest of the word meant nothing. Counted
//! here.
//!
//! NOT MODELLED, AND NOT GUESSED: the media-clock capture and recovery
//! registers, the cyclic compare, the pulse output and the security config,
//! all of which need pins the board does not route. They are shadowed for
//! readback, exactly as dev leaves them, and never interpreted.
const std = @import("std");

const periph = @import("../registry.zig");
pub const timer = @import("timer.zig");

/// GPTP geometry (ra8_ether_regs.h): the whole aperture of HUM Table 35.3.
/// The ESWM media mux above it stays in the sparse fallback.
pub const win_base: u32 = 0x403E_0000;
pub const win_span: u32 = 0x1000;

/// Timer units on this part.
pub const unit_count: usize = 2;

/// The global registers, and where the per-unit blocks start.
pub const off = struct {
    pub const ptpipv: u32 = 0x00;
    pub const ptptmec: u32 = 0x10;
    pub const ptptmdc: u32 = 0x14;
    pub const timer0: u32 = 0x20;
    pub const timer_stride: u32 = 0x40;
};

/// Offsets inside one unit's block.
pub const unit_off = struct {
    pub const ptptivc: u32 = 0x00;
    pub const ptptovcl: u32 = 0x10;
    pub const ptptovcm: u32 = 0x14;
    pub const ptptovcu: u32 = 0x18;
    pub const ptpavtptml: u32 = 0x20;
    pub const ptpavtptmu: u32 = 0x24;
    pub const ptpgptptml: u32 = 0x30;
    pub const ptpgptptmm: u32 = 0x34;
    pub const ptpgptptmu: u32 = 0x38;
};

/// PTPIPV is read-only and resets nonzero; the apps read it to decide the
/// block is really there.
pub const ipv_reset: u32 = 0x0000_0003;

/// Which unit a window offset belongs to, and where inside its block.
pub const Spot = struct {
    unit: usize,
    inoff: u32,
};

/// The modelled GPTP: the shadow firmware reads its own config back out of,
/// the two counters behind it, and what went wrong.
pub const Gptp = struct {
    reg: [win_span]u8 = @splat(0),
    units: [unit_count]timer.Unit = @splat(timer.Unit{}),
    ns_remainder: u64 = 0,
    /// Units started, and units stopped, over the run.
    starts: u32 = 0,
    stops: u32 = 0,
    /// Enable or disable bits naming a unit this part does not have.
    unknown_unit: u32 = 0,
    /// Stores into a monitoring register the timer owns.
    faked: u32 = 0,
    /// Stores into PTPIPV, which is read-only.
    read_only: u32 = 0,
    /// Offsets committed with more than a second of nanoseconds.
    denormal: u32 = 0,

    pub fn init() Gptp {
        return .{};
    }

    pub fn quiet(self: *const Gptp) bool {
        if (self.starts != 0 or self.stops != 0) return false;
        if (self.unknown_unit != 0 or self.faked != 0) return false;
        if (self.read_only != 0 or self.denormal != 0) return false;
        for (&self.units) |*unit| {
            if (unit.ran()) return false;
        }
        return true;
    }

    /// Advance each enabled timer for the ESWCLK cycles in this elapsed
    /// virtual-time span. Fractional cycles carry into the next chunk.
    pub fn tick(self: *Gptp, elapsed_ns: u64) void {
        const scaled = @as(u128, self.ns_remainder) +
            @as(u128, elapsed_ns) * timer.scale.eswclk_hz;
        const esw_cycles: u64 = @intCast(scaled / std.time.ns_per_s);
        self.ns_remainder = @intCast(scaled % std.time.ns_per_s);
        for (&self.units, 0..) |*unit, index| {
            unit.advance(
                self.shadowWord(unitOffset(index) + unit_off.ptptivc),
                esw_cycles,
            );
        }
    }

    pub fn read(self: *Gptp, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const base = offset & ~@as(u32, 3);
        if (self.computed(base, offset)) |value| return narrow(value, width);
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < width and offset + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.reg[offset + index]) << shift;
        }
        return value;
    }

    pub fn write(self: *Gptp, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        var staged: ?usize = null;
        var index: u32 = 0;
        while (index < width and offset + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            const byte: u8 = @truncate(value >> shift);
            if (self.store(offset + index, byte)) |unit| staged = unit;
        }
        // The offset commits on the write to L, and what commits is the
        // whole staged triple, so it happens once however wide the store.
        if (staged) |unit| self.commit(unit);
    }

    /// One byte of a store. Returns the unit whose offset the store staged.
    fn store(self: *Gptp, offset: u32, byte: u8) ?usize {
        const base = offset & ~@as(u32, 3);
        const lane: u5 = @intCast((offset - base) * 8);
        const bits = @as(u32, byte) << lane;
        if (base == off.ptpipv) {
            self.read_only +%= 1;
            return null;
        }
        if (base == off.ptptmec) {
            self.enable(bits);
            return null;
        }
        if (base == off.ptptmdc) {
            self.disable(bits);
            return null;
        }
        if (decode(base)) |spot| {
            if (isMonitor(spot.inoff)) {
                self.faked +%= 1;
                return null;
            }
            self.reg[offset] = byte;
            return if (spot.inoff == unit_off.ptptovcl) spot.unit else null;
        }
        self.reg[offset] = byte;
        return null;
    }

    /// PTPTMEC is write-1-to-set: a bit naming a unit starts it, a bit
    /// naming no unit is counted rather than ignored.
    fn enable(self: *Gptp, bits: u32) void {
        var bit: usize = 0;
        while (bit < 32) : (bit += 1) {
            if (bits & (@as(u32, 1) << @intCast(bit)) == 0) continue;
            if (bit >= unit_count) {
                self.unknown_unit +%= 1;
                continue;
            }
            if (!self.units[bit].enabled) self.starts +%= 1;
            self.units[bit].start();
        }
    }

    /// PTPTMDC is write-1-to-clear, and a stop clears the count with it.
    fn disable(self: *Gptp, bits: u32) void {
        var bit: usize = 0;
        while (bit < 32) : (bit += 1) {
            if (bits & (@as(u32, 1) << @intCast(bit)) == 0) continue;
            if (bit >= unit_count) {
                self.unknown_unit +%= 1;
                continue;
            }
            if (self.units[bit].enabled) self.stops +%= 1;
            self.units[bit].stop();
        }
    }

    /// Form the 78-bit offset out of the three staged registers.
    fn commit(self: *Gptp, unit: usize) void {
        const base = unitOffset(unit);
        const upper: u64 = self.shadowWord(base + unit_off.ptptovcu);
        const middle: u64 = self.shadowWord(base + unit_off.ptptovcm);
        const lower: u64 = self.shadowWord(base + unit_off.ptptovcl);
        const sec = ((upper & timer.mask.sec_upper) << timer.mask.sec_shift) | middle;
        const nsec: u32 = @intCast(lower & timer.mask.nsec);
        if (self.units[unit].setOffset(sec, nsec)) self.denormal +%= 1;
    }

    /// The registers this model answers for itself, or null when the shadow
    /// owns the offset. An L read samples, so this is not a const read.
    fn computed(self: *Gptp, base: u32, offset: u32) ?u32 {
        const word = self.wordAt(base) orelse return null;
        const shift: u5 = @intCast((offset - base) * 8);
        return word >> shift;
    }

    fn wordAt(self: *Gptp, base: u32) ?u32 {
        if (base == off.ptpipv) return ipv_reset;
        if (base == off.ptptmec) return self.enableMask();
        // PTPTMDC is write-only and reads back zero.
        if (base == off.ptptmdc) return 0;
        const spot = decode(base) orelse return null;
        const unit = &self.units[spot.unit];
        return switch (spot.inoff) {
            unit_off.ptpgptptml => unit.sampleGptp(),
            unit_off.ptpgptptmm => unit.latchedMiddle(),
            unit_off.ptpgptptmu => unit.latchedUpper(),
            unit_off.ptpavtptml => unit.sampleAvtp(),
            unit_off.ptpavtptmu => unit.latchedAvtpUpper(),
            else => null,
        };
    }

    pub fn enableMask(self: *const Gptp) u32 {
        var value: u32 = 0;
        for (&self.units, 0..) |*unit, index| {
            if (unit.enabled) value |= @as(u32, 1) << @intCast(index);
        }
        return value;
    }

    /// A 32-bit register straight out of the shadow, for the config
    /// registers the model reads back (PTPTIVCt and the offset triple).
    pub fn shadowWord(self: *const Gptp, offset: u32) u32 {
        var value: u32 = 0;
        var index: u32 = 0;
        while (index < 4 and offset + index < win_span) : (index += 1) {
            const shift: u5 = @intCast(index * 8);
            value |= @as(u32, self.reg[offset + index]) << shift;
        }
        return value;
    }

    pub fn block(self: *Gptp) periph.Block {
        return .{
            .name = "GPTP",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// Where unit `index` starts in the window.
pub fn unitOffset(index: usize) u32 {
    return off.timer0 + (@as(u32, @intCast(index)) * off.timer_stride);
}

/// Resolve an aligned window offset to a unit, or null for the global
/// registers and the tail the shadow owns.
pub fn decode(base: u32) ?Spot {
    if (base < off.timer0) return null;
    const rel = base - off.timer0;
    const unit = rel / off.timer_stride;
    if (unit >= unit_count) return null;
    return .{ .unit = unit, .inoff = rel % off.timer_stride };
}

/// The five registers the timer owns and firmware only reads.
pub fn isMonitor(inoff: u32) bool {
    return switch (inoff) {
        unit_off.ptpavtptml,
        unit_off.ptpavtptmu,
        unit_off.ptpgptptml,
        unit_off.ptpgptptmm,
        unit_off.ptpgptptmu,
        => true,
        else => false,
    };
}

/// Hand back only as much of a register as the access asked for.
fn narrow(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Gptp = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Gptp = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
