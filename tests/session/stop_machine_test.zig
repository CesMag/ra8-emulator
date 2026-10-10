//! The run, step, step over, step out, continue and halt decisions.
const std = @import("std");
const ra8 = @import("ra8");
const stop_machine = ra8.session.stop_machine;
const Machine = stop_machine.Machine;
const Event = stop_machine.Event;

fn at(pc: u32) Event {
    return .{ .pc = pc, .size = 2, .sp = 0x2000_1000 };
}

fn isStepped(stop: ?stop_machine.Stop) bool {
    const got = stop orelse return false;
    return got == .stepped;
}

test "a halted session never stops the CPU" {
    var machine = Machine{};
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
}

test "a step runs the instruction it stopped on and stops on the next" {
    var machine = Machine{};
    machine.step();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
    try std.testing.expectEqual(stop_machine.Mode.halted, machine.mode);
}

test "running stops at a break and not before" {
    var machine = Machine{};
    const id = try machine.breaks.add(.{ .address = 0x108 });
    machine.proceed();
    for ([_]u32{ 0x100, 0x102, 0x104, 0x106 }) |pc| {
        try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(pc)));
    }
    const stop = machine.onInstruction(at(0x108)).?;
    try std.testing.expectEqual(id, stop.breakpoint);
}

test "continuing from a break runs past it instead of stopping again" {
    var machine = Machine{};
    _ = try machine.breaks.add(.{ .address = 0x108, .arrival = 2 });
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    try std.testing.expect(machine.onInstruction(at(0x108)) != null);
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x10A)));
}

test "a step over a call runs the call and stops after it" {
    var machine = Machine{};
    machine.stepOver();
    const call = Event{ .pc = 0x100, .size = 4, .sp = 0x2000_1000, .call = true };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(call));
    // Inside the callee, on a deeper frame.
    const inside = Event{ .pc = 0x400, .size = 2, .sp = 0x2000_0FF8 };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(inside));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x104))));
}

test "a step over of a plain instruction is a single step" {
    var machine = Machine{};
    machine.stepOver();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
}

test "a break inside a stepped-over call still stops" {
    var machine = Machine{};
    const id = try machine.breaks.add(.{ .address = 0x400 });
    machine.stepOver();
    const call = Event{ .pc = 0x100, .size = 4, .sp = 0x2000_1000, .call = true };
    _ = machine.onInstruction(call);
    const stop = machine.onInstruction(.{ .pc = 0x400, .size = 2, .sp = 0x2000_0FF8 }).?;
    try std.testing.expectEqual(id, stop.breakpoint);
}

test "a step out stops on the return address at the caller's frame" {
    var machine = Machine{};
    machine.stepOut(0x205, 0x2000_0FF8);
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x400)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x402)));
    const back = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_1000 };
    try std.testing.expect(isStepped(machine.onInstruction(back)));
}

test "a step out ignores the same return address on a deeper recursive frame" {
    var machine = Machine{};
    machine.stepOut(0x204, 0x2000_0FF0);
    _ = machine.onInstruction(at(0x400));
    const deeper = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_0FE0 };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(deeper));
    const caller = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_0FF0 };
    try std.testing.expect(isStepped(machine.onInstruction(caller)));
}

test "a halt request stops a running session before its next instruction" {
    var machine = Machine{};
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
    machine.requestHalt();
    const stop = machine.onInstruction(at(0x104)).?;
    try std.testing.expect(stop == .halt_requested);
    try std.testing.expectEqual(stop_machine.Mode.halted, machine.mode);
}

test "a halt request on a halted session is dropped" {
    var machine = Machine{};
    machine.requestHalt();
    machine.step();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
}

test "a watched write stops after the instruction that made it" {
    var machine = Machine{};
    const id = try machine.watches.add(try ra8.session.watch_table.Watch.span(0x2000_0040, 4, .write));
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
    machine.onAccess(0x2000_0040, 4, .write, null);
    const stop = machine.onInstruction(at(0x104)).?;
    try std.testing.expectEqual(id, stop.watchpoint.id);
    try std.testing.expectEqual(ra8.session.watch_table.Access.write, stop.watchpoint.access);
}

test "a watched access on a halted session is ignored" {
    var machine = Machine{};
    _ = try machine.watches.add(try ra8.session.watch_table.Watch.span(0x2000_0040, 4, .access));
    machine.onAccess(0x2000_0040, 4, .read, null);
    machine.step();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
}

test "resuming clears a watch stop that was already reported" {
    var machine = Machine{};
    _ = try machine.watches.add(try ra8.session.watch_table.Watch.span(0x2000_0040, 4, .write));
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    machine.onAccess(0x2000_0040, 4, .write, null);
    try std.testing.expect(machine.onInstruction(at(0x102)) != null);
    machine.step();
    _ = machine.onInstruction(at(0x102));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x104))));
}

