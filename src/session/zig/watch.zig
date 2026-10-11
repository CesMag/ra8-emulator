//! `--watch` on a `--cpu zig` run (RA8EMU-639). The Zig core owns no hooks, so this sits between the
//! core and its bus the way src/session/rtos/zig.zig does, and hands every
//! store that starts in the watched word to watchpoint.Watched.
//!
//! The core moves pc past an instruction before running it, so a store
//! cannot read its own pc off the registers. It is held until the
//! instruction retires, and the retire listener stamps it with that
//! instruction's address. A store no instruction made (exception stacking)
//! is stamped by the next instruction to retire, and one still held when
//! the run ends is stamped with the pc the run stopped at.
const std = @import("std");
const bus = @import("ra8_chip").core.cpu.bus;
const boot = @import("ra8_chip").core.cpu.boot;
const cpu = @import("ra8_chip").core.cpu.cpu;
const elf = @import("ra8_board").image.elf;
const Source = @import("ra8_chip").core.cpu.exception.source.Source;
const watchpoint = @import("../watchpoint.zig");

pub const limits = struct {
    /// Stores one instruction can land in a four-byte word: four byte
    /// stores at most, with room for an exception frame around them.
    pub const held: usize = 8;
};

/// A store waiting for the instruction that made it to retire.
const Held = struct { lr: u32, address: u32, width: u8, value: u32 };

pub const Recorder = struct {
    watched: watchpoint.Watched = .{},
    armed: bool = false,
    /// The listener this one stands in front of (`--trace-rtos`), or null.
    next: ?boot.Wrap = null,
    next_retire: ?cpu.RetireListener = null,
    /// The core's registers, lent for the run, for the store's lr.
    regs: ?*const boot.Regs = null,
    inner: bus.Bus = undefined,
    held: [limits.held]Held = undefined,
    count: usize = 0,

    /// Resolve `spec` and stand in front of `next`. Returns the wrap the
    /// run takes: this recorder's, or `next` untouched when nothing is
    /// watched.
    pub fn arm(self: *Recorder, image: elf.Image, spec: ?[]const u8, next: ?boot.Wrap, now: *const u64) ?boot.Wrap {
        var found = watchpoint.resolve(image, spec) orelse return next;
        found.now = now;
        self.* = .{ .watched = found, .armed = true, .next = next };
        return self.wrap();
    }

    pub fn wrap(self: *Recorder) boot.Wrap {
        return .{ .context = self, .busFn = busThunk, .sourceFn = sourceThunk, .retiredFn = retiredThunk, .regsFn = regsThunk };
    }

    /// The retire listener the run takes, chained in front of `next`.
    pub fn listener(self: *Recorder, next: ?cpu.RetireListener) ?cpu.RetireListener {
        if (!self.armed) return next;
        self.next_retire = next;
        return .{ .context = self, .instructionFn = retireThunk };
    }

    pub fn onBus(self: *Recorder, under: bus.Bus) bus.Bus {
        self.inner = if (self.next) |w| w.busFn(w.context, under) else under;
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch, .repeat = repeat } };
    }

    /// A store reached the bus: hold it when it starts in the window.
    pub fn stored(self: *Recorder, address: u32, bytes: []const u8) void {
        if (address < self.watched.address or address > self.watched.end()) return;
        if (self.count == limits.held) self.retired(if (self.regs) |r| r.pc else 0);
        self.held[self.count] = .{ .lr = if (self.regs) |r| r.lr else 0, .address = address, .width = width(bytes.len), .value = value(bytes) };
        self.count += 1;
    }

    /// The instruction at `pc` retired: everything held is its.
    pub fn retired(self: *Recorder, pc: u32) void {
        for (self.held[0..self.count]) |one| self.watched.record(pc, one.lr, one.address, one.width, one.value);
        self.count = 0;
    }

    /// The log once the run is over, or null when nothing was watched.
    pub fn result(self: *Recorder, pc: u32) ?watchpoint.Watched {
        if (!self.armed) return null;
        self.retired(pc);
        return self.watched;
    }
};

fn busThunk(context: *anyopaque, inner: bus.Bus) bus.Bus {
    const self: *Recorder = @ptrCast(@alignCast(context));
    return self.onBus(inner);
}

fn sourceThunk(context: *anyopaque, inner: Source) Source {
    const self: *Recorder = @ptrCast(@alignCast(context));
    const w = self.next orelse return inner;
    return w.sourceFn(w.context, inner);
}

fn retiredThunk(context: *anyopaque, count: *const u64) void {
    const self: *Recorder = @ptrCast(@alignCast(context));
    const w = self.next orelse return;
    if (w.retiredFn) |lend| lend(w.context, count);
}

fn regsThunk(context: *anyopaque, regs: *const boot.Regs) void {
    const self: *Recorder = @ptrCast(@alignCast(context));
    self.regs = regs;
    const w = self.next orelse return;
    if (w.regsFn) |lend| lend(w.context, regs);
}

fn retireThunk(context: *anyopaque, address: u32) void {
    const self: *Recorder = @ptrCast(@alignCast(context));
    self.retired(address);
    if (self.next_retire) |next| next.instruction(address);
}

fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
    const self: *Recorder = @ptrCast(@alignCast(ctx));
    return self.inner.read(address, into);
}

fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
    const self: *Recorder = @ptrCast(@alignCast(ctx));
    try self.inner.write(address, bytes);
    self.stored(address, bytes);
}

/// A fault status bit stays a latch, and no store (RA8EMU-634).
fn latch(ctx: *anyopaque, address: u32, bits: u32) bus.Error!void {
    const self: *Recorder = @ptrCast(@alignCast(ctx));
    return self.inner.latch(address, bits);
}

fn repeat(ctx: *anyopaque, address: u32, len: usize, times: u64) bool {
    const self: *Recorder = @ptrCast(@alignCast(ctx));
    return self.inner.repeat(address, len, times);
}

fn width(len: usize) u8 {
    return @intCast(@min(len, std.math.maxInt(u8)));
}

/// The low word a store moved, little-endian.
fn value(bytes: []const u8) u32 {
    var word: [4]u8 = .{ 0, 0, 0, 0 };
    const len = @min(bytes.len, word.len);
    @memcpy(word[0..len], bytes[0..len]);
    return std.mem.readInt(u32, &word, .little);
}
