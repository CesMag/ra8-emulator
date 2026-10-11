//! The `memory` object of `--report json` (RA8EMU-350): caches, SRAM ECC
//! and its protect register, the DMAC and CPU1's DTC, and the unmodelled
//! register worklist. The same facts report/memory.zig, dma.zig, dtc1.zig
//! and unmodelled.zig print; every key is always present, and per-unit
//! lists carry only the channels or operations that saw anything.
const Board = @import("ra8_board").board.Board;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const external = @import("ra8_board").external.memory;
const backing = @import("ra8_board").external.backing;
const cache = @import("ra8_chip").periph.cache;
const dmac = @import("ra8_chip").periph.dmac;
const dtc = @import("ra8_chip").periph.dtc;
const dma = @import("../dma.zig");
const unmodelled = @import("../unmodelled.zig");

/// The whole `memory` object, keyed inside the document.
pub fn section(j: anytype, board: *Board, memory: ?Guest, elapsed: u64) !void {
    try j.open("memory", '{');
    try caches(j, &board.caches);
    try sram(j, board);
    try transfers(j, &board.dma);
    try dtc1(j, &board.transfers1);
    try worklist(j, board);
    try externalRegions(j, board, memory, elapsed);
    try j.close('}');
}

fn caches(j: anytype, unit: *const cache.Cache) !void {
    try j.open("cache", '{');
    try j.field("line_bytes", unit.lineBytes());
    try j.field("ctr", unit.ctr);
    try j.field("icache_on", unit.icacheOn());
    try j.field("dcache_on", unit.dcacheOn());
    try j.field("set_way_walk_declined", unit.walkDeclined() and unit.setWayAsked() != 0);
    try j.field("refused_stores", unit.refused);
    try j.open("maintenance", '[');
    for (0..cache.op_count) |index| {
        const which: cache.Op = @fromBackingInt(@intCast(index));
        const count = unit.count(which);
        if (count == 0) continue;
        try j.open(null, '{');
        try j.field("op", which.name());
        try j.field("count", count);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn sram(j: anytype, board: *Board) !void {
    const memory = &board.ecc;
    const lock = &memory.lock;
    try j.open("sram", '{');
    try j.field("ecc_latches", memory.latches);
    try j.field("sramesr", memory.esr);
    try j.field("refused_esr_stores", memory.faked);
    try j.field("prcr_unlocked", lock.open());
    try j.field("prcr_key_writes", lock.accepted);
    try j.field("prcr_guarded_stores", lock.allowed);
    try j.field("prcr_ignored_keys", lock.ignored);
    try j.field("prcr_refused_stores", lock.blocked);
    try j.close('}');
}

fn transfers(j: anytype, unit: *const dmac.Dmac) !void {
    const sum = dma.tally(unit);
    try j.open("dmac", '{');
    try j.field("requests", sum.requests);
    try j.field("units", sum.units);
    try j.field("bytes", sum.bytes);
    try j.field("finished", sum.completions);
    try j.field("cut_short", sum.faults);
    try j.field("still_armed", sum.armed);
    try j.field("started", unit.started());
    try j.field("refused", unit.refused);
    try j.field("last_refusal", if (unit.last_refusal) |why| dmac.refusalName(why) else null);
    try j.open("channels", '[');
    for (&unit.channels, 0..) |*one, index| {
        if (one.quiet()) continue;
        const shape = one.plan();
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("mode", @tagName(shape.mode));
        try j.field("width", @tagName(shape.width));
        try j.field("requests", one.requests);
        try j.field("units", one.units);
        try j.field("bytes", one.bytes);
        try j.field("finished", one.completions);
        try j.field("dmsar", one.dmsar);
        try j.field("dmdar", one.dmdar);
        try j.field("cut_short", one.faults);
        try j.field("units_owed", one.pending);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn dtc1(j: anytype, unit: *const dtc.Dtc) !void {
    try j.open("dtc1", '{');
    try j.field("activations", unit.activations);
    try j.field("units", unit.units);
    try j.field("bytes", unit.bytes);
    try j.field("finished", unit.completions);
    try j.field("dtcvbr", unit.dtcvbr);
    try j.field("interrupts_held", unit.suppressed);
    try j.field("refused", unit.refused);
    try j.field("last_refusal", if (unit.last_refusal) |why| dtc.refusalName(why) else null);
    try j.close('}');
}

fn worklist(j: anytype, board: *Board) !void {
    var buffer: [unmodelled.limit]unmodelled.Entry = undefined;
    const shown = unmodelled.lowest(&board.bus, &buffer);
    try j.open("unmodelled", '{');
    try j.field("total", board.bus.unmodelledAddresses());
    try j.open("lowest", '[');
    for (shown) |entry| {
        try j.open(null, '{');
        try j.field("address", entry.address);
        try j.field("written", entry.written);
        try j.close('}');
    }
    try j.close(']');
    try j.close('}');
}

fn externalRegions(j: anytype, board: *Board, memory: ?Guest, elapsed: u64) !void {
    try j.open("external_regions", '[');
    inline for (.{ external.Kind.ospi, external.Kind.sdram }) |kind| {
        const config = board.external_memory.region(kind);
        const counters = if (memory) |guest| if (backing.fabricOf(guest.store)) |fabric| fabric.counters(kind, elapsed) else external.Counters{} else external.Counters{};
        try j.open(null, '{');
        try j.field("name", kind.label());
        try j.field("base", kind.base());
        try j.field("size_bytes", config.size);
        try j.field("bus_width_bits", config.width);
        try j.field("clock_hz", config.clock_hz);
        try j.field("latency_cycles", config.latency_cycles);
        try j.field("burst", @tagName(config.burst));
        try j.field("memory_window_cycles", board.external_memory.window_cycles);
        try j.field("read_high_water_bytes", counters.read_high_water_bytes);
        try j.field("write_high_water_bytes", counters.write_high_water_bytes);
        try j.field("bytes_read", counters.bytes_read);
        try j.field("bytes_written", counters.bytes_written);
        try j.field("average_read_bytes_per_second", counters.average_read_bytes_per_second);
        try j.field("average_write_bytes_per_second", counters.average_write_bytes_per_second);
        try j.field("peak_read_bytes_per_second", counters.peak_read_bytes_per_second);
        try j.field("peak_write_bytes_per_second", counters.peak_write_bytes_per_second);
        try j.open("stall_cycles", '{');
        try j.field("cpu", counters.cpu_stall_cycles);
        try j.field("ethos_u55", counters.ethos_u55_stall_cycles);
        try j.close('}');
        try j.close('}');
    }
    try j.close(']');
}
