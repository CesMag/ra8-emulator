//! The network part of the end-of-run report: the frames a CAN controller
//! actually put on its internal loopback and the ones it only wrote down,
//! where the Ethernet PTP timers got to, and what the AT modem on the
//! MikroBUS UART was asked.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const ether = @import("ether.zig");
const riic_report = @import("riic.zig");
const modem_line = @import("ra8_components").modem_at;
const pi4ioe = @import("ra8_components").pi4ioe;
const ov5640 = @import("ra8_components").ov5640;
const gt911 = @import("ra8_components").gt911;
const lsm6dso = @import("ra8_components").lsm6dso;
const max17048 = @import("ra8_components").max17048;

/// One block per controller that saw traffic. A transmit made out of
/// operation mode moves nothing on silicon, and a delivery with no receive
/// stage free is a frame the reader never sees, so both are reported apart
/// from the frames that landed.
pub fn sections(board: *Board, out: Writer) !void {
    try can(board, out);
    try ptp(board, out);
    try modem(board, out);
    try i2c(board, out);
    try ether.sections(board, out);
}

/// The I2C bus: the controller's own lines first, then a line for each part
/// sitting on it.
fn i2c(board: *Board, out: Writer) !void {
    try riic_report.channels(board, out);
    try expander(board, out);
    try camera(board, out);
    try touchline(board, out);
    try panel(board, out);
    try imu(board, out);
    try gauge(board, out);
    try optional(board, out);
}

/// Which optional parts the run fitted. The Click-module parts are not on the
/// EK-RA8D2, so a run without `--click` answers nothing at their addresses,
/// and a firmware probing for them should be read against this line.
fn optional(board: *Board, out: Writer) !void {
    const wire = &board.wire;
    if (!wire.click and wire.quiet()) return;
    const addresses = .{ @as(u8, lsm6dso.address), @as(u8, max17048.address) };
    if (wire.click) {
        try out.print("I2C optional parts: Click module fitted, LSM6DSO 0x{X:0>2} and MAX17048 0x{X:0>2}\n", addresses);
    } else {
        try out.print("I2C optional parts: none fitted, nothing answers at 0x{X:0>2} or 0x{X:0>2} (--click fits them)\n", addresses);
    }
}

/// The LSM6DSO IMU at 0x6B. A store into a register the part measures for
/// itself and an output read taken while that half of the part was still in
/// power-down are both things dev answered anyway, so each is reported apart
/// from the bursts that were served.
fn imu(board: *Board, out: Writer) !void {
    const part = &board.wire.imu;
    if (part.quiet()) return;
    try out.print(
        "I2C imu 0x{X:0>2}: {d} burst(s) read, {d} configuration write(s), accelerometer {s}, gyroscope {s}",
        .{
            @as(u8, lsm6dso.address),
            part.reads,
            part.writes,
            if (part.accelRunning()) "running" else "in power-down",
            if (part.gyroRunning()) "running" else "in power-down",
        },
    );
    if (part.unstarted != 0) {
        try out.print(", {d} OUTPUT READ(S) FROM A PART THAT WAS NEVER STARTED REFUSED", .{part.unstarted});
    }
    if (part.read_only != 0) {
        try out.print(", {d} STORE(S) INTO A REGISTER THE PART OWNS REFUSED", .{part.read_only});
    }
    if (part.bad_pointer != 0) {
        try out.print(", {d} POINTER(S) PAST THE END OF THE MAP REFUSED", .{part.bad_pointer});
    }
    if (part.past_end != 0) {
        try out.print(", {d} byte(s) asked for past the end of the map", .{part.past_end});
    }
    try out.print("\n", .{});
}

