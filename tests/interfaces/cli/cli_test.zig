//! Tests for src/interfaces/cli/cli.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const mod = cli_app.cli;

const parse = mod.parse;
const Part = ra8.chip.core.part.Part;

test "the command line takes an image and an optional instruction budget" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqualStrings("a.elf", defaults.path);
    try std.testing.expectEqual(@as(?usize, null), defaults.instructions);

    const bounded = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64" });
    try std.testing.expectEqual(@as(?usize, 64), bounded.instructions);

    try std.testing.expectError(error.MissingImage, parse(&[_][]const u8{"emu"}));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--instructions" }));
    try std.testing.expectError(error.UnknownFlag, parse(&[_][]const u8{ "emu", "a.elf", "--nope" }));
}

test "--console streams finished SCI lines when requested" {
    try std.testing.expect(!(try parse(&[_][]const u8{ "emu", "a.elf" })).console);
    try std.testing.expect((try parse(&[_][]const u8{ "emu", "a.elf", "--console" })).console);
}

test "--console-reply takes PROMPT=LINE and refuses an empty prompt" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--console-reply", "READY v1=RA8NET1:61:" });
    try std.testing.expectEqualStrings("READY v1", options.console_reply.prompt);
    try std.testing.expectEqualStrings("RA8NET1:61:", options.console_reply.text);
    try std.testing.expect(!(try parse(&[_][]const u8{ "emu", "a.elf" })).console_reply.armed());
    try std.testing.expectError(error.BadReply, parse(&[_][]const u8{ "emu", "a.elf", "--console-reply", "=x" }));
}

test "the part defaults to the RA8D2 and is named, never guessed" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(Part.ra8d2, defaults.part);

    const npu_part = try parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8p1" });
    try std.testing.expectEqual(Part.ra8p1, npu_part.part);

    try std.testing.expectError(error.UnknownPart, parse(&[_][]const u8{ "emu", "a.elf", "--part", "ra8m1" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--part" }));
}

test "an unwatched run gets the default budget" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(mod.budget, options.budgetFor(false));
}

test "a watched run gets the larger budget, because it stops on its counter" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--stop-sym", "g_tick", "5" });
    try std.testing.expectEqual(mod.watched_budget, options.budgetFor(true));
    try std.testing.expect(mod.watched_budget > mod.budget);
}

test "a timed run's ceiling leaves the default budget for boot" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--ms", "1000" });
    try std.testing.expectEqual(@as(usize, 1000) * mod.instructions_per_ms + mod.budget, options.budgetFor(false));
    try std.testing.expectEqual(@as(usize, 0), mod.ceilingFor(0));
    try std.testing.expectEqual(std.math.maxInt(usize), mod.ceilingFor(std.math.maxInt(u64)));
}

test "a counter that did not resolve watches nothing, so it keeps the default" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--stop-sym", "g_absent", "5" });
    try std.testing.expectEqual(mod.budget, options.budgetFor(false));
}

test "an asked-for budget wins over either default" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64", "--stop-sym", "g_tick", "5" });
    try std.testing.expectEqual(@as(usize, 64), options.budgetFor(true));
    try std.testing.expectEqual(@as(usize, 64), options.budgetFor(false));
}

test "the Click module is off unless --click fits it" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!defaults.click);
    const fitted = try parse(&[_][]const u8{ "emu", "a.elf", "--click" });
    try std.testing.expect(fitted.click);
}

test "--sd selects a raw card image" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--sd", "card.img" });
    try std.testing.expectEqualStrings("card.img", options.sd_path.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--sd" }));
}

test "--cpu picks the CPU, defaulting to the Zig core" {
    const Choice = ra8.chip.core.cpu.choice.Choice;
    try std.testing.expectEqual(Choice.zig, (try parse(&[_][]const u8{ "emu", "a.elf" })).cpu);
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu", "other" }));
    try std.testing.expectEqual(Choice.zig, (try parse(&[_][]const u8{ "emu", "a.elf", "--cpu", "zig" })).cpu);
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu", "arm" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu" }));
}

