//! `--trace-rtos` on a `--cpu zig` run (RA8EMU-261).
//!
//! The Zig core owns no hooks, so the tracer listens the way watch_bus.zig
//! does: it sits between the core and its bus, and between the core and its
//! exception source. A store to ThreadX's current-thread pointer reaches
//! Tracer.onStore; an exception the core takes or returns from is recorded
//! as it is reported to the source. Everything else passes straight on.
const std = @import("std");
const bus = @import("ra8_chip").core.cpu.bus;
const Source = @import("ra8_chip").core.cpu.exception.source.Source;
const Entry = @import("ra8_chip").core.cpu.exception.active.Entry;
const boot = @import("ra8_chip").core.cpu.boot;
const rtos_hook = @import("rtos_hook.zig");

pub const Listener = struct {
    tracer: *rtos_hook.Tracer,
    inner_bus: bus.Bus = undefined,
    inner_source: Source = undefined,

    /// What boot.zig takes to put this listener in front of a run.
    pub fn wrap(self: *Listener) boot.Wrap {
        return .{ .context = self, .busFn = busThunk, .sourceFn = sourceThunk, .retiredFn = retiredThunk };
    }

    pub fn onBus(self: *Listener, inner: bus.Bus) bus.Bus {
        self.inner_bus = inner;
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch } };
    }

    pub fn onSource(self: *Listener, inner: Source) Source {
        self.inner_source = inner;
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }
};

fn busThunk(context: *anyopaque, inner: bus.Bus) bus.Bus {
    const self: *Listener = @ptrCast(@alignCast(context));
    return self.onBus(inner);
}

fn sourceThunk(context: *anyopaque, inner: Source) Source {
    const self: *Listener = @ptrCast(@alignCast(context));
    return self.onSource(inner);
}

/// The core's retired count is the load clock, one tick per instruction
/// (RA8EMU-284).
fn retiredThunk(context: *anyopaque, retired: *const u64) void {
    const self: *Listener = @ptrCast(@alignCast(context));
    self.tracer.trace.fine = retired;
}

fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    return self.inner_bus.read(address, into);
}

fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    try self.inner_bus.write(address, bytes);
    if (bytes.len != 4) return;
    self.tracer.onStore(address, 4, std.mem.readInt(u32, bytes[0..4], .little));
}

/// A fault status bit stays a latch through the listener (RA8EMU-634).
fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    return self.inner_bus.latch(address, bits);
}

fn winner(ctx: *anyopaque, through: bus.Bus) bus.Error!?Entry {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    return self.inner_source.winner(through);
}

fn taken(ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    try self.inner_source.taken(through, number);
    self.tracer.trace.exception(self.tracer.core, self.tracer.stamp(), .enter, number);
}

fn returned(ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
    const self: *Listener = @ptrCast(@alignCast(ctx));
    try self.inner_source.returned(through, number);
    self.tracer.trace.exception(self.tracer.core, self.tracer.stamp(), .leave, number);
}
