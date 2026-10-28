//! Covers src/interfaces/cli/history_replay_elf_cli.zig and the history
//! command line's `replay-elf`: the parse, the exit codes (0 compatible,
//! 3 diverged), the text and the JSON a run writes, and a missing ELF
//! failing as an error and not as a verdict.
const std = @import("std");
const cli_app = @import("cli_app");
const rig = @import("../rpc/regression_rig.zig");

const history_cli = cli_app.history_cli;
const replay_cli = cli_app.history_replay_elf_cli;

const gpa = std.testing.allocator;

test "the history command line parses replay-elf" {
    const ok = try history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "replay-elf", "s", "--elf", "a.elf", "--json" });
    try std.testing.expectEqual(history_cli.Op.@"replay-elf", ok.op);
    try std.testing.expectEqualStrings("s", ok.entry.?);
    try std.testing.expectEqualStrings("a.elf", ok.elf.?);
    try std.testing.expect(ok.json);
    const plain = try history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "--elf", "a.elf", "replay-elf", "s" });
    try std.testing.expect(!plain.json);
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "replay-elf", "s" }));
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "replay-elf", "--elf", "a.elf" }));
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "ls", "--json" }));
    try std.testing.expectError(error.Usage, history_cli.parse(&.{ "ra8_emulator", "history", "--root", "r", "du", "--elf", "a.elf" }));
}

test "a compatible rebuild exits 0 and a diverged one exits 3, in text and in JSON" {
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const variant = try rig.patched(gpa, scratch.dir, "variant.elf");
    defer gpa.free(variant);
    const name = recorded.sessionName();

    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    try std.testing.expectEqual(@as(u8, 0), try replay_cli.run(gpa, std.testing.io, &recorded.base, name, rig.image, false, &text.writer));
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "checkpoints: 3 of 3 match") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "(same image)") != null);
    try std.testing.expect(std.mem.endsWith(u8, text.written(), "compatible\n"));

    text.clearRetainingCapacity();
    try std.testing.expectEqual(replay_cli.exit_diverged, try replay_cli.run(gpa, std.testing.io, &recorded.base, name, variant, false, &text.writer));
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "diverged at checkpoint 1, round 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.written(), "first difference: memory 0x22000100, recorded 0x04, rebuilt 0x00") != null);

    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    try std.testing.expectEqual(replay_cli.exit_diverged, try replay_cli.run(gpa, std.testing.io, &recorded.base, name, variant, true, &json.writer));
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json.written(), .{});
    defer parsed.deinit();
    const top = parsed.value.object;
    try std.testing.expectEqualStrings("diverged", top.get("verdict").?.string);
    try std.testing.expectEqual(@as(i64, 3), top.get("checkpoints").?.integer);
    try std.testing.expectEqual(@as(i64, 1), top.get("matched").?.integer);
    try std.testing.expectEqual(false, top.get("elf").?.object.get("identical").?.bool);
    try std.testing.expectEqual(@as(i64, 0x2000041), top.get("elf").?.object.get("first_changed_address").?.integer);
    const d = top.get("divergence").?.object;
    try std.testing.expectEqual(@as(i64, 1), d.get("round").?.integer);
    try std.testing.expectEqual(@as(i64, 0), d.get("core").?.integer);
    try std.testing.expect(d.get("symbol").? == .null);
    const where = d.get("where").?.object;
    try std.testing.expectEqualStrings("memory", where.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0x22000100), where.get("address").?.integer);

    json.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try replay_cli.run(gpa, std.testing.io, &recorded.base, name, rig.image, true, &json.writer));
    const same = try std.json.parseFromSlice(std.json.Value, gpa, json.written(), .{});
    defer same.deinit();
    try std.testing.expectEqualStrings("compatible", same.value.object.get("verdict").?.string);
    try std.testing.expect(same.value.object.get("divergence").? == .null);
}

test "a missing ELF is an error and not a verdict" {
    const recorded = try rig.Recorded.open(gpa, 1);
    defer recorded.close(gpa);
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    const err = replay_cli.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), "no/such/rebuilt.elf", false, &sink.writer);
    try std.testing.expectError(error.FileNotFound, err);
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}
