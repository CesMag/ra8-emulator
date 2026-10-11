//! VCMP and VCMPE (T1 register, T2 against +0.0), single and double
//! precision, and the FPSCR transfers VMRS and VMSR.
//!
//! VCMP{E}: hw1 is 1110 1110 1 D 11 010z and hw2 is Vd 101 sz E 1 M 0 Vm,
//! with z set for the compare with zero, whose M and Vm must be zero. The
//! result goes to FPSCR.NZCV; E makes a quiet NaN signal IOC as well.
//!
//! VMRS: 1110 1110 1111 0001, Rt 1010 0001 0000. Rt = 15 is the
//! APSR_nzcv form, which copies FPSCR.NZCV into the APSR flags. VMSR:
//! 1110 1110 1110 0001, same hw2. The register field (hw1[3:0]) decodes
//! FPSCR (0001) and the Armv8.1-M VPR (1100) and P0 (1101), where P0 moves
//! only VPR[15:0] and a VPR write clears its reserved top byte. FPCXT and
//! FPSCR_nzcvqc forms are decoded; FPCXT access is Secure-only. SP as Rt,
//! and PC for VMSR, stay unclaimed.
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const fpu = @import("../../fpu/all.zig");
const Format = fpu.format.Format;
const Fpscr = fpu.fpscr.Fpscr;
const fp_regs = @import("regs.zig");

pub const group: op.Group = .{ .name = "fp_system", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const vmrs: u16 = 0xEEF1;
    pub const vmsr: u16 = 0xEEE1;
    pub const vmrs_vpr: u16 = 0xEEFC;
    pub const vmsr_vpr: u16 = 0xEEEC;
    pub const vmrs_p0: u16 = 0xEEFD;
    pub const vmsr_p0: u16 = 0xEEED;
    pub const vmrs_nzcvqc: u16 = 0xEEF2;
    pub const vmsr_nzcvqc: u16 = 0xEEE2;
    pub const vmrs_fpcxt_ns: u16 = 0xEEFE;
    pub const vmsr_fpcxt_ns: u16 = 0xEEEE;
    pub const vmrs_fpcxt_s: u16 = 0xEEFF;
    pub const vmsr_fpcxt_s: u16 = 0xEEEF;
    /// hw2 of VMRS and VMSR with Rt ([15:12]) masked out.
    pub const transfer_hw2: u16 = 0x0A10;
};

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4) return null;
    if (instr.hw2 & 0x0FFF == encodings.transfer_hw2) return decodeTransfer(instr);
    if (instr.hw1 & 0xFFBE != 0xEEB4) return null;
    const half = instr.hw2 & 0x0F50 == 0x0940;
    if (!half and instr.hw2 & 0x0E50 != 0x0A40) return null;
    const zero = instr.hw1 & 1 == 1;
    if (zero and instr.hw2 & 0x002F != 0) return null;
    const double = !half and instr.hw2 >> 8 & 1 == 1;
    if (!fp_regs.exists(dReg(instr, double), double)) return null;
    if (!zero and !fp_regs.exists(mReg(instr, double), double)) return null;
    if (half) return if (zero) compareFor(fpu.format.half, true) else compareFor(fpu.format.half, false);
    if (double) return if (zero) compareFor(fpu.format.double, true) else compareFor(fpu.format.double, false);
    return if (zero) compareFor(fpu.format.single, true) else compareFor(fpu.format.single, false);
}

fn decodeTransfer(instr: Instr) ?op.Exec {
    const rt = instr.hw2 >> 12;
    return switch (instr.hw1) {
        encodings.vmrs => if (rt == 13) null else &vmrs,
        encodings.vmsr => if (rt == 13 or rt == 15) null else &vmsr,
        encodings.vmrs_vpr => if (rt >= 13) null else &vmrsVpr,
        encodings.vmsr_vpr => if (rt >= 13) null else &vmsrVpr,
        encodings.vmrs_p0 => if (rt >= 13) null else &vmrsP0,
        encodings.vmsr_p0 => if (rt >= 13) null else &vmsrP0,
        encodings.vmrs_nzcvqc => if (rt >= 13) null else &vmrsNzcvqc,
        encodings.vmsr_nzcvqc => if (rt >= 13) null else &vmsrNzcvqc,
        encodings.vmrs_fpcxt_ns => if (rt >= 13) null else &vmrsFpcxtNs,
        encodings.vmsr_fpcxt_ns => if (rt >= 13) null else &vmsrFpcxtNs,
        encodings.vmrs_fpcxt_s => if (rt >= 13) null else &vmrsFpcxtS,
        encodings.vmsr_fpcxt_s => if (rt >= 13) null else &vmsrFpcxtS,
        else => null,
    };
}

pub fn dReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 >> 12), @intCast(instr.hw1 >> 6 & 1), double);
}

pub fn mReg(instr: Instr, double: bool) u5 {
    return fp_regs.index(@intCast(instr.hw2 & 0xF), @intCast(instr.hw2 >> 5 & 1), double);
}

/// Writes a compare result into FPSCR.NZCV.
pub fn setNzcv(fpscr: *Fpscr, nzcv: u4) void {
    fpscr.n = @intCast(nzcv >> 3);
    fpscr.z = @intCast(nzcv >> 2 & 1);
    fpscr.c = @intCast(nzcv >> 1 & 1);
    fpscr.v = @intCast(nzcv & 1);
}

