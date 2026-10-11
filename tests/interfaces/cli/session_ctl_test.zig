//! `ctl --connect ... --json` against a spawned `serve --listen` on a temp
//! Unix path (RA8EMU-747, RA8EMU-750): each command's JSON shape, a
//! refusal, and the usage refusal.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");
const serve_peer = @import("serve_peer.zig");
const ctl_run = @import("ctl_run.zig");
const Answer = ctl_run.Answer;
const run = ctl_run.run;
const expectInteger = ctl_run.expectInteger;
const stream = ctl_run.stream;
const uart_image = ctl_run.uart_image;
const ctl = cli_app.session_ctl;
const Term = std.process.Child.Term;
const Value = std.json.Value;

test "ctl --json drives load, run, step, pause, regs and mem against a running serve" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ctl.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    var loaded = try run(gpa, spec, &.{ "load", serve_peer.image_path });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loaded.term);
    try std.testing.expectEqualStrings(serve_peer.image_path, loaded.field("loaded").string);
    try std.testing.expect(try expectInteger(loaded.field("bytes")) > 0);

    // A step straight after the load runs one instruction from reset; the
    // fixture may end in a fault once it has run to completion.
    var stepped = try run(gpa, spec, &.{"step"});
    defer stepped.deinit();
    try std.testing.expectEqualStrings("stepped", stepped.field("stopped").object.get("reason").?.string);
    // Where the first step landed is code, so it is mapped for the read below.
    const code = try expectInteger(stepped.field("stopped").object.get("pc").?);

    var ran = try run(gpa, spec, &.{ "run", "--budget", "1000" });
    defer ran.deinit();
    const stop = ran.field("stopped").object;
    try std.testing.expectEqualStrings("cpu0", stop.get("core").?.string);
    try std.testing.expect(stop.get("reason").? == .string);
    try std.testing.expect(try expectInteger(stop.get("pc").?) != 0);
    _ = try expectInteger(stop.get("detail").?);

    var paused = try run(gpa, spec, &.{"pause"});
    defer paused.deinit();
    try std.testing.expect(paused.field("paused").bool);

    var all = try run(gpa, spec, &.{"regs"});
    defer all.deinit();
    const registers = all.field("registers").object;
    try std.testing.expectEqual(@as(usize, 17), registers.count());
    const pc = try expectInteger(registers.get("pc").?);

    var two = try run(gpa, spec, &.{ "regs", "pc", "sp" });
    defer two.deinit();
    try std.testing.expectEqual(@as(usize, 2), two.field("registers").object.count());
    try std.testing.expectEqual(pc, try expectInteger(two.field("registers").object.get("pc").?));

    const at = try std.fmt.allocPrint(gpa, "{d}", .{code});
    defer gpa.free(at);
    var memory = try run(gpa, spec, &.{ "mem", at, "4" });
    defer memory.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, memory.term);
    try std.testing.expectEqual(code, try expectInteger(memory.field("address")));
    try std.testing.expectEqual(@as(i64, 4), try expectInteger(memory.field("length")));
    try std.testing.expectEqual(@as(usize, 8), memory.field("hex").string.len);

    var refused = try run(gpa, spec, &.{ "mem", "0", "0x200000" });
    defer refused.deinit();
    try std.testing.expectEqual(Term{ .exited = 1 }, refused.term);
    try std.testing.expectEqualStrings("Refused", refused.field("error").string);
    try std.testing.expectEqual(@as(i64, ra8.rpc.session_server.app_codes.too_long), try expectInteger(refused.field("code")));
}

fn stoppedAt(answer: *const Answer) !struct { reason: []const u8, pc: i64 } {
    const stop = answer.field("stopped").object;
    return .{ .reason = stop.get("reason").?.string, .pc = try expectInteger(stop.get("pc").?) };
}

