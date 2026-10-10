//! The `protection` object of `--report json` (RA8EMU-349): what the
//! firmware programmed into the MPU and SAU, what enforcement refused, and
//! what the Secure boot attributed to the Non-Secure world. The same facts
//! the MPU, SAU and attribution lines of report/cores.zig print, every key
//! always present so a quiet run reads as zeros rather than missing keys.
const Board = @import("../../../board/board.zig").Board;
const mpu = @import("ra8_chip").periph.mpu;
const sau = @import("ra8_chip").periph.sau;

/// The whole `protection` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("protection", '{');
    try regions(j, board);
    try partitions(j, &board.partitions);
    try ipcAttribution(j, board);
    try chipAttribution(j, board);
    try j.close('}');
}

fn regions(j: anytype, board: *Board) !void {
    const unit = &board.regions;
    const latch = &board.guard.latch;
    try j.open("mpu", '{');
    try j.field("enabled", unit.on());
    try j.field("programmed_regions", unit.programmed());
    try j.field("regions", mpu.geometry.regions);
    try j.field("read_only_regions", unit.readOnly());
    try j.field("privileged_default", unit.privilegedDefault());
    try j.field("refused_stores", latch.violations -| (latch.fetches + latch.loads));
    try j.field("refused_loads", latch.loads);
    try j.field("refused_fetches", latch.fetches);
    try j.field("outside_every_region", latch.background);
    try j.field("unprivileged", latch.privilege);
    try j.field("memmanage", latch.faults);
    try j.field("escalated", latch.escalated);
    try j.field("unhandled", latch.unhandled);
    try j.field("stood_down", latch.stood_down);
    try j.close('}');
}

/// One core's SAU. Public so a second-core document can reuse it.
pub fn partitions(j: anytype, unit: *const sau.Sau) !void {
    try j.open("sau", '{');
    try j.field("enabled", unit.on());
    try j.field("programmed_regions", unit.programmed());
    try j.field("regions", sau.geometry.regions);
    try j.field("non_secure_callable", unit.callable());
    try j.field("outside_is_non_secure", unit.outsideIsNonSecure());
    try j.field("refused_type_stores", unit.refused);
    try j.close('}');
}

fn ipcAttribution(j: anytype, board: *Board) !void {
    const unit = &board.mailbox.attrib;
    try j.open("ipc_attribution", '{');
    try j.field("ipcsar", unit.sar);
    try j.field("ipcpar", unit.par);
    try j.field("non_secure_channels", unit.givenAway());
    try j.field("refused_stores", unit.locked_writes);
    try j.close('}');
}

fn chipAttribution(j: anytype, board: *Board) !void {
    const unit = &board.chip_attribution;
    try j.open("cpscu_attribution", '{');
    try j.field("bussara", unit.wordOf(.bussara));
    try j.field("bussarb", unit.wordOf(.bussarb));
    try j.field("bussarc", unit.wordOf(.bussarc));
    try j.field("mmpusara", unit.wordOf(.mmpusara));
    try j.field("mmpusarb", unit.wordOf(.mmpusarb));
    try j.field("cpusar", unit.wordOf(.cpusar));
    try j.field("refused_stores", unit.locked_writes);
    try j.field("reserved_stores", unit.reserved_writes);
    try j.close('}');
}
