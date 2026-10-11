//! Host tests for the core-addressed session API.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Store = ra8.chip.core.cpu.memory.store.Store;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const api = ra8.session.api;
const breakpoint = ra8.session.breakpoint;
const Machine = ra8.session.stop_machine.Machine;
const zig_session = ra8.session.step_hook.zig.session;
const input_script = ra8.components.input_script;
const gt911 = ra8.components.gt911;
const gpio = ra8.chip.periph.gpio;
const touch_input = ra8.components.touch_input;
const switches = ra8.board.switches;
const timebase = ra8.chip.periph.clocks.timebase;

/// A small RAM image with an initial vector table and three Thumb instructions.
const Ram = struct {
    bytes: [8192]u8 = @splat(0),

    fn init() Ram {
        var memory: Ram = .{};
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF, 0x80, 0xBA };
        @memcpy(memory.bytes[0..code.len], &code);
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

const LoadLog = struct {
    calls: [2]usize = .{ 0, 0 },

    fn load(context: *anyopaque, core: api.Core, image: []const u8) anyerror!void {
        const self: *LoadLog = @ptrCast(@alignCast(context));
        if (image.len == 0) return error.EmptyImage;
        self.calls[@backingInt(core)] += 1;
    }
};

const ClockBoard = struct {
    base: *timebase.TimeBase,

    fn tick(context: *anyopaque, guest: Guest, instructions: u32) anyerror!void {
        _ = guest;
        const self: *ClockBoard = @ptrCast(@alignCast(context));
        self.base.advance(instructions);
    }
};

const InputBoard = struct {
    events: *input_script.Script,
    panel: *gt911.Panel,
    pins: *gpio.Gpio,
    input: *touch_input.Input,
    now_ns: u64 = 0,

    fn tick(context: *anyopaque, guest: Guest, instructions: u32) anyerror!void {
        _ = guest;
        const self: *InputBoard = @ptrCast(@alignCast(context));
        self.now_ns += @as(u64, instructions) * 50_000_000;
        self.events.dispatch(self.now_ns, self.panel, self.pins, self.input);
    }
};

test "session now exposes board virtual nanoseconds across a run" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    var session: api.Session = .{ .live = live };
    var base: timebase.TimeBase = .{};
    var board = ClockBoard{ .base = &base };
    var store = try Store.init(null);
    defer store.deinit();
    session.attachTimeBase(&base);
    session.attachBoard(.cpu0, .{ .context = &board, .tickFn = ClockBoard.tick }, .{ .store = &store });

    try std.testing.expectEqual(@as(u64, 0), try session.now());
    _ = try session.step(.cpu0);
    try std.testing.expectEqual(@as(u64, 1), try session.now());
}

test "core fault event keeps the core, stop address, order and virtual time" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 };
    var session: api.Session = .{ .live = live };
    var base: timebase.TimeBase = .{};
    session.attachTimeBase(&base);
    try session.setRegister(.cpu0, .pc, memory.bytes.len);
    const subscription = try session.subscribe();

    const ended = try session.step(.cpu0);
    try std.testing.expectEqual(.core, std.meta.activeTag(ended));
    try std.testing.expectEqual(@as(u32, memory.bytes.len), ended.core.bus_fault);
    var events: [2]api.Event = undefined;
    const got = session.pollEvents(subscription, &events).?;
    try std.testing.expectEqual(@as(usize, 2), got.count);
    try std.testing.expectEqual(api.Event.Kind.stopped, events[0].kind);
    try std.testing.expectEqual(api.Event.Kind.fault, events[1].kind);
    try std.testing.expectEqual(api.Core.cpu0, events[1].core);
    try std.testing.expectEqual(@as(u64, 0), events[1].virtual_ns);
    try std.testing.expectEqual(@as(?u32, memory.bytes.len), events[1].payload.fault.address);
}