/// The MAX17048 fuel gauge at 0x36, and the battery state the run gave it.
fn gauge(board: *Board, out: Writer) !void {
    const part = &board.wire.gauge;
    if (part.quiet()) return;
    try out.print(
        "I2C fuel gauge 0x{X:0>2}: {d}% and {s}, {d} word(s) read, {d} write(s)",
        .{
            @as(u8, max17048.address),
            part.battery.soc_pct,
            if (part.battery.charging) "charging" else "discharging",
            part.reads,
            part.writes,
        },
    );
    if (part.read_only != 0) {
        try out.print(", {d} STORE(S) INTO A REGISTER THE GAUGE MEASURES REFUSED", .{part.read_only});
    }
    if (part.misaligned != 0) {
        try out.print(", {d} POINTER(S) INSIDE A WORD REFUSED", .{part.misaligned});
    }
    if (part.unmapped != 0) {
        try out.print(", {d} POINTER(S) AT A REGISTER IT DOES NOT HAVE REFUSED", .{part.unmapped});
    }
    if (part.torn != 0) {
        try out.print(", {d} half-written word(s) lost at STOP", .{part.torn});
    }
    if (part.resets != 0) {
        try out.print(", {d} power-on-reset command(s) carried out", .{part.resets});
    }
    try out.print("\n", .{});
}

/// The I3C channel driven in legacy I2C mode. A byte put in the buffer with
/// no transaction open, a read past what the part had to say, and a role
/// change on top of a live transfer are all things dev went along with, so
/// each is reported apart from the transfers that completed.
fn touchline(board: *Board, out: Writer) !void {
    const unit = &board.wire.touchline;
    if (unit.quiet()) return;
    try out.print(
        "I3C: {d} transfer(s), {d} byte(s) out, {d} byte(s) in, {d} address(es) NACKed",
        .{ unit.transfers, unit.sent, unit.received, unit.nacks },
    );
    if (unit.reserved != 0) {
        try out.print(", {d} ADDRESS(ES) I2C KEEPS FOR ITSELF REFUSED", .{unit.reserved});
    }
    if (unit.no_start != 0) {
        try out.print(", {d} DATA WRITE(S) WITH NO TRANSACTION OPEN", .{unit.no_start});
    }
    if (unit.st_busy != 0) {
        try out.print(", {d} START(S) ON A BUSY BUS REFUSED", .{unit.st_busy});
    }
    if (unit.rs_idle != 0) {
        try out.print(", {d} REPEATED START(S) WITH NOTHING TO REPEAT", .{unit.rs_idle});
    }
    if (unit.overdrain != 0) {
        try out.print(", {d} READ(S) PAST WHAT THE PART HAD TO SAY", .{unit.overdrain});
    }
    if (unit.role_clash != 0) {
        try out.print(", {d} ROLE CHANGE(S) ON TOP OF A LIVE TRANSFER REFUSED", .{unit.role_clash});
    }
    if (unit.resets != 0) {
        try out.print(
            ", {d} RSTCTL software reset(s) took the channel back to idle",
            .{unit.resets},
        );
    }
    if (unit.reset_busy != 0) {
        try out.print(", {d} of them with a transaction still open", .{unit.reset_busy});
    }
    try out.print("\n", .{});
    try responder(board, out);
}

/// The channel's own responder half, live once the firmware claims an
/// address of its own.
fn responder(board: *Board, out: Writer) !void {
    const half = &board.wire.touchline.responder;
    if (half.quiet()) return;
    try out.print(
        "I3C target: own 0x{X:0>2}, {d} controller write+read cycle(s), echo {s}",
        .{ @as(u8, half.own_address), half.cycles, if (half.mismatched) "MISMATCHED" else "matched" },
    );
    if (half.unprompted != 0) {
        try out.print(", {d} ECHO(ES) WITH NOTHING TO ECHO REFUSED", .{half.unprompted});
    }
    if (half.starved != 0) {
        try out.print(", {d} drain(s) with nothing written", .{half.starved});
    }
    if (half.refused != 0) {
        try out.print(", {d} OWN ADDRESS(ES) I2C KEEPS FOR ITSELF REFUSED", .{half.refused});
    }
    try out.print("\n", .{});
}

