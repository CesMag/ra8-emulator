//! The SCI part of the end-of-run report: what each channel moved, and the
//! console line the firmware printed through it. Split out of report.zig,
//! which was at the file-length limit.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;
const Host = @import("ra8_chip").periph.usbhs.Host;
const Echo = @import("ra8_components").usb.echo.Device;
const usb_cable = @import("usb/cable.zig");

/// One line per SCI channel that moved bytes, plus the last console line the
/// firmware printed. A TDR write made with CCR0.TE clear never leaves the
/// transmitter on silicon, so those are reported apart from the bytes that
/// did go out, and so are the accesses that landed in RDR or TDR without
/// naming the byte the character sits in.
pub fn sections(board: *Board, out: Writer) !void {
    if (board.serial.quiet()) return;
    for (&board.serial.channels, 0..) |*channel, index| {
        if (channel.quiet()) continue;
        try out.print(
            "SCI{d}: TX {d} bytes, RX {d} bytes, {d} dropped on a full queue",
            .{ index, channel.transmitted, channel.received, channel.rx.dropped },
        );
        if (channel.unsent != 0) {
            try out.print(", {d} WRITE(S) WITH TE CLEAR NEVER SENT", .{channel.unsent});
        }
        try out.print("\n", .{});
        if (channel.status_stores != 0) {
            try out.print(
                "SCI{d}: REFUSED {d} store(s) to CSR/FRSR/FTSR, the controller owns those words\n",
                .{ index, channel.status_stores },
            );
        }
        if (channel.errors.overruns != 0) {
            try out.print(
                "SCI{d}: {d} OVERRUN(S), CSR.ORER {s}\n",
                .{
                    index,
                    channel.errors.overruns,
                    if (channel.errors.overrun) "still standing" else "cleared by the driver",
                },
            );
        }
        if (channel.unnamed_reads != 0) {
            try out.print(
                "SCI{d}: REFUSED {d} load(s) of RDR above RDAT, the byte stayed queued\n",
                .{ index, channel.unnamed_reads },
            );
        }
        if (channel.lin.breaks != 0) {
            try out.print(
                "SCI{d} LIN: {d} break field(s) put on the wire, {d} timer period(s) long\n",
                .{ index, channel.lin.breaks, channel.lin.length() },
            );
        }
        if (channel.lin.unenabled != 0) {
            try out.print(
                "SCI{d} LIN: REFUSED {d} TCST pulse(s) with XCR0.BFE clear, no break was generated\n",
                .{ index, channel.lin.unenabled },
            );
        }
        if (channel.lin.status_stores != 0) {
            try out.print(
                "SCI{d} LIN: REFUSED {d} store(s) to XSR0/XSR1, the block owns those words\n",
                .{ index, channel.lin.status_stores },
            );
        }
        if (channel.unnamed_stores != 0) {
            try out.print(
                "SCI{d}: REFUSED {d} store(s) to TDR above TDAT, no character was sent\n",
                .{ index, channel.unnamed_stores },
            );
        }
        if (channel.idle_frames != 0) {
            try out.print(
                "SCI{d}: {d} Simple-SPI frame(s) clocked in off an idle line, 0xFF each\n",
                .{ index, channel.idle_frames },
            );
        }
    }
    if (board.serial.line.lines != 0) {
        try out.print("SCI console: {d} line(s), last \"{s}\"\n", .{ board.serial.line.lines, board.serial.line.slice() });
    }
}

/// One line per SPI channel the firmware touched. A store made with SPE
/// clear never reaches a wire on silicon, and a read of an empty receive
/// holding register is a frame dev would have served twice.
pub fn spi(board: *Board, out: Writer) !void {
    for (&board.spi.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "SPI{d}: SPE={d}, {d} frame(s) clocked, last 0x{X:0>2}, loopback={s}\n",
            .{
                index,
                @intFromBool(unit.enabled()),
                unit.frames,
                unit.last,
                if (unit.loopback()) "on" else "off",
            },
        );
        if (unit.width != 0 and unit.width != 8) {
            try out.print(
                "SPI{d}: frame {d} bit(s), {s}-first\n",
                .{ index, unit.width, if (unit.frameOf().lsb_first) "LSB" else "MSB" },
            );
        }
        if (unit.unnamed != 0) {
            try out.print(
                "SPI{d}: {d} frame(s) with an SPCMD0.SPB encoding no header names, clocked at the 8-bit default\n",
                .{ index, unit.unnamed },
            );
        }
        if (unit.refused != 0) {
            try out.print(
                "SPI{d}: REFUSED {d} SPDR store(s) with SPE clear, the channel was never started\n",
                .{ index, unit.refused },
            );
        }
        if (unit.starved != 0) {
            try out.print(
                "SPI{d}: {d} SPDR read(s) with the receive register empty, no frame had arrived\n",
                .{ index, unit.starved },
            );
        }
        if (unit.narrow_writes != 0) {
            try out.print(
                "SPI{d}: REFUSED {d} SPDR store(s) too narrow for the frame, no part frame was clocked\n",
                .{ index, unit.narrow_writes },
            );
        }
        if (unit.locked.ignored != 0) {
            try out.print(
                "SPI{d}: IGNORED {d} SPCR2 store(s) made with SPE set, the channel was already running\n",
                .{ index, unit.locked.ignored },
            );
        }
        if (unit.narrow_reads != 0) {
            try out.print(
                "SPI{d}: REFUSED {d} SPDR read(s) too narrow for the frame, the receive register kept it\n",
                .{ index, unit.narrow_reads },
            );
        }
    }
}

