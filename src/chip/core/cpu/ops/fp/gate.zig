//! ExecuteFPCheck() in front of the FP and MVE groups (RA8EMU-170). The
//! decode table wraps each of those groups with `gated`, so an instruction
//! that passes its condition first finishes any pending lazy preservation
//! (FPCCR.LSPACT, RA8EMU-163), then opens a new FP context: with
//! FPCCR.ASPEN set and CONTROL.FPCA clear, FPSCR loads from FPDSCR and FPCA
//! is set.
//!
//! Before any of that, CheckCPEnabled(10) (RA8EMU-145): with CPACR.CP10
//! refusing the access the instruction raises UsageFault.NOCP and touches no
//! FP state. NSACR is not modelled, so the check reads the CPACR the core
//! holds as the Secure one, as VLLDM/VLSTM already do.
//!
//! The wrapper decodes the instruction a second time when it runs, because
//! a group's decode hands back a bare function with nothing to close over.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const mpu_check = @import("../../mpu_check.zig");
const lazy = @import("../../fpu/lazy.zig");
const fp_mem = @import("mem.zig");
const cpacr = @import("../../fpu/cpacr.zig");
const sysreg = @import("../../sysreg.zig");

/// The same group, with ExecuteFPCheck() ahead of every instruction it runs.
pub fn gated(comptime inner: op.Group) op.Group {
    const Wrap = struct {
        fn decode(instr: Instr) ?op.Exec {
            return if (inner.decode(instr) != null) &exec else null;
        }

        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            try check(cpu);
            const run = inner.decode(instr).?;
            return run(cpu, instr);
        }
    };
    return .{ .name = inner.name, .decode = &Wrap.decode, .oracle = inner.oracle };
}

/// VLDR FPCXT_NS on an inactive context is the one memory-system-register
/// form that deliberately avoids ExecuteFPCheck and FP context creation.
pub fn gatedFpMemory(comptime inner: op.Group) op.Group {
    const Wrap = struct {
        fn decode(instr: Instr) ?op.Exec {
            return if (inner.decode(instr) != null) &exec else null;
        }

        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const inactive = cpu.fp.context.fpccr.aspen == 1 and
                cpu.regs.control & @import("../../regs.zig").control_bits.fpca == 0;
            if (!(fp_mem.isInactiveFpcxtNs(instr) and inactive)) try check(cpu);
            return inner.decode(instr).?(cpu, instr);
        }
    };
    return .{ .name = inner.name, .decode = &Wrap.decode, .oracle = inner.oracle };
}

/// The checks an FP or MVE instruction makes before it touches FP state.
pub fn check(cpu: *Cpu) op.Error!void {
    const verdict = cpacr.check(.{ .cpacr = cpu.fp.cpacr, .privileged = sysreg.privileged(&cpu.regs) });
    if (!verdict.enabled) return error.NoCoprocessor;
    if (lazy.pending(&cpu.fp)) {
        try preserve(cpu);
        if (cpu.fp.context.fpccr.s == 1 and cpu.banked.current == .non_secure) hideSecure(cpu);
    }
    cpu.regs.control = cpu.fp.context.touch(
        cpu.regs.control,
        cpu.banked.current,
        &cpu.fp.fpscr,
        &cpu.fp.vpr,
    );
}

/// A Secure context the deferred push just saved while Non-secure code
/// runs: S0-S15 and FPSCR, and S16-S31 with FPCCR.TS, are cleared so the
/// Non-secure instruction cannot read Secure values (RA8EMU-165).
fn hideSecure(cpu: *Cpu) void {
    const n: usize = if (cpu.fp.context.fpccr.ts == 1) 32 else 16;
    for (0..n) |i| cpu.fp.bank.writeS(@intCast(i), 0);
    cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0);
}

/// PreserveFPState under the MPU as the lazy entry saw it: privileged as
/// FPCCR.USER says and at negative priority while FPCCR.HFRDY is clear
/// (DDI0553 AccType_LAZYFP). A refusal is MemManage MLSPERR (RA8EMU-621).
fn preserve(cpu: *Cpu) op.Error!void {
    const m = cpu.mpu orelse return push(cpu, null);
    const armed = m.armed;
    const privileged = m.privileged;
    defer {
        m.armed = armed;
        m.privileged = privileged;
    }
    const fpccr = cpu.fp.context.fpccr;
    m.arm(fpccr.user == 0, fpccr.hfrdy == 0);
    return push(cpu, m);
}

/// The push itself: an MPU refusal is MLSPERR, a Security Attribution
/// refusal SecureFault LSPERR, any other bus error BusFault LSPERR.
fn push(cpu: *Cpu, m: ?*mpu_check.Check) op.Error!void {
    lazy.preserve(cpu.bus, &cpu.fp) catch |err| {
        if (m) |c| if (c.take() != null) return error.LazyMemManage;
        return switch (err) {
            error.LazyPreserveError, error.SecurityViolation => error.LazyPreserveError,
            error.Unmapped => error.LazyBusFault,
        };
    };
}
