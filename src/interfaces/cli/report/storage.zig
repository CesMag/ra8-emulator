//! The storage part of the end-of-run report: what the firmware did to the
//! octal NOR flash and to the two cards, one on the SD host controller and
//! one on the SPI line, and the commands each engine refused.
const Board = @import("ra8_board").board.Board;
const Writer = @import("../report.zig").Writer;

/// Every storage path, in the order it was added to the board: the octal NOR
/// flash, the card on the SD host controller, then the card on the SPI line.
pub fn sections(board: *Board, out: Writer) !void {
    try flash(board, out);
    try cipher(board, out);
    try card(board, out);
    try spiCard(board, out);
}

/// The order the OSPI came out of module stop in. Silent on a run that
/// either left MSTPB16/B17 alone or handshook OCTACKCR first, which is what
/// every well-behaved driver does, so the line only ever marks the bug.
fn clock(board: *Board, out: Writer) !void {
    const unit = &board.octa;
    if (unit.quiet()) return;
    try out.print(
        "OCTACLK: {d} OSPI module-stop release(s) BEFORE the clock was stable, " ++
            "MSTPB16/B17 need the OCTACKCR handshake first\n",
        .{unit.early_releases},
    );
}

/// One line per DOTF channel the firmware touched. Nothing is decrypted
/// here, so what is worth saying is what the driver asked the block for: the
/// conversion area it programmed, the cipher it selected, the self-tests it
/// ran, and the key or IV words it pushed into the staging window.
fn cipher(board: *Board, out: Writer) !void {
    for (&board.cipher.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "DOTF{d}: {s}, {s}, {d} page(s) from 0x{X:0>8}\n",
            .{ index, unit.mode().name(), unit.keySize().name(), unit.pages(), unit.start() },
        );
        if (unit.self_tests != 0) {
            try out.print(
                "DOTF{d}: {d} self-test(s), REG00 bit 20 auto-cleared\n",
                .{ index, unit.self_tests },
            );
        }
        if (unit.staged != 0) {
            try out.print(
                "DOTF{d}: {d} word(s) staged through REG03\n",
                .{ index, unit.staged },
            );
        }
        if (unit.staged_dark != 0) {
            try out.print(
                "DOTF{d}: {d} word(s) staged with the AES core switched off\n",
                .{ index, unit.staged_dark },
            );
        }
        if (unit.out_of_window != 0) {
            try out.print(
                "DOTF{d}: {d} conversion area(s) programmed outside this channel's XSPI window\n",
                .{ index, unit.out_of_window },
            );
        }
        if (unit.reversed_areas != 0) {
            try out.print(
                "DOTF{d}: {d} conversion area(s) with the start above the end, which is prohibited\n",
                .{ index, unit.reversed_areas },
            );
        }
        if (unit.live_area_writes != 0) {
            try out.print(
                "DOTF{d}: {d} conversion area store(s) made while the core was decrypting\n",
                .{ index, unit.live_area_writes },
            );
        }
    }
}

/// One line per run that clocked SD commands down the SPI line. A transfer
/// before the card was brought up, a block off the end of it, a payload whose
/// checksum did not match, and an erase with no range latched are all things
/// dev let pass, so each is reported apart from the blocks that moved.
fn spiCard(board: *Board, out: Writer) !void {
    const sd = &board.sd;
    if (board.sd_volume) |volume| {
        try out.print(
            "SD over SPI: card formatted {s}, {d} sector(s), {d} per cluster, {d} cluster(s), FAT {d} sector(s) x2\n",
            .{
                volume.kind.text(),
                volume.layout.total_sectors,
                volume.layout.sectors_per_cluster,
                volume.layout.clusters,
                volume.layout.fat_sectors,
            },
        );
        if (volume.cleared != 0) {
            try out.print(
                "SD over SPI: format cleared {d} block(s) the card was still holding in the metadata region\n",
                .{volume.cleared},
            );
        }
    }
    if (sd.quiet()) return;
    try out.print(
        "SD over SPI: {d} command(s), {d} block read(s), {d} block write(s), {d} block(s) holding data\n",
        .{ sd.commands, sd.reads, sd.writes, sd.img.held() },
    );
    if (sd.uninit != 0) {
        try out.print(
            "SD over SPI: REFUSED {d} transfer(s), the card never completed ACMD41\n",
            .{sd.uninit},
        );
    }
    if (sd.past_end != 0) {
        try out.print(
            "SD over SPI: REFUSED {d} block(s) addressed past the end of the card\n",
            .{sd.past_end},
        );
    }
    if (sd.crc_rejects != 0) {
        try out.print(
            "SD over SPI: REFUSED {d} write payload(s) whose CRC16 did not match\n",
            .{sd.crc_rejects},
        );
    }
    if (sd.erase_seq != 0) {
        try out.print(
            "SD over SPI: REFUSED {d} erase(s) with no block range latched\n",
            .{sd.erase_seq},
        );
    }
    if (sd.erased != 0) {
        try out.print("SD over SPI: {d} block(s) erased back to zeros\n", .{sd.erased});
    }
}