test "ctl --json sets speed, breakpoints and watchpoints, and a breakpoint stops a run" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ctl.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    var loaded = try run(gpa, spec, &.{ "load", serve_peer.image_path });
    defer loaded.deinit();
    var stepped = try run(gpa, spec, &.{"step"});
    defer stepped.deinit();
    const second = (try stoppedAt(&stepped)).pc;

    // Reload so the run starts from reset again and meets the breakpoint
    // on the second instruction.
    var again = try run(gpa, spec, &.{ "load", serve_peer.image_path });
    defer again.deinit();
    const at = try std.fmt.allocPrint(gpa, "{d}", .{second});
    defer gpa.free(at);
    var set = try run(gpa, spec, &.{ "break", at });
    defer set.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, set.term);
    const id = try expectInteger(set.field("breakpoint"));
    try std.testing.expectEqual(second, try expectInteger(set.field("address")));

    var hit = try run(gpa, spec, &.{ "run", "--budget", "1000" });
    defer hit.deinit();
    const stop = try stoppedAt(&hit);
    try std.testing.expectEqualStrings("breakpoint", stop.reason);
    try std.testing.expectEqual(second, stop.pc);

    const which = try std.fmt.allocPrint(gpa, "{d}", .{id});
    defer gpa.free(which);
    var gone = try run(gpa, spec, &.{ "break", "--clear", which });
    defer gone.deinit();
    try std.testing.expectEqual(id, try expectInteger(gone.field("cleared")));

    var watch = try run(gpa, spec, &.{ "watch", "0x20000000", "write" });
    defer watch.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, watch.term);
    try std.testing.expectEqualStrings("write", watch.field("access").string);
    try std.testing.expectEqual(@as(i64, 0x2000_0000), try expectInteger(watch.field("address")));
    const watch_id = try std.fmt.allocPrint(gpa, "{d}", .{try expectInteger(watch.field("watchpoint"))});
    defer gpa.free(watch_id);
    var unwatched = try run(gpa, spec, &.{ "watch", "--clear", watch_id });
    defer unwatched.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, unwatched.term);

    var fast = try run(gpa, spec, &.{ "speed", "100" });
    defer fast.deinit();
    try std.testing.expectEqual(@as(i64, 100), try expectInteger(fast.field("speed")));
    var max = try run(gpa, spec, &.{ "speed", "max" });
    defer max.deinit();
    try std.testing.expectEqualStrings("max", max.field("speed").string);
}

test "ctl with a bad command prints its usage and exits 2" {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ test_paths.emulator, "ctl", "--connect", "unix:/nonexistent/ctl.sock", "--json", "fly" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 2 }, result.term);
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, ctl.usage));
}

test "ctl parse: --json anywhere, register names, budgets and memory reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const regs = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "tcp::7000", "regs", "pc", "sp", "--json" });
    try std.testing.expect(regs.json);
    try std.testing.expectEqualSlices(ra8.rpc.session_rpc.Register, &.{ .pc, .sp }, regs.command.regs);
    const ran = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "run", "--budget", "0x10" });
    try std.testing.expect(!ran.json);
    try std.testing.expectEqual(@as(u64, 16), ran.command.run);
    const mem = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "mem", "0x20000000", "8" });
    try std.testing.expectEqual(@as(u32, 0x2000_0000), mem.command.mem.address);
    try std.testing.expectError(error.UnknownRegister, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "regs", "r99" }));
    try std.testing.expectError(error.BadLength, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "mem", "0", "0" }));
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "--json" }));
}

