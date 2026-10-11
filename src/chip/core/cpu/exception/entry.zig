//! Exception entry: stack the basic frame on the stack in use, leave
//! EXC_RETURN in LR, and branch to the handler the vector table names, in
//! Handler mode on the Main stack.
//!
//! R0-R3 and R12 are left as they were (the architecture makes them
//! UNKNOWN). Whether an exception may be taken at all, and the active stack,
//! are dispatch.zig's; this is only the architectural entry sequence.
const bus = @import("../bus.zig");
const regs_mod = @import("../regs.zig");
const memmap = @import("../../memmap.zig");
const Cpu = @import("../cpu.zig").Cpu;
const frame = @import("frame.zig");
const fp_frame = @import("fp/frame.zig");
const fp_ready = @import("fp/ready.zig");
const exc_return = @import("exc_return.zig");
const target = @import("target.zig");
const callee = @import("callee.zig");
const State = @import("../../banked.zig").State;
const sysreg = @import("../sysreg.zig");
const stack_fault = @import("stack_fault.zig");

/// EPSR.ICI/IT and B; exception entry clears each from live xPSR.
pub const it_bits: u32 = (0x3 << 25) | (0x3F << 10) | regs_mod.xpsr_bits.bti;

pub const Number = u9;

pub const Result = struct {
    overflow: bool,
    from: State,
    failed: ?stack_fault.Failure = null,
};

/// Take an exception directly. Dispatch uses takeDetailed to route any
/// derived stacking fault; callers that enter a known-good test frame only
/// need the stack-limit result.
pub fn take(cpu: *Cpu, number: Number, return_address: u32) bus.Error!bool {
    return (try takeDetailed(cpu, number, return_address)).overflow;
}

/// Take exception `number`, retaining whether moving its frame faulted.
pub fn takeDetailed(cpu: *Cpu, number: Number, return_address: u32) bus.Error!Result {
    const r = &cpu.regs;
    cpu.exclusive = null;
    const from_secure = cpu.banked.current == .secure;
    const to_secure = target.secure(cpu, number);
    const handler = try handlerOf(cpu, number);
    const stacked: frame.Frame = .{
        r.low[0],  r.low[1], r.low[2],       r.low[3],
        r.low[12], r.lr,     return_address, r.xpsr,
    };
    const fp = r.control & regs_mod.control_bits.fpca != 0;
    const from: exc_return.Target = .{
        .thread = !r.handlerMode(),
        .psp = r.usesPsp(),
        .fp = fp,
        .secure = to_secure,
        .secure_stack = from_secure,
    };
    // FPCCR.TS: a Secure FP context also stacks S16-S31 (RA8EMU-165).
    const ts = fp and from_secure and cpu.fp.context.fpccr.ts == 1;
    const size = if (fp) fp_frame.sizeFor(ts) else frame.size;
    const at = frameAddress(r.sp(), size);
    const limit = r.spLimit();
    const overflow = limit != 0 and at < limit;
    var failed: ?stack_fault.Failure = null;
    if (overflow) {
        // DDI0553 B3.21: exception entry sets SP to the limit and does not
        // push frame words below it. Dispatch selects the derived STKOF.
        r.setSp(limit);
        if (fp and cpu.fp.context.fpccr.lspen == 1) armLazy(cpu, at, from_secure, true);
    } else {
        stack_fault.beginEntry(cpu, number);
        defer stack_fault.end(cpu);
        const pushed = (if (fp)
            pushFp(cpu, stacked, from_secure, ts)
        else
            frame.push(cpu.bus, r.sp(), stacked)) catch blk: {
            failed = stack_fault.failure(cpu);
            break :blk at;
        };
        r.setSp(pushed);
        if (failed == null and from_secure and !to_secure) hideSecure(cpu, fp, ts) catch {
            failed = stack_fault.failure(cpu);
        };
    }
    if (from_secure and !to_secure and (overflow or failed != null)) scrubSecure(cpu, ts);
    r.lr = exc_return.forEntry(from);
    cpu.banked.switchTo(r, if (to_secure) .secure else .non_secure);
    r.control &= ~(regs_mod.control_bits.spsel | regs_mod.control_bits.fpca);
    land(cpu, number, handler);
    return .{ .overflow = overflow, .from = if (from_secure) .secure else .non_secure, .failed = failed };
}

/// A Non-secure exception over Secure code: stack R4-R11 under the
/// integrity signature on the Secure stack, then clear R0-R12 so the
/// Non-secure handler sees none of them (DDI0553 B3.19).
/// With FPCCR.TS an eagerly stacked Secure FP context is cleared too:
/// S0-S31 and FPSCR (RA8EMU-165).
fn hideSecure(cpu: *Cpu, fp: bool, ts: bool) bus.Error!void {
    const r = &cpu.regs;
    var saved: callee.Callee = undefined;
    for (&saved, 4..) |*word, i| word.* = r.low[i];
    r.setSp(try callee.push(cpu.bus, r.sp(), saved, fp));
    scrubSecure(cpu, ts);
}

fn scrubSecure(cpu: *Cpu, ts: bool) void {
    for (0..13) |i| cpu.regs.low[i] = 0;
    if (ts and cpu.fp.context.fpccr.lspact == 0) {
        for (0..32) |i| cpu.fp.bank.writeS(@intCast(i), 0);
        cpu.fp.fpscr = @TypeOf(cpu.fp.fpscr).fromBits(0);
    }
}