test "one API loads and drives CPU0 and CPU1 with per-core registers, memory, and breakpoints" {
    var memory0 = Ram.init();
    var memory1 = Ram.init();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu0.reset(0);
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    var live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100 };
    live.other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1, .budget = 100, .index = 1 };

    var session: api.Session = .{ .live = live };
    var loader: LoadLog = .{};
    session.attachLoader(.{ .context = &loader, .loadFn = LoadLog.load });
    const slow_subscriber = try session.subscribe();
    const observer = try session.subscribe();
    try std.testing.expect(session.hasCore(.cpu0));
    try std.testing.expect(session.hasCore(.cpu1));

    try session.load(.cpu0, "cpu0-image");
    try session.load(.cpu1, "cpu1-image");
    try std.testing.expectEqual(@as(usize, 1), loader.calls[0]);
    try std.testing.expectEqual(@as(usize, 1), loader.calls[1]);

    const id = try session.setBreakpoint(.cpu1, .{ .address = 0x0E });
    const ended1 = try session.run(.cpu1, .run);
    try std.testing.expectEqual(.breakpoint, std.meta.activeTag(ended1.stop));
    try std.testing.expectEqual(@as(u32, 0x0E), try session.register(.cpu1, .pc));
    try std.testing.expectEqual(@as(u32, 0x08), try session.register(.cpu0, .pc));

    try session.setRegister(.cpu0, .r0, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234), try session.register(.cpu0, .r0));
    try session.write(.cpu1, 0x20, &.{ 0x34, 0x12 });
    var bytes: [2]u8 = undefined;
    try session.read(.cpu1, 0x20, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, &bytes);

    try session.clearBreakpoint(.cpu1, id);
    try session.setSpeed(.cpu1, 2);
    try std.testing.expectEqual(@as(u64, 2_000_000), session.live.budget);
    const ended0 = try session.step(.cpu0);
    try std.testing.expectEqual(.stepped, std.meta.activeTag(ended0.stop));
    try std.testing.expectEqual(@as(u32, 0x0A), try session.register(.cpu0, .pc));
    _ = try session.register(.cpu1, .pc);
    try std.testing.expectEqual(@as(u64, 2_000_000), session.live.budget);
    var queued_events: [32]api.Event = undefined;
    const observed = session.pollEvents(observer, &queued_events).?;
    try std.testing.expect(observed.count >= 8);
    const delivered = session.pollEvents(slow_subscriber, &queued_events).?;
    try std.testing.expect(delivered.count >= 8);
    try std.testing.expectEqual(@as(u64, 0), queued_events[0].virtual_ns);
    try session.pause(.cpu0);
    const paused = session.pollEvents(observer, &queued_events).?;
    try std.testing.expectEqual(@as(usize, 1), paused.count);
    try std.testing.expectEqual(api.Event.Kind.paused, queued_events[0].kind);
    try std.testing.expectEqual(api.Core.cpu0, queued_events[0].core);
}

test "session input calls advance the board and expose firmware touch reports" {
    var memory = Ram.init();
    for (memory.bytes[8..], 0..) |*byte, index| byte.* = if (index % 2 == 0) 0x00 else 0xBF;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 };
    var session: api.Session = .{ .live = live };
    var events = input_script.Script{};
    var panel = gt911.Panel{};
    var pins = switches.pulled();
    var input = touch_input.Input{ .switches = &switches.user };
    var board = InputBoard{ .events = &events, .panel = &panel, .pins = &pins, .input = &input };
    var store = try Store.init(null);
    defer store.deinit();
    session.attachInputScript(&events);
    session.attachBoard(.cpu0, .{ .context = &board, .tickFn = InputBoard.tick }, .{ .store = &store });

    try session.swipe(.cpu0, 100_000_000, .{ .x = 900, .y = 700 }, .{ .x = 100, .y = 700 }, 100_000_000);
    try session.tap(.cpu0, 50_000_000, 300, 400);
    try session.longpress(.cpu0, 250_000_000, .{ .x = 500, .y = 500 }, 100_000_000);
    try session.button(.cpu0, 400_000_000, .sw1);

    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 300, .y = 400 }, firmwareReport(&panel).?);
    try std.testing.expectError(error.InputInPast, session.tap(.cpu0, 25_000_000, 0, 0));

    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 900, .y = 700 }, firmwareReport(&panel).?);
    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 500, .y = 700 }, firmwareReport(&panel).?);
    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 100, .y = 700 }, firmwareReport(&panel).?);

    _ = try session.step(.cpu0);
    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 500, .y = 500 }, firmwareReport(&panel).?);
    _ = try session.step(.cpu0);
    _ = try session.step(.cpu0);
    try std.testing.expect(!pins.pinLevel(switches.user[0].port, switches.user[0].pin));
    _ = try session.step(.cpu0);
    _ = try session.step(.cpu0);
    try std.testing.expect(pins.pinLevel(switches.user[0].port, switches.user[0].pin));
}

