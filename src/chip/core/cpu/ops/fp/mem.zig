//! The FP loads and stores (T1/T2): VLDR/VSTR, VLDM/VSTM and their
//! VPUSH/VPOP aliases. fpu/transfer.zig plans the run of S words; this
//! file reads or writes them through the bus, lowest address first, and
//! writes Rn back only once every access has succeeded.
//!
//!   hw1 1110 110 P U D W L Rn    hw2 Vd 101 sz imm8
//!
//! P set with W clear is VLDR/VSTR; the other P U W choices are VLDM/VSTM
//! except 000, the 64-bit transfers (fp_move). d is Vd:D for singles and
//! D:Vd for doubles. Whatever transfer.zig calls UNDEFINED or
//! UNPREDICTABLE stays unclaimed, which also leaves VSCCLRM (Rn = PC)
//! and VLLDM/VLSTM (P U W = 001) to their own groups. VLDR/VSTR.16 (hw2
//! bits 11:8 = 1001, P set, W clear) moves the halfword at imm8 << 1 from
//! the base: a load writes Zeros(16):value to S[Vd:D], a store writes
//! S[Vd:D]<15:0>; VSTR.16 with a PC base stays unclaimed, and there is no
//! 16-bit VLDM/VSTM. Alignment checks wait on the core lane's MemA support
//! (RA8EMU-85).
const op = @import("../../op.zig");
const Cpu = @import("../../cpu.zig").Cpu;
const Instr = @import("../../instr.zig").Instr;
const transfer = @import("../../fpu/transfer/transfer.zig");
const alignment = @import("../../alignment.zig");
const Fpscr = @import("../../fpu/fpscr.zig").Fpscr;

pub const group: op.Group = .{ .name = "fp_mem", .decode = decode, .oracle = false };

pub const Bits = struct { p: u1, u: u1, w: u1, load: bool, rn: u4, d: u5, imm8: u8, double: bool };

pub fn bits(instr: Instr) Bits {
    const double = instr.hw2 >> 8 & 1 == 1;
    const vd: u5 = @intCast(instr.hw2 >> 12);
    const dbit: u5 = @intCast(instr.hw1 >> 6 & 1);
    return .{
        .p = @intCast(instr.hw1 >> 8 & 1),
        .u = @intCast(instr.hw1 >> 7 & 1),
        .w = @intCast(instr.hw1 >> 5 & 1),
        .load = instr.hw1 >> 4 & 1 == 1,
        .rn = @intCast(instr.hw1 & 0xF),
        .d = if (double) dbit << 4 | vd else vd << 1 | dbit,
        .imm8 = @truncate(instr.hw2),
        .double = double,
    };
}

/// The system-register forms use regh:regl in hw1[6]:hw2[15:12].
pub const SystemBits = struct { p: u1, add: u1, regh: u1, w: u1, load: bool, rn: u4, regl: u4, imm: u7 };

pub fn systemBits(instr: Instr) SystemBits {
    return .{
        .p = @intCast(instr.hw1 >> 8 & 1),
        .add = @intCast(instr.hw1 >> 7 & 1),
        .regh = @intCast(instr.hw1 >> 6 & 1),
        .w = @intCast(instr.hw1 >> 5 & 1),
        .load = instr.hw1 >> 4 & 1 == 1,
        .rn = @intCast(instr.hw1 & 0xF),
        .regl = @intCast(instr.hw2 >> 12),
        .imm = @truncate(instr.hw2),
    };
}

/// FPCXT_NS VLDR avoids ExecuteFPCheck when the FP context is inactive.
pub fn isInactiveFpcxtNs(instr: Instr) bool {
    if (!isSystemRegister(instr)) return false;
    const b = systemBits(instr);
    return systemRegister(b) == 14;
}

fn systemRegister(b: SystemBits) u4 {
    return @as(u4, b.regh) << 3 | b.regl;
}

fn isSystemRegister(instr: Instr) bool {
    if (instr.size != 4 or instr.hw1 & 0xFE00 != 0xEC00) return false;
    if (instr.hw2 & 0x0F80 != 0x0F80) return false;
    const b = systemBits(instr);
    if (b.p == 0 and b.w == 0 or b.rn == 15) return false;
    return switch (systemRegister(b)) {
        1, 2, 12, 13, 14, 15 => true,
        else => false,
    };
}

