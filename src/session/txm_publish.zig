//! ThreadX module loads and unloads onto the session event stream
//! (RA8EMU-1139).
//!
//! The Module Manager keeps its loaded modules on a list
//! (src/session/txm_modules.zig). A Watcher reads that list at each chunk
//! boundary and publishes `module_loaded` for an instance that appeared and
//! `module_unloaded` for one that left, the instance's address in the
//! event's address. The wire carries both as session events.
//!
//! A module's memory fault is handled by the guest, so the run never stops
//! on it. The Module Manager's fault handler records it in
//! `_txm_module_manager_memory_fault_info` (TXM_MODULE_MANAGER_MEMORY_FAULT_INFO
//! in the Cortex-M33 port's txm_module_port.h: the faulting thread at 0, the
//! code location at 4). When that pair changes to a new fault, the Watcher
//! publishes `module_faulted` for the loaded module whose code holds the
//! location.
const txm = @import("txm_modules.zig");
const txm_debug = @import("txm_debug.zig");
const rtos_hook = @import("rtos_hook.zig");
const stream_mod = @import("event_stream.zig");
const zig_boundary = @import("zig_boundary.zig");
const timebase = @import("ra8_chip").periph.timebase;

/// Modules a Watcher follows; a longer list is cut short.
pub const most = 16;

/// The instances on the list as last read.
pub const Known = struct {
    count: usize = 0,
    instances: [most]u32 = undefined,

    fn has(self: *const Known, instance: u32) bool {
        for (self.instances[0..self.count]) |one| if (one == instance) return true;
        return false;
    }
};

/// Where the Module Manager records the last memory fault.
pub const fault_symbol = "_txm_module_manager_memory_fault_info";

/// The fault record's thread and code location as last read.
pub const Fault = struct {
    thread: u32 = 0,
    code: u32 = 0,
};

/// Whether `now` records a fault `last` did not: a thread is set and the
/// pair differs.
pub fn fresh(last: Fault, now: Fault) bool {
    return now.thread != 0 and (now.thread != last.thread or now.code != last.code);
}

/// The instance whose code holds `pc`, or null when none does.
pub fn owner(modules: []const txm.Module, pc: u32) ?u32 {
    for (modules) |entry| {
        if (pc >= entry.code_start and pc - entry.code_start < entry.code_size) return entry.instance;
    }
    return null;
}

/// One instance that appeared or left.
pub const Change = struct {
    kind: stream_mod.Event.Kind,
    instance: u32,
};

/// What changed between `known` and `now`, written to `into` (at most
/// twice `most`), loads first; `known` becomes `now`.
pub fn changes(known: *Known, now: []const txm.Module, into: *[2 * most]Change) usize {
    var next = Known{};
    var count: usize = 0;
    for (now[0..@min(now.len, most)]) |entry| {
        next.instances[next.count] = entry.instance;
        next.count += 1;
        if (known.has(entry.instance)) continue;
        into[count] = .{ .kind = .module_loaded, .instance = entry.instance };
        count += 1;
    }
    for (known.instances[0..known.count]) |instance| {
        if (next.has(instance)) continue;
        into[count] = .{ .kind = .module_unloaded, .instance = instance };
        count += 1;
    }
    known.* = next;
    return count;
}

pub const Watcher = struct {
    /// Where the image keeps `_txm_module_manager_loaded_list_ptr`.
    head_at: u32,
    memory: rtos_hook.Memory,
    stream: *stream_mod.Stream,
    /// The board's boundary, ticked before each read; null ticks nothing.
    inner: ?zig_boundary.Boundary = null,
    /// The board's time base, for each event's stamp; null stamps zero.
    time: ?*const timebase.TimeBase = null,
    known: Known = .{},
    /// Where the image keeps the fault record; null watches no faults.
    fault_at: ?u32 = null,
    fault: Fault = .{},
    /// Paired module ELFs placed on each load and dropped on each unload
    /// (RA8EMU-1141); null places none.
    table: ?*txm_debug.Table = null,

    /// Publish every load, unload and module fault since the last read.
    pub fn poll(self: *Watcher) void {
        var now: [most]txm.Module = undefined;
        const count = txm.loaded(self.memory, self.head_at, &now);
        var found: [2 * most]Change = undefined;
        const changed = changes(&self.known, now[0..count], &found);
        const at = self.nowNs();
        for (found[0..changed]) |one| {
            self.stream.publish(.{ .core = .cpu0, .virtual_ns = at, .kind = one.kind, .address = one.instance });
            self.place(one);
        }
        self.pollFault(now[0..count], at);
    }

    /// Keep the table in step with one load or unload.
    fn place(self: *Watcher, one: Change) void {
        const table = self.table orelse return;
        if (one.kind != .module_loaded) return table.unloaded(one.instance);
        const entry = txm.module(self.memory, one.instance) orelse return;
        var buffer: [txm.longest]u8 = undefined;
        const named = txm.name(self.memory, entry, &buffer) orelse return;
        _ = table.loaded(one.instance, named, entry.code_start);
    }

    fn pollFault(self: *Watcher, modules: []const txm.Module, at: u64) void {
        const base = self.fault_at orelse return;
        const thread = txm.word(self.memory, base) orelse return;
        const read = Fault{ .thread = thread, .code = txm.word(self.memory, base +% 4) orelse return };
        defer self.fault = read;
        if (!fresh(self.fault, read)) return;
        const instance = owner(modules, read.code) orelse return;
        self.stream.publish(.{ .core = .cpu0, .virtual_ns = at, .kind = .module_faulted, .address = instance });
    }

    fn nowNs(self: *const Watcher) u64 {
        const time = self.time orelse return 0;
        return time.base_ns + timebase.toNs(time.cycles, time.hz);
    }

    /// The inner boundary with a read after every chunk.
    pub fn hook(self: *Watcher) zig_boundary.Boundary {
        const chunk = if (self.inner) |inner| inner.chunk else zig_boundary.default_chunk;
        return .{ .context = self, .tickFn = tick, .chunk = chunk, .sleepFn = asleep };
    }

    fn asleep(context: *anyopaque, normal: u32) u32 {
        const self: *Watcher = @ptrCast(@alignCast(context));
        const inner = self.inner orelse return normal;
        const reach = inner.sleepFn orelse return normal;
        return reach(inner.context, normal);
    }

    fn tick(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Watcher = @ptrCast(@alignCast(context));
        if (self.inner) |inner| try inner.tickFn(inner.context, instructions);
        self.poll();
    }
};
