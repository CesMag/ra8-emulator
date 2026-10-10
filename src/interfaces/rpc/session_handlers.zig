//! The session RPC handlers: one thin adapter per method onto the Session
//! API (RA8EMU-735). Handlers never see bytes; session_server.zig routes.
const std = @import("std");
const rpc = @import("ra8_rpc_wire");
const proto = @import("session_rpc.zig");
const api = @import("ra8_session").session_api;
const stop_machine = @import("ra8_session").stop_machine;
const region_map = @import("ra8_session").region_map;
const source_spec = @import("ra8_host").camera.source_spec;
const session_rtc = @import("ra8_session").session_rtc;

/// The refusal codes live with the wire (RA8EMU-998): both ends agree on them.
pub const app_codes = proto.app_codes;

/// Writes the fitted parts as `MODEL@ENDPOINT` lines into the buffer given.
/// Installs a camera source for set_camera_source (RA8EMU-795).
pub const Camera = struct {
    context: *anyopaque,
    setFn: *const fn (*anyopaque, source_spec.Spec) anyerror!void,
};

/// Writes the memory map of a core's last loaded image (RA8EMU-794): the
/// core index, JSON or text, and the buffer to write into.
pub const Mapping = struct {
    context: *anyopaque,
    mapFn: *const fn (*anyopaque, usize, bool, []u8) anyerror![]const u8,
    /// The main stack reservation of a core's last loaded image (RA8EMU-816).
    stackFn: ?*const fn (*anyopaque, usize) ?region_map.Stack = null,
};

pub const Listing = struct {
    context: *anyopaque,
    listFn: *const fn (*anyopaque, []u8) anyerror![]const u8,
};

const topic_count = @typeInfo(proto.Topic).@"enum".field_names.len;

pub const Context = struct {
    session: *api.Session,
    /// Holds read_memory replies; its length caps one read.
    scratch: []u8,
    /// The stop the last run or step ended in, until Host.poll sends it.
    pending: ?proto.Stopped = null,
    /// Subscribed topics per core, one bit per Topic in declaration order.
    topics: [2]u8 = .{ 0, 0 },
    /// The session event-stream queue UART bytes are read from while any
    /// core wants the uart topic.
    uart_feed: ?usize = null,
    /// The event-stream queue panel refreshes are read from while any core
    /// wants lcd_dirty (RA8EMU-789).
    lcd_feed: ?usize = null,
    /// The event-stream queue session events are read from while any core
    /// wants the session topic (RA8EMU-942).
    session_feed: ?usize = null,
    /// Owns each captured panel frame. A server without one, or a session
    /// without a display, refuses lcd_dirty.
    gpa: ?std.mem.Allocator = null,
    /// The run file's snapshot and restore, when the server has one.
    state: ?@import("ra8_session").board_state.Hook = null,
    /// Writes the fitted parts for list_parts; a server without one refuses it.
    listing: ?Listing = null,
    /// Changes the camera source; a server without one refuses it.
    camera: ?Camera = null,
    /// Writes the memory map for `map`; a server without one refuses it.
    mapping: ?Mapping = null,
    /// Snapshots the RTC counters for `rtc`; a server without one refuses it.
    clock: ?session_rtc.Clock = null,

    pub fn wants(self: *const Context, of: proto.Core, topic: proto.Topic) bool {
        return self.topics[@backingInt(of)] & bit(topic) != 0;
    }
};

fn bit(topic: proto.Topic) u8 {
    const index = @backingInt(topic) - @backingInt(proto.Topic.stop);
    std.debug.assert(index < topic_count);
    return @as(u8, 1) << @intCast(index);
}

const Ack = rpc.Outcome(proto.Ack);
const ack: Ack = .{ .ok = .{ .accepted = 1 } };

fn code(value: u16) rpc.Code {
    return @fromBackingInt(@intCast(value));
}

fn refuse(comptime Reply: type, err: anyerror) rpc.Outcome(Reply) {
    if (err == error.CoreNotAttached) return .{ .err = code(app_codes.no_core) };
    return .{ .err = code(app_codes.refused) };
}

