//! DTC: the data transfer controller, which moves bytes on an interrupt
//! without waking the CPU.
//!
//! The DTC is not triggered by a register write the way the DMAC is. It is
//! activated by an INTERRUPT: an ICU slot whose IELSR.DTCE bit is set hands
//! its event to the controller instead of straight to the core, the
//! controller reads the descriptor that slot points at, moves what it says,
//! and only lets the CPU see the interrupt once the descriptor has run out.
//! That is why this block is the first consumer of the DTCE bit
//! src/chip/periph/icu/icu.zig has been carrying with nothing reading it.
//!
//!   DTCCR  (+0x00, 8b)  RRS, the read-skip bit (src/chip/periph/dtc/dtc_skip.zig)
//!   DTCVBR (+0x04, 32b) the vector table: one TI pointer per ICU slot
//!   DTCST  (+0x0C, 8b)  DTCST b0, the module start bit
//!   DTCSTS (+0x0E, 16b) ACT b15 and the vector number of the last transfer
//!
//! Ported from board_periph_dtc.c on dev, with three of its behaviours
//! corrected rather than carried over, each named in the decisions below: dev
//! moves the whole descriptor on one activation, ignores DTCST entirely, and
//! never writes the descriptor back.
//!
//! ONE DIVERGENCE OF THIS TREE'S OWN, SAID OUT LOUD: the transfer happens at
//! the chunk boundary, where the board drains the events, not inside the
//! store that fired the event. dev performs the copy inside the ELSEGR write,
//! so a firmware there can read the destination in the next instruction; here
//! it has to wait, the way it would wait on any transfer. Silicon steals a
//! bus cycle and is done long before either, so a driver that polls is right
//! on all three and a driver that reads straight through is only right on dev.
const periph = @import("../registry.zig");
const icu = @import("../icu/icu.zig");
const xfer = @import("dtc_xfer.zig");
const skip = @import("dtc_skip.zig");
const regs = @import("dtc_regs.zig");
const bytelanes = @import("../bytelanes.zig");
/// DTCSAR, the two controllers' security attribution word in CPSCU.
pub const attribution = @import("dtc_sar.zig");
/// The read-skip cache lives next door; re-exported so a caller holding the
/// block also has the RRS vocabulary.
pub const readskip = skip;

/// R_DTC geometry (ra8_dtc_regs.h): DTCCR..DTCSTS sit in the first 0x40.
pub const win_base: u32 = 0x4000_AC00;
pub const win_span: u32 = 0x40;

pub const off = struct {
    pub const dtccr: u32 = 0x00;
    pub const dtcvbr: u32 = 0x04;
    pub const dtcst: u32 = 0x0C;
    pub const dtcsts: u32 = 0x0E;
};

pub const field = struct {
    /// DTCST.DTCST b0: the module start bit. Clear, and no event activates.
    pub const start: u8 = 0x01;
    /// DTCSTS.ACT b15: a transfer is in progress right now.
    pub const active: u16 = 0x8000;
    /// DTCSTS.VECN[7:0]: the vector number of that transfer.
    pub const vector: u16 = 0x00FF;
    /// A vector-table entry's b0 is a privilege attribute, not address.
    pub const ti_address: u32 = 0xFFFF_FFFE;
};

/// One vector-table entry per ICU slot, four bytes each.
pub const entry_bytes: u32 = 4;

/// Why an activation moved nothing. All of these read as a plain interrupt to
/// the firmware, so they are counted and reported rather than passed over.
pub const Refusal = union(enum) {
    /// DTCST.DTCST is clear: the controller was never started, so silicon
    /// leaves the interrupt to the CPU. dev shadows DTCST and transfers
    /// anyway, so a firmware that forgets it works there and not on a bench.
    stopped,
    /// DTCVBR is zero, or the slot's vector-table entry is.
    unprogrammed,
    /// The descriptor's counts are already spent.
    exhausted,
    /// Memory refused a descriptor read, a write-back, or a unit.
    unreadable,
    /// A descriptor shape this model will not invent a transfer for.
    unsupported: xfer.Unsupported,
};

