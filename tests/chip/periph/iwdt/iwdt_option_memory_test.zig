//! OFS0 read from the loaded image at reset, the way the boot ROM does.
const std = @import("std");
const ra8 = @import("ra8");

const iwdt = ra8.chip.periph.iwdt;
const option_memory = ra8.chip.periph.iwdt_option_memory;

const Image = struct {
    word: ?u32,

    pub fn readWord(self: *const Image, address: u32) !u32 {
        try std.testing.expectEqual(iwdt.ofs0.address, address);
        return self.word orelse error.Unmapped;
    }
};

test "an image that left OFS0 unwritten reads as erased and the IWDT stays stopped" {
    var watchdog: iwdt.Iwdt = .{};
    option_memory.apply(&watchdog, &Image{ .word = null });
    try std.testing.expectEqual(@as(?u32, iwdt.ofs0.erased), watchdog.option_word);
    try std.testing.expect(!watchdog.armed);
}

test "an image that clears IWDTSTRT auto-starts the IWDT" {
    var watchdog: iwdt.Iwdt = .{};
    const word = iwdt.ofs0.erased & ~iwdt.ofs0.field.strt;
    option_memory.apply(&watchdog, &Image{ .word = word });
    try std.testing.expectEqual(@as(?u32, word), watchdog.option_word);
    try std.testing.expect(watchdog.armed);
}
