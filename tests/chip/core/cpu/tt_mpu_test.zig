//! Covers src/chip/core/cpu/tt_mpu.zig and its use in src/chip/core/cpu/ops/tt.zig:
//! TT, TTT, TTA and TTAT on the Zig core report the MPU half from the
//! core's MPU, over a configured SAU and MPU map (RA8EMU-276).
const std = @import("std");
const ra8 = @import("ra8");
const ops_tt = ra8.chip.core.cpu.ops.tt;
const sau = ra8.chip.periph.sau;
const mpu = ra8.chip.periph.mpu;
const mpu_check = ra8.chip.core.cpu.board_bus.mpu_check;
const field = ra8.chip.core.csel.tt.field;
const fixture = @import("exception/ram.zig");
const cpu_mod = ra8.chip.core.cpu.cpu;
const tt_mpu = cpu_mod.tt_mpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const SauSource = cpu_mod.sau_source.SauSource;

const both = field.r | field.rw;
const ns_both = field.nsr | field.nsrw;
const mrvalid = tt_mpu.mrvalid;

/// Region 0 read-write for everyone, 1 read-only for everyone, 2 privileged
/// only. All three sit in Non-secure SRAM (SAU region 0).
const open_at: u32 = 0x3210_0040;
const read_only_at: u32 = 0x3210_0410;
const privileged_at: u32 = 0x3210_0810;
/// Non-secure SRAM no MPU region covers.
const uncovered_at: u32 = 0x3210_2000;

fn sauMap() sau.Sau {
    var unit = sau.Sau{ .ctrl = 1 };
    unit.table[0] = sau.Region.fromPair(0x3210_0000, 0x3217_FFE0 | 1);
    unit.table[1] = sau.Region.fromPair(0x0200_8000, 0x0200_8FE0 | 2 | 1);
    return unit;
}

fn region(base: u32, rbar_bits: u32) mpu.Region {
    return mpu.Region.fromPair(base | rbar_bits, ((base + 0x3FF) & mpu.field.address) | mpu.field.rlar_enable);
}

fn mpuMap(ctrl: u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    unit.table[0] = region(0x3210_0000, mpu.field.rbar_ap_unprivileged);
    unit.table[1] = region(0x3210_0400, mpu.field.rbar_ap_unprivileged | mpu.field.rbar_ap_ro);
    unit.table[2] = region(0x3210_0800, 0);
    unit.ctrl = ctrl;
    return unit;
}

/// TT r3, r0 with the A and T bits as given: TT, TTT, TTA, TTAT.
fn form(alternate: bool, unprivileged: bool) Instr {
    var second: u16 = 0xF300;
    if (alternate) second |= 0x80;
    if (unprivileged) second |= 0x40;
    return .{ .address = fixture.base, .hw1 = 0xE840, .hw2 = second, .size = 4 };
}

const Rig = struct {
    ram: fixture.Ram = .{},
    sau_unit: sau.Sau = undefined,
    source: SauSource = undefined,
    unit: mpu.Mpu = undefined,
    check: mpu_check.Check = undefined,
    cpu: cpu_mod.Cpu = undefined,

    fn init(self: *Rig, ctrl: u32) !void {
        self.* = .{};
        self.sau_unit = sauMap();
        self.source = .{ .unit = &self.sau_unit };
        self.unit = mpuMap(ctrl);
        self.check = .{ .unit = &self.unit };
        self.cpu = try fixture.boot(&self.ram);
        self.cpu.attribution = self.source.source();
        self.cpu.mpu = &self.check;
    }

    fn run(self: *Rig, instr: Instr, target: u32) !u32 {
        self.cpu.regs.set(0, target);
        try ops_tt.group.decode(instr).?(&self.cpu, instr);
        return self.cpu.regs.get(3);
    }
};

const on = mpu.field.ctrl_enable;
const privdef = mpu.field.ctrl_enable | mpu.field.ctrl_privdefena;
const ns_secure_half = field.srvalid | ns_both;

test "each form reports the deciding region and its permissions" {
    var rig: Rig = undefined;
    try rig.init(on);
    const Case = struct { a: bool, t: bool, at: u32, want: u32 };
    const cases = [_]Case{
        .{ .a = false, .t = false, .at = open_at, .want = ns_secure_half | mrvalid | both },
        .{ .a = true, .t = false, .at = open_at, .want = ns_secure_half | mrvalid | both },
        .{ .a = false, .t = true, .at = open_at, .want = ns_secure_half | mrvalid | both },
        .{ .a = true, .t = true, .at = open_at, .want = ns_secure_half | mrvalid | both },
        .{ .a = false, .t = false, .at = read_only_at, .want = field.srvalid | field.nsr | mrvalid | 1 | field.r },
        .{ .a = true, .t = true, .at = read_only_at, .want = field.srvalid | field.nsr | mrvalid | 1 | field.r },
        .{ .a = false, .t = false, .at = privileged_at, .want = ns_secure_half | mrvalid | 2 | both },
        .{ .a = true, .t = false, .at = privileged_at, .want = ns_secure_half | mrvalid | 2 | both },
        .{ .a = false, .t = true, .at = privileged_at, .want = field.srvalid | mrvalid | 2 },
        .{ .a = true, .t = true, .at = privileged_at, .want = field.srvalid | mrvalid | 2 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.want, try rig.run(form(case.a, case.t), case.at));
    }
}

test "an address no region covers falls to the background" {
    var rig: Rig = undefined;
    try rig.init(on);
    try std.testing.expectEqual(field.srvalid, try rig.run(form(false, false), uncovered_at));
    try rig.init(privdef);
    try std.testing.expectEqual(field.srvalid | both | ns_both, try rig.run(form(false, false), uncovered_at));
    try std.testing.expectEqual(field.srvalid, try rig.run(form(false, true), uncovered_at));
}

test "a disabled MPU answers with the default map and no region" {
    var rig: Rig = undefined;
    try rig.init(0);
    try std.testing.expectEqual(ns_secure_half | both, try rig.run(form(false, false), privileged_at));
    try std.testing.expectEqual(ns_secure_half | both, try rig.run(form(false, true), privileged_at));
}

test "Secure memory keeps S and reports the MPU half without NSR or NSRW" {
    var rig: Rig = undefined;
    try rig.init(privdef);
    const word = try rig.run(form(false, false), 0x2200_0000);
    try std.testing.expectEqual(field.s | both, word);
}

test "an unprivileged core gets permissions but never the region number" {
    const unit = mpuMap(on);
    const view: tt_mpu.View = .{ .privileged = false, .reports_region = false };
    try std.testing.expectEqual(both, tt_mpu.half(&unit, open_at, view));
    try std.testing.expectEqual(@as(u32, 0), tt_mpu.half(&unit, privileged_at, view));
}

test "the PPB and an absent MPU answer with the default map" {
    const unit = mpuMap(on);
    const view: tt_mpu.View = .{ .privileged = false, .reports_region = true };
    try std.testing.expectEqual(both, tt_mpu.half(&unit, 0xE000_ED00, view));
    try std.testing.expectEqual(both, tt_mpu.half(null, open_at, view));
}

test "merge keeps the security half and recomputes NSR and NSRW" {
    const security = field.srvalid | both | ns_both;
    try std.testing.expectEqual(field.srvalid | mrvalid | field.r | field.nsr, tt_mpu.merge(security, mrvalid | field.r));
    try std.testing.expectEqual(field.s, tt_mpu.merge(field.s | both, 0));
}
