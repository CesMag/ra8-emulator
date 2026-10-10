//! The `--report json` document: the run and cores sections (RA8EMU-347),
//! then protection (report/json_protect.zig, RA8EMU-349) and memory
//! (report/json_mem.zig, RA8EMU-350), then clocks (report/json_clock.zig,
//! RA8EMU-355) and timers (report/json_timers.zig, RA8EMU-356), then serial,
//! storage and riic (report/json_serial.zig, json_storage.zig and
//! json_riic.zig, RA8EMU-360), then network (report/json_net.zig and
//! json_i2c.zig, RA8EMU-362), ethernet and usb (report/json_ether.zig,
//! json_usb.zig and json_usbfs.zig, RA8EMU-364), graphics
//! (report/json_glcdc.zig and json_glcdc_out.zig, RA8EMU-366; json_drw.zig, RA8EMU-371),
//! audio, mipi_phy, capture (report/json_media.zig, RA8EMU-371), icu, pinfunc,
//! options, part, backup (report/json_system.zig, json_options.zig) and
//! analog (report/json_analog.zig, RA8EMU-373), compute
//! (report/json_compute.zig, RA8EMU-377), steps, hotspots, functions,
//! profile (report/json_where.zig, RA8EMU-378), timing (report/json_timing.zig,
//! RA8EMU-383), sites (report/json_sites.zig, RA8EMU-382),
//! dumps (report/json_dumps.zig, RA8EMU-381), cpu_load (report/json_load.zig,
//! RA8EMU-266).
//!
//! One line, one object, `"schema": "ra8-report/1"` first. Every key in a
//! section is always present, quiet or not, so an agent can index without
//! checking; lists (IPC channels, semaphores, doorbells) carry only the
//! units that saw traffic, each with its index. The other report sections
//! join this document under RA8EMU-198's later subtasks.
const Board = @import("../../../board/board.zig").Board;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const bus_fault = @import("ra8_chip").periph.bus_fault;
const cpu_ctrl = @import("ra8_chip").periph.cpu_ctrl;
const ipc = @import("ra8_chip").periph.ipc;
const sync = @import("ra8_chip").periph.ipc_sync;
const json = @import("json.zig");
const json_protect = @import("json_protect.zig");
const json_mem = @import("json_mem.zig");
const json_clock = @import("json_clock.zig");
const json_timers = @import("json_timers.zig");
const json_serial = @import("json_serial.zig");
const json_storage = @import("json_storage.zig");
const json_riic = @import("json_riic.zig");
const json_net = @import("json_net.zig");
const json_ether = @import("json_ether.zig");
const json_usb = @import("json_usb.zig");
const json_glcdc = @import("json_glcdc.zig");
const json_media = @import("json_media.zig");
const json_system = @import("json_system.zig");
const json_analog = @import("json_analog.zig");
const json_compute = @import("json_compute.zig");
pub const json_where = @import("json_where.zig");
pub const json_timing = @import("json_timing.zig");
pub const json_sites = @import("json_sites.zig");
pub const json_dumps = @import("json_dumps.zig");
pub const json_load = @import("json_load.zig");
const eink_log = @import("../eink_log.zig");

pub const schema = "ra8-report/1";

/// What the run itself says: which part, which engine, how far it got.
pub const Run = struct {
    engine: []const u8,
    elapsed: u64,
    /// Shared external-memory wall-clock cycles and the backing store whose
    /// fabric owns the per-region counters.
    elapsed_cycles: u64 = 0,
    external: ?Guest = null,
    bus_errors: bus_fault.Tally = .{},
    /// The run's own tables (RA8EMU-378); each null when not collected.
    where: json_where.Where = .{},
    /// The run's timing hooks (RA8EMU-383); null on the Zig core.
    timing: ?*const json_timing.Timing = null,
    /// The addresses behind the counters (RA8EMU-382); null on the Zig core.
    sites: ?*const json_sites.Sites = null,
    /// The requested symbol, register and memory reads (RA8EMU-381).
    dumps: ?*const json_dumps.Dumps = null,
    /// The `--cpu-load` table per core (RA8EMU-266); null when not asked.
    load: ?*const json_load.Load = null,
    eink_log: ?*const eink_log.Run = null,
};

