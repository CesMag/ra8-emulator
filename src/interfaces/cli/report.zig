//! The end-of-run narration: what the board saw, in the order a person reads
//! it. Kept apart from board.zig so the models and the words about them do
//! not share a file, and apart from main.zig so main stays wiring.
const std = @import("std");
pub const profile = @import("report/profile.zig");
pub const after = @import("report/after.zig");
/// The board view's PNG writer (RA8EMU-73).
pub const png = @import("../render/png.zig");
pub const frame_out = @import("frame_out.zig");
pub const frames_out = @import("frames_out.zig");
pub const undefined_sites = @import("report/undefined.zig");
/// Stills of the host window (RA8EMU-500).
const Board = @import("../../board/board.zig").Board;
const elc = @import("ra8_chip").periph.elc;
const clocks = @import("ra8_chip").periph.clocks;
const nvic = @import("ra8_chip").periph.nvic;
const cac = @import("ra8_chip").periph.cac;
const dtc = @import("ra8_chip").periph.dtc;
pub const dtc1 = @import("report/dtc1.zig");
const analog = @import("report/analog.zig");
const graphics = @import("report/graphics.zig");
const audio = @import("report/audio.zig");
const capture = @import("report/capture.zig");
const compute = @import("report/compute.zig");
const cores = @import("report/cores.zig");
const dma = @import("report/dma.zig");
const backup = @import("report/backup.zig");
const memory = @import("report/memory.zig");
const modules = @import("report/modules.zig");
const mipi = @import("report/mipi.zig");
const network = @import("report/network.zig");
const options = @import("report/options.zig");
const icu = @import("report/icu.zig");
const pinfunc = @import("report/pinfunc.zig");
const sysclock = @import("report/sysclk.zig");
const lowpower = @import("report/lowpower.zig");
const pll1 = @import("report/pll.zig");
const voltage = @import("report/voltage.zig");
const monitors = @import("report/monitors.zig");
const serial = @import("report/serial.zig");
const storage = @import("report/storage.zig");
const time = @import("report/time.zig");
const timers = @import("report/timers.zig");
const watchdog = @import("report/watchdog.zig");
/// Public so its tests can reach it; root.zig is at the gate's 400 lines.
pub const usb = @import("report/usb.zig");
pub const usb_cable = @import("report/usb_cable.zig");
pub const json = @import("report/json.zig");
pub const json_run = @import("report/json_run.zig");
pub const json_protect = @import("report/json_protect.zig");
pub const json_mem = @import("report/json_mem.zig");
pub const json_clock = @import("report/json_clock.zig");
pub const json_modules = @import("report/json_modules.zig");
pub const json_timers = @import("report/json_timers.zig");
pub const json_watch = @import("report/json_watch.zig");
pub const json_serial = @import("report/json_serial.zig");
pub const json_storage = @import("report/json_storage.zig");
pub const json_riic = @import("report/json_riic.zig");
pub const json_net = @import("report/json_net.zig");
pub const json_i2c = @import("report/json_i2c.zig");
const gpio = @import("ra8_chip").periph.gpio;
const poeg = @import("ra8_chip").periph.poeg;
const reset = @import("ra8_chip").periph.reset;
const reboot = @import("ra8_chip").core.reboot;
const scb = @import("ra8_chip").periph.scb;
const lob = @import("ra8_chip").core.lob;
const unmodelled = @import("report/unmodelled.zig");

pub const Writer = *std.Io.Writer;

pub fn bus(board: *Board, out: Writer) !void {
    try out.print(
        "peripheral accesses: {d} read, {d} written, {d} distinct unmodelled registers\n",
        .{ board.bus.counters.reads, board.bus.counters.writes, board.bus.unmodelledAddresses() },
    );
    try unmodelled.section(&board.bus, out);
    try modules.section(board, out);
}