fn compareFor(comptime fmt: Format, comptime zero: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const double = comptime fmt.width() == 64;
            const bank = &cpu.fp.bank;
            const a = fp_regs.read(fmt, bank, dReg(instr, double));
            const b: fmt.Bits() = if (zero) 0 else fp_regs.read(fmt, bank, mReg(instr, double));
            const signal = instr.hw2 >> 7 & 1 == 1;
            setNzcv(&cpu.fp.fpscr, fpu.compare.compare(fmt, a, b, signal, &cpu.fp.fpscr));
        }
    }.exec;
}

fn vmrs(cpu: *Cpu, instr: Instr) op.Error!void {
    const rt: u4 = @intCast(instr.hw2 >> 12);
    if (rt == 15) {
        cpu.regs.xpsr = (cpu.regs.xpsr & 0x0FFF_FFFF) | cpu.fp.fpscr.apsrNzcv();
        return;
    }
    cpu.regs.set(rt, cpu.fp.fpscr.bits());
}

fn vmsr(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.fp.fpscr = Fpscr.fromBits(cpu.regs.get(@intCast(instr.hw2 >> 12)));
}

fn vmrsVpr(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.set(@intCast(instr.hw2 >> 12), @bitCast(cpu.fp.vpr));
}

fn vmsrVpr(cpu: *Cpu, instr: Instr) op.Error!void {
    var vpr: @TypeOf(cpu.fp.vpr) = @bitCast(cpu.regs.get(@intCast(instr.hw2 >> 12)));
    vpr.reserved = 0;
    cpu.fp.vpr = vpr;
}

fn vmrsP0(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.set(@intCast(instr.hw2 >> 12), cpu.fp.vpr.p0);
}

fn vmsrP0(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.fp.vpr.p0 = @truncate(cpu.regs.get(@intCast(instr.hw2 >> 12)));
}

fn vmrsNzcvqc(cpu: *Cpu, instr: Instr) op.Error!void {
    cpu.regs.set(@intCast(instr.hw2 >> 12), cpu.fp.fpscr.bits() & 0xF800_0000);
}

fn vmsrNzcvqc(cpu: *Cpu, instr: Instr) op.Error!void {
    const flags = cpu.regs.get(@intCast(instr.hw2 >> 12)) & 0xF800_0000;
    cpu.fp.fpscr = Fpscr.fromBits((cpu.fp.fpscr.bits() & 0x07FF_FFFF) | flags);
}

fn requireSecure(cpu: *const Cpu) op.Error!void {
    if (cpu.banked.current != .secure) return error.Undefined;
}

fn fpInactive(cpu: *const Cpu) bool {
    const control_bits = @import("../../regs.zig").control_bits;
    return cpu.fp.context.fpccr.aspen == 1 and cpu.regs.control & control_bits.fpca == 0;
}

fn contextPayload(sfpa: u1, fpscr: u32) u32 {
    return (@as(u32, sfpa) << 31) | (fpscr & 0x0FFF_FFFF);
}

fn vmrsFpcxtNs(cpu: *Cpu, instr: Instr) op.Error!void {
    try requireSecure(cpu);
    const inactive = fpInactive(cpu);
    const control_bits = @import("../../regs.zig").control_bits;
    const secure_context = cpu.regs.control & control_bits.sfpa != 0;
    const saved = if (inactive)
        contextPayload(0, cpu.fp.context.defaultFpscr().bits())
    else
        contextPayload(@intFromBool(secure_context), cpu.fp.fpscr.bits());
    cpu.regs.set(@intCast(instr.hw2 >> 12), saved);
    if (!inactive and !secure_context) cpu.fp.fpscr = cpu.fp.context.defaultFpscr();
}

fn vmsrFpcxtNs(cpu: *Cpu, instr: Instr) op.Error!void {
    try requireSecure(cpu);
    // With no FP context active the write is a NOP (DDI0553 VMSR FPCXT_NS).
    if (fpInactive(cpu)) return;
    writeContext(cpu, cpu.regs.get(@intCast(instr.hw2 >> 12)));
}

fn vmrsFpcxtS(cpu: *Cpu, instr: Instr) op.Error!void {
    try requireSecure(cpu);
    const control_bits = @import("../../regs.zig").control_bits;
    cpu.regs.set(@intCast(instr.hw2 >> 12), contextPayload(@truncate(cpu.regs.control >> 3), cpu.fp.fpscr.bits()));
    cpu.fp.fpscr = cpu.fp.context.defaultFpscr();
    cpu.regs.control &= ~control_bits.sfpa;
}

fn vmsrFpcxtS(cpu: *Cpu, instr: Instr) op.Error!void {
    try requireSecure(cpu);
    writeContext(cpu, cpu.regs.get(@intCast(instr.hw2 >> 12)));
}

fn writeContext(cpu: *Cpu, payload: u32) void {
    const control_bits = @import("../../regs.zig").control_bits;
    const sfpa = @as(u32, @truncate(payload >> 31)) << 3;
    cpu.regs.control = (cpu.regs.control & ~control_bits.sfpa) | sfpa;
    cpu.fp.fpscr = Fpscr.fromBits(payload & 0x0FFF_FFFF);
}