/// One line per run that touched the flash. A program or erase that arrived
/// with the write-enable latch clear does nothing on silicon, and a
/// descriptor asking for more than slot 0 holds is a driver bug dev would
/// have run anyway, so both are reported apart from the work that landed.
fn flash(board: *Board, out: Writer) !void {
    const unit = &board.flash;
    try clock(board, out);
    if (unit.quiet()) return;
    try out.print(
        "XSPI flash: {d} read(s), {d} program(s), {d} erase(s), {d} sector(s) holding data\n",
        .{ unit.reads, unit.programs, unit.erases, board.nor.live() },
    );
    if (unit.unarmed != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} program/erase(s) with the write-enable latch clear\n",
            .{unit.unarmed},
        );
    }
    if (unit.oversized != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} descriptor(s) asking for more than the 8 bytes slot 0 holds\n",
            .{unit.oversized},
        );
    }
    if (unit.out_of_part != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} command(s) running off the end of the part\n",
            .{unit.out_of_part},
        );
    }
    if (unit.wrapped != 0) {
        try out.print(
            "XSPI flash: {d} program(s) WRAPPED to the start of their own 256-byte page\n",
            .{unit.wrapped},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} store(s) to INTS, firmware cannot raise a completion itself\n",
            .{unit.faked},
        );
    }
    if (unit.lost != 0) {
        try out.print("XSPI flash: {d} program(s) LOST, no room to hold the sector\n", .{unit.lost});
    }
    if (unit.stalled != 0) {
        try out.print(
            "XSPI flash: {d} command(s) STALLED, TRREQ cannot retire on an OSPI uncovered early\n",
            .{unit.stalled},
        );
    }
}

/// One line per run that talked to the SD host controller. A block command
/// from a card that was never selected, a FIFO touched with no transfer in
/// flight, and a store to a response register are all things dev let pass,
/// so each is reported apart from the blocks that actually moved.
fn card(board: *Board, out: Writer) !void {
    const host = &board.card;
    if (host.quiet()) return;
    try out.print(
        "SDHI card: {d} block read(s), {d} block write(s), {d} block(s) holding data, {d}-bit bus\n",
        .{ host.reads, host.writes, host.card.held(), host.lanes() },
    );
    if (host.out_of_state != 0) {
        try out.print(
            "SDHI card: REFUSED {d} block command(s), the card was not selected\n",
            .{host.out_of_state},
        );
    }
    if (host.while_reset != 0) {
        try out.print(
            "SDHI card: REFUSED {d} command(s) issued while SOFT_RST was asserted\n",
            .{host.while_reset},
        );
    }
    if (host.faked != 0) {
        try out.print(
            "SDHI card: REFUSED {d} store(s) to a response register\n",
            .{host.faked},
        );
    }
    if (host.starved != 0) {
        try out.print(
            "SDHI card: {d} SD_BUF0 access(es) with no transfer in flight\n",
            .{host.starved},
        );
    }
    if (host.narrow != 0) {
        try out.print(
            "SDHI card: REFUSED {d} SD_BUF0 access(es) narrower than the 32-bit port\n",
            .{host.narrow},
        );
    }
    if (board.host_card.past_end != 0) {
        try out.print(
            "SDHI card: REFUSED {d} block(s) addressed past the end of the card\n",
            .{board.host_card.past_end},
        );
    }
    if (host.lost != 0) {
        try out.print(
            "SDHI card: {d} data phase(s) ENDED on a block the card refused, the blocks before it stayed\n",
            .{host.lost},
        );
    }
}