test "a comparator the firmware enabled in the core's FPB stops the run there" {
    var machine = Machine{};
    const fpb = ra8.session.fpb;
    _ = machine.fpb.write(fpb.offsets.comp0 + 4, 0x108 | fpb.comp_enable);
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    _ = machine.fpb.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    try std.testing.expectEqual(@as(usize, 1), machine.onInstruction(at(0x108)).?.unit_break);
}

test "a halting DWT data comparator stops the run once the access retired" {
    var machine = Machine{};
    const dwt = ra8.chip.periph.dwt;
    machine.dwt.trcena = true;
    _ = machine.dwt.write(dwt.offsets.comp0, 0x2000_1000);
    _ = machine.dwt.write(dwt.offsets.function0, dwt.match.data_write | (dwt.function_bits.action_debug << dwt.function_bits.action_shift) | (2 << dwt.function_bits.size_shift));
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
    machine.onAccess(0x2000_1000, 4, .write, null);
    try std.testing.expectEqual(@as(usize, 0), machine.onInstruction(at(0x104)).?.unit_watch);
}

test "with halting debug off, an FPB match runs on and is held for DebugMonitor" {
    var machine = Machine{ .halting = false };
    const fpb = ra8.session.fpb;
    _ = machine.fpb.write(fpb.offsets.comp0, 0x108 | fpb.comp_enable);
    _ = machine.fpb.write(fpb.offsets.ctrl, fpb.ctrl_bits.enable | fpb.ctrl_bits.key);
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    try std.testing.expectEqual(@as(?stop_machine.Monitor, .breakpoint), machine.takeMonitor());
    try std.testing.expectEqual(@as(?stop_machine.Monitor, null), machine.takeMonitor());
}

test "with DHCSR.C_STEP set, a resume runs one instruction and halts" {
    var machine = Machine{};
    const dcb = ra8.chip.periph.dcb;
    const keyed = dcb.dhcsr_bits.key << dcb.dhcsr_bits.key_shift;
    machine.dcb.attachDebugger();
    _ = machine.dcb.write(dcb.offsets.dhcsr, keyed | dcb.dhcsr_bits.c_debugen | dcb.dhcsr_bits.c_step);
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
    _ = machine.dcb.write(dcb.offsets.dhcsr, keyed | dcb.dhcsr_bits.c_debugen);
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x104)));
}

test "C_STEP written without a debugger attached is ignored" {
    var machine = Machine{};
    const dcb = ra8.chip.periph.dcb;
    const keyed = dcb.dhcsr_bits.key << dcb.dhcsr_bits.key_shift;
    _ = machine.dcb.write(dcb.offsets.dhcsr, keyed | dcb.dhcsr_bits.c_step);
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
}

test "breaks and watches are numbered from one sequence" {
    var machine = Machine{};
    const watch = try ra8.session.watch_table.Watch.span(0x2200_0054, 4, .write);
    try std.testing.expectEqual(@as(u32, 1), try machine.addBreak(.{ .address = 0x2200_0008 }));
    try std.testing.expectEqual(@as(u32, 2), try machine.addWatch(watch));
    try std.testing.expectEqual(@as(u32, 3), try machine.addBreak(.{ .address = 0x2200_0010 }));
    try machine.breaks.remove(1);
    try std.testing.expectEqual(@as(u32, 4), try machine.addWatch(watch));
}

test "a free run with nothing armed is quiet" {
    var machine = Machine{};
    try std.testing.expect(!machine.quiet());
    machine.begin();
    try std.testing.expect(machine.quiet());
    machine.proceed();
    try std.testing.expect(!machine.quiet());
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(machine.quiet());
    machine.requestHalt();
    try std.testing.expect(!machine.quiet());
}

test "anything armed keeps a run from being quiet" {
    var broken = Machine{};
    _ = try broken.addBreak(.{ .address = 0x200 });
    broken.begin();
    try std.testing.expect(!broken.quiet());
    var fpb_on = Machine{};
    fpb_on.fpb.enabled = true;
    fpb_on.begin();
    try std.testing.expect(!fpb_on.quiet());
    var traced = Machine{};
    traced.dwt.trcena = true;
    traced.dwt.functions[0] = 0b0100; // MATCH: instruction address
    traced.begin();
    try std.testing.expect(!traced.quiet());
    var stepping = Machine{};
    stepping.step();
    try std.testing.expect(!stepping.quiet());
}

test "trace enabled with no comparator set stays quiet, a set comparator does not" {
    var machine = Machine{};
    machine.begin();
    try std.testing.expect(machine.quiet());
    machine.dwt.trcena = true;
    try std.testing.expect(machine.quiet());
    machine.dwt.functions[1] = 0b0100; // MATCH: instruction address
    try std.testing.expect(!machine.quiet());
    machine.dwt.trcena = false;
    try std.testing.expect(machine.quiet());
}
