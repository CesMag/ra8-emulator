//! Conformance vectors for the MVE VLD2/VLD4/VST2/VST4 beat offsets
//! (interleave.beatOffset), worked from the Arm ARM (DDI0553) pseudocode
//! by /workspace/tools/mve_interleave.py on the lane's box.
const vector = @import("../../conformance/vector.zig");
const interleave = @import("interleave.zig");

const V = vector.Vector(interleave.Beat, u32);

pub const vectors = [_]V{
    .{ .encoding = "VLD20", .name = "beat 0", .input = .{ .regs = 2, .pat = 0, .beat = 0 }, .expect = 0 },
    .{ .encoding = "VLD20", .name = "beat 3", .input = .{ .regs = 2, .pat = 0, .beat = 3 }, .expect = 28 },
    .{ .encoding = "VLD21", .name = "beat 1", .input = .{ .regs = 2, .pat = 1, .beat = 1 }, .expect = 12 },
    .{ .encoding = "VLD21", .name = "beat 2", .input = .{ .regs = 2, .pat = 1, .beat = 2 }, .expect = 16 },
    .{ .encoding = "VLD40", .name = "beat 0", .input = .{ .regs = 4, .pat = 0, .beat = 0 }, .expect = 0 },
    .{ .encoding = "VLD40", .name = "beat 3", .input = .{ .regs = 4, .pat = 0, .beat = 3 }, .expect = 44 },
    .{ .encoding = "VLD41", .name = "beat 1", .input = .{ .regs = 4, .pat = 1, .beat = 1 }, .expect = 12 },
    .{ .encoding = "VLD41", .name = "beat 2", .input = .{ .regs = 4, .pat = 1, .beat = 2 }, .expect = 48 },
    .{ .encoding = "VLD42", .name = "beat 0", .input = .{ .regs = 4, .pat = 2, .beat = 0 }, .expect = 16 },
    .{ .encoding = "VLD42", .name = "beat 3", .input = .{ .regs = 4, .pat = 2, .beat = 3 }, .expect = 60 },
    .{ .encoding = "VLD43", .name = "beat 1", .input = .{ .regs = 4, .pat = 3, .beat = 1 }, .expect = 28 },
    .{ .encoding = "VLD43", .name = "beat 2", .input = .{ .regs = 4, .pat = 3, .beat = 2 }, .expect = 32 },
    .{ .encoding = "VST20", .name = "beat 0", .input = .{ .regs = 2, .pat = 0, .beat = 0 }, .expect = 0 },
    .{ .encoding = "VST20", .name = "beat 3", .input = .{ .regs = 2, .pat = 0, .beat = 3 }, .expect = 28 },
    .{ .encoding = "VST21", .name = "beat 1", .input = .{ .regs = 2, .pat = 1, .beat = 1 }, .expect = 12 },
    .{ .encoding = "VST21", .name = "beat 2", .input = .{ .regs = 2, .pat = 1, .beat = 2 }, .expect = 16 },
    .{ .encoding = "VST40", .name = "beat 0", .input = .{ .regs = 4, .pat = 0, .beat = 0 }, .expect = 0 },
    .{ .encoding = "VST40", .name = "beat 3", .input = .{ .regs = 4, .pat = 0, .beat = 3 }, .expect = 44 },
    .{ .encoding = "VST41", .name = "beat 1", .input = .{ .regs = 4, .pat = 1, .beat = 1 }, .expect = 12 },
    .{ .encoding = "VST41", .name = "beat 2", .input = .{ .regs = 4, .pat = 1, .beat = 2 }, .expect = 48 },
    .{ .encoding = "VST42", .name = "beat 0", .input = .{ .regs = 4, .pat = 2, .beat = 0 }, .expect = 16 },
    .{ .encoding = "VST42", .name = "beat 3", .input = .{ .regs = 4, .pat = 2, .beat = 3 }, .expect = 60 },
    .{ .encoding = "VST43", .name = "beat 1", .input = .{ .regs = 4, .pat = 3, .beat = 1 }, .expect = 28 },
    .{ .encoding = "VST43", .name = "beat 2", .input = .{ .regs = 4, .pat = 3, .beat = 2 }, .expect = 32 },
};

pub const claimed = [_][]const u8{ "VLD20", "VLD21", "VLD40", "VLD41", "VLD42", "VLD43", "VST20", "VST21", "VST40", "VST41", "VST42", "VST43" };

pub const covered = vector.encodingsOf(interleave.Beat, u32, &vectors);
