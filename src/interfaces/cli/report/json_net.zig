//! The `network` object of `--report json` (RA8EMU-362): the CAN-FD
//! controllers, the gPTP timers, the AT modem on the MikroBUS UART and the
//! parts on the I2C/I3C bus, the same facts report/network.zig prints.
//! Every key is always present; lists hold only the units that did
//! anything. The R-Switch Ethernet lines (report/ether.zig) and the USB
//! host lines follow under their own subtask.
const Board = @import("../../../board/board.zig").Board;
const modem_line = @import("ra8_components").modem_at;
const json_i2c = @import("json_i2c.zig");

/// The whole `network` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("network", '{');
    try can(j, board);
    try j.field("can_wakes", board.can.wakes);
    try ptp(j, board);
    try modem(j, board);
    try json_i2c.parts(j, board);
    try j.close('}');
}

fn can(j: anytype, board: *Board) !void {
    try j.open("can", '[');
    for (&board.can.units, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("transmitted", unit.sent);
        try j.field("received", unit.received);
        try j.field("waiting", unit.queue.len());
        try j.field("refused_out_of_operation", unit.refused);
        try j.field("filtered", unit.filtered);
        try j.field("lost_no_stage", unit.lost);
        try j.field("overrun_standing", unit.rx_sts.lost_latched);
        try j.field("overrun_acks", unit.rx_sts.acknowledged);
        try j.field("refused_rfsts_stores", unit.rx_sts.invented);
        try j.field("dropped_fifo_off", unit.unarmed);
        try j.field("refused_rfe_stores", unit.rx.refused);
        try j.field("empty_pops", unit.starved);
        try j.field("dropped_tmtrf_standing", unit.tx.stalled);
        try j.field("ignored_mode_writes", unit.dozing.ignored());
        try j.field("refused_status_stores", unit.faked);
        try j.field("refused_erfl_stores", unit.faults.invented);
        try j.field("error_flags", unit.faults.flags);
        try j.close('}');
    }
    try j.close(']');
}

fn ptp(j: anytype, board: *Board) !void {
    const unit = &board.ptp;
    try j.open("gptp", '{');
    try j.open("timers", '[');
    for (&unit.units, 0..) |*timer, index| {
        if (!timer.ran()) continue;
        const now = timer.now();
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("seconds", now.sec);
        try j.field("nanoseconds", now.nsec);
        try j.field("boundaries", timer.ticks);
        try j.field("running", timer.enabled);
        try j.close('}');
    }
    try j.close(']');
    try j.field("unknown_unit_bits", unit.unknown_unit);
    try j.field("denormal_offsets", unit.denormal);
    try j.field("refused_monitor_stores", unit.faked);
    try j.field("refused_ptpipv_stores", unit.read_only);
    try j.close('}');
}

fn modem(j: anytype, board: *Board) !void {
    const unit = &board.modem;
    const left = unit.pending();
    try j.open("modem", '{');
    try j.field("answered", unit.answered);
    try j.field("cme_errors", unit.errors);
    try j.field("refused_overlong", unit.overlong);
    try j.field("unterminated", if (left.len != 0) left else null);
    try j.field("sci_channel", modem_line.line_channel);
    try j.field("lost_reply_bytes", board.serial.channels[modem_line.line_channel].unheard);
    try j.close('}');
}
