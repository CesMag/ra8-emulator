//! The DTC descriptor: one Transfer Information block, as the controller
//! reads it out of memory and writes it back.
//!
//! The DTC keeps nothing about a transfer in its own registers. DTCVBR points
//! at a table of pointers, one per ICU slot, and each entry points at a
//! sixteen-byte TI block in RAM holding the mode word, the two addresses and
//! the two counts. The controller reads that block when an event activates
//! it, moves what the mode word says to move, and writes the block back with
//! the addresses and counts where they now stand, so the next activation
//! carries on where this one stopped (HUM Ch 18.2 p 790, r_dtc_xfer_info_t).
//!
//! The descriptor gets its own file so src/chip/periph/dtc/dtc.zig stays a register
//! window and an activation path, the same split drw.zig and drw/blend.zig
//! have.

/// A TI block is sixteen bytes: MR, SAR, DAR, then CRB and CRA sharing a word.
pub const bytes: u32 = 16;

/// Field offsets inside the block (HUM Figure 18.4 p 792).
pub const off = struct {
    pub const mr: u32 = 0;
    pub const sar: u32 = 4;
    pub const dar: u32 = 8;
    /// CRB is the low half of this word and CRA the high half.
    pub const counts: u32 = 12;
};

/// MR is one word holding two byte-wide mode registers, MRA then MRB.
pub const field = struct {
    pub const mra_shift: u5 = 24;
    pub const mrb_shift: u5 = 16;
    /// MRB.DISEL b5: interrupt the CPU on every transfer, not only the last.
    pub const disel: u8 = 0x20;
    /// MRB.CHNE b7: a chain transfer follows this descriptor.
    pub const chne: u8 = 0x80;
};

/// MRA.MD[7:6]: how much one activation moves and which count comes down.
pub const Mode = enum(u2) { normal, repeat, block, reserved };

/// MRA.SZ[5:4]: the unit the transfer moves.
pub const Width = enum(u2) { byte, half, word, reserved };

/// MRA.SM[3:2] and MRB.DM[3:2]: what happens to an address after a unit.
pub const Addressing = enum(u2) { fixed, offset, increment, decrement };

/// A block size of zero means 256 units, not none (HUM Ch 18.2.7 p 797).
pub const block_wrap: u32 = 256;

/// A descriptor this model will not invent a transfer for. Each is declined
/// out loud rather than approximated, so an app relying on one goes visibly
/// nowhere here instead of passing on bytes the bench would not have moved.
pub const Unsupported = enum {
    /// MD = 01. Repeat mode reloads its counter and its address forever; the
    /// reload rule differs per repeat area and is not modelled.
    repeat_mode,
    /// MD = 11 is reserved.
    reserved_mode,
    /// SZ = 11 is reserved: there is no unit width to move.
    reserved_width,
    /// SM or DM = 01 adds DTCOFR to the address, and DTCOFR is unmodelled.
    offset_addressing,
    /// MRB.CHNE: a second descriptor runs back to back with this one.
    chained,
};

/// One decoded TI block.
pub const Info = struct {
    mode: Mode,
    width: Width,
    source: Addressing,
    destination: Addressing,
    interrupt_each: bool,
    chained: bool,
    sar: u32,
    dar: u32,
    /// Normal mode: units left. Block mode: CRAH is the block size and CRAL
    /// counts inside it, which is why the high byte is the size below.
    cra: u16,
    /// Block mode: blocks left. Unused in normal mode.
    crb: u16,

    pub fn decode(mr: u32, sar: u32, dar: u32, crb: u16, cra: u16) Info {
        const mra: u8 = @truncate(mr >> field.mra_shift);
        const mrb: u8 = @truncate(mr >> field.mrb_shift);
        return .{
            .mode = @fromBackingInt(@intCast(@as(u2, @truncate(mra >> 6)))),
            .width = @fromBackingInt(@intCast(@as(u2, @truncate(mra >> 4)))),
            .source = @fromBackingInt(@intCast(@as(u2, @truncate(mra >> 2)))),
            .destination = @fromBackingInt(@intCast(@as(u2, @truncate(mrb >> 2)))),
            .interrupt_each = mrb & field.disel != 0,
            .chained = mrb & field.chne != 0,
            .sar = sar,
            .dar = dar,
            .cra = cra,
            .crb = crb,
        };
    }

    /// Bytes in one unit. Zero only for the reserved width, which is refused
    /// before anything is moved.
    pub fn unit(self: *const Info) u32 {
        return switch (self.width) {
            .byte => 1,
            .half => 2,
            .word => 4,
            .reserved => 0,
        };
    }

    /// Units ONE activation moves. This is the line dev gets wrong: it moves
    /// CRA * CRB units on the first activation whatever the mode says, so a
    /// normal-mode descriptor that silicon drains one unit per event lands
    /// its whole buffer there off a single event.
    pub fn burst(self: *const Info) u32 {
        if (self.mode != .block) return 1;
        const size: u32 = self.cra >> 8;
        return if (size == 0) block_wrap else size;
    }

    /// How far an address moves per unit. Fixed stays put, which is how a
    /// peripheral data register is read or written for a whole run.
    pub fn step(self: *const Info, which: Addressing) i64 {
        const width: i64 = self.unit();
        return switch (which) {
            .increment => width,
            .decrement => -width,
            .fixed, .offset => 0,
        };
    }

    /// Where the descriptor stands after one activation: the addresses have
    /// walked over the units just moved and the count that this mode spends
    /// has come down. Block mode leaves CRA alone on purpose, because a whole
    /// block moves at once and CRAL ends back at the CRAH it reloads from.
    pub fn advance(self: *Info) void {
        self.walkBy(self.burst());
        switch (self.mode) {
            .block => self.crb -%= 1,
            else => self.cra -%= 1,
        }
    }

    /// Walk the two addresses over `units` and spend NO count. This is the
    /// half of an advance a short activation earns: memory refused a unit
    /// partway through a block, so the addresses stand where the copy
    /// stopped, but the block did not complete and its count has not been
    /// paid. A whole activation is this followed by the count coming down.
    pub fn walkBy(self: *Info, units: u32) void {
        const moved: i64 = @intCast(units);
        self.sar = walk(self.sar, self.step(self.source) * moved);
        self.dar = walk(self.dar, self.step(self.destination) * moved);
    }

    /// Nothing left to move, which is when the controller takes the slot's
    /// DTCE down and lets the CPU have its interrupt.
    pub fn exhausted(self: *const Info) bool {
        return switch (self.mode) {
            .block => self.crb == 0,
            else => self.cra == 0,
        };
    }

    pub fn unsupported(self: *const Info) ?Unsupported {
        if (self.mode == .repeat) return .repeat_mode;
        if (self.mode == .reserved) return .reserved_mode;
        if (self.width == .reserved) return .reserved_width;
        if (self.source == .offset or self.destination == .offset) return .offset_addressing;
        if (self.chained) return .chained;
        return null;
    }

    /// CRB and CRA as the one word they share at the end of the block.
    pub fn packedCounts(self: *const Info) u32 {
        return @as(u32, self.crb) | (@as(u32, self.cra) << 16);
    }
};

/// Move an address by a signed step, wrapping the way a 32-bit pointer does.
pub fn walk(address: u32, delta: i64) u32 {
    return @truncate(@as(u64, @bitCast(@as(i64, address) +% delta)));
}
