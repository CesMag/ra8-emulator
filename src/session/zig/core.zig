//! The debugger's view of the Zig core (RA8EMU-105): registers by their
//! architectural names, memory through the core's own bus, one
//! instruction at a time, and a run that stops on a breakpoint address.
//!
//! It owns nothing. The front end builds the `Cpu` on the board's bus and
//! hands this a pointer to it, so the session can drive either core.
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const bus = @import("ra8_chip").core.cpu.bus;
const debug_read = @import("../debug_read.zig");
const dispatch = @import("ra8_chip").core.cpu.exception.dispatch;

pub const Cortex = @import("ra8_chip").core.cpu.cortex.Cortex;

/// Why a run handed control back to the debugger.
pub const Stop = union(enum) {
    /// The PC reached one of the breakpoint addresses.
    breakpoint: u32,
    /// Every instruction it was allowed ran.
    count,
    /// The core itself stopped (an unknown encoding, a bus fault, ...).
    core: cpu_mod.Stop,
};

/// Both stack pointers and the lowest each reached since reset
/// (RA8EMU-816); a low mark of regs.never_low was never written.
pub const StackMarks = struct { msp: u32, psp: u32, low_msp: u32, low_psp: u32 };

pub const ZigCore = struct {
    cpu: *cpu_mod.Cpu,

    pub fn stack(self: ZigCore) StackMarks {
        const r = &self.cpu.regs;
        return .{ .msp = r.msp, .psp = r.psp, .low_msp = r.low_msp, .low_psp = r.low_psp };
    }

    pub fn register(self: ZigCore, which: Cortex) u32 {
        const r = &self.cpu.regs;
        return switch (which) {
            .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12 => r.low[low(which)],
            .sp => r.sp(),
            .lr => r.lr,
            .pc => r.pc,
            .xpsr => r.xpsr,
            .msp => r.msp,
            .psp => r.psp,
            .primask => r.primask,
            .basepri => r.basepri,
            .faultmask => r.faultmask,
            .control => r.control,
            .fpscr => self.cpu.fp.fpscr.bits(),
            .msplim => r.msplim,
            .psplim => r.psplim,
            .s0, .s1, .s2, .s3, .s4, .s5, .s6, .s7, .s8, .s9, .s10, .s11, .s12, .s13, .s14, .s15, .s16, .s17, .s18, .s19, .s20, .s21, .s22, .s23, .s24, .s25, .s26, .s27, .s28, .s29, .s30, .s31 => self.cpu.fp.bank.s[single(which)],
            .vpr => @bitCast(self.cpu.fp.vpr),
        };
    }

    pub fn setRegister(self: ZigCore, which: Cortex, value: u32) void {
        const r = &self.cpu.regs;
        switch (which) {
            .r0, .r1, .r2, .r3, .r4, .r5, .r6, .r7, .r8, .r9, .r10, .r11, .r12 => r.low[low(which)] = value,
            .sp => r.setSp(value),
            .lr => r.lr = value,
            .pc => r.pc = value,
            .xpsr => r.xpsr = value,
            .msp => r.setMsp(value),
            .psp => r.setPsp(value),
            .primask => r.primask = value,
            .basepri => r.basepri = value,
            .faultmask => r.faultmask = value,
            .control => r.control = value,
            .fpscr => self.cpu.fp.fpscr = @TypeOf(self.cpu.fp.fpscr).fromBits(value),
            // Bits 2:0 of a stack limit are RES0, as MSR writes them.
            .msplim => r.msplim = value & ~@as(u32, 7),
            .psplim => r.psplim = value & ~@as(u32, 7),
            .s0, .s1, .s2, .s3, .s4, .s5, .s6, .s7, .s8, .s9, .s10, .s11, .s12, .s13, .s14, .s15, .s16, .s17, .s18, .s19, .s20, .s21, .s22, .s23, .s24, .s25, .s26, .s27, .s28, .s29, .s30, .s31 => self.cpu.fp.bank.s[single(which)] = value,
            .vpr => self.cpu.fp.vpr = @bitCast(value),
        }
    }

    pub fn read(self: ZigCore, address: u32, into: []u8) bus.Error!void {
        return debug_read.read(self.cpu.bus, address, into);
    }

    pub fn readWord(self: ZigCore, address: u32) bus.Error!u32 {
        return self.cpu.bus.readWord(address);
    }

    pub fn write(self: ZigCore, address: u32, bytes: []const u8) bus.Error!void {
        return self.cpu.bus.write(address, bytes);
    }

    /// One instruction, taking a pending exception first the way `Cpu.run`
    /// does. Null when it retired cleanly.
    pub fn step(self: ZigCore) ?cpu_mod.Stop {
        _ = dispatch.poll(self.cpu) catch return .{ .bus_fault = self.cpu.regs.pc };
        return self.cpu.step();
    }

    /// Run up to `count` instructions. The instruction under the PC always
    /// runs first, so continuing from a breakpoint moves off it; the run
    /// then stops as soon as the PC lands on any address in `breaks`.
    pub fn runUntil(self: ZigCore, breaks: []const u32, count: u64) Stop {
        var left = count;
        while (left > 0) : (left -= 1) {
            if (self.step()) |stopped| return .{ .core = stopped };
            const pc = self.cpu.regs.pc;
            for (breaks) |at| {
                if (at & ~@as(u32, 1) == pc) return .{ .breakpoint = pc };
            }
        }
        return .count;
    }
};

/// R0-R12's index into `Regs.low`.
/// S0 to S31 sit last in `Cortex`, in order.
fn single(which: Cortex) usize {
    return @backingInt(which) - @backingInt(Cortex.s0);
}

fn low(which: Cortex) usize {
    return switch (which) {
        .r0 => 0,
        .r1 => 1,
        .r2 => 2,
        .r3 => 3,
        .r4 => 4,
        .r5 => 5,
        .r6 => 6,
        .r7 => 7,
        .r8 => 8,
        .r9 => 9,
        .r10 => 10,
        .r11 => 11,
        .r12 => 12,
        else => unreachable,
    };
}
