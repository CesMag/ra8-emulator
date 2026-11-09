//! Bounded snapshots for the device health pane (RA8EMU-1240).
const load = @import("rtos/load.zig");
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const symbols = @import("symbols.zig");

pub const Stack = struct {
    pointer: u32 = 0,
    limit: u32 = 0,
    top: u32 = 0,
    pub fn known(self: Stack) bool {
        return self.top > self.limit;
    }
    pub fn used(self: Stack) u32 {
        return if (self.known()) stackAddress(self.top) -| stackAddress(self.pointer) else 0;
    }
    pub fn warning(self: Stack) bool {
        const pointer = stackAddress(self.pointer);
        const limit = stackAddress(self.limit);
        const top = stackAddress(self.top);
        return self.known() and (pointer < limit or pointer > top or @as(u64, pointer -| limit) * 10 < top - limit);
    }
};
fn stackAddress(address: u32) u32 {
    const map = @import("ra8_chip").core.memmap;
    if (address >= map.ns_sram_base and address <= map.ns_sram_end) return address - map.ns_offset;
    if (address >= map.ns_sdram_base and address <= map.ns_sdram_end) return address - map.ns_offset;
    return address;
}

pub const Memory = struct { pages: usize = 0, capacity: usize = 0, known: bool = true };
pub const Snapshot = struct {
    attached: bool = false,
    epoch: u64 = 0,
    active: u64 = 0,
    idle: u64 = 0,
    msp: Stack = .{},
    psp: Stack = .{},
    sram: Memory = .{},
    sdram: Memory = .{},
    rtos: bool = false,
    owners: [load.limits.slots]load.Slot = undefined,
    owner_count: usize = 0,
    other: u64 = 0,
};
pub const Hook = struct {
    context: *anyopaque,
    readFn: *const fn (*anyopaque, u1) Snapshot,
};

pub fn collect(cpu: ?*const cpu_mod.Cpu, store: ?*const Store, image: ?symbols.Image, traced: ?*const load.Load, core: u1) Snapshot {
    const live = cpu orelse return .{};
    var out: Snapshot = .{ .attached = true, .epoch = live.metrics_epoch, .active = live.slots, .idle = live.idle_cycles };
    out.msp.pointer = live.regs.msp;
    out.psp.pointer = live.regs.psp;
    if (image) |elf| {
        out.msp = stackBounds(out.msp.pointer, elf, "__StackLimit", "__StackTop");
        // PSP bounds are distinct; never apply the main stack's bounds to an RTOS thread.
        out.psp = stackBounds(out.psp.pointer, elf, "__ProcessStackLimit", "__ProcessStackTop");
    }
    if (store) |memory| {
        const tracker = memory.touches();
        out.sram = .{ .known = tracker.valid, .pages = tracker.sram.count(), .capacity = @TypeOf(tracker.*).sram_capacity };
        out.sdram = .{ .known = tracker.valid, .pages = tracker.sdram.count(), .capacity = if (memory.port) |port| port.sdram.len else 0 };
    }
    if (traced) |original| {
        var current = original.*;
        current.finish(live.retired);
        const rows = current.rows(core);
        @memcpy(out.owners[0..rows.len], rows);
        out.owner_count = rows.len;
        out.other = current.cores[core].other;
        out.rtos = true;
    }
    return out;
}

fn stackBounds(pointer: u32, image: symbols.Image, lower: []const u8, upper: []const u8) Stack {
    const limit = symbols.addressOf(image, lower) orelse return .{ .pointer = pointer };
    const top = symbols.addressOf(image, upper) orelse return .{ .pointer = pointer };
    return .{ .pointer = pointer, .limit = limit, .top = top };
}

/// A pane-local sampling window, so a past busy boot does not hide current sleep.
pub const Window = struct {
    epoch: u64 = 0,
    active: u64 = 0,
    idle: u64 = 0,
    percent: u8 = 0,
    pinned: bool = false,
    primed: bool = false,
    pub fn sample(self: *Window, snapshot: *const Snapshot) void {
        const a = snapshot.active -| self.active;
        const i = snapshot.idle -| self.idle;
        const valid = self.primed and snapshot.epoch == self.epoch and snapshot.active >= self.active and snapshot.idle >= self.idle;
        self.epoch = snapshot.epoch;
        self.active = snapshot.active;
        self.idle = snapshot.idle;
        self.primed = snapshot.attached;
        self.pinned = valid and a > 0 and i == 0;
        self.percent = if (valid and a + i > 0) @intCast(@as(u128, a) * 100 / (@as(u128, a) + i)) else 0;
    }
};

pub fn read(self: *@import("api.zig").Session, core: @import("api.zig").Core) Snapshot {
    const hook = self.metrics orelse return .{};
    return hook.readFn(hook.context, @intCast(@backingInt(core)));
}
