//! The `storage` object of `--report json` (RA8EMU-360): the OSPI clock
//! order, the DOTF channels, the XSPI flash, the card on the SD host
//! controller and the card on the SPI line, the same facts
//! report/storage.zig prints. Every key is always present; the DOTF list
//! holds only the channels the firmware touched.
const Board = @import("ra8_board").board.Board;

/// The whole `storage` object, keyed inside the document.
pub fn section(j: anytype, board: *Board) !void {
    try j.open("storage", '{');
    try j.field("ospi_early_releases", board.octa.early_releases);
    try cipher(j, board);
    try flash(j, board);
    try card(j, board);
    try spiCard(j, board);
    try j.close('}');
}

fn cipher(j: anytype, board: *Board) !void {
    try j.open("dotf", '[');
    for (&board.cipher.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("mode", unit.mode().name());
        try j.field("key_size", unit.keySize().name());
        try j.field("pages", unit.pages());
        try j.field("start", unit.start());
        try j.field("self_tests", unit.self_tests);
        try j.field("staged_words", unit.staged);
        try j.field("staged_dark", unit.staged_dark);
        try j.field("out_of_window", unit.out_of_window);
        try j.field("reversed_areas", unit.reversed_areas);
        try j.field("live_area_writes", unit.live_area_writes);
        try j.close('}');
    }
    try j.close(']');
}

fn flash(j: anytype, board: *Board) !void {
    const unit = &board.flash;
    try j.open("xspi_flash", '{');
    try j.field("reads", unit.reads);
    try j.field("programs", unit.programs);
    try j.field("erases", unit.erases);
    try j.field("sectors_held", board.nor.live());
    try j.field("refused_unarmed", unit.unarmed);
    try j.field("refused_oversized", unit.oversized);
    try j.field("refused_out_of_part", unit.out_of_part);
    try j.field("wrapped_programs", unit.wrapped);
    try j.field("refused_ints_stores", unit.faked);
    try j.field("lost_programs", unit.lost);
    try j.field("stalled", unit.stalled);
    try j.close('}');
}

fn card(j: anytype, board: *Board) !void {
    const host = &board.card;
    try j.open("sdhi", '{');
    try j.field("reads", host.reads);
    try j.field("writes", host.writes);
    try j.field("blocks_held", host.card.held());
    try j.field("bus_width", host.lanes());
    try j.field("refused_unselected", host.out_of_state);
    try j.field("refused_in_reset", host.while_reset);
    try j.field("refused_response_stores", host.faked);
    try j.field("starved_buffer", host.starved);
    try j.field("refused_narrow", host.narrow);
    try j.field("refused_past_end", board.host_card.past_end);
    try j.field("ended_on_refusal", host.lost);
    try j.close('}');
}

fn spiCard(j: anytype, board: *Board) !void {
    const sd = &board.sd;
    try j.open("sd_spi", '{');
    if (board.sd_volume) |volume| {
        try j.open("volume", '{');
        try j.field("kind", volume.kind.text());
        try j.field("sectors", volume.layout.total_sectors);
        try j.field("sectors_per_cluster", volume.layout.sectors_per_cluster);
        try j.field("clusters", volume.layout.clusters);
        try j.field("fat_sectors", volume.layout.fat_sectors);
        try j.field("cleared", volume.cleared);
        try j.close('}');
    } else try j.field("volume", null);
    try j.field("commands", sd.commands);
    try j.field("reads", sd.reads);
    try j.field("writes", sd.writes);
    try j.field("blocks_held", sd.img.held());
    try j.field("refused_uninit", sd.uninit);
    try j.field("refused_past_end", sd.past_end);
    try j.field("refused_crc", sd.crc_rejects);
    try j.field("refused_erase_sequence", sd.erase_seq);
    try j.field("erased", sd.erased);
    try j.close('}');
}