/// The GT911 touch controller at 0x5D.
fn panel(board: *Board, out: Writer) !void {
    const part = &board.wire.panel;
    if (part.quiet()) return;
    try out.print(
        "I2C touch 0x{X:0>2}: {d} contact(s) drained, {d} frame(s) acked",
        .{ @as(u8, gt911.address), part.reported, part.acked },
    );
    if (part.phantom != 0) {
        try out.print(", {d} POINT READ(S) WITH NO CONTACT REFUSED", .{part.phantom});
    }
    if (part.unknown != 0) {
        try out.print(", {d} read(s) at a register this model does not carry", .{part.unknown});
    }
    try out.print("\n", .{});
}

/// The PI4IOE5V6408 port expander at 0x43.
fn expander(board: *Board, out: Writer) !void {
    const part = &board.wire.expander;
    if (part.quiet()) return;
    try out.print("I2C expander 0x{X:0>2}: {d} register write(s)", .{ @as(u8, pi4ioe.address), part.writes });
    if (part.bad_pointer != 0) {
        try out.print(", {d} POINTER(S) AT A REGISTER IT DOES NOT HAVE REFUSED", .{part.bad_pointer});
    }
    if (part.dropped != 0) {
        try out.print(", {d} payload byte(s) dropped with no register selected", .{part.dropped});
    }
    try out.print("\n", .{});
}

/// The camera's SCCB side at 0x3C.
fn camera(board: *Board, out: Writer) !void {
    const part = &board.wire.sensor;
    if (part.quiet()) return;
    try out.print(
        "I2C camera 0x{X:0>2}: {d} chip-id byte(s) read, {d} configuration write(s)",
        .{ @as(u8, ov5640.address), part.id_reads, part.writes },
    );
    if (part.unmodelled != 0) {
        try out.print(", {d} write(s) to a register this model does not carry", .{part.unmodelled});
    }
    try out.print("\n", .{});
}

/// Everything the receive FIFO got wrong on one controller: the frames that
/// never reached a stage, and what CFDRFSTS said about it. Apart from can()
/// because the register's own flags are a story of their own, and because
/// that function had grown past the length gate.
fn receiveFifo(index: usize, unit: anytype, out: Writer) !void {
    if (unit.lost != 0) {
        try out.print("CANFD{d}: {d} frame(s) LOST, no receive stage free\n", .{ index, unit.lost });
    }
    if (unit.rx_sts.lost_latched) {
        try out.print(
            "CANFD{d}: CFDRFSTS.RFMLT still standing, the overrun was never acknowledged\n",
            .{index},
        );
    }
    if (unit.rx_sts.acknowledged != 0) {
        try out.print(
            "CANFD{d}: {d} overrun acknowledgement(s) lowered CFDRFSTS.RFMLT\n",
            .{ index, unit.rx_sts.acknowledged },
        );
    }
    if (unit.rx_sts.invented != 0) {
        try out.print(
            "CANFD{d}: REFUSED {d} store(s) to CFDRFSTS that would have raised a flag the controller owns\n",
            .{ index, unit.rx_sts.invented },
        );
    }
    if (unit.unarmed != 0) {
        try out.print(
            "CANFD{d}: {d} frame(s) DROPPED, the receive FIFO was never enabled\n",
            .{ index, unit.unarmed },
        );
    }
    if (unit.rx.refused != 0) {
        try out.print(
            "CANFD{d}: REFUSED {d} store(s) asking for CFDRFCC.RFE, out of reset or with no depth\n",
            .{ index, unit.rx.refused },
        );
    }
    if (unit.starved != 0) {
        try out.print("CANFD{d}: {d} pop(s) of an empty receive FIFO\n", .{ index, unit.starved });
    }
}

