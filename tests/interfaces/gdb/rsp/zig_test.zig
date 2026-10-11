//! Tests for src/interfaces/gdb/rsp/zig.zig and the Dispatch path that reaches it.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Machine = ra8.session.stop_machine.Machine;
const dispatch = ra8.gdb.rsp.dispatch;
const zig_run = dispatch.zig_run;
const zig_session = ra8.session.step_hook.zig.session;
const session_api = ra8.session.api;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 bf00 nop ; 0x0A f3af 8000 nop.w ; 0x0E bf00 nop ; 0x10 ba80 (unallocated)
fn ram() Ram {
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF,
        0x80, 0xBA,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

fn expectReply(target: *zig_run.Target, request: []const u8, want: []const u8) !void {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings(want, try zig_run.answer(target, request, &out));
}

test "one thread: thread queries and selecting any other thread" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session };
    try expectReply(&target, "qfThreadInfo", "m1");
    try expectReply(&target, "qsThreadInfo", "l");
    try expectReply(&target, "qC", "QC1");
    try expectReply(&target, "Hg1", "OK");
    try expectReply(&target, "Hg0", "OK");
    try expectReply(&target, "Hg2", "E00");
    try expectReply(&target, "T2", "E00");
    try expectReply(&target, "vCont?", "vCont;c;C;s;S");
    try expectReply(&target, "?", "T05thread:1;");
}

test "with CPU1 attached it is thread 2, and selecting it moves g, s and ?" {
    var memory0 = ram();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    try cpu0.reset(0);
    var memory1 = ram();
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100, .other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1 } };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session };
    try expectReply(&target, "qfThreadInfo", "m1,2");
    try expectReply(&target, "T2", "OK");
    try expectReply(&target, "T3", "E00");
    try expectReply(&target, "Hg2", "OK");
    try expectReply(&target, "qC", "QC2");
    try std.testing.expectEqual(@as(u8, 1), api_session.live.index);
    try expectReply(&target, "s", "T05thread:2;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu1.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x08), cpu0.regs.pc);
    try expectReply(&target, "vCont;s:1", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu0.regs.pc);
    try expectReply(&target, "Hg0", "OK");
    try expectReply(&target, "qC", "QC1");
}

test "s steps one instruction, c stops on a break and then on the core's fault" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    _ = try machine.addBreak(.{ .address = 0x0E });
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session };
    try expectReply(&target, "s", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0A), cpu.regs.pc);
    try expectReply(&target, "vCont;c:1", "T05thread:1;");
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
    try expectReply(&target, "c", "T0bthread:1;");
    try expectReply(&target, "?", "T0bthread:1;");
}

test "an interrupt from the poll stops a continue with SIGINT" {
    var memory = ram();
    // 0x08 e7fe b . : a loop that never stops on its own
    memory.bytes[8] = 0xFE;
    memory.bytes[9] = 0xE7;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 50 };
    const Interrupt = struct {
        asked: u32 = 0,
        fn check(context: *anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.asked += 1;
            return self.asked == 3;
        }
    };
    var interrupt: Interrupt = .{};
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session, .poll = .{ .context = &interrupt, .check = Interrupt.check } };
    try expectReply(&target, "c", "T02thread:1;");
    try std.testing.expectEqual(@as(u32, 3), interrupt.asked);
    try std.testing.expectEqual(@as(u32, 0x08), cpu.regs.pc);
}

test "Dispatch with a Zig session reads the Zig core's registers and memory" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var api_session: session_api.Session = .{ .live = session };
    var target: zig_run.Target = .{ .session = &api_session };
    const stub = dispatch.Dispatch{ .zig = &target };
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings("08000000", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("40000000", try stub.answer("pd", &out));
    try std.testing.expectEqualStrings("00bfaff3", try stub.answer("m8,4", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("s", &out));
    try std.testing.expectEqualStrings("0a000000", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("Z0,e,2", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("c", &out));
    try std.testing.expectEqualStrings("0e000000", try stub.answer("pf", &out));
}