fn frameAddress(sp: u32, size: u32) u32 {
    return (sp -% size) & ~(sp & 4);
}

/// The extended frame. With FPCCR.LSPEN clear it goes out whole. With it
/// set only the basic words are written: FPCAR names the reserved FP space
/// and UpdateFPCCR records LSPACT, USER, THREAD, S and the *RDY bits
/// (fp_ready.zig), so the first FP instruction in the handler writes the
/// context (fpu/lazy.zig, RA8EMU-163).
fn pushFp(cpu: *Cpu, stacked: frame.Frame, secure: bool, ts: bool) bus.Error!u32 {
    const r = &cpu.regs;
    const ctx = &cpu.fp.context;
    if (ctx.fpccr.lspen == 0) return fp_frame.push(cpu.bus, r.sp(), stacked, fpContext(cpu, ts));
    const at = try fp_frame.reserve(cpu.bus, r.sp(), stacked, ts);
    armLazy(cpu, at, secure, false);
    return at;
}

/// UpdateFPCCR for a lazy entry whose frame starts at `at`: FPCAR, LSPACT,
/// USER, THREAD, S, SPLIMVIOL and the *RDY bits.
fn armLazy(cpu: *Cpu, at: u32, secure: bool, violated: bool) void {
    const r = &cpu.regs;
    const ctx = &cpu.fp.context;
    ctx.writeFpcar(at +% frame.size);
    ctx.fpccr.lspact = 1;
    ctx.fpccr.user = @intFromBool(!sysreg.privileged(r));
    ctx.fpccr.thread = @intFromBool(!r.handlerMode());
    ctx.fpccr.s = @intFromBool(secure);
    ctx.fpccr.splimviol = @intFromBool(violated);
    fp_ready.record(cpu, &ctx.fpccr);
}

/// S0-S15, FPSCR and, with MVE, VPR as the eager extended frame stacks
/// them, and S16-S31 when `ts`.
fn fpContext(cpu: *const Cpu, ts: bool) fp_frame.Fp {
    const vpr: u32 = if (cpu.profile.mve) @bitCast(cpu.fp.vpr) else 0;
    var fp: fp_frame.Fp = .{ .s = undefined, .fpscr = cpu.fp.fpscr.bits(), .vpr = vpr };
    for (&fp.s, 0..) |*s, i| s.* = cpu.fp.bank.readS(@intCast(i));
    if (ts) {
        var high: [16]u32 = undefined;
        for (&high, 16..) |*s, i| s.* = cpu.fp.bank.readS(@intCast(i));
        fp.high = high;
    }
    return fp;
}

/// Redirect an in-progress entry to a derived exception without stacking
/// again. LR already contains EXC_RETURN for the interrupted context.
pub fn retarget(cpu: *Cpu, number: Number, from_state: State) bus.Error!void {
    const was = cpu.banked.current;
    cpu.banked.current = from_state;
    const to_secure = target.secure(cpu, number);
    const handler = handlerOf(cpu, number) catch |err| {
        cpu.banked.current = was;
        return err;
    };
    cpu.banked.current = was;
    const es = exc_return.bits.es;
    cpu.regs.lr = if (to_secure) cpu.regs.lr | es else cpu.regs.lr & ~es;
    cpu.banked.switchTo(&cpu.regs, if (to_secure) .secure else .non_secure);
    cpu.regs.control &= ~(regs_mod.control_bits.spsel | regs_mod.control_bits.fpca);
    land(cpu, number, handler);
}

/// Take exception `number` without stacking a frame, with `lr` as the link
/// value: a fault raised by a failed exception return, whose frame is still
/// on the stack where the return found it.
pub fn chain(cpu: *Cpu, number: Number, lr: u32) bus.Error!void {
    cpu.exclusive = null;
    const handler = try cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
    cpu.regs.lr = lr;
    cpu.regs.control &= ~(regs_mod.control_bits.spsel | regs_mod.control_bits.fpca);
    land(cpu, number, handler);
}

/// IPSR, EPSR.T and the PC for a handler about to run. Entry also sets the
/// event register.
fn land(cpu: *Cpu, number: Number, handler: u32) void {
    const r = &cpu.regs;
    cpu.event = true;
    r.xpsr = (r.xpsr & ~(it_bits | regs_mod.xpsr_bits.ipsr)) | number;
    const thumb = regs_mod.xpsr_bits.thumb;
    r.xpsr = if (handler & 1 != 0) r.xpsr | thumb else r.xpsr & ~thumb;
    r.pc = handler & ~@as(u32, 1);
}

/// The handler for `number` in the vector table of the state it is taken
/// to: VTOR reads through the bus as the running state sees it, so the
/// state is set for the read and put back.
pub fn handlerOf(cpu: *Cpu, number: Number) bus.Error!u32 {
    const was = cpu.banked.current;
    cpu.banked.current = if (target.secure(cpu, number)) State.secure else State.non_secure;
    defer cpu.banked.current = was;
    return cpu.bus.readWord(vectorTable(cpu) +% @as(u32, number) * 4);
}

/// VTOR as the firmware set it, or the table the core reset from while
/// nothing answers at VTOR or it still reads zero.
pub fn vectorTable(cpu: *const Cpu) u32 {
    const vtor = cpu.bus.readWord(memmap.scb.vtor) catch 0;
    return if (vtor != 0) vtor else cpu.vtor;
}