fn isSingle(b: Bits) bool {
    return b.p == 1 and b.w == 0;
}

/// True for decoded floating-point load/store multiples, not VLDR/VSTR
/// or memory system-register forms.
pub fn isMultiple(instr: Instr) bool {
    if (isSystemRegister(instr)) return false;
    return !isSingle(bits(instr));
}

/// The plan for `base`, Rn's value (or, for a PC base, the PC it reads).
pub fn plan(b: Bits, base: u32) transfer.Plan {
    if (isSingle(b)) return transfer.single(.{ .u = b.u, .rn = b.rn, .base = base, .d = b.d, .imm8 = b.imm8, .double = b.double, .store = !b.load });
    return transfer.multiple(.{ .p = b.p, .u = b.u, .w = b.w, .rn = b.rn, .base = base, .d = b.d, .imm8 = b.imm8, .double = b.double });
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw1 & 0xFE00 != 0xEC00) return null;
    if (isSystemRegister(instr)) return &runSystem;
    if (instr.hw2 & 0x0F80 == 0x0F80) return null;
    if (instr.hw2 & 0x0F00 == 0x0900) return decodeHalf(instr);
    if (instr.hw2 & 0x0E00 != 0x0A00) return null;
    const b = bits(instr);
    if (b.p == 0 and b.u == 0 and b.w == 0) return null;
    if (plan(b, 0).fault != .none) return null;
    return &run;
}

fn runSystem(cpu: *Cpu, instr: Instr) op.Error!void {
    if (!cpu.profile.v8_1m) return error.Undefined;
    const b = systemBits(instr);
    const reg = systemRegister(b);
    if ((reg == 12 or reg == 13) and !cpu.profile.mve) return error.Undefined;
    if ((reg == 14 or reg == 15) and cpu.banked.current != .secure) return error.Undefined;

    const base = cpu.regs.get(b.rn);
    const delta: u32 = @as(u32, b.imm) << 2;
    const offset_addr = if (b.add == 1) base +% delta else base -% delta;
    const address = if (b.p == 1) offset_addr else base;
    if (b.w == 1 and b.rn == 13 and offset_addr < cpu.regs.spLimit()) return error.StackOverflow;
    const inactive = cpu.fp.context.fpccr.aspen == 1 and cpu.regs.control & @import("../../regs.zig").control_bits.fpca == 0;
    if (reg == 14 and inactive) {
        // DDI0553's FPCXT_NS load case does not read memory for an inactive context.
        updateBase(cpu, b);
        return;
    }

    try alignment.memA(address, 4);

    if (b.load) {
        const value = try readWord(cpu, address);
        loadSystem(cpu, reg, value, inactive);
    } else {
        const value = storeSystem(cpu, reg, inactive);
        try writeWord(cpu, address, value);
        if (reg == 15 or (reg == 14 and !inactive and cpu.regs.control & @import("../../regs.zig").control_bits.sfpa == 0)) {
            cpu.fp.fpscr = cpu.fp.context.defaultFpscr();
            if (reg == 15) cpu.regs.control &= ~@import("../../regs.zig").control_bits.sfpa;
        }
    }
    updateBase(cpu, b);
}

fn updateBase(cpu: *Cpu, b: SystemBits) void {
    if (b.w == 1) {
        const base = cpu.regs.get(b.rn);
        const delta: u32 = @as(u32, b.imm) << 2;
        cpu.regs.set(b.rn, if (b.add == 1) base +% delta else base -% delta);
    }
}

fn loadSystem(cpu: *Cpu, reg: u4, value: u32, inactive: bool) void {
    switch (reg) {
        1 => cpu.fp.fpscr = Fpscr.fromBits(value),
        2 => cpu.fp.fpscr = Fpscr.fromBits((cpu.fp.fpscr.bits() & 0x07FF_FFFF) | (value & 0xF800_0000)),
        12 => {
            var vpr: @TypeOf(cpu.fp.vpr) = @bitCast(value);
            vpr.reserved = 0;
            cpu.fp.vpr = vpr;
        },
        13 => cpu.fp.vpr.p0 = @truncate(value),
        14 => if (!inactive) loadFpcxt(cpu, value),
        15 => loadFpcxt(cpu, value),
        else => unreachable,
    }
}

