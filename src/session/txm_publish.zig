//! ThreadX module loads and unloads onto the session event stream
//! (RA8EMU-1139).
//!
//! The Module Manager keeps its loaded modules on a list
//! (src/session/txm_modules.zig). A Watcher reads that list at each chunk
//! boundary and publishes `module_loaded` for an instance that appeared and
//! `module_unloaded` for one that left, the instance's address in the
//! event's address. The wire carries both as session events.
const txm = @import("txm_modules.zig");
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

    /// Publish every load and unload since the last read.
    pub fn poll(self: *Watcher) void {
        var now: [most]txm.Module = undefined;
        const count = txm.loaded(self.memory, self.head_at, &now);
        var found: [2 * most]Change = undefined;
        const changed = changes(&self.known, now[0..count], &found);
        const at = self.nowNs();
        for (found[0..changed]) |one| {
            self.stream.publish(.{ .core = .cpu0, .virtual_ns = at, .kind = one.kind, .address = one.instance });
        }
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
