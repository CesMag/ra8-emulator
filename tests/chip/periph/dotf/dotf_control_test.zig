const std = @import("std");
const ra8 = @import("ra8");

const control = ra8.chip.periph.dotf_control;

test "the self-test bit never lands, which is what ends the driver wait" {
    const written = control.value.enable | control.mask.self_test;
    try std.testing.expect(control.testRequested(written));
    try std.testing.expectEqual(@as(u32, 0), control.stored(written) & control.mask.self_test);
}

test "storing leaves everything but the self-test bit alone" {
    const written = control.value.enable | control.mask.self_test;
    try std.testing.expectEqual(control.value.enable, control.stored(written));
}

test "a write with no self-test asks for none" {
    try std.testing.expect(!control.testRequested(control.value.enable));
}

test "bit 9 is the AES core enable" {
    try std.testing.expect(control.enabled(control.value.enable));
    try std.testing.expect(!control.enabled(control.value.disable));
    try std.testing.expect(!control.enabled(control.value.default_field));
}

test "the FSP enable pattern is CTR mode with a 128-bit key" {
    try std.testing.expectEqual(control.KeySize.bits128, control.KeySize.of(control.value.enable));
    try std.testing.expectEqual(control.Mode.ctr, control.Mode.of(control.value.enable));
    try std.testing.expect(control.decrypting(control.value.enable));
}

test "the key size field carries all three sizes" {
    try std.testing.expectEqual(@as(u16, 128), control.KeySize.of(0x0200_0000).bits());
    try std.testing.expectEqual(@as(u16, 192), control.KeySize.of(0x0100_0000).bits());
    try std.testing.expectEqual(@as(u16, 256), control.KeySize.of(0x0300_0000).bits());
    try std.testing.expectEqual(@as(u16, 0), control.KeySize.of(0).bits());
}

test "a mode this part does not define is reported, not assumed" {
    try std.testing.expectEqual(control.Mode.other1, control.Mode.of(0x1000_0000));
    try std.testing.expectEqualStrings("a mode this part does not define", control.Mode.of(0x1000_0000).name());
    try std.testing.expectEqualStrings("no mode selected", control.Mode.of(0).name());
}

test "an enabled core in the wrong mode is not decrypting" {
    try std.testing.expect(!control.decrypting(control.mask.aes_enable));
}

test "the side-channel countermeasure reads back" {
    try std.testing.expect(control.countermeasure(control.mask.sca_enable));
    try std.testing.expect(!control.countermeasure(control.value.enable));
}

test "the key size names say which size they are" {
    try std.testing.expectEqualStrings("AES-256", control.KeySize.of(0x0300_0000).name());
    try std.testing.expectEqualStrings("no key size selected", control.KeySize.of(0).name());
}