/// One line per block that was actually used, so a run only reports the
/// peripherals the firmware touched.
pub fn blocks(board: *Board, out: Writer, timebase: clocks.Clocks) !void {
    if (!board.checksum.quiet()) {
        try out.print(
            "CRC: GPS={d}, CRCDOR 0x{X:0>8}, {d} byte(s) folded\n",
            .{ @backingInt(board.checksum.gps()), board.checksum.dor, board.checksum.bytes },
        );
        if (board.checksum.cleared != 0) {
            try out.print(
                "CRC: {d} DORCLR pulse(s), each one putting the remainder back to zero\n",
                .{board.checksum.cleared},
            );
        }
    }
    if (!board.dataops.quiet()) {
        try out.print(
            "DOC: OMS={d}, DODSR0 0x{X:0>8}, DOPCF={d}, {d} operation(s)\n",
            .{ @backingInt(board.dataops.mode()), board.dataops.dodsr0, @intFromBool(board.dataops.flag), board.dataops.ops },
        );
        if (board.dataops.windows != 0) {
            try out.print(
                "DOC: {d} window compare(s), {s}, DODSR0 0x{X:0>4}..DODSR1 0x{X:0>4}\n",
                .{
                    board.dataops.windows,
                    board.dataops.relation().name(),
                    board.dataops.dodsr0 & 0xFFFF,
                    board.dataops.dodsr1 & 0xFFFF,
                },
            );
        }
        if (board.dataops.refused() != 0) {
            try out.print(
                "DOC: {d} DODIR STORE(S) TOO NARROW TO CARRY AN OPERAND\n",
                .{board.dataops.refused()},
            );
        }
    }
    if (!board.accuracy.quiet()) try accuracy(board, out);
    try mipi.sections(board, out);
    try graphics.sections(board, out);
    try watchdog.section(board, out, timebase);
    try usb.section(&board.usb.script, out);
    try causes(board, out);
    try masks(board, out);
    try control(board, out);
    try monitors.sections(board, out);
    try icu.sections(board, out);
    try eventLinks(board, out);
    try transfers(board, out);
    try dtc1.section(&board.transfers1, out);
    try dma.section(board, out);
    try serial.sections(board, out);
    try serial.spi(board, out);
    try serial.trace(board, out);
    try serial.usb(board, out);
    try shutoff(board, out);
    try analog.sections(board, out);
    try analog.converter(board, out);
    try analog.comparators(board, out);
    try audio.sections(board, out);
    try audio.microphone(board, out);
    try capture.sections(board, out);
    try memory.sections(board, out);
    try storage.sections(board, out);
    try options.sections(board, out);
    try pinfunc.sections(board, out);
    try sysclock.sections(board, out);
    try lowpower.sections(board, out);
    try pll1.sections(board, out);
    try voltage.sections(board, out);
    try network.sections(board, out);
    try cores.sections(board, out);
    try compute.sections(board, out);
    try time.sections(board, out);
    try timers.sections(board, out);
    try backup.sections(board, out);
    try leds(board, out);
}

fn accuracy(board: *Board, out: Writer) !void {
    try out.print(
        "CAC: {d} measurement(s), count {d}, window [{d},{d}], FERRF={d}\n",
        .{
            board.accuracy.measurements,
            board.accuracy.cacntbr,
            board.accuracy.callvr,
            board.accuracy.caulvr,
            @intFromBool(board.accuracy.flagSet(cac.status.ferrf)),
        },
    );
    if (board.accuracy.hot_config > 0) {
        try out.print(
            "CAC: {d} store(s) into a clock select or window limit with CFME set\n",
            .{board.accuracy.hot_config},
        );
    }
}

/// Safe shutoff, one line per group the firmware moved. The refused store is
/// the loud case: PIDF, IOCF and OSTPF belong to a pin and the two detectors,
/// so an image that wrote one proved nothing about its shutoff path.
fn shutoff(board: *Board, out: Writer) !void {
    for (&board.shutoff.groups, 0..) |*group, index| {
        if (group.quiet()) continue;
        try out.print(
            "POEG{d}: {d} shutoff(s), {d} re-enable(s), outputs {s}\n",
            .{
                index,
                group.asserts,
                group.clears,
                if (group.disabled()) "high-impedance" else "driven",
            },
        );
        if (group.faked != 0) {
            try out.print(
                "POEG{d}: REFUSED {d} store(s) to PIDF/IOCF/OSTPF, firmware cannot raise a trigger flag itself\n",
                .{ index, group.faked },
            );
        }
    }
}