test "session lists widgets and taps the named widget center" {
    var memory = Ram.init();
    for (memory.bytes[8..], 0..) |*byte, index| byte.* = if (index % 2 == 0) 0x00 else 0xBF;
    const tree_address: u32 = 256;
    var channel: [16 + 88]u8 = @splat(0);
    std.mem.writeInt(u32, channel[0..4], 0x52385754, .little);
    std.mem.writeInt(u16, channel[4..6], 1, .little);
    std.mem.writeInt(u16, channel[6..8], 1, .little);
    std.mem.writeInt(u32, channel[8..12], 7, .little);
    const record = channel[16..];
    putText(record[0..32], "settings_button");
    putText(record[32..48], "button");
    putText(record[48..72], "ready");
    std.mem.writeInt(i32, record[72..76], 200, .little);
    std.mem.writeInt(i32, record[76..80], 300, .little);
    std.mem.writeInt(i32, record[80..84], 100, .little);
    std.mem.writeInt(i32, record[84..88], 50, .little);
    @memcpy(memory.bytes[tree_address..][0..channel.len], &channel);

    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 };
    var session: api.Session = .{ .live = live };
    var loader: LoadLog = .{};
    session.attachLoader(.{ .context = &loader, .loadFn = LoadLog.load });
    var image: [256]u8 = @splat(0);
    widgetTreeElf(&image, tree_address);
    try session.load(.cpu0, &image);
    var events = input_script.Script{};
    var panel = gt911.Panel{};
    var pins = gpio.Gpio.init();
    var input = touch_input.Input{};
    var board = InputBoard{ .events = &events, .panel = &panel, .pins = &pins, .input = &input };
    var store = try Store.init(null);
    defer store.deinit();
    session.attachInputScript(&events);
    session.attachBoard(.cpu0, .{ .context = &board, .tickFn = InputBoard.tick }, .{ .store = &store });

    const widgets = try session.widgets(std.testing.allocator, .cpu0);
    defer std.testing.allocator.free(widgets);
    try std.testing.expectEqual(@as(usize, 1), widgets.len);
    try std.testing.expectEqualStrings("settings_button", widgets[0].nameSlice());
    try std.testing.expectEqualStrings("button", widgets[0].kindSlice());
    try std.testing.expectEqualStrings("ready", widgets[0].stateSlice());
    try std.testing.expectEqual(ra8.session.widget_tree.Rect{ .x = 200, .y = 300, .w = 100, .h = 50 }, widgets[0].rect);

    try session.tapWidget(std.testing.allocator, .cpu0, 50_000_000, "settings_button");
    _ = try session.step(.cpu0);
    try std.testing.expectEqual(gt911.Contact{ .x = 250, .y = 325 }, firmwareReport(&panel).?);
    try std.testing.expectError(error.WidgetNotFound, session.tapWidget(std.testing.allocator, .cpu0, 100_000_000, "missing"));
    try std.testing.expectError(error.BadPart, session.tapWidgetPart(std.testing.allocator, .cpu0, 100_000_000, "settings_button", .{ .cell = 0 }));

    try session.tapWidgetPart(std.testing.allocator, .cpu0, 150_000_000, "settings_button", .{ .at = .{ .x_pct = 10, .y_pct = 80 } });
    var report: ?gt911.Contact = null;
    for (0..4) |_| {
        _ = try session.step(.cpu0);
        report = firmwareReport(&panel) orelse continue;
        if (report.?.x != 250) break;
    }
    try std.testing.expectEqual(gt911.Contact{ .x = 210, .y = 340 }, report.?);
}

