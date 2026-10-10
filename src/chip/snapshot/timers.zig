//! The board's timer units in a snapshot (RA8EMU-662): RTC, AGT, GPT and
//! its PWM delay generator, GPTP, WDT and IWDT, as one `timers` section.
//!
//! SysTick needs nothing here: its CSR, RVR and CVR live in the PPB words
//! of guest memory, which the memory section already carries. Board wiring
//! (which board owns these units) is RA8EMU-660's.
const file = @import("ra8_snapshot").file;
const units = @import("ra8_snapshot").units;

pub const Error = units.Error;

/// The units in format order. `board` is anything with these fields: the
/// Board, or a test's stand-in. Appending is a format change.
fn of(board: anytype) @TypeOf(.{ &board.clock, &board.interval, &board.pwm, &board.pwm_delay, &board.ptp, &board.watchdog, &board.heartbeat }) {
    return .{ &board.clock, &board.interval, &board.pwm, &board.pwm_delay, &board.ptp, &board.watchdog, &board.heartbeat };
}

pub fn save(board: anytype, writer: anytype) !void {
    try units.save(writer, .timers, of(board));
}

pub fn load(board: anytype, bytes: []const u8) Error!void {
    try units.load(bytes, .timers, of(board));
}
