//! IPCSAR / IPCPAR: which IPC channels the Secure world handed over, and the
//! protection gate that has to be open before either word will land.
//!
//! The four IPC channels are Secure and Privileged out of cold reset, so a
//! Non-Secure application cannot reach the mailbox at all until the Secure
//! boot gives it away. Two words in the CPSCU window do the giving: IPCSAR
//! at 0x4000_8610 marks a channel Non-Secure, IPCPAR at 0x4000_8614 marks it
//! Unprivileged (HUM Ch 3.2.1 "IPCSAR" p 205, Ch 3.2.2 "IPCPAR" p 207). The
//! bit is active-high for the permissive state, which ra8_ipc_types.h states
//! twice in so many words, so a set bit is a channel given away and a clear
//! one is a channel kept.
//!
//! BOTH WORDS ARE GATED BY PRCR_S.PRC4 and that gate is the whole reason
//! this block exists rather than letting the sparse register file keep
//! answering. A store issued with PRC4 shut is discarded by silicon with no
//! fault and no status bit, exactly like every other protected register, and
//! the firmware in this tree depends on it: cpu1_pingpong_ipc's
//! trustzone_init.c carries a paragraph saying that
//! ra8_tz_secure_boot_security_init "opens PRC4 for the IPCSAR write then
//! relocks the whole PRCR_S, so the writes inside ra8_cpu1_release are
//! silently dropped without an explicit unlock here", with the bench symptom
//! recorded next to it. The library's own security_init brackets the pair
//! between a gateOpen and a gateClose for the same reason. The sparse file
//! took the store whenever it arrived, so a firmware that forgot the unlock
//! was told it had given the channels away and every later read agreed.
//!
//! THE ATTRIBUTION IS RECORDED, NOT ENFORCED, which is the same line the SAU
//! model holds: nothing here refuses an IPC access because the channel was
//! kept Secure. A single-image headless run has no second world to refuse on
//! behalf of, and inventing a refusal would stop the apps that reach the
//! mailbox from the Secure side. What the run can honestly say is which
//! channels the boot gave away and whether the words it wrote landed, and
//! that is what the report carries.
//!
//! NOT MODELLED, AND NOT GUESSED: the rest of the CPSCU attribution window.
//! BUSSARA/B/C, MMPUSARA/B and CPUSAR are written by the same boot and are
//! still shadow, because they attribute the bus arbiter and the bus-initiator MPU,
//! neither of which this board models; giving them a home here would be a
//! register file pretending to be a decision.
const periph = @import("../registry.zig");
const prcr = @import("../prcr.zig");
const lanes = @import("../lanes.zig");

/// CPSCU geometry (ra8_ipc_regs.h: IPCSAR 0x4000_8610, IPCPAR 0x4000_8614).
pub const win_base: u32 = 0x4000_8610;
pub const win_span: u32 = 0x8;

pub const off = struct {
    pub const sar: u32 = 0x00;
    pub const par: u32 = 0x04;
};

/// One bit per channel, and the channels the mailbox actually has.
pub const field = struct {
    pub const channels: usize = 4;
    pub const mask: u32 = (1 << channels) - 1;
};

/// Which world and which privilege a channel was left in.
pub const World = enum { secure, non_secure };
pub const Access = enum { privileged, unprivileged };

/// The attribution pair, plus what the protection gate turned away.
pub const Attribution = struct {
    /// The live words. Reset is zero: every channel Secure and Privileged.
    sar: u32 = 0,
    par: u32 = 0,
    /// Stores that landed with PRC4 open.
    writes: u32 = 0,
    /// Stores silicon would have discarded, because PRC4 was shut.
    locked_writes: u32 = 0,
    /// The protection model this board owns. Null until wired, and a block
    /// that was never wired accepts nothing, which is the safe direction.
    protection: ?*const prcr.Prcr = null,

    pub fn init(protection: *const prcr.Prcr) Attribution {
        return .{ .protection = protection };
    }

    /// Untouched units stay out of the end-of-run report.
    pub fn quiet(self: *const Attribution) bool {
        return self.writes == 0 and self.locked_writes == 0;
    }

    /// Whether PRC4 is open right now. The gate question, asked once per
    /// store and never for a read: HUM Ch 13 gates writes only.
    fn open(self: *const Attribution) bool {
        const gate = self.protection orelse return false;
        return gate.unlocked(prcr.group.sar);
    }

    pub fn worldOf(self: *const Attribution, channel: usize) World {
        const bit = @as(u32, 1) << @intCast(channel);
        return if (self.sar & bit != 0) .non_secure else .secure;
    }

    pub fn accessOf(self: *const Attribution, channel: usize) Access {
        const bit = @as(u32, 1) << @intCast(channel);
        return if (self.par & bit != 0) .unprivileged else .privileged;
    }

    /// How many of the four channels were handed to the Non-Secure world.
    pub fn givenAway(self: *const Attribution) usize {
        var count: usize = 0;
        for (0..field.channels) |channel| {
            if (self.worldOf(channel) == .non_secure) count += 1;
        }
        return count;
    }

    pub fn read(self: *Attribution, address: u32, width: u3) u32 {
        const offset = address -% win_base;
        const word = if (offset < off.par) self.sar else self.par;
        return lanes.part(word, offset & 0x3, width);
    }

    pub fn write(self: *Attribution, address: u32, width: u3, value: u32) void {
        if (!self.open()) {
            self.locked_writes +%= 1;
            return;
        }
        const offset = address -% win_base;
        const slot = if (offset < off.par) &self.sar else &self.par;
        slot.* = lanes.merge(slot.*, offset & 0x3, width, value);
        self.writes +%= 1;
    }

    pub fn block(self: *Attribution) periph.Block {
        return .{
            .name = "IPC-ATTR",
            .base = win_base,
            .size = win_span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Attribution = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Attribution = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