fn loadFpcxt(cpu: *Cpu, payload: u32) void {
    const control_bits = @import("../../regs.zig").control_bits;
    cpu.regs.control = (cpu.regs.control & ~control_bits.sfpa) | (@as(u32, @truncate(payload >> 31)) << 3);
    cpu.fp.fpscr = Fpscr.fromBits(payload & 0x0FFF_FFFF);
}

fn storeSystem(cpu: *Cpu, reg: u4, inactive: bool) u32 {
    return switch (reg) {
        1 => cpu.fp.fpscr.bits(),
        2 => cpu.fp.fpscr.bits() & 0xF800_0000,
        12 => @bitCast(cpu.fp.vpr),
        13 => cpu.fp.vpr.p0,
        14 => if (inactive)
            cpu.fp.context.defaultFpscr().bits() & 0x0FFF_FFFF
        else
            (@as(u32, @truncate(cpu.regs.control >> 3)) << 31) | (cpu.fp.fpscr.bits() & 0x0FFF_FFFF),
        15 => (@as(u32, @truncate(cpu.regs.control >> 3)) << 31) | (cpu.fp.fpscr.bits() & 0x0FFF_FFFF),
        else => unreachable,
    };
}

fn run(cpu: *Cpu, instr: Instr) op.Error!void {
    const b = bits(instr);
    const base = if (b.rn == 15) instr.address +% 4 else cpu.regs.get(b.rn);
    const p = plan(b, base);
    // Every word is MemA (RA8EMU-85); the transfer is contiguous from start.
    try alignment.memA(p.start, 4);
    var words: [32]u32 = undefined;
    if (b.load) {
        for (words[0..p.words], 0..) |*word, k| word.* = try readWord(cpu, p.start +% @as(u32, @intCast(k)) * 4);
        transfer.load(p, &cpu.fp.bank, &words);
    } else {
        transfer.store(p, &cpu.fp.bank, &words);
        for (words[0..p.words], 0..) |word, k| try writeWord(cpu, p.start +% @as(u32, @intCast(k)) * 4, word);
    }
    if (p.wback) |value| cpu.regs.set(b.rn, value);
}

fn decodeHalf(instr: Instr) ?op.Exec {
    const p = instr.hw1 >> 8 & 1;
    const w = instr.hw1 >> 5 & 1;
    if (p != 1 or w != 0) return null;
    const load = instr.hw1 >> 4 & 1 == 1;
    if (!load and instr.hw1 & 0xF == 15) return null;
    return &runHalf;
}

/// The address VLDR/VSTR.16 reaches: a PC base is Align(PC, 4).
pub fn halfAddress(instr: Instr, base: u32) u32 {
    const aligned = if (instr.hw1 & 0xF == 15) base & ~@as(u32, 3) else base;
    const imm32: u32 = @as(u32, instr.hw2 & 0xFF) << 1;
    return if (instr.hw1 >> 7 & 1 == 1) aligned +% imm32 else aligned -% imm32;
}

fn runHalf(cpu: *Cpu, instr: Instr) op.Error!void {
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const base = if (rn == 15) instr.address +% 4 else cpu.regs.get(rn);
    const address = halfAddress(instr, base);
    try alignment.memA(address, 2);
    const d: u5 = @intCast((instr.hw2 >> 12) << 1 | (instr.hw1 >> 6 & 1));
    var bytes: [2]u8 = undefined;
    if (instr.hw1 >> 4 & 1 == 1) {
        try cpu.bus.read(address, &bytes);
        cpu.fp.bank.writeS(d, @import("std").mem.readInt(u16, &bytes, .little));
    } else {
        @import("std").mem.writeInt(u16, &bytes, @truncate(cpu.fp.bank.readS(d)), .little);
        try cpu.bus.write(address, &bytes);
    }
}

fn readWord(cpu: *Cpu, address: u32) op.Error!u32 {
    var bytes: [4]u8 = undefined;
    try cpu.bus.read(address, &bytes);
    return @import("std").mem.readInt(u32, &bytes, .little);
}

fn writeWord(cpu: *Cpu, address: u32, value: u32) op.Error!void {
    var bytes: [4]u8 = undefined;
    @import("std").mem.writeInt(u32, &bytes, value, .little);
    try cpu.bus.write(address, &bytes);
}