/// Why the part booted, and whether anything asked it to boot again. Every
/// request is carried out, software and watchdog alike; the reboots line
/// counts those.
fn causes(board: *Board, out: Writer) !void {
    const unit = &board.causes;
    if (unit.quiet()) return;
    try out.print("RESET: RSTSR0=0x{X:0>2} RSTSR1=0x{X:0>8} (", .{ unit.rstsr0, unit.rstsr1 });
    if (unit.rstsr0 & reset.cause.porf != 0) try out.print("POR ", .{});
    if (unit.latched(reset.cause.swrf)) try out.print("SW ", .{});
    if (unit.latched(reset.cause.wdtrf)) try out.print("WDT ", .{});
    if (unit.latched(reset.cause.iwdtrf)) try out.print("IWDT ", .{});
    try out.print(")\n", .{});
    if (unit.requests != 0) {
        try out.print(
            "RESET: {d} RESET(S) REQUESTED (each one performed as a warm reboot)\n",
            .{unit.requests},
        );
    }
    if (unit.bad_acks != 0) {
        try out.print(
            "RESET: {d} ack(s) wrote a one at a cause flag and cleared nothing (RSTSRn is write-zero-to-clear)\n",
            .{unit.bad_acks},
        );
    }
}

/// SYRSTMSK0/1/2: the resets this run switched off, and the mask stores the
/// part would not have taken. A firmware that thinks it masked a watchdog
/// reset and did not is one that reboots where it expected to carry on.
fn masks(board: *Board, out: Writer) !void {
    const unit = &board.causes.masks;
    if (unit.quiet()) return;
    try out.print(
        "SYRSTMSK: 0x{X:0>2} 0x{X:0>2} 0x{X:0>2} (a one masks that reset)\n",
        .{ unit.m0, unit.m1, unit.m2 },
    );
    if (unit.dropped_locked != 0) {
        try out.print(
            "SYRSTMSK: DROPPED {d} store(s) with PRCR.PRC5 shut\n",
            .{unit.dropped_locked},
        );
    }
    if (unit.ignored_iwdt != 0) {
        try out.print(
            "SYRSTMSK: IGNORED {d} store(s) at IWDTMASK while the IWDT was running, the bit freezes until it stops\n",
            .{unit.ignored_iwdt},
        );
    }
    if (unit.ignored_wdt0 == 0) return;
    try out.print(
        "SYRSTMSK: IGNORED {d} store(s) at WDT0MASK while the WDT was running, the bit freezes until it stops\n",
        .{unit.ignored_wdt0},
    );
}

/// What the firmware asked AIRCR for. A write the key gate dropped is the
/// loud line here: dev honours a keyless SYSRESETREQ, so a driver that forgot
/// the 0x05FA reboots there and is ignored by the silicon it runs on.
fn control(board: *Board, out: Writer) !void {
    const unit = &board.control;
    if (unit.quiet()) return;
    try out.print(
        "AIRCR: {d} write(s), {d} reset request(s), priority group {d}\n",
        .{ unit.writes, unit.requests, unit.priorityGroup() },
    );
    if (unit.rejected == 0) return;
    try out.print(
        "AIRCR: {d} write(s) DROPPED for a missing or wrong VECTKEY (0x{X:0>4} required)\n",
        .{ unit.rejected, scb.key.write },
    );
}

/// The event link controller, and the loud cases behind it: dev models no ELC
/// at all, so its registers fall through to the sparse register file. A
/// firmware there runs the three-step ELSEGR sequence, reads the value back,
/// and believes it raised a software event that never existed; and every
/// event a peripheral raises there passes the link table without being
/// offered to it, so a route that was never going to conduct looks identical
/// to one that did.
fn eventLinks(board: *Board, out: Writer) !void {
    const unit = &board.links;
    if (unit.quiet()) return;
    try out.print(
        "ELC: {s}, {d} link(s) programmed, {d} software event(s) generated",
        .{ if (unit.enabled()) "ELCON set" else "ELCON CLEAR, nothing conducts", unit.linkCount(), unit.generated },
    );
    if (unit.refused() != 0) {
        try out.print(
            ", {d} TRIGGER(S) REFUSED ({d} write-inhibited, {d} unarmed, {d} with the block off)",
            .{ unit.refused(), unit.inhibited, unit.unarmed, unit.disabled },
        );
    }
    try out.print("\n", .{});
    try conduction(&unit.table, out);
}

