//! DOTF: decryption on the fly, so an encrypted-XSPI bring-up finishes.
//!
//! Two channels sit at 0x4026_8800 with a 0x100 stride, one in front of each
//! xSPI controller (ra8_dotf_regs.h ra8_dotf_addr_t, cited there against FSP
//! R_DOTF_Type and HUM Ch 45 p 3048-3050). The block had no model here at
//! all: every access fell through to the sparse register file, which stores
//! whatever it is given and hands it straight back. That gets one thing
//! actively wrong rather than merely thin. `ra8_dotf_self_test` writes
//! REG00 bit 20 and then waits for that same bit to read back CLEAR, so a
//! register that keeps what it was given never ends the test: the driver
//! spins out its budget and reports a hardware timeout on a part that is
//! working. CONVAREAD was wrong in a quieter way, reading back the zeroes
//! that were written into its reserved field where silicon reads ones.
//!
//!   CONVAREAST (+0x000, 32b) conversion area start, 4 KB granular
//!   CONVAREAD  (+0x004, 32b) conversion area end, reserved field reads 1
//!   REG00      (+0x080, 32b) AES enable, key size, mode, self-test
//!   REG03      (+0x08C, 32b) key and IV staging window, write-only
//!
//! The address rules are in src/chip/periph/dotf/region.zig and the REG00 rule in
//! src/chip/periph/dotf/control.zig, each of which states what it does not model.
//! Two conversion-area configurations silicon does not allow are counted
//! rather than refused, because the HUM records each as a requirement on the
//! driver without saying what the hardware does when it is broken: a
//! reversed pair (start above end) and an area moved while the AES core is
//! decrypting. region.zig carries both citations.
//!
//! REG03 IS A STAGING WINDOW, NOT A REGISTER. The driver pushes four words
//! of IV, or four to eight words of wrapped key, big-endian, one after the
//! other into the same address (ra8_dotf.c internal_stage_iv and
//! internal_stage_key). Nothing reads it back, and there is no read value in
//! either tree, so a read answers zero and a write is counted rather than
//! stored. Every other offset in the window is reserved padding in FSP's own
//! struct; it is shadowed so a read-modify-write survives, and never read.
const periph = @import("../registry.zig");
const control = @import("control.zig");
const region = @import("region.zig");

/// DOTF geometry. The bus folds the Non-secure alias onto this base.
pub const win_base: u32 = 0x4026_8800;
pub const stride: u32 = 0x100;
pub const channel_count: usize = 2;
pub const win_span: u32 = stride * @as(u32, channel_count);

/// The two rules, re-exported so callers reach them through this block.
pub const core = control;
pub const area = region;

pub const off = struct {
    pub const convareast: u32 = 0x000;
    pub const convaread: u32 = 0x004;
    pub const reg00: u32 = 0x080;
    pub const reg03: u32 = 0x08C;
};

