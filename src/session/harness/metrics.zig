//! On-demand per-core RTOS ownership for device metrics.
const std = @import("std");
const rtos = @import("../rtos/hook.zig");
const metrics = @import("../device_metrics.zig");
const elf = @import("ra8_board").image.elf;

pub const Track = struct {
    tracer: rtos.Tracer = undefined,
    listener: rtos.zig.Listener = undefined,
    bound: bool = false,
    armed: bool = false,
    identity: ?[16]u8 = null,
    sampled_retired: u64 = 0,
    epoch: u64 = 0,
};

pub fn read(state: anytype, core: u1) metrics.Snapshot {
    const cpu = state.loading.cpu[core] orelse return .{};
    const bytes = state.loading.loaded[core] orelse if (core == 0) state.bytes else return metrics.collect(cpu, &state.cpu0.store.?, null, null, core);
    const image = elf.Image.init(bytes) catch return .{};
    // Reuse an explicitly armed CPU0 trace rather than wrapping its bus twice.
    if (core == 0) if (state.tracer) |*tracer| {
        const track = &state.metrics_tracking[core];
        if (cpu.metrics_epoch != track.epoch or cpu.retired < track.sampled_retired or cpu.retired < tracer.trace.load.cores[core].since) {
            seed(tracer, cpu, state.loading.memory[core], core);
        }
        track.epoch = cpu.metrics_epoch;
        track.sampled_retired = cpu.retired;
        return metrics.collect(cpu, &state.cpu0.store.?, image, &tracer.trace.load, core);
    };
    const track = &state.metrics_tracking[core];
    const identity = state.loading.hashes[core] orelse @import("ra8_board").snapshot.run.imageIdentity(bytes);
    const changed = if (track.identity) |old| !std.mem.eql(u8, &old, &identity) else true;
    const rewound = track.armed and (cpu.metrics_epoch != track.epoch or cpu.retired < track.sampled_retired or cpu.retired < track.tracer.trace.load.cores[core].since);
    if (changed or rewound) {
        track.identity = identity;
        if (@import("../symbols.zig").addressOf(image, rtos.symbol)) |address| {
            track.tracer = .{ .address = address, .core = core };
            track.tracer.now = &state.board.time.base.retired;
            track.tracer.trace.fine = &cpu.retired;
            seed(&track.tracer, cpu, state.loading.memory[core], core);
            track.armed = true;
            if (!track.bound) {
                track.listener = .{ .tracer = &track.tracer };
                cpu.bus = track.listener.onBus(cpu.bus);
                if (cpu.source) |source| cpu.source = track.listener.onSource(source);
                track.bound = true;
            }
        } else {
            track.armed = false;
            // A previously installed listener remains a forwarding adapter.
            if (track.bound) track.tracer = .{ .address = std.math.maxInt(u32) };
        }
    }
    track.epoch = cpu.metrics_epoch;
    track.sampled_retired = cpu.retired;
    return metrics.collect(cpu, &state.cpu0.store.?, image, if (track.armed) &track.tracer.trace.load else null, core);
}

/// A new epoch starts with the actual running thread and active exception stack.
fn seed(tracer: *rtos.Tracer, cpu: anytype, memory: ?@import("ra8_chip").core.cpu.memory.guest.Guest, core: u1) void {
    tracer.trace.load = .{ .from = cpu.retired };
    for (cpu.active.stack[0..cpu.active.depth]) |entry| {
        tracer.trace.load.feed(.{ .core = core, .when = cpu.retired, .kind = .enter, .exception = entry.number });
    }
    if (memory) |guest| {
        if (guest.readWord(tracer.address)) |thread| {
            tracer.trace.current[core] = thread;
            tracer.trace.load.feed(.{ .core = core, .when = cpu.retired, .kind = if (thread == 0) .idle else .switch_to, .thread = thread });
        } else |_| {}
    }
}