/// What the link table actually conducted. The destination peripheral behind
/// a slot is HUM Table 19.2 and is not in this tree, so an arrival is counted
/// at the slot and stops there, which the line says rather than implying a
/// peripheral ran.
fn conduction(table: *const elc.route.Table, out: Writer) !void {
    if (table.offered == 0) return;
    try out.print(
        "  links: {d} event(s) offered, {d} routed to {d} slot(s), {d} unrouted",
        .{ table.offered, table.delivered, table.busySlots(), table.unrouted },
    );
    if (table.blocked != 0) {
        try out.print(", {d} LINKED EVENT(S) LOST WITH ELCON CLEAR", .{table.blocked});
    }
    try out.print("\n", .{});
    for (0..elc.route.slots) |index| {
        const arrivals = table.arrivalsAt(index);
        if (arrivals == 0) continue;
        try out.print(
            "  ELSR{d}: event 0x{X:0>3}, {d} arrival(s), destination not modelled (HUM Table 19.2)\n",
            .{ index, table.source(index), arrivals },
        );
    }
}

/// What the transfer controller moved without waking the CPU, and the loud
/// cases behind it: a refused activation looks exactly like a plain interrupt
/// to the firmware, and dev transfers whatever the module start bit says, so
/// an image that never started the controller passes there and moves nothing
/// on a bench.
fn transfers(board: *Board, out: Writer) !void {
    const unit = &board.transfers;
    if (unit.quiet()) return;
    try out.print(
        "DTC: {d} activation(s), {d} unit(s) / {d} byte(s) moved, {d} descriptor(s) finished, DTCVBR 0x{X:0>8}\n",
        .{ unit.activations, unit.units, unit.bytes, unit.completions, unit.dtcvbr },
    );
    if (unit.suppressed != 0) {
        try out.print(
            "DTC: {d} interrupt(s) kept from the core while a descriptor still had units left\n",
            .{unit.suppressed},
        );
    }
    if (unit.cache.skips != 0 or unit.cache.drops != 0) {
        try out.print(
            "DTC: DTCCR.RRS skipped {d} descriptor read(s) on a repeated vector, {d} read from memory, {d} copy(s) dropped\n",
            .{ unit.cache.skips, unit.cache.reads, unit.cache.drops },
        );
    }
    if (unit.refused == 0) return;
    try out.print(
        "DTC: REFUSED {d} activation(s), last because of {s} (the core took the interrupt)\n",
        .{ unit.refused, dtc.refusalName(unit.last_refusal.?) },
    );
}

/// The low-power timer, which is how the deep-idle images wake themselves.
/// dev raises the underflow event on the rising edge of TUNDF only, so a
/// periodic image that never clears the flag gets one wake there and wakes
/// every period on the bench; every underflow is an interrupt request here,
/// and a forced stop through TSTOP is taken rather than discarded.
fn leds(board: *Board, out: Writer) !void {
    if (board.pins.refusedStores() != 0) {
        try out.print(
            "GPIO PORT: REFUSED {d} store(s) into PCNTR2, which the pads drive\n",
            .{board.pins.refusedStores()},
        );
    }
    if (board.pins.quiet()) {
        try out.print("GPIO LEDs: none driven\n", .{});
        return;
    }
    try out.print("GPIO LEDs:", .{});
    for (gpio.leds, 0..) |led, i| {
        try out.print(" [{s} {s} x{d}]", .{
            led.name,
            if (board.pins.ledLevel(i) == 1) "ON" else "OFF",
            board.pins.ledEdges(i),
        });
    }
    try out.print("\n", .{});
}

/// Reboots the run actually performed. Silent on a run that never reset,
/// which is nearly all of them.
pub fn reboots(out: Writer, pending: reboot.Reboot) !void {
    if (pending.performed == 0) return;
    try out.print(
        "reboots: {d} warm reset(s) performed from the vector table, peripheral state kept\n",
        .{pending.performed},
    );
}

pub const gif = @import("gif.zig");
pub const wav = @import("wav.zig");
pub const audio_out = @import("audio_out.zig");
