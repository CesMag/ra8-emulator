//! ITM port 0 text sent to gdb as `O` packets: which requests get them,
//! the hex, the chunking, and the text forgotten once sent.
const std = @import("std");
const ra8 = @import("ra8");

const console = ra8.gdb.rsp_dispatch.console;
const itm = ra8.chip.periph.itm;
const packet = ra8.gdb.rsp_packet;

fn enabled() itm.Itm {
    var unit = itm.Itm{};
    _ = unit.write(itm.offsets.tcr, itm.tcr_bits.itmena, 4);
    _ = unit.write(itm.offsets.ter, 1, 4);
    return unit;
}

fn say(unit: *itm.Itm, text: []const u8) void {
    for (text) |byte| _ = unit.write(itm.offsets.stim0, byte, 1);
}

fn framedAs(out: *std.Io.Writer, payload: []const u8) !void {
    var framed: [64]u8 = undefined;
    try out.writeAll(try packet.frame(&framed, payload));
}

test "only a resume takes O packets" {
    try std.testing.expect(console.resumes("c"));
    try std.testing.expect(console.resumes("s"));
    try std.testing.expect(console.resumes("vCont;c:1"));
    try std.testing.expect(!console.resumes("vCont?"));
    try std.testing.expect(!console.resumes("g"));
    try std.testing.expect(!console.resumes(""));
}

test "port 0 text goes out as hex in an O packet and is then forgotten" {
    var unit = enabled();
    say(&unit, "hi\n");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var framed: [4096]u8 = undefined;
    try console.send(&out.writer, &unit, &framed);
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    try framedAs(&expected.writer, "O68690a");
    try std.testing.expectEqualStrings(expected.written(), out.written());
    try std.testing.expectEqual(@as(usize, 0), unit.output().len);
    out.clearRetainingCapacity();
    try console.send(&out.writer, &unit, &framed);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "long text is split into chunk-sized packets" {
    var unit = enabled();
    var line: [console.limits.chunk + 3]u8 = undefined;
    @memset(&line, 'a');
    say(&unit, &line);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var framed: [4096]u8 = undefined;
    try console.send(&out.writer, &unit, &framed);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "$O"));
    var tail: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tail.deinit();
    try framedAs(&tail.writer, "O616161");
    try std.testing.expect(std.mem.endsWith(u8, out.written(), tail.written()));
}

test "characters the ITM dropped are reported after the text" {
    var unit = enabled();
    var full: [itm.limits.capacity + 2]u8 = undefined;
    @memset(&full, 'x');
    say(&unit, &full);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var framed: [4096]u8 = undefined;
    try console.send(&out.writer, &unit, &framed);
    const packets = itm.limits.capacity / console.limits.chunk + 1;
    try std.testing.expectEqual(@as(usize, packets), std.mem.count(u8, out.written(), "$O"));
    const note = "(2 characters dropped)\n";
    var tail: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer tail.deinit();
    try framedAs(&tail.writer, "O" ++ std.fmt.bytesToHex(note.*, .lower));
    try std.testing.expect(std.mem.endsWith(u8, out.written(), tail.written()));
    try std.testing.expectEqual(@as(usize, 0), unit.dropped);
}