test "--ns names the Non-Secure companion image, and is off by default" {
    try std.testing.expectEqual(@as(?[]const u8, null), (try parse(&[_][]const u8{ "emu", "a.elf" })).ns_path);
    const options = try parse(&[_][]const u8{ "emu", "s.elf", "--ns", "s_ns.elf" });
    try std.testing.expectEqualStrings("s_ns.elf", options.ns_path.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "s.elf", "--ns" }));
}

test {
    _ = @import("../../session/touch_spec_test.zig");
    _ = @import("../../session/rtc/start_test.zig");
    _ = @import("realtime_test.zig");
    _ = @import("../../session/duration_test.zig");
    _ = @import("../../session/fault_file_test.zig");
    _ = @import("../render/png_test.zig");
    _ = @import("frame_out_test.zig");
    _ = @import("frames/args_test.zig");
    _ = @import("state_args_test.zig");
    _ = @import("frames/out_test.zig");
    _ = @import("video_out_test.zig");
    _ = @import("gif_out_test.zig");
    _ = @import("audio_out_test.zig");
    _ = @import("audio_tone_test.zig");
    _ = @import("ctl/args_test.zig");
}

test "--cpu-load-from and --cpu-load-to set the load window and turn --cpu-load on" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(plain.rtosWanted() == null);
    const whole = try parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load" });
    try std.testing.expectEqual(@as(u64, 0), whole.rtosWanted().?.from);
    try std.testing.expectEqual(std.math.maxInt(u64), whole.rtosWanted().?.to);
    const windowed = try parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load-from", "1000", "--cpu-load-to", "0x2000" });
    try std.testing.expect(windowed.cpu_load);
    try std.testing.expectEqual(@as(u64, 1000), windowed.rtosWanted().?.from);
    try std.testing.expectEqual(@as(u64, 0x2000), windowed.rtosWanted().?.to);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--cpu-load-to" }));
}

test "precise BusFaults are on unless --no-bus-errors turns them off" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(defaults.bus_errors);
    const asked = try parse(&[_][]const u8{ "emu", "a.elf", "--bus-errors" });
    try std.testing.expect(asked.bus_errors);
    const off = try parse(&[_][]const u8{ "emu", "a.elf", "--no-bus-errors" });
    try std.testing.expect(!off.bus_errors);
}

test "the Zig core runs formed blocks unless --no-blocks turns them off" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(defaults.blocks);
    const asked = try parse(&[_][]const u8{ "emu", "a.elf", "--blocks" });
    try std.testing.expect(asked.blocks);
    const off = try parse(&[_][]const u8{ "emu", "a.elf", "--no-blocks" });
    try std.testing.expect(!off.blocks);
}

test "profile prints counts and folded profile takes an output path" {
    const cli = @import("cli_app").cli;
    const asked = try parse(&[_][]const u8{ "emu", "a.elf", "--profile" });
    try std.testing.expect(asked.profile);
    try std.testing.expectEqual(@as(?[]const u8, null), asked.profile_folded);
    const folded = try parse(&[_][]const u8{ "emu", "a.elf", "--profile-folded", "out.folded" });
    try std.testing.expect(folded.profile);
    try std.testing.expectEqualStrings("out.folded", folded.profile_folded.?);
    try std.testing.expectError(error.MissingValue, cli.parse(&[_][]const u8{ "emu", "a.elf", "--profile-folded" }));
}

test "--usb-loop cables the two USB jacks together when requested" {
    try std.testing.expect(!(try parse(&[_][]const u8{ "emu", "a.elf" })).usb_loop);
    try std.testing.expect((try parse(&[_][]const u8{ "emu", "a.elf", "--usb-loop" })).usb_loop);
}

test "--trace-rtos-out takes a path and turns the trace on" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--trace-rtos-out", "run.trace" });
    try std.testing.expect(options.trace_rtos);
    try std.testing.expectEqualStrings("run.trace", options.trace_rtos_out.?);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--trace-rtos-out" }));
}