/// One block per CAN controller that saw traffic.
fn can(board: *Board, out: Writer) !void {
    for (&board.can.units, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "CANFD{d}: {d} frame(s) transmitted, {d} received, {d} waiting in the FIFO\n",
            .{ index, unit.sent, unit.received, unit.queue.len() },
        );
        if (unit.refused != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} transmit(s) out of operation mode, the channel was never started\n",
                .{ index, unit.refused },
            );
        }
        if (unit.filtered != 0) {
            try out.print(
                "CANFD{d}: {d} frame(s) dropped by the acceptance filter\n",
                .{ index, unit.filtered },
            );
        }
        try receiveFifo(index, unit, out);
        if (unit.tx.stalled != 0) {
            try out.print(
                "CANFD{d}: DROPPED {d} transmit request(s), CFDTMSTS.TMTRF was never cleared\n",
                .{ index, unit.tx.stalled },
            );
        }
        if (!unit.dozing.quiet()) {
            try out.print(
                "CANFD{d}: IGNORED {d} mode write(s), the sleep request was still standing\n",
                .{ index, unit.dozing.ignored() },
            );
        }
        if (unit.faked != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} store(s) into a status register the controller owns\n",
                .{ index, unit.faked },
            );
        }
        if (unit.faults.invented != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} store(s) to CFDCnERFL that would have raised an error flag the controller never saw\n",
                .{ index, unit.faults.invented },
            );
        }
        if (unit.faults.flags != 0) {
            try out.print("CANFD{d}: error flags standing: 0x{x:0>4}\n", .{ index, unit.faults.flags });
        }
    }
    if (board.can.wakes != 0) {
        try out.print("CANFD0: {d} receive event(s) raised\n", .{board.can.wakes});
    }
}

/// One line per PTP timer unit that ran, then the things firmware got
/// wrong. A store into a register the timer owns and an offset that was
/// not a time are both bench-visible bugs, so they are reported apart from
/// the time that was actually kept.
fn ptp(board: *Board, out: Writer) !void {
    const unit = &board.ptp;
    if (board.wire.quiet()) return;
    for (&unit.units, 0..) |*timer, index| {
        if (!timer.ran()) continue;
        const now = timer.now();
        try out.print(
            "GPTP timer{d}: {d}.{d:0>9} s after {d} boundaries, {s}\n",
            .{ index, now.sec, now.nsec, timer.ticks, if (timer.enabled) "running" else "stopped" },
        );
    }
    if (unit.unknown_unit != 0) {
        try out.print(
            "GPTP: {d} enable bit(s) naming a timer this part does not have\n",
            .{unit.unknown_unit},
        );
    }
    if (unit.denormal != 0) {
        try out.print(
            "GPTP: {d} offset(s) carried, the nanoseconds field held a second or more\n",
            .{unit.denormal},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "GPTP: REFUSED {d} store(s) into a monitoring register the timer owns\n",
            .{unit.faked},
        );
    }
    if (unit.read_only != 0) {
        try out.print("GPTP: REFUSED {d} store(s) into PTPIPV, which is read-only\n", .{unit.read_only});
    }
}

/// What the modem answered, then the two ways a run can look answered and
/// not be: a line too long to be the command the driver sent, and a command
/// left on the line when the run ended.
fn modem(board: *Board, out: Writer) !void {
    const unit = &board.modem;
    if (board.wire.quiet()) return;
    try out.print(
        "AT modem: {d} command(s) answered, {d} refused with +CME ERROR\n",
        .{ unit.answered, unit.errors },
    );
    if (unit.overlong != 0) {
        try out.print(
            "AT modem: REFUSED {d} command line(s) longer than the modem accepts\n",
            .{unit.overlong},
        );
    }
    const left = unit.pending();
    if (left.len != 0) {
        try out.print("AT modem: \"{s}\" was left on the line, never terminated\n", .{left});
    }
    const channel = &board.serial.channels[modem_line.line_channel];
    if (channel.unheard != 0) {
        try out.print(
            "SCI{d}: {d} reply byte(s) LOST, the receiver was never enabled\n",
            .{ modem_line.line_channel, channel.unheard },
        );
    }
}
