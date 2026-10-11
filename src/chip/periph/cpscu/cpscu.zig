//! CPSCU: the chip-level security attribution words for the bus initiators,
//! the bus-initiator MPUs and the second CPU, and the gate in front of them.
//!
//! The CPSCU window at 0x4000_8000 carries the attribution the Secure boot
//! writes before it hands anything to the Non-Secure world. Two of its words
//! already have a home: IPCSAR and IPCPAR live in ipc/attr.zig, because they
//! attribute the mailbox channels and the mailbox is what reports them. This
//! file is the rest of what the firmware in this tree touches: the three bus
//! controller words, the two bus-initiator MPU words, and the CPU attribution word.
//!
//! WHAT THE FIRMWARE DOES WITH THEM. cpu1_pingpong_ipc's trustzone_init.c
//! writes all six in one protected scope, immediately before it releases the
//! second core, and says why in its own comment: "With these at cold-reset
//! defaults the M33's view of NS peripherals is gated by the chip's bus
//! arbiter; the CPU1 SAU init in cpu1_main.c alone is not sufficient to reach
//! IPCSAR-attributed channels."
//!
//! WHY THEY ARE MODELLED RATHER THAN LEFT TO THE SPARSE BUS, which is the
//! same argument pscu.zig makes for PSARB..PSARE next door. An unmodelled
//! address is answered out of an unmodelled cell, and that cell alternates 0
//! and 0xFFFF_FFFF on repeated reads. For an attribution word those two
//! values are "everything Secure" and "everything given away", the two
//! opposite answers, and which one a driver gets is a function of how often
//! the address has been touched. No image in this tree reads one back yet,
//! so what the run gains today is the PRC4 gate below and a report that says
//! what the boot delegated; the determinism is for the image that does.
//!
//! EVERY WORD IS GATED BY PRCR_S.PRC4, the same gate ipc/attr.zig holds and
//! the reason this is a block rather than a shadow. A store issued with PRC4
//! shut is discarded by silicon with no fault and no status bit. The
//! firmware opens PRC4 and PRC1 together across the whole release sequence
//! for exactly that reason, so the happy path is unaffected and what the
//! gate catches is a firmware that forgot.
//!
//! THE RESERVED CHECK RUNS BEFORE THE GATE, the cut spi.zig already made
//! between a malformed access and a disabled channel: an offset that is not
//! a register is not a register whether or not PRC4 was open, so it is
//! counted as reserved and never as refused.
//!
//! RESET IS ZERO ON ALL SIX. The active-high convention across this window
//! is that a set bit is the permissive state, so all-zero is "everything
//! Secure", which is the cold-reset state ra8_dual_core.h names for the one
//! word it talks about ("CPUSAR.CPUSA1 defaults Secure") and the same reset
//! pscu.zig records for the peripheral attribution words.
//!
//! RECORDED, NOT ENFORCED, the line the SAU and IPC attribution models both
//! hold. Nothing here refuses an access because an initiator was left Secure:
//! this board has no bus arbiter and no bus-initiator MPU to refuse on behalf of,
//! and a refusal invented out of a register value would be a register file
//! pretending to be a decision.
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
const lanes = @import("../lanes.zig");

/// SRAMSAR, SRAMSABAR0..3 and SRAMESAR, in windows of their own.
pub const sram = @import("sram.zig");

/// The window, from the first register to one past the last.
pub const win_base: u32 = 0x4000_8100;
pub const win_span: u32 = 0x74;

/// Offsets from win_base (trustzone_init.c, absolute addresses in the
/// source: 0x4000_8100, _8104, _8110, _8130, _8134, _8170).
pub const off = struct {
    pub const bussara: u32 = 0x00;
    pub const bussarb: u32 = 0x04;
    pub const bussarc: u32 = 0x10;
    pub const mmpusara: u32 = 0x30;
    pub const mmpusarb: u32 = 0x34;
    pub const cpusar: u32 = 0x70;
};

/// The six words, in the order the unit stores them.
pub const Register = enum(usize) {
    bussara = 0,
    bussarb,
    bussarc,
    mmpusara,
    mmpusarb,
    cpusar,
};

pub const register_count: usize = 6;

/// Offset per slot, parallel to Register.
pub const layout = [register_count]u32{
    off.bussara,
    off.bussarb,
    off.bussarc,
    off.mmpusara,
    off.mmpusarb,
    off.cpusar,
};

/// Reset: every initiator Secure.
pub const reset: u32 = 0;

/// The six words, and what the gate turned away.
pub const Unit = struct {
    words: [register_count]u32 = @splat(reset),
    /// Stores that landed on a register with PRC4 open.
    writes: u32 = 0,
    /// Stores silicon would have discarded, because PRC4 was shut.
    locked_writes: u32 = 0,
    /// Stores that named an offset in the window that is not a register.
    reserved_writes: u32 = 0,
    /// The protection model this board owns. Null until wired, and a block
    /// that was never wired accepts nothing, which is the safe direction.
    protection: ?*const prcr.Prcr = null,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Unit) bool {
        return self.writes == 0 and self.locked_writes == 0 and self.reserved_writes == 0;
    }

    /// Whether PRC4 is open right now. Asked once per store and never for a
    /// read: HUM Ch 13 gates writes only.
    fn open(self: *const Unit) bool {
        const gate = self.protection orelse return false;
        return gate.unlocked(prcr.group.sar);
    }

    pub fn wordOf(self: *const Unit, register: Register) u32 {
        return self.words[@backingInt(register)];
    }

    /// True once any initiator has been handed to the Non-Secure world.
    pub fn anyDelegated(self: *const Unit) bool {
        for (self.words) |word| {
            if (word != reset) return true;
        }
        return false;
    }

    /// Which register an offset lands in, or null for the gaps between them.
    fn slotOf(offset: u32) ?usize {
        const aligned = offset & ~@as(u32, 0x3);
        for (layout, 0..) |at, slot| {
            if (at == aligned) return slot;
        }
        return null;
    }

    pub fn read(self: *Unit, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const slot = slotOf(offset) orelse return 0;
        return lanes.part(self.words[slot], offset & 0x3, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        const offset = address -% win_base;
        const slot = slotOf(offset) orelse {
            self.reserved_writes +%= 1;
            return;
        };
        if (!self.open()) {
            self.locked_writes +%= 1;
            return;
        }
        const word = &self.words[slot];
        word.* = lanes.merge(word.*, offset & 0x3, width, value);
        self.writes +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "CPSCU-SAR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