test "--report takes text or json and refuses anything else" {
    const plain = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expect(!plain.report_json);
    const as_json = try parse(&[_][]const u8{ "emu", "a.elf", "--report", "json" });
    try std.testing.expect(as_json.report_json);
    const as_text = try parse(&[_][]const u8{ "emu", "a.elf", "--report", "json", "--report", "text" });
    try std.testing.expect(!as_text.report_json);
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--report", "yaml" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--report" }));
}

test "--sd-save attaches the image and asks for the write-back; --sd does not" {
    const saved = try parse(&.{ "ra8_emulator", "fw.elf", "--sd-save", "card.img" });
    try std.testing.expectEqualStrings("card.img", saved.sd_path.?);
    try std.testing.expect(saved.sd_save);
    const plain = try parse(&.{ "ra8_emulator", "fw.elf", "--sd", "card.img" });
    try std.testing.expect(!plain.sd_save);
    const labelled = try parse(&.{ "ra8_emulator", "fw.elf", "--sd-new", "fat32:BOOK" });
    try std.testing.expectEqualStrings("BOOK", labelled.sd_label);
    const bare = try parse(&.{ "ra8_emulator", "fw.elf", "--sd-new", "fat16" });
    try std.testing.expectEqualStrings("RA8", bare.sd_label);
}

test "--touch @PATH names a live touch source; --touch X,Y still queues" {
    const live = try parse(&.{ "emu", "a.elf", "--touch", "@/tmp/touches", "--touch", "3,4" });
    try std.testing.expectEqualStrings("/tmp/touches", live.touch_in.?);
    try std.testing.expectEqual(@as(usize, 1), live.touch_count);
    try std.testing.expectEqual(@as(u16, 3), live.touches[0].x);
}