fn core(of: proto.Core) api.Core {
    return @fromBackingInt(@intCast(@backingInt(of)));
}

fn register(of: proto.Register) ?api.Register {
    return std.meta.stringToEnum(api.Register, @tagName(of));
}

pub fn load(context: *Context, args: proto.Load) Ack {
    context.session.load(core(args.core), args.image) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn run(context: *Context, args: proto.Run) Ack {
    const session = context.session;
    if (args.budget != 0) {
        session.setRunBudget(core(args.core), args.budget) catch |err| return refuse(proto.Ack, err);
    }
    const mode = std.meta.stringToEnum(api.Run, @tagName(args.mode)) orelse return .{ .err = .bad_args };
    const ended = session.run(core(args.core), mode) catch |err| return refuse(proto.Ack, err);
    context.pending = stopped(session, args.core, ended);
    return ack;
}

pub fn step(context: *Context, args: proto.CoreOnly) Ack {
    return run(context, .{ .core = args.core, .mode = .step, .budget = 0 });
}

pub fn pause(context: *Context, args: proto.CoreOnly) Ack {
    context.session.pause(core(args.core)) catch |err| return refuse(proto.Ack, err);
    return ack;
}

/// Thousandths of the default rate; zero is `max`, the unpaced speed.
pub fn setSpeed(context: *Context, args: proto.SetSpeed) Ack {
    const factor: ?f64 = if (args.milli == 0) null else @as(f64, @floatFromInt(args.milli)) / 1000.0;
    context.session.setSpeed(core(args.core), factor) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn setRunBudget(context: *Context, args: proto.RunBudget) Ack {
    context.session.setRunBudget(core(args.core), args.instructions) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn readRegister(context: *Context, args: proto.ReadRegister) rpc.Outcome(proto.U32) {
    const which = register(args.register) orelse return .{ .err = .bad_args };
    const value = context.session.register(core(args.core), which) catch |err| return refuse(proto.U32, err);
    return .{ .ok = .{ .value = value } };
}

pub fn writeRegister(context: *Context, args: proto.WriteRegister) Ack {
    const which = register(args.register) orelse return .{ .err = .bad_args };
    context.session.setRegister(core(args.core), which, args.value) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn readMemory(context: *Context, args: proto.ReadMemory) rpc.Outcome(proto.Memory) {
    if (args.length > context.scratch.len) return .{ .err = code(app_codes.too_long) };
    const into = context.scratch[0..args.length];
    context.session.read(core(args.core), args.address, into) catch |err| return refuse(proto.Memory, err);
    return .{ .ok = .{ .bytes = into } };
}

pub fn writeMemory(context: *Context, args: proto.WriteMemory) Ack {
    context.session.write(core(args.core), args.address, args.bytes) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn setBreakpoint(context: *Context, args: proto.Point) rpc.Outcome(proto.U32) {
    const id = context.session.setBreakpoint(core(args.core), .{ .address = args.address }) catch |err|
        return refuse(proto.U32, err);
    return .{ .ok = .{ .value = id } };
}

pub fn clearBreakpoint(context: *Context, args: proto.PointId) Ack {
    context.session.clearBreakpoint(core(args.core), args.id) catch |err| return refuse(proto.Ack, err);
    return ack;
}

pub fn setWatchpoint(context: *Context, args: proto.Watch) rpc.Outcome(proto.U32) {
    if (args.last < args.first) return .{ .err = .bad_args };
    const kind = std.meta.stringToEnum(@FieldType(@import("ra8_session").watch_table.Watch, "kind"), @tagName(args.access)) orelse
        return .{ .err = .bad_args };
    const id = context.session.setWatchpoint(core(args.core), .{ .first = args.first, .last = args.last, .kind = kind }) catch |err|
        return refuse(proto.U32, err);
    return .{ .ok = .{ .value = id } };
}

pub fn clearWatchpoint(context: *Context, args: proto.PointId) Ack {
    context.session.clearWatchpoint(core(args.core), args.id) catch |err| return refuse(proto.Ack, err);
    return ack;
}

/// Replies 0 when the id was a breakpoint and 1 when it was a watchpoint.
pub fn removePoint(context: *Context, args: proto.PointId) rpc.Outcome(proto.U32) {
    const removed = context.session.removePoint(core(args.core), args.id) catch |err| return refuse(proto.U32, err);
    return .{ .ok = .{ .value = @backingInt(removed) } };
}

pub fn subscribe(context: *Context, args: proto.Subscription) Ack {
    if (!context.session.hasCore(core(args.core))) return .{ .err = code(app_codes.no_core) };
    if (args.topic == .uart and context.uart_feed == null) {
        context.uart_feed = context.session.subscribe() catch |err| return refuse(proto.Ack, err);
    }
    if (args.topic == .session and context.session_feed == null) {
        context.session_feed = context.session.subscribe() catch |err| return refuse(proto.Ack, err);
    }
    if (args.topic == .lcd_dirty and context.lcd_feed == null) {
        const display = context.session.display orelse return .{ .err = code(app_codes.refused) };
        if (context.gpa == null) return .{ .err = code(app_codes.refused) };
        context.lcd_feed = context.session.subscribe() catch |err| return refuse(proto.Ack, err);
        // A GLCDC panel is scanned only for a viewer: this client is one now.
        display.watch(true);
    }
    context.topics[@backingInt(args.core)] |= bit(args.topic);
    return ack;
}

pub fn unsubscribe(context: *Context, args: proto.Subscription) Ack {
    context.topics[@backingInt(args.core)] &= ~bit(args.topic);
    if (!context.wants(.cpu0, .uart) and !context.wants(.cpu1, .uart)) release(context, &context.uart_feed);
    if (!context.wants(.cpu0, .lcd_dirty) and !context.wants(.cpu1, .lcd_dirty)) unwatch(context);
    if (!context.wants(.cpu0, .session) and !context.wants(.cpu1, .session)) release(context, &context.session_feed);
    return ack;
}

/// Drop every subscription, as a new connection starts with none.
pub fn forget(context: *Context) void {
    context.topics = .{ 0, 0 };
    context.pending = null;
    release(context, &context.uart_feed);
    unwatch(context);
    release(context, &context.session_feed);
}

/// Give up the panel feed, and the watch on the panel that came with it.
fn unwatch(context: *Context) void {
    if (context.lcd_feed == null) return;
    release(context, &context.lcd_feed);
    if (context.session.display) |display| display.watch(false);
}

fn release(context: *Context, feed: *?usize) void {
    const id = feed.* orelse return;
    context.session.unsubscribe(id);
    feed.* = null;
}

pub fn now(context: *Context, args: proto.Now) rpc.Outcome(proto.U64) {
    _ = args;
    const ns = context.session.now() catch |err| return refuse(proto.U64, err);
    return .{ .ok = .{ .value = ns } };
}

pub fn interrupt(context: *Context, args: proto.CoreOnly) rpc.Outcome(proto.Stopped) {
    const stop = context.session.interrupt(core(args.core)) catch |err| return refuse(proto.Stopped, err);
    return .{ .ok = stopped(context.session, args.core, .{ .stop = stop }) };
}

/// The wire form of how a run ended, at the PC it left.
pub fn stopped(session: *api.Session, of: proto.Core, ended: api.Ended) proto.Stopped {
    const pc = session.register(core(of), .pc) catch 0;
    return switch (ended) {
        .count => .{ .core = of, .reason = .count, .address = pc, .detail = 0 },
        .core => |stop| .{ .core = of, .reason = .core_fault, .address = pc, .detail = @backingInt(std.meta.activeTag(stop)) },
        .stop => |stop| .{ .core = of, .reason = reason(stop), .address = pc, .detail = detail(stop) },
    };
}

fn reason(stop: stop_machine.Stop) proto.StopReason {
    return std.meta.stringToEnum(proto.StopReason, @tagName(stop)) orelse .halt_requested;
}

fn detail(stop: stop_machine.Stop) u32 {
    return switch (stop) {
        .watchpoint => |hit| hit.id,
        inline else => |value| switch (@typeInfo(@TypeOf(value))) {
            .int => @truncate(value),
            else => 0,
        },
    };
}