/// The whole document, ending in a newline.
pub fn document(out: anytype, board: *Board, of: Run) !void {
    var j = json.over(out);
    try j.open(null, '{');
    try j.field("schema", schema);
    try run(&j, board, of);
    try j.open("cores", '{');
    try cpu1(&j, &board.second_core);
    try mailbox(&j, &board.mailbox);
    try j.close('}');
    try json_protect.section(&j, board);
    try json_mem.section(&j, board, of.external, of.elapsed_cycles);
    try json_clock.section(&j, board);
    try json_timers.section(&j, board);
    try json_serial.section(&j, board);
    try json_storage.section(&j, board);
    try json_riic.section(&j, board);
    try json_net.section(&j, board);
    try json_ether.section(&j, board);
    try json_usb.section(&j, board);
    try json_glcdc.section(&j, board);
    try json_media.section(&j, board);
    try json_system.section(&j, board);
    try json_analog.section(&j, board);
    try json_compute.section(&j, board);
    try json_where.section(&j, of.where);
    try json_timing.section(&j, of.timing);
    try json_sites.section(&j, of.sites);
    try json_dumps.section(&j, board, of.dumps);
    try json_load.section(&j, of.load);
    try j.close('}');
    try out.writeByte('\n');
}

fn run(j: anytype, board: *Board, of: Run) !void {
    try j.open("run", '{');
    try j.field("part", board.part.label());
    try j.field("engine", of.engine);
    try j.field("elapsed_instructions", of.elapsed);
    try j.field("elapsed_cycles", of.elapsed_cycles);
    try j.open("bus", '{');
    try j.field("reads", board.bus.counters.reads);
    try j.field("writes", board.bus.counters.writes);
    try j.field("unmodelled_registers", board.bus.unmodelledAddresses());
    try j.close('}');
    try j.open("bus_faults", '{');
    try j.field("raised", of.bus_errors.raised);
    try j.field("escalated", of.bus_errors.escalated);
    try j.close('}');
    if (of.eink_log) |log| try log.reportJson(j);
    try j.close('}');
}

/// CPU0's view of the second-core release handshake.
pub fn cpu1(j: anytype, unit: *const cpu_ctrl.CpuCtrl) !void {
    try j.open("cpu1", '{');
    try j.field("activated", unit.act);
    try j.field("running", unit.running());
    try j.field("mapped", unit.mapped);
    try j.field("vector_table", unit.initvtor);
    try j.field("actcsr", unit.status());
    try j.field("refused_stores", unit.refused);
    try j.close('}');
}

/// The IPC block: channels, events, and the semaphores and doorbells.
pub fn mailbox(j: anytype, unit: *const ipc.Ipc) !void {
    try j.open("ipc", '{');
    try j.field("wakes", unit.wakes);
    try j.field("undelivered", unit.undelivered);
    try j.open("channels", '[');
    for (&unit.channels, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("sends", one.sends);
        try j.field("pushed", one.pushes);
        try j.field("taken", one.pops);
        try j.field("status", one.status());
        try j.field("lost", one.lost);
        try j.field("starved", one.starved);
        try j.field("narrow_reads", one.narrow_reads);
        try j.field("narrow_writes", one.narrow_writes);
        try j.close('}');
    }
    try j.close(']');
    try locks(j, &unit.locks);
    try j.close('}');
}

fn locks(j: anytype, unit: *const sync.Sync) !void {
    try j.open("semaphores", '[');
    for (&unit.semaphores, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("taken", one.takes);
        try j.field("contended", one.contentions);
        try j.field("released", one.releases);
        try j.field("held", one.locked);
        try j.field("stray_releases", one.stray_releases);
        try j.field("unnamed_reads", one.unnamed_reads);
        try j.close('}');
    }
    try j.close(']');
    try j.open("doorbells", '[');
    for (&unit.doorbells, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("sent", one.sends);
        try j.field("acknowledged", one.acks);
        try j.field("pending", one.pending);
        try j.field("coalesced", one.coalesced);
        try j.close('}');
    }
    try j.close(']');
}
