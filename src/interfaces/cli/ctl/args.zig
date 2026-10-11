//! Normalizes ctl cpu-load arguments for the shared emulator run parser.
const std = @import("std");

pub const capacity = 256;

pub const Arguments = struct {
    values: [capacity][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Arguments) []const []const u8 {
        return self.values[0..self.len];
    }
};

pub fn parse(argv: []const []const u8) !Arguments {
    if (argv.len < 3) return error.MissingCommand;
    if (!std.mem.eql(u8, argv[2], "cpu-load")) return error.UnknownCommand;
    if (argv.len < 4) return error.MissingImage;

    var result = Arguments{};
    result.values[0] = argv[0];
    result.values[1] = argv[3];
    result.len = 2;
    var source: usize = 4;
    while (source < argv.len) {
        const flag = argv[source];
        source += 1;
        if (result.len >= capacity) return error.TooManyArguments;
        const from = std.mem.eql(u8, flag, "--from");
        const to = std.mem.eql(u8, flag, "--to");
        result.values[result.len] = if (from) "--cpu-load-from" else if (to) "--cpu-load-to" else flag;
        result.len += 1;
        if (from or to) {
            if (source >= argv.len) return error.MissingValue;
            if (result.len >= capacity) return error.TooManyArguments;
            result.values[result.len] = argv[source];
            result.len += 1;
            source += 1;
        }
    }
    return result;
}