test "ctl parse: speed, break and watch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "ra8", "ctl", "--connect", "unix:/s" };
    const half = try ctl.parse(a, &(base ++ [_][]const u8{ "speed", "0.5" }));
    try std.testing.expectEqual(@as(u64, 500), half.command.speed);
    const max = try ctl.parse(a, &(base ++ [_][]const u8{ "speed", "max" }));
    try std.testing.expectEqual(@as(u64, 0), max.command.speed);
    try std.testing.expectError(error.BadSpeed, ctl.parse(a, &(base ++ [_][]const u8{ "speed", "0" })));
    const brk = try ctl.parse(a, &(base ++ [_][]const u8{ "break", "0x100" }));
    try std.testing.expectEqual(@as(u32, 0x100), brk.command.set_break);
    const unbrk = try ctl.parse(a, &(base ++ [_][]const u8{ "break", "--clear", "3" }));
    try std.testing.expectEqual(@as(u32, 3), unbrk.command.clear_break);
    const watch = try ctl.parse(a, &(base ++ [_][]const u8{ "watch", "0x20000000", "access" }));
    try std.testing.expectEqual(ra8.rpc.session_rpc.Access.access, watch.command.set_watch.access);
    const unwatch = try ctl.parse(a, &(base ++ [_][]const u8{ "watch", "--clear", "2" }));
    try std.testing.expectEqual(@as(u32, 2), unwatch.command.clear_watch);
    try std.testing.expectError(error.UnknownAccess, ctl.parse(a, &(base ++ [_][]const u8{ "watch", "0", "poke" })));
}

test "ctl load takes a firmware image with option-setting segments and resets to its vector" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/load.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    // uart_irq_echo carries OFS, SAS, BPS and OTP segments beside its code.
    var loaded = try run(gpa, spec, &.{ "load", "tests/fixtures/uart/uart_irq_echo.elf" });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loaded.term);
    var regs = try run(gpa, spec, &.{ "regs", "pc" });
    defer regs.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, regs.term);
    const pc = regs.field("registers").object.get("pc").?;
    try std.testing.expectEqual(@as(i64, 0x02000AFC), try expectInteger(pc));
}

test "ctl events waits for a UART line and times out on one that never comes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/events.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);
    var loaded = try run(gpa, spec, &.{ "load", uart_image });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loaded.term);

    var ready = try stream(gpa, spec, &.{ "events", "--until", "uart_irq_echo ready", "--timeout", "60s" });
    defer ready.deinit(gpa);
    try std.testing.expectEqual(Term{ .exited = 0 }, ready.term);
    try std.testing.expect(std.mem.indexOf(u8, ready.text.items, "uart_irq_echo ready") != null);

    var never = try stream(gpa, spec, &.{ "events", "--until", "never printed", "--timeout", "1s" });
    defer never.deinit(gpa);
    try std.testing.expectEqual(Term{ .exited = 1 }, never.term);
    try std.testing.expect(std.mem.startsWith(u8, never.last.items, "{\"timeout\""));
}

test "ctl events parses topics, the text to wait for and durations" {
    const events = ctl.events;
    try std.testing.expectEqual(@as(i64, 500), try events.parseDuration("500ms"));
    try std.testing.expectEqual(@as(i64, 30_000), try events.parseDuration("30s"));
    try std.testing.expectEqual(@as(i64, 2_000), try events.parseDuration("2"));
    try std.testing.expectError(error.BadDuration, events.parseDuration("0s"));
    const options = try events.parse(&.{ "--topic", "stop", "--until", "ready" });
    try std.testing.expect(options.stop and options.uart);
    try std.testing.expectEqualStrings("ready", options.until.?);
    try std.testing.expect((try events.parse(&.{})).uart);
    const modules = try events.parse(&.{ "--topic", "session" });
    try std.testing.expect(modules.session and !modules.uart);
    try std.testing.expectError(error.UnknownTopic, events.parse(&.{ "--topic", "lcd" }));
    try std.testing.expectError(error.BadArguments, events.parse(&.{"--until"}));
}

