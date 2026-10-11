//! Covers src/chip/periph/scb/scb.zig: the AIRCR key gate, the architectural read-back
//! and the software-reset request the firmware makes through it.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.chip.core.memmap;
const scb = ra8.chip.periph.scb;

/// One PPB word, which is all AIRCR needs. The real engine is a heavier
/// fixture than this test wants and the model only ever touches one address.
const Ppb = struct {
    word: u32 = 0,

    pub fn readWord(self: *Ppb, address: u32) !u32 {
        try std.testing.expectEqual(memmap.scb.aircr, address);
        return self.word;
    }

    pub fn writeWord(self: *Ppb, address: u32, value: u32) !void {
        try std.testing.expectEqual(memmap.scb.aircr, address);
        self.word = value;
    }
};

/// A keyed write the firmware would make, as one word.
fn keyed(bits: u32) u32 {
    return (scb.key.write << scb.key.shift) | bits;
}

test "a fresh model is quiet" {
    const unit = scb.Scb.init();
    try std.testing.expect(unit.quiet());
    try std.testing.expectEqual(@as(u32, 0), unit.requests);
}

test "priming puts the key status in the register" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    try std.testing.expectEqual(scb.key.status, ppb.word);
}

test "a boundary with no write decides nothing" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expect(unit.quiet());
}

test "a keyed reset request is honoured" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(scb.field.sysresetreq);
    try std.testing.expect(try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 1), unit.requests);
    try std.testing.expectEqual(@as(u32, 0), unit.rejected);
}

test "a reset request without the key resets nothing" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = scb.field.sysresetreq;
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 0), unit.requests);
    try std.testing.expectEqual(@as(u32, 1), unit.rejected);
}

test "a discarded write leaves the register as it was" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = scb.field.sysresetreq;
    _ = try unit.poll(&ppb);
    try std.testing.expectEqual(scb.key.status, ppb.word);
}

test "a wrong key is as good as none" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = (0x05FB << scb.key.shift) | scb.field.sysresetreq;
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 1), unit.rejected);
}

test "the read-back key is the status half, not the written one" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(scb.field.sysresetreq);
    _ = try unit.poll(&ppb);
    try std.testing.expectEqual(scb.key.read, ppb.word >> scb.key.shift);
}

test "the reset request does not read back set" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(scb.field.sysresetreq);
    _ = try unit.poll(&ppb);
    try std.testing.expectEqual(@as(u32, 0), ppb.word & scb.field.sysresetreq);
}

test "VECTCLRACTIVE is write-only too" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(scb.field.vectclractive);
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 0), ppb.word & scb.field.vectclractive);
}

test "the priority group is retained" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(0x0000_0500);
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u3, 5), unit.priorityGroup());
    try std.testing.expectEqual(scb.key.status | 0x0000_0500, ppb.word);
}

test "a group write is a write, not a request" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(0x0000_0300);
    _ = try unit.poll(&ppb);
    try std.testing.expect(!unit.quiet());
    try std.testing.expectEqual(@as(u32, 1), unit.writes);
    try std.testing.expectEqual(@as(u32, 0), unit.requests);
}

test "a request keeps the group the previous write programmed" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(0x0000_0400);
    _ = try unit.poll(&ppb);
    ppb.word = keyed(0x0000_0400 | scb.field.sysresetreq);
    try std.testing.expect(try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u3, 4), unit.priorityGroup());
}

test "writing the read-back value straight back unlocks nothing" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    // A driver that reads AIRCR and ORs its request in without replacing the
    // key half writes 0xFA05....: the status half is not the write key.
    ppb.word = scb.key.status | scb.field.sysresetreq;
    try std.testing.expect(!try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 1), unit.rejected);
}

test "two keyed requests count twice" {
    var ppb = Ppb{};
    var unit = scb.Scb.init();
    try unit.prime(&ppb);
    ppb.word = keyed(scb.field.sysresetreq);
    try std.testing.expect(try unit.poll(&ppb));
    ppb.word = keyed(scb.field.sysresetreq);
    try std.testing.expect(try unit.poll(&ppb));
    try std.testing.expectEqual(@as(u32, 2), unit.requests);
    try std.testing.expectEqual(@as(u32, 2), unit.writes);
}
