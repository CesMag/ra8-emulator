//! The `i2c_parts` object inside `network` of `--report json`
//! (RA8EMU-362): each part sitting on the I2C/I3C bus, the same facts the
//! part lines of report/network.zig print. The RIIC controller itself is
//! the top-level `riic` array (json_riic.zig). Every key is always present.
const Board = @import("ra8_board").board.Board;

/// The whole `i2c_parts` object, keyed inside `network`.
pub fn parts(j: anytype, board: *Board) !void {
    const wire = &board.wire;
    try j.open("i2c_parts", '{');
    try j.field("click_fitted", wire.click);
    try j.open("expander", '{');
    try j.field("writes", wire.expander.writes);
    try j.field("refused_bad_pointer", wire.expander.bad_pointer);
    try j.field("dropped_unselected", wire.expander.dropped);
    try j.close('}');
    try j.open("camera", '{');
    try j.field("id_reads", wire.sensor.id_reads);
    try j.field("writes", wire.sensor.writes);
    try j.field("unmodelled_writes", wire.sensor.unmodelled);
    try j.close('}');
    try j.open("touch", '{');
    try j.field("contacts_drained", wire.panel.reported);
    try j.field("frames_acked", wire.panel.acked);
    try j.field("refused_phantom_reads", wire.panel.phantom);
    try j.field("unmodelled_reads", wire.panel.unknown);
    try j.close('}');
    try i3c(j, board);
    try imu(j, board);
    try gauge(j, board);
    try j.close('}');
}

fn i3c(j: anytype, board: *Board) !void {
    const unit = &board.wire.touchline;
    const half = &unit.responder;
    try j.open("i3c", '{');
    try j.field("transfers", unit.transfers);
    try j.field("sent", unit.sent);
    try j.field("received", unit.received);
    try j.field("nacks", unit.nacks);
    try j.field("refused_reserved", unit.reserved);
    try j.field("writes_no_start", unit.no_start);
    try j.field("refused_busy_starts", unit.st_busy);
    try j.field("idle_restarts", unit.rs_idle);
    try j.field("overreads", unit.overdrain);
    try j.field("refused_role_clash", unit.role_clash);
    try j.field("resets", unit.resets);
    try j.field("resets_busy", unit.reset_busy);
    try j.open("target", '{');
    try j.field("own_address", @as(u8, half.own_address));
    try j.field("cycles", half.cycles);
    try j.field("mismatched", half.mismatched);
    try j.field("refused_unprompted", half.unprompted);
    try j.field("starved_drains", half.starved);
    try j.field("refused_reserved", half.refused);
    try j.close('}');
    try j.close('}');
}

fn imu(j: anytype, board: *Board) !void {
    const part = &board.wire.imu;
    try j.open("imu", '{');
    try j.field("bursts", part.reads);
    try j.field("writes", part.writes);
    try j.field("accel_running", part.accelRunning());
    try j.field("gyro_running", part.gyroRunning());
    try j.field("refused_unstarted", part.unstarted);
    try j.field("refused_read_only", part.read_only);
    try j.field("refused_bad_pointer", part.bad_pointer);
    try j.field("past_end", part.past_end);
    try j.close('}');
}

fn gauge(j: anytype, board: *Board) !void {
    const part = &board.wire.gauge;
    try j.open("gauge", '{');
    try j.field("soc_pct", part.battery.soc_pct);
    try j.field("charging", part.battery.charging);
    try j.field("reads", part.reads);
    try j.field("writes", part.writes);
    try j.field("refused_read_only", part.read_only);
    try j.field("refused_misaligned", part.misaligned);
    try j.field("refused_unmapped", part.unmapped);
    try j.field("torn_words", part.torn);
    try j.field("resets", part.resets);
    try j.close('}');
}