test "ctl --json plugs a part, faults it, clears it, unplugs it and refuses a typo" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/parts.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(spec, &line);
    defer served.child.kill(std.testing.io);

    const steps = [_]struct { words: []const []const u8, key: []const u8, value: []const u8 }{
        .{ .words = &.{ "plug", "max17048@i2c:riic@0x36" }, .key = "plugged", .value = "max17048@i2c:riic@0x36" },
        .{ .words = &.{ "fault", "max17048@i2c:riic@0x36=nack:2" }, .key = "fault_set", .value = "max17048@i2c:riic@0x36=nack:2" },
        .{ .words = &.{ "fault", "--clear", "i2c:riic@0x36" }, .key = "fault_cleared", .value = "i2c:riic@0x36" },
        .{ .words = &.{ "unplug", "i2c:riic@0x36" }, .key = "unplugged", .value = "i2c:riic@0x36" },
    };
    for (steps) |step| {
        var answer = try run(gpa, spec, step.words);
        defer answer.deinit();
        try std.testing.expectEqual(Term{ .exited = 0 }, answer.term);
        try std.testing.expectEqualStrings(step.value, answer.field(step.key).string);
    }

    var typo = try run(gpa, spec, &.{ "plug", "nosuch@i2c:riic@0x36" });
    defer typo.deinit();
    try std.testing.expectEqual(Term{ .exited = 1 }, typo.term);
    try std.testing.expectEqualStrings("Refused", typo.field("error").string);
}

test "ctl parse: plug, unplug and fault" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "ra8", "ctl", "--connect", "unix:/s" };
    const plug = try ctl.parse(a, &(base ++ [_][]const u8{ "plug", "button@gpio:p005" }));
    try std.testing.expectEqual(ra8.rpc.session_rpc.Method.plug, plug.command.part.method);
    try std.testing.expectEqualStrings("button@gpio:p005", plug.command.part.text);
    const clear = try ctl.parse(a, &(base ++ [_][]const u8{ "fault", "--clear", "i2c:riic@0x36" }));
    try std.testing.expectEqual(ra8.rpc.session_rpc.Method.clear_fault, clear.command.part.method);
    const set = try ctl.parse(a, &(base ++ [_][]const u8{ "fault", "@i2c:riic@0x37=nack:2" }));
    try std.testing.expectEqual(ra8.rpc.session_rpc.Method.set_fault, set.command.part.method);
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &(base ++ [_][]const u8{"unplug"})));
}

test "ctl parse: snapshot and restore take one path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const saved = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "snapshot", "/tmp/run.ra8snap", "--json" });
    try std.testing.expectEqual(ra8.rpc.session_rpc.Method.snapshot, saved.command.files.method);
    try std.testing.expectEqualStrings("/tmp/run.ra8snap", saved.command.files.path);
    try std.testing.expect(saved.json);
    const back = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "restore", "run.ra8snap" });
    try std.testing.expectEqual(ra8.rpc.session_rpc.Method.restore, back.command.files.method);
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "restore" }));
}

test "ctl parse: periph lists blocks, or one block's registers when named" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const blocks = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "periph" });
    try std.testing.expectEqualStrings("", blocks.command.periph);
    const rtc = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "periph", "RTC", "--json" });
    try std.testing.expectEqualStrings("RTC", rtc.command.periph);
    try std.testing.expect(rtc.json);
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "periph", "RTC", "AGT" }));
}

test "ctl parse: folded takes an optional thread and an optional window" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "folded" });
    try std.testing.expectEqual(ra8.rpc.session_rpc.all_threads, all.command.folded.thread);
    const one = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "folded", "0x22025060" });
    try std.testing.expectEqual(@as(u32, 0x22025060), one.command.folded.thread);
    const window = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "folded", "100", "200" });
    try std.testing.expectEqual(@as(u64, 100), window.command.folded.from_ns);
    try std.testing.expectEqual(@as(u64, 200), window.command.folded.to_ns);
    const both = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "folded", "0", "1", "2" });
    try std.testing.expectEqual(@as(u32, 0), both.command.folded.thread);
    try std.testing.expectEqual(@as(u64, 2), both.command.folded.to_ns);
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "folded", "1", "2", "3", "4" }));
}