pub fn refusalName(reason: Refusal) []const u8 {
    return switch (reason) {
        .unsupported => |detail| @tagName(detail),
        else => @tagName(reason),
    };
}

/// What one copy got through. `short` means memory refused a unit partway
/// into a block: the units before it are in the destination and stay there,
/// because a transfer is not a transaction on silicon either.
pub const Moved = struct {
    units: u32,
    short: bool,
};

/// What one activation did, so the board knows whether the CPU still sees the
/// interrupt behind it.
pub const Outcome = struct {
    slot: usize,
    units: u32,
    bytes: u32,
    /// The descriptor ran out on this activation, so DTCE came down.
    complete: bool,
    /// Whether the interrupt reaches the core at all.
    interrupt: bool,
};

/// The control registers, the activation path, and the counters behind the
/// end-of-run line.
pub const Dtc = struct {
    dtccr: u8 = 0,
    dtcvbr: u32 = 0,
    dtcst: u8 = 0,
    dtcsts: u16 = 0,
    /// Activations that actually moved something.
    activations: u32 = 0,
    units: u64 = 0,
    bytes: u64 = 0,
    /// Descriptors that ran out, each one clearing its slot's DTCE.
    completions: u32 = 0,
    /// Interrupts the controller swallowed because the descriptor had more to
    /// move and MRB.DISEL was clear.
    suppressed: u32 = 0,
    refused: u32 = 0,
    last_refusal: ?Refusal = null,
    /// DTCCR.RRS: the descriptor copy the controller is holding.
    cache: skip.Cache = .{},
    /// DTC1, CPU1's own controller at this same address (HUM Rev 1.30 ch 18:
    /// DTC0 is reachable only from CPU0, DTC1 only from CPU1). Set on DTC0;
    /// the window then serves whichever one `issuer` names.
    twin: ?*Dtc = null,
    issuer: ?*const periph.Issuer = null,
    /// The ICU table whose DTCE bits start this controller: CPU1's for DTC1.
    table: periph.Issuer = .cpu0,

    pub fn init() Dtc {
        return .{};
    }

    /// A run that never programmed the block stays out of the report.
    pub fn quiet(self: *const Dtc) bool {
        return self.activations == 0 and self.refused == 0 and self.dtcvbr == 0;
    }

    pub fn started(self: *const Dtc) bool {
        return self.dtcst & field.start != 0;
    }

    /// An event fired. If an ICU slot links it with DTCE set this is a DTC
    /// activation: run the descriptor and answer with what moved. Null means
    /// the event is not the controller's and the board raises it as usual,
    /// which is also what a refused activation leaves behind.
    pub fn activate(self: *Dtc, core: anytype, events: *icu.Icu, event: u16) ?Outcome {
        const slot = events.dtcSlotOn(self.table, event) orelse return null;
        if (!self.started()) return self.refuse(.stopped);
        const at = self.descriptorAt(core, slot) orelse return self.refuse(.unprogrammed);
        const vector = vectorOf(slot);
        var info = self.fetch(core, at, vector) orelse return self.refuse(.unreadable);
        if (info.unsupported()) |reason| return self.refuse(.{ .unsupported = reason });
        if (info.exhausted()) return self.refuse(.exhausted);
        const moved = self.copy(core, info);
        if (moved.short) return self.stopShort(core, at, &info, vector, moved.units);
        info.advance();
        writeInfo(core, at, info);
        self.cache.keep(vector, info);
        return self.settle(events, slot, info, moved.units * info.unit());
    }

    /// The descriptor this activation runs. With RRS set and the same vector
    /// as last time the controller never looks at RAM, so an edit made there
    /// since is not seen; that is the whole point of the bit, and the reason
    /// the in-tree driver toggles it after rewriting the table.
    fn fetch(self: *Dtc, core: anytype, at: u32, vector: u8) ?xfer.Info {
        if (self.cache.fetch(self.dtccr, vector)) |held| return held;
        return readInfo(core, at);
    }

    /// Book the activation and decide who gets the interrupt. With DISEL
    /// clear the CPU only hears about the last transfer, which is the whole
    /// point of the controller: an ISR per byte would cost more than the copy.
    fn settle(self: *Dtc, events: *icu.Icu, slot: usize, info: xfer.Info, moved: u32) Outcome {
        self.activations +%= 1;
        self.dtcsts = vectorOf(slot);
        const complete = info.exhausted();
        if (complete) {
            events.clearDtceOn(self.table, slot);
            self.completions +%= 1;
        }
        const interrupt = complete or info.interrupt_each;
        if (!interrupt) self.suppressed +%= 1;
        return .{
            .slot = slot,
            .units = moved / @max(info.unit(), 1),
            .bytes = moved,
            .complete = complete,
            .interrupt = interrupt,
        };
    }

    /// The TI block the slot's vector-table entry points at. Bit 0 of the
    /// entry is a privilege attribute rather than part of the address.
    fn descriptorAt(self: *const Dtc, core: anytype, slot: usize) ?u32 {
        if (self.dtcvbr == 0) return null;
        const entry = self.dtcvbr +% entry_bytes * @as(u32, @intCast(slot));
        const pointer = core.readWord(entry) catch return null;
        const at = pointer & field.ti_address;
        return if (at == 0) null else at;
    }

    /// Move one activation's worth: a single unit in normal mode, one block in
    /// block mode. Answers what actually moved, which in block mode is not
    /// always the whole block.
    fn copy(self: *Dtc, core: anytype, info: xfer.Info) Moved {
        const unit = info.unit();
        const units = info.burst();
        const source_step = info.step(info.source);
        const dest_step = info.step(info.destination);
        var source = info.sar;
        var dest = info.dar;
        var cell: [4]u8 = undefined;
        var done: u32 = 0;
        while (done < units) : (done += 1) {
            const slice = cell[0..unit];
            core.read(source, slice) catch break;
            core.write(dest, slice) catch break;
            source = xfer.walk(source, source_step);
            dest = xfer.walk(dest, dest_step);
        }
        self.units += done;
        self.bytes += done * unit;
        return .{ .units = done, .short = done < units };
    }

    /// A block that stopped partway. The units that landed are already in the
    /// destination and already booked, so the descriptor is written back with
    /// its addresses over them: leaving it where it started would hand the
    /// next activation the same bytes again and deny in the counters that
    /// these ever moved. The count is NOT spent, because the block did not
    /// complete, and the activation is still a refusal, so DTCE stays up and
    /// the CPU gets the interrupt the controller could not absorb.
    fn stopShort(self: *Dtc, core: anytype, at: u32, info: *xfer.Info, vector: u8, units: u32) ?Outcome {
        info.walkBy(units);
        writeInfo(core, at, info.*);
        self.cache.keep(vector, info.*);
        return self.refuse(.unreadable);
    }

    fn refuse(self: *Dtc, reason: Refusal) ?Outcome {
        self.last_refusal = reason;
        self.refused +%= 1;
        return null;
    }

    /// An access is the bytes it names, low lane first. DTCST and DTCSTS share
    /// the word at +0x0C, so a word read there answers both: the start bit in
    /// the low lane and the status word two lanes up, which is what a driver
    /// that reads the pair in one go is asking for.
    pub fn read(self: *Dtc, address: u32, width: u3) u32 {
        const start = address -% win_base;
        var answer: u32 = 0;
        var index: u32 = 0;
        while (index < bytelanes.span(width)) : (index += 1) {
            answer = bytelanes.place(answer, self.readByte(start +% index), index);
        }
        return answer;
    }

    /// The same rule for a store, in ascending lane order. A byte no register
    /// owns holds nothing, and DTCSTS is written by the controller rather than
    /// the firmware, so a store there is dropped rather than shadowed.
    pub fn write(self: *Dtc, address: u32, width: u3, value: u32) void {
        const start = address -% win_base;
        var index: u32 = 0;
        while (index < bytelanes.span(width)) : (index += 1) {
            self.writeByte(start +% index, bytelanes.byteAt(value, index));
        }
    }

    fn readByte(self: *const Dtc, offset: u32) u8 {
        const place = regs.owner(offset) orelse return 0;
        const shift = bytelanes.shift(place.index);
        return switch (place.reg) {
            .dtccr => self.dtccr,
            .dtcvbr => @truncate(self.dtcvbr >> shift),
            .dtcst => self.dtcst,
            .dtcsts => @truncate(@as(u32, self.dtcsts) >> shift),
        };
    }

    /// One byte into the register that owns it, leaving the rest of that
    /// register where it was: a driver is free to program the vector base in
    /// two halfword stores, and both of them have to land.
    fn writeByte(self: *Dtc, offset: u32, byte: u8) void {
        const place = regs.owner(offset) orelse return;
        if (!regs.writable(place.reg)) return;
        switch (place.reg) {
            .dtccr => {
                self.cache.latch(self.dtccr, byte);
                self.dtccr = byte;
            },
            .dtcvbr => self.dtcvbr = fold(self.dtcvbr, place.index, byte),
            .dtcst => self.dtcst = byte,
            .dtcsts => {},
        }
    }

    pub fn block(self: *Dtc) periph.Block {
        return .{
            .name = "DTC transfers",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The descriptor as it stands in memory. CRB and CRA share the last word,
/// CRB in the low half.
fn readInfo(core: anytype, at: u32) ?xfer.Info {
    const mr = core.readWord(at +% xfer.off.mr) catch return null;
    const sar = core.readWord(at +% xfer.off.sar) catch return null;
    const dar = core.readWord(at +% xfer.off.dar) catch return null;
    const counts = core.readWord(at +% xfer.off.counts) catch return null;
    return xfer.Info.decode(mr, sar, dar, @truncate(counts), @truncate(counts >> 16));
}

/// Put the walked addresses and the spent counts back where the controller
/// found them. dev never does this, so a second activation there re-reads the
/// original descriptor and copies the same bytes to the same place forever.
fn writeInfo(core: anytype, at: u32, info: xfer.Info) void {
    core.writeWord(at +% xfer.off.sar, info.sar) catch {};
    core.writeWord(at +% xfer.off.dar, info.dar) catch {};
    core.writeWord(at +% xfer.off.counts, info.packedCounts()) catch {};
}

/// Put one byte back into a wider register at its own lane.
fn fold(current: u32, index: u32, byte: u8) u32 {
    const shift = bytelanes.shift(index);
    const window = @as(u32, 0xFF) << shift;
    return (current & ~window) | (@as(u32, byte) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    return serving(context).read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    serving(context).write(address, width, value);
}

/// The controller the core in front of the bus reaches: DTC1 for CPU1 when
/// a twin is set, DTC0 otherwise.
fn serving(context: *anyopaque) *Dtc {
    const self: *Dtc = @ptrCast(@alignCast(context));
    const twin = self.twin orelse return self;
    const issuer = self.issuer orelse return self;
    return if (issuer.* == .cpu1) twin else self;
}

/// The vector number behind an ICU slot, which is what DTCSTS reports and
/// what the read skip compares one activation against the next.
pub fn vectorOf(slot: usize) u8 {
    return @truncate(@as(u16, @intCast(icu.exceptionFor(slot))) & field.vector);
}

/// The address of one vector-table entry, so a test or a later slice does not
/// redo the arithmetic.
pub fn entryAddress(vector_base: u32, slot: usize) u32 {
    return vector_base +% entry_bytes * @as(u32, @intCast(slot));
}