fn widgetTreeElf(out: []u8, address: u32) void {
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 1;
    out[5] = 1;
    std.mem.writeInt(u16, out[18..20], 40, .little);
    std.mem.writeInt(u32, out[32..36], 52, .little);
    std.mem.writeInt(u16, out[46..48], 40, .little);
    std.mem.writeInt(u16, out[48..50], 3, .little);
    std.mem.writeInt(u16, out[50..52], 0, .little);
    const symtab = out[92..132];
    std.mem.writeInt(u32, symtab[4..8], 2, .little);
    std.mem.writeInt(u32, symtab[16..20], 172, .little);
    std.mem.writeInt(u32, symtab[20..24], 32, .little);
    std.mem.writeInt(u32, symtab[24..28], 2, .little);
    std.mem.writeInt(u32, symtab[32..36], 4, .little);
    std.mem.writeInt(u32, symtab[36..40], 16, .little);
    const strings = out[132..172];
    std.mem.writeInt(u32, strings[4..8], 3, .little);
    std.mem.writeInt(u32, strings[16..20], 204, .little);
    const symbol_name = "\x00ra8_widget_debug_tree\x00";
    std.mem.writeInt(u32, strings[20..24], @intCast(symbol_name.len), .little);
    std.mem.writeInt(u32, out[188..192], 1, .little);
    std.mem.writeInt(u32, out[192..196], address, .little);
    @memcpy(out[204..][0..symbol_name.len], symbol_name);
}

fn putText(out: []u8, value: []const u8) void {
    @memcpy(out[0..value.len], value);
}

fn firmwareReport(panel: *gt911.Panel) ?gt911.Contact {
    var status: [1]u8 = undefined;
    panel.pointer = gt911.reg.status;
    _ = panel.read(&status);
    if (status[0] & gt911.status.ready == 0) return null;
    var record: [gt911.record.bytes]u8 = undefined;
    panel.pointer = gt911.reg.point0;
    _ = panel.read(&record);
    panel.pointer = gt911.reg.status;
    panel.taken = gt911.pointer_bytes;
    panel.write(0);
    return .{ .x = @as(u16, record[2]) << 8 | record[1], .y = @as(u16, record[4]) << 8 | record[3] };
}

const SpeedLog = struct {
    milli: [4]?u64 = undefined,
    count: usize = 0,

    fn set(context: *anyopaque, milli: ?u64) anyerror!void {
        const self: *SpeedLog = @ptrCast(@alignCast(context));
        self.milli[self.count] = milli;
        self.count += 1;
    }
};

test "a speed change reaches the attached hook in thousandths; a refused one reaches nothing" {
    var memory = Ram.init();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    try session.setSpeed(.cpu0, 2);
    var log: SpeedLog = .{};
    session.speed = .{ .context = &log, .setFn = SpeedLog.set };
    try session.setSpeed(.cpu0, 0.25);
    try session.setSpeed(.cpu0, 5);
    try std.testing.expectError(error.InvalidSpeed, session.setSpeed(.cpu0, 0));
    try std.testing.expectError(error.InvalidSpeed, session.setSpeed(.cpu0, 2_000_000));
    try std.testing.expectEqualSlices(?u64, &.{ 250, 5000 }, log.milli[0..log.count]);
    try std.testing.expectEqual(@as(u64, 5_000_000), session.live.budget);
    try session.setSpeed(.cpu0, null);
    try std.testing.expectEqualSlices(?u64, &.{ 250, 5000, null }, log.milli[0..log.count]);
}
