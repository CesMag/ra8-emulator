//! Tests for src/session/stack/sampler.zig: a real core runs outer -> middle
//! -> leaf, once with a .debug_frame table and no frame pointer, once with
//! r7 frame records and no table, and every sample must name the chain.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const hook = ra8.session.step_hook;
const stack_samples = hook.stack.samples;
const Sampler = hook.stack.sampler.Sampler;

const outer: u32 = 0x40;
const middle: u32 = 0x60;
const leaf: u32 = 0x80;
/// Where middle's call to leaf returns, and outer's call to middle.
const from_leaf: u32 = 0x68;
const from_middle: u32 = 0x48;

/// 1 KiB of RAM at address 0: the vector table, the code, the stack.
const Ram = struct {
    bytes: [0x400]u8 = @splat(0),

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

    fn half(self: *Ram, at: u32, value: u16) void {
        std.mem.writeInt(u16, self.bytes[at..][0..2], value, .little);
    }

    fn call(self: *Ram, at: u32, target: u32) void {
        const offset: i32 = @as(i32, @intCast(target)) - @as(i32, @intCast(at + 4));
        const imm: u32 = @bitCast(offset >> 1);
        const s = (imm >> 23) & 1;
        const j1 = ~(((imm >> 22) & 1) ^ s) & 1;
        const j2 = ~(((imm >> 21) & 1) ^ s) & 1;
        self.half(at, @intCast(0xF000 | s << 10 | ((imm >> 11) & 0x3FF)));
        self.half(at + 2, @intCast(0xD000 | j1 << 13 | j2 << 11 | (imm & 0x7FF)));
    }
};

/// outer loops calling middle, which calls leaf. With records each frame
/// that calls pushes {r7, lr} and sets r7 = sp; without, it pushes {r4, lr}.
fn image(records: bool) Ram {
    var ram: Ram = .{};
    std.mem.writeInt(u32, ram.bytes[0..4], 0x400, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], outer | 1, .little);
    const push: u16 = if (records) 0xB580 else 0xB510;
    const set_fp: u16 = if (records) 0x466F else 0xBF00;
    ram.half(outer, push);
    ram.half(outer + 2, set_fp);
    ram.call(outer + 4, middle);
    ram.half(outer + 8, 0xE7FC); // b outer + 4
    ram.half(middle, push);
    ram.half(middle + 2, set_fp);
    ram.call(middle + 4, leaf);
    ram.half(middle + 8, if (records) 0xBD80 else 0xBD10);
    for (0..4) |i| ram.half(leaf + @as(u32, @intCast(i)) * 2, 0xBF00);
    ram.half(leaf + 8, 0x4770); // bx lr
    return ram;
}

fn entry(list: *std.Io.Writer, head: []const u8, program: []const u8) !void {
    try list.writeInt(u32, @intCast(head.len + program.len), .little);
    try list.writeAll(head);
    try list.writeAll(program);
}

fn fde(list: *std.Io.Writer, start: u32, range: u32, program: []const u8) !void {
    var head: [12]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], 0, .little);
    std.mem.writeInt(u32, head[4..8], start, .little);
    std.mem.writeInt(u32, head[8..12], range, .little);
    try entry(list, &head, program);
}

/// CFI for the record-less image: outer keeps no return address (the
/// outermost frame), middle saves lr at cfa-4, leaf moves nothing.
fn table(into: []u8) ![]const u8 {
    var list: std.Io.Writer = .fixed(into);
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try entry(&list, &cie_head, &.{ 0x0c, 0x0d, 0x00 });
    try fde(&list, outer, 0x20, &.{ 0x07, 0x0e, 0x41, 0x0e, 0x08, 0x84, 0x02 });
    try fde(&list, middle, 0x20, &.{ 0x41, 0x0e, 0x08, 0x8e, 0x01, 0x84, 0x02 });
    try fde(&list, leaf, 0x10, &.{});
    return list.buffered();
}

