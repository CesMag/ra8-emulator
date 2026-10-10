//! The GPTP time itself: a free-running accumulator, an additive offset, and
//! the two views firmware reads them through.
//!
//! The block is a timer, not a transport. Each unit counts in 5.27
//! fixed-point nanoseconds per ESWCLK cycle (PTPTIVCt), and what firmware
//! reads is `offset + free-running`, the equation HUM 35.5.1.1 gives. The
//! arithmetic lives here so the register window next door stays a register
//! window.
//!
//! Split out of the port of board_periph_gptp.c on dev, with the carry done
//! properly: dev subtracts one second at most from the summed nanoseconds
//! and then masks the result to the field's thirty bits, so an offset whose
//! nanoseconds sit between one second and the 2^30 ceiling (a range the
//! field allows and dev commits unchanged) is reported as a nanoseconds
//! value at or above one second, which is not a time any clock can show.
//! Here the offset is normalized when it is committed and the sum is
//! carried to completion, so a nanoseconds read is always below one second
//! and the seconds it belonged to are in the seconds field.
const std = @import("std");

/// The GPTP clock and fixed-point scale.
pub const scale = struct {
    /// ESWCLK = PLL1P / 4 on this part.
    pub const eswclk_hz: u64 = 250_000_000;
    /// PTPTIVCt is 5.27 fixed-point nanoseconds per clk.
    pub const subns_shift: u6 = 27;
    pub const ns_per_sec: u64 = 1_000_000_000;
    pub const one_second_fixed: u64 = ns_per_sec << subns_shift;
};

/// Field widths of the 78-bit GPTP time: nanoseconds in [29:0], seconds
/// split 32 + 16 across the M and U registers.
pub const mask = struct {
    pub const nsec: u32 = 0x3FFF_FFFF;
    pub const sec_upper: u64 = 0xFFFF;
    pub const sec: u64 = 0xFFFF_FFFF_FFFF;
    pub const sec_shift: u6 = 32;
};

/// One reading of a unit's clock.
pub const Time = struct {
    sec: u64 = 0,
    nsec: u32 = 0,

    /// The same instant flattened to nanoseconds, which is the AVTP view.
    pub fn avtp(self: Time) u64 {
        return (self.sec *% scale.ns_per_sec) +% @as(u64, self.nsec);
    }

    pub fn upper(self: Time) u32 {
        return @intCast((self.sec >> mask.sec_shift) & mask.sec_upper);
    }

    pub fn middle(self: Time) u32 {
        return @truncate(self.sec);
    }
};

/// One timer unit: whether it runs, the offset firmware staged, and the
/// free-running count. `fixed` is the sub-second part in 5.27 fixed point
/// and never reaches one second, so the pair cannot overflow.
pub const Unit = struct {
    enabled: bool = false,
    off_sec: u64 = 0,
    off_nsec: u32 = 0,
    acc_sec: u64 = 0,
    fixed: u64 = 0,
    /// The M and U halves sampled when the matching L register was last
    /// read, so an ordered three-read of L, M, U is one instant.
    latch_sec: u64 = 0,
    latch_avtp: u64 = 0,
    /// Boundaries this unit counted through.
    ticks: u32 = 0,

    pub fn start(self: *Unit) void {
        self.enabled = true;
    }

    /// A stopped unit reads zero, so a stop is also a clear of the
    /// free-running count. The staged offset survives it.
    pub fn stop(self: *Unit) void {
        self.enabled = false;
        self.acc_sec = 0;
        self.fixed = 0;
    }

    /// Count ESWCLK edges at the programmed increment. A stopped unit and a
    /// zero increment both stand still.
    pub fn advance(self: *Unit, increment: u32, esw_cycles: u64) void {
        if (!self.enabled or increment == 0) return;
        self.ticks +%= 1;
        const total = @as(u128, self.fixed) + @as(u128, increment) * esw_cycles;
        const whole = total / scale.one_second_fixed;
        self.acc_sec +%= @truncate(whole);
        self.fixed = @intCast(total % scale.one_second_fixed);
    }

    /// Stage the 78-bit offset. Returns whether the nanoseconds field held
    /// more than a second's worth and had to be carried, which is a
    /// firmware bug worth reporting rather than one to hide.
    pub fn setOffset(self: *Unit, sec: u64, nsec: u32) bool {
        const carried = @as(u64, nsec) / scale.ns_per_sec;
        self.off_nsec = @intCast(@as(u64, nsec) % scale.ns_per_sec);
        self.off_sec = (sec +% carried) & mask.sec;
        return carried != 0;
    }

    /// offset + free-running, carried to completion. A stopped unit reads
    /// time zero.
    pub fn now(self: *const Unit) Time {
        if (!self.enabled) return .{};
        const free_ns = self.fixed >> scale.subns_shift;
        const total = @as(u64, self.off_nsec) + free_ns;
        const carry = total / scale.ns_per_sec;
        return .{
            .sec = (self.off_sec +% self.acc_sec +% carry) & mask.sec,
            .nsec = @intCast((total % scale.ns_per_sec) & mask.nsec),
        };
    }

    /// Sample the GPTP view and hold the seconds for the M and U reads.
    pub fn sampleGptp(self: *Unit) u32 {
        const time = self.now();
        self.latch_sec = time.sec;
        return time.nsec;
    }

    /// Sample the AVTP view and hold its upper half for the U read.
    pub fn sampleAvtp(self: *Unit) u32 {
        const flat = self.now().avtp();
        self.latch_avtp = flat;
        return @truncate(flat);
    }

    pub fn latchedMiddle(self: *const Unit) u32 {
        return @truncate(self.latch_sec);
    }

    pub fn latchedUpper(self: *const Unit) u32 {
        return @intCast((self.latch_sec >> mask.sec_shift) & mask.sec_upper);
    }

    pub fn latchedAvtpUpper(self: *const Unit) u32 {
        return @truncate(self.latch_avtp >> mask.sec_shift);
    }

    pub fn ran(self: *const Unit) bool {
        return self.enabled or self.acc_sec != 0 or self.fixed != 0;
    }
};