/// The RTT ring, once a firmware has published one. A run with no RTT user
/// says nothing here. The unfinished tail is reported rather than dropped:
/// text the firmware never ended with a newline is still text it wrote, and
/// a line this model cut short is counted apart from the lines it did end.
pub fn trace(board: *Board, out: Writer) !void {
    const probe = &board.trace;
    if (probe.quiet()) return;
    if (probe.found) |at| {
        try out.print(
            "SEGGER RTT: control block @0x{X:0>8}, {d} byte(s) drained, {d} line(s)\n",
            .{ at, probe.drained, probe.line.lines },
        );
    } else {
        try out.print(
            "SEGGER RTT: no live control block, {d} byte(s) drained, {d} line(s)\n",
            .{ probe.drained, probe.line.lines },
        );
    }
    if (probe.line.lines != 0) {
        try out.print("SEGGER RTT: last \"{s}\"\n", .{probe.line.slice()});
    }
    if (probe.line.pending().len != 0) {
        try out.print(
            "SEGGER RTT: {d} byte(s) drained with no newline behind them, \"{s}\"\n",
            .{ probe.line.pending().len, probe.line.pending() },
        );
    }
    if (probe.line.wrapped != 0) {
        try out.print(
            "SEGGER RTT: {d} line(s) CUT at {d} characters, the firmware never ended them\n",
            .{ probe.line.wrapped, @as(u32, @intCast(probe.line.pending().len + probe.line.slice().len)) },
        );
    }
    if (probe.off_ram != 0) {
        try out.print(
            "SEGGER RTT: REFUSED {d} control block(s) whose ring was not in RAM\n",
            .{probe.off_ram},
        );
    }
    if (probe.forgotten != 0) {
        try out.print(
            "SEGGER RTT: {d} block(s) went away mid-run and the scan was re-armed\n",
            .{probe.forgotten},
        );
    }
}

/// The USB host controller: where its bring-up got to, and what it refused on
/// the way. A controller nothing touched says nothing.
pub fn usb(board: *Board, out: Writer) !void {
    const host = &board.usb.host;
    if (host.quiet()) return;
    try out.print(
        "USBHS host: {s}, {s} role, {d} port reset(s), speed {s}\n",
        .{
            if (host.phy.powered()) "on" else "off",
            if (host.phy.host()) "host" else "device",
            host.phy.resets,
            @tagName(host.phy.speed),
        },
    );
    if (host.phy.blind != 0) {
        try out.print(
            "  {d} line-state read(s) answered SE0 with something on the far end: " ++
                "CNEN, or VBUSEN as a host or DPRPU as a device, was clear\n",
            .{host.phy.blind},
        );
    }
    if (host.pll.locks != 0 or host.pll.stalled != 0) {
        try out.print(
            "  PHY PLL: {d} lock(s), {d} read(s) answered unlocked\n",
            .{ host.pll.locks, host.pll.stalled },
        );
    }
    if (host.xfer.setups != 0 and board.usb.cable == null) {
        try out.print(
            "  {d} SETUP(s), device {s} at address {d}, {d} stalled\n",
            .{
                host.xfer.setups,
                @tagName(board.usb.echo.state),
                board.usb.echo.address,
                host.xfer.stalls,
            },
        );
    }
    if (host.xfer.refused_out != 0) {
        try out.print(
            "  {d} OUT packet(s) the device REFUSED, {d} byte(s) still staged for a retry\n",
            .{ host.xfer.refused_out, host.xfer.refused_bytes },
        );
    }
    try usbRefused(host, if (board.usb.cable) |*plugged| plugged else null, &board.usb.echo, out);
}

/// What the controller turned away, in the order the driver would meet it:
/// the window's own refusals, then the two data ports, then the transfers.
/// Split out of usb() above, which was at the function-length limit.
fn usbRefused(host: *const Host, cable: ?*const usb_cable.Loop, echo: *const Echo, out: Writer) !void {
    try usb_cable.section(cable, out);
    if (host.refusals() == 0) return;
    try out.print(
        "  refused: {d} odd offset, {d} with the module off, {d} status write(s), " ++
            "{d} in device role, {d} bad pipe, {d} packet size\n",
        .{
            host.misaligned,
            host.off,
            host.read_only + host.phy.read_only,
            host.phy.not_host,
            host.pipes.bad_pipe + host.pipes.dcp_config + host.xfer.port.bad_pipe,
            host.pipes.too_big + host.xfer.port.oversize,
        },
    );
    const data = &host.xfer.data;
    if (data.refusals() != 0) {
        try out.print(
            "  data ports refused: {d} bad pipe, " ++
                "{d} pipe already held, {d} wrong access width, {d} against the pipe's direction\n",
            .{
                data.ports[0].bad_pipe + data.ports[1].bad_pipe,
                data.ports[0].contended + data.ports[1].contended,
                data.ports[0].bad_width + data.ports[1].bad_width,
                data.ports[0].wrong_way + data.ports[1].wrong_way,
            },
        );
    }
    if (host.xfer.refusals() + echo.refusals() == host.xfer.stalls + data.refusals()) return;
    try out.print(
        "  transfers refused: {d} with nothing on the bus, {d} stray CCPL, " ++
            "{d} FIFO not ready, {d} drained past the packet, " ++
            "{d} out of order at the device\n",
        .{
            host.xfer.no_device,
            host.xfer.stray_ccpl,
            host.xfer.port.not_ready,
            host.xfer.port.overdrain,
            echo.out_of_order,
        },
    );
}