test "--cms and --sfs set the code MRAM and SiP flash split, nine bits at most" {
    const unset = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(@as(?u9, null), unset.cms);
    try std.testing.expectEqual(@as(?u9, null), unset.sfs);

    const split = try parse(&[_][]const u8{ "emu", "a.elf", "--cms", "2", "--sfs", "0x1FF" });
    try std.testing.expectEqual(@as(?u9, 2), split.cms);
    try std.testing.expectEqual(@as(?u9, 0x1FF), split.sfs);

    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--cms", "0x200" }));
    try std.testing.expectError(error.BadValue, parse(&[_][]const u8{ "emu", "a.elf", "--sfs", "-1" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--cms" }));
}

test "the board-world flags still read the same after moving out of cli.zig" {
    const world = try parse(&[_][]const u8{ "emu", "a.elf", "--click", "--battery", "40", "--no-blocks", "--usb-loop" });
    try std.testing.expect(world.click);
    try std.testing.expectEqual(@as(u8, 40), world.battery.soc_pct);
    try std.testing.expect(!world.blocks);
    try std.testing.expect(world.usb_loop);
}

test "--until takes the console text a run ends on" {
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--until", "decode=96x96 PASS" });
    try std.testing.expectEqualStrings("decode=96x96 PASS", options.until.?);
    const none = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(@as(?[]const u8, null), none.until);
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--until" }));
}

test "the console tap hands a finished line to the --until wait" {
    var tap = mod.console_output.Tap{ .wait = .{ .needle = "PASS" } };
    try std.testing.expect(tap.wanted());
    try mod.console_output.tapLine(&tap, "demo: boot");
    try std.testing.expect(!tap.waiting().?.met());
    try mod.console_output.tapLine(&tap, "demo: PASS");
    try std.testing.expect(tap.waiting().?.met());
    try std.testing.expect(!(mod.console_output.Tap{}).wanted());
}

test "--attach queues catalog models in the order asked" {
    const none = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqual(@as(usize, 0), none.attach_count);
    const two = try parse(&[_][]const u8{ "emu", "a.elf", "--attach", "max17048@i2c:touch@0x37", "--attach", "lsm6dso@i2c:riic@0x6A" });
    try std.testing.expectEqual(@as(usize, 2), two.attach_count);
    try std.testing.expectEqualStrings("max17048", two.attaches[0].name);
    try std.testing.expectEqualStrings("lsm6dso", two.attaches[1].name);
    try std.testing.expectError(error.UnknownModel, parse(&[_][]const u8{ "emu", "a.elf", "--attach", "nope@i2c:riic@0x40" }));
    try std.testing.expectError(error.MissingValue, parse(&[_][]const u8{ "emu", "a.elf", "--attach" }));
}

test "ctl cpu-load selects an image, a load window and the requested CPU" {
    const options = try parse(&.{ "emu", "ctl", "cpu-load", "blink.elf", "--from", "0x10", "--to", "32", "--instructions", "128", "--cpu", "zig" });
    try std.testing.expectEqualStrings("blink.elf", options.path);
    try std.testing.expect(options.ctl_cpu_load);
    try std.testing.expect(options.cpu_load);
    try std.testing.expectEqual(@as(u64, 16), options.cpu_load_window.from);
    try std.testing.expectEqual(@as(u64, 32), options.cpu_load_window.to);
    try std.testing.expectEqual(@as(?usize, 128), options.instructions);
    try std.testing.expectEqual(ra8.chip.core.cpu.choice.Choice.zig, options.cpu);
}

test "--dump-mem repeats keep every place in order, each with its own count" {
    const one = try parse(&[_][]const u8{ "emu", "a.elf", "--dump-mem", "0x22100034" });
    try std.testing.expectEqual(@as(usize, 1), one.memDumps().len);
    try std.testing.expectEqual(@as(?u32, null), one.memDumps()[0].words);

    const two = try parse(&[_][]const u8{ "emu", "a.elf", "--dump-mem", "0x22100034", "2", "--dump-mem", "0x22100008" });
    const asks = two.memDumps();
    try std.testing.expectEqual(@as(usize, 2), asks.len);
    try std.testing.expectEqualStrings("0x22100034", asks[0].spec);
    try std.testing.expectEqual(@as(?u32, 2), asks[0].words);
    try std.testing.expectEqualStrings("0x22100008", asks[1].spec);
    try std.testing.expectEqual(@as(?u32, null), asks[1].words);
    try std.testing.expectEqual(@as(usize, 0), (try parse(&[_][]const u8{ "emu", "a.elf" })).memDumps().len);
}

test "--camera-source picks the CEU's source; unknown kinds are refused" {
    const plain = try parse(&.{ "ra8", "app.elf" });
    try std.testing.expectEqual(ra8.host.camera.source_spec.Kind.gradient, plain.camera.kind);
    const chosen = try parse(&.{ "ra8", "app.elf", "--camera-source", "gradient" });
    try std.testing.expectEqual(ra8.host.camera.source_spec.Kind.gradient, chosen.camera.kind);
    try std.testing.expectError(error.UnknownCameraSource, parse(&.{ "ra8", "app.elf", "--camera-source", "camera:0" }));
    const cam = try parse(&.{ "ra8", "app.elf", "--allow-webcam", "--camera-source", "webcam:2" });
    try std.testing.expectEqual(ra8.host.camera.source_spec.Kind.webcam, cam.camera.kind);
    try std.testing.expect(cam.camera.allow_webcam);
    try std.testing.expect(!(try parse(&.{ "ra8", "app.elf", "--camera-source", "webcam" })).camera.allow_webcam);
    try std.testing.expectError(error.MissingValue, parse(&.{ "ra8", "app.elf", "--camera-source" }));
    const still = try parse(&.{ "ra8", "app.elf", "--camera-source", "image:pic.ppm" });
    try std.testing.expectEqual(ra8.host.camera.source_spec.Kind.image, still.camera.kind);
    try std.testing.expectEqualStrings("pic.ppm", still.camera.arg);
    try std.testing.expectError(error.BadValue, parse(&.{ "ra8", "app.elf", "--camera-source", "image" }));
}

test "a timed run gets its window after boot headroom" {
    try std.testing.expectEqual(@as(usize, 0), mod.ceilingFor(0));
    const options = try parse(&[_][]const u8{ "emu", "a.elf", "--ms", "1" });
    try std.testing.expectEqual(mod.budget + mod.instructions_per_ms, options.budgetFor(false));
    try std.testing.expectEqual(std.math.maxInt(usize), mod.ceilingFor(std.math.maxInt(u64)));
}