const Run = struct {
    ram: Ram,
    cpu: Cpu,
    store: *stack_samples.Store,
    trace: hook.rtos.trace.Trace = .{},
    sampler: Sampler,

    fn start(self: *Run, records: bool, frame: []const u8, every: u32) !void {
        self.ram = image(records);
        self.cpu = .{ .bus = self.ram.view() };
        try self.cpu.reset(0);
        self.store = try std.testing.allocator.create(stack_samples.Store);
        self.store.* = .{};
        self.trace = .{};
        self.sampler = .{
            .view = .{ .zig = .{ .cpu = &self.cpu } },
            .core = 0,
            .every = every,
            .frame = frame,
            .store = self.store,
            .trace = &self.trace,
            .clock = &self.cpu.retired,
        };
        self.cpu.retire_listener = self.sampler.listener();
    }

    fn stop(self: *Run) void {
        std.testing.allocator.destroy(self.store);
    }

    fn steps(self: *Run, count: usize) !void {
        for (0..count) |_| if (self.cpu.step()) |why| {
            std.debug.print("core stopped: {any}\n", .{why});
            return error.CoreStopped;
        };
    }
};

/// Every sample in leaf names middle and outer above it, and every sample
/// stopped at middle's call names outer; at least one of each was taken.
fn expectChains(store: *const stack_samples.Store) !void {
    var in_leaf: usize = 0;
    var at_call: usize = 0;
    for (0..store.count) |index| {
        const stack = store.at(index).stack();
        if (stack[0] >= leaf and stack[0] < leaf + 10) {
            try std.testing.expectEqualSlices(u32, &.{ stack[0], from_leaf, from_middle }, stack);
            in_leaf += 1;
        }
        if (stack[0] == middle + 4) {
            try std.testing.expectEqualSlices(u32, &.{ middle + 4, from_middle }, stack);
            at_call += 1;
        }
    }
    try std.testing.expect(in_leaf >= 4);
    try std.testing.expect(at_call >= 2);
}

test "with CFI and no frame pointer, every sample names the call chain" {
    var bytes: [128]u8 = undefined;
    var run: Run = undefined;
    try run.start(false, try table(&bytes), 1);
    defer run.stop();
    try run.steps(60);
    try std.testing.expectEqual(@as(usize, 60), run.store.count);
    try expectChains(run.store);
}

test "without CFI the r7 frame records and lr name the call chain" {
    var run: Run = undefined;
    try run.start(true, &.{}, 1);
    defer run.stop();
    try run.steps(60);
    try expectChains(run.store);
}

test "a sample is taken every Nth retired instruction, stamped with virtual time" {
    var run: Run = undefined;
    try run.start(true, &.{}, 7);
    defer run.stop();
    try run.steps(50);
    try std.testing.expectEqual(@as(usize, 8), run.store.count);
    for (0..run.store.count) |index| {
        try std.testing.expectEqual(@as(u64, 1 + 7 * index), run.store.at(index).at_ns);
    }
}

test "the thread tag follows a switch the RTOS tracer reports" {
    var run: Run = undefined;
    try run.start(true, &.{}, 1);
    defer run.stop();
    try run.steps(10);
    run.trace.store(0, run.cpu.retired, 0x2000_0100);
    try run.steps(10);
    run.trace.store(1, run.cpu.retired, 0x2000_0200);
    run.trace.store(0, run.cpu.retired, 0);
    try run.steps(10);
    for (0..run.store.count) |index| {
        const want: u32 = if (index >= 10 and index < 20) 0x2000_0100 else 0;
        try std.testing.expectEqual(want, run.store.at(index).thread);
        try std.testing.expectEqual(@as(u8, 0), run.store.at(index).core);
    }
}

test "a listener already on the core is still told every instruction" {
    const Count = struct {
        seen: usize = 0,
        fn instruction(context: *anyopaque, _: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.seen += 1;
        }
    };
    var counted: Count = .{};
    var run: Run = undefined;
    try run.start(true, &.{}, 5);
    defer run.stop();
    run.sampler.next = .{ .context = &counted, .instructionFn = Count.instruction };
    try run.steps(20);
    try std.testing.expectEqual(@as(usize, 20), counted.seen);
    try std.testing.expectEqual(@as(usize, 4), run.store.count);
}