/// One channel: the four registers this model interprets, a shadow for the
/// reserved padding around them, and what the run should be told.
pub const Channel = struct {
    convareast: u32 = 0,
    convaread: u32 = 0,
    reg00: u32 = 0,
    shadow: [stride]u8 = @splat(0),
    /// Self-tests run to completion inside the write that asked for one.
    self_tests: u32 = 0,
    /// Words pushed into the staging window.
    staged: u32 = 0,
    /// Words pushed with the AES core switched off, which stage nothing.
    staged_dark: u32 = 0,
    /// Reads of the staging window, which has no value to give.
    empty_reads: u32 = 0,
    /// Times the core was switched on.
    enables: u32 = 0,
    /// Regions programmed outside the XSPI window this channel is bound to,
    /// counted once per region rather than once per write.
    out_of_window: u32 = 0,
    /// Whether the region standing now is one of them, so a region written
    /// in several writes is counted once and a re-write is not counted again.
    outside: bool = false,
    /// Reversed pairs programmed, a start above its end, counted once per
    /// region the same way out_of_window is.
    reversed_areas: u32 = 0,
    /// Whether the pair standing now is reversed.
    backwards: bool = false,
    /// Conversion-area stores made while the core was decrypting.
    live_area_writes: u32 = 0,

    pub fn quiet(self: *const Channel) bool {
        return self.self_tests == 0 and self.staged == 0 and self.staged_dark == 0 and
            self.empty_reads == 0 and self.enables == 0 and self.reg00 == 0 and
            self.convareast == 0 and self.convaread == 0 and
            self.reversed_areas == 0 and self.live_area_writes == 0;
    }

    pub fn enabled(self: *const Channel) bool {
        return control.enabled(self.reg00);
    }

    pub fn decrypting(self: *const Channel) bool {
        return control.decrypting(self.reg00);
    }

    pub fn keySize(self: *const Channel) control.KeySize {
        return control.KeySize.of(self.reg00);
    }

    pub fn mode(self: *const Channel) control.Mode {
        return control.Mode.of(self.reg00);
    }

    pub fn start(self: *const Channel) u32 {
        return region.address(self.convareast);
    }

    pub fn end(self: *const Channel) u32 {
        return region.address(self.convaread);
    }

    pub fn pages(self: *const Channel) u32 {
        return region.pages(self.convareast, self.convaread);
    }

    /// True when this channel would decrypt a read of that address.
    pub fn covers(self: *const Channel, address: u32) bool {
        return self.decrypting() and region.covers(self.convareast, self.convaread, address);
    }

    /// The value a register actually holds, so a narrow write folds into
    /// the bytes it does not name. This is the stored value, not the one a
    /// read gives back: CONVAREAD reads its reserved field back as ones, and
    /// folding those in would let a byte write carry them into the address
    /// field. The staging window holds nothing, so it folds into zero.
    fn held(self: *const Channel, local: u32) u32 {
        return switch (local) {
            off.convareast => self.convareast,
            off.convaread => self.convaread,
            off.reg00 => self.reg00,
            off.reg03 => 0,
            else => self.shadowWord(local),
        };
    }

    fn word(self: *Channel, local: u32) u32 {
        return switch (local) {
            off.convareast => region.startReadback(self.convareast),
            off.convaread => region.endReadback(self.convaread),
            off.reg00 => self.reg00,
            off.reg03 => self.readStage(),
            else => self.shadowWord(local),
        };
    }

    fn readStage(self: *Channel) u32 {
        self.empty_reads +%= 1;
        return 0;
    }

    fn shadowWord(self: *const Channel, local: u32) u32 {
        var value: u32 = 0;
        var i: u32 = 0;
        while (i < 4 and local + i < stride) : (i += 1) {
            value |= @as(u32, self.shadow[local + i]) << @intCast(i * 8);
        }
        return value;
    }

    fn writeWord(self: *Channel, index: usize, local: u32, value: u32) void {
        switch (local) {
            off.convareast, off.convaread => self.setArea(index, local, value),
            off.reg00 => self.setControl(value),
            off.reg03 => self.stage(),
            else => self.setShadow(local, value),
        }
    }

    /// A region is refused on the pair, not on the half of an address that
    /// has just landed. Firmware programs these registers a word or a
    /// halfword at a time, so between the two writes the channel names an
    /// address it was never asked to decrypt over.
    fn setArea(self: *Channel, index: usize, local: u32, value: u32) void {
        // The precondition is on the state standing BEFORE the store, so a
        // store that itself switches the core off is judged against the core
        // that was running when it was made.
        if (self.decrypting()) self.live_area_writes +%= 1;
        if (local == off.convareast) self.convareast = value else self.convaread = value;
        const now = region.outsideWindow(region.window(index), self.convareast, self.convaread);
        if (now and !self.outside) self.out_of_window +%= 1;
        self.outside = now;
        const backwards = region.reversed(self.convareast, self.convaread);
        if (backwards and !self.backwards) self.reversed_areas +%= 1;
        self.backwards = backwards;
    }

    /// The self-test runs inside the write, so the bit never lands.
    fn setControl(self: *Channel, value: u32) void {
        if (control.testRequested(value)) self.self_tests +%= 1;
        const was_on = self.enabled();
        self.reg00 = control.stored(value);
        if (self.enabled() and !was_on) self.enables +%= 1;
    }

    fn stage(self: *Channel) void {
        if (self.enabled()) self.staged +%= 1 else self.staged_dark +%= 1;
    }

    fn setShadow(self: *Channel, local: u32, value: u32) void {
        var i: u32 = 0;
        while (i < 4 and local + i < stride) : (i += 1) {
            self.shadow[local + i] = @truncate(value >> @intCast(i * 8));
        }
    }
};

pub const Dotf = struct {
    channels: [channel_count]Channel = @splat(Channel{}),

    pub fn init() Dotf {
        return .{};
    }

    pub fn quiet(self: *const Dotf) bool {
        for (&self.channels) |*unit| {
            if (!unit.quiet()) return false;
        }
        return true;
    }

    pub fn read(self: *Dotf, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        if (offset >= win_span) return 0;
        const index = offset / stride;
        const local = offset % stride;
        const aligned = local & ~@as(u32, 3);
        const value = self.channels[index].word(aligned);
        return narrow(value, local - aligned, width);
    }

    pub fn write(self: *Dotf, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        if (offset >= win_span) return;
        const index = offset / stride;
        const local = offset % stride;
        const aligned = local & ~@as(u32, 3);
        const unit = &self.channels[index];
        const placed = if (width >= 4 and local == aligned)
            value
        else
            merge(unit.held(aligned), local - aligned, width, value);
        unit.writeWord(index, aligned, placed);
    }

    pub fn block(self: *Dotf) periph.Block {
        return .{
            .name = "DOTF",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

/// The part of a 32-bit register a narrow access names.
fn narrow(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4 and byte_offset == 0) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const shifted = value >> shift;
    return switch (width) {
        1 => shifted & 0xFF,
        2 => shifted & 0xFFFF,
        else => shifted,
    };
}

/// Fold a narrow write into a 32-bit register without disturbing the bytes
/// the access does not name.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    const shift: u5 = @intCast(byte_offset * 8);
    const span: u32 = switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
    const window = span << shift;
    return (current & ~window) | ((value & span) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Dotf = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Dotf = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The address of one channel's register window, so a test or a later slice
/// does not do the arithmetic itself.
pub fn channelAddress(channel: usize) u32 {
    return win_base + @as(u32, @intCast(channel)) * stride;
}
