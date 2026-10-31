//! Explicit rebuilt-ELF replay overrides only the ELF identity. Unknown
//! historical provenance and unapplied configuration refuse comparison.
const std = @import("std");
const root = @import("ra8_session").history_root;
const board = @import("ra8_board");
const build = @import("history_build");

pub const snapshot_version = board.snapshot.run.file.version;
pub const commit = build.commit;
pub const model = build.model;

pub const Error = error{
    UnknownBuildIdentity,
    BuildMismatch,
    ModelMismatch,
    SnapshotVersionMismatch,
    UnsupportedRootPart,
    UnsupportedRootMemory,
    UnsupportedRootGrid,
    UnsupportedRootIdleSkip,
    UnsupportedRootVsync,
    UnsupportedRootPace,
    UnsupportedRootRtcStart,
    UnsupportedRootAttaches,
    UnsupportedRootFaults,
    UnsupportedRootInput,
    UnsupportedRootCamera,
    UnsupportedRootSkipFlags,
    MissingRootProfile,
    MissingInitialMedia,
};

/// No legacy exception: the old producer wrote snapshot=1, zero commit
/// and empty model/config. It cannot prove the run this build would replay.
/// Codec compatibility remains unchanged; comparison fails closed here.
pub fn check(r: root.Root) !void {
    try root.check(&r);
    if (std.mem.allEqual(u8, &r.emulator_commit, 0) or std.mem.allEqual(u8, &commit, 0)) return Error.UnknownBuildIdentity;
    if (!std.mem.eql(u8, &r.emulator_commit, &commit)) return Error.BuildMismatch;
    if (!std.mem.eql(u8, r.model_version, model)) return Error.ModelMismatch;
    if (r.snapshot_version != snapshot_version) return Error.SnapshotVersionMismatch;
    if (!std.mem.eql(u8, r.part, "ra8p1")) return Error.UnsupportedRootPart;
    if (r.board_profile.len == 0) return Error.MissingRootProfile;
    _ = try board.profile.parse(r.board_profile);
    if (r.memory_config.len != 0) return Error.UnsupportedRootMemory;
    if (r.grid.len != 0) return Error.UnsupportedRootGrid;
    if (!r.idle_skip) return Error.UnsupportedRootIdleSkip;
    if (r.panel_vsync != null) return Error.UnsupportedRootVsync;
    if (r.pace != .virtual) return Error.UnsupportedRootPace;
    if (r.rtc_start != null) return Error.UnsupportedRootRtcStart;
    if (r.attaches.len != 0) return Error.UnsupportedRootAttaches;
    if (r.faults.len != 0) return Error.UnsupportedRootFaults;
    if (r.input_script.len != 0) return Error.UnsupportedRootInput;
    if (!std.mem.eql(u8, r.camera, "gradient")) return Error.UnsupportedRootCamera;
    if (r.skip_flags != 0) return Error.UnsupportedRootSkipFlags;
    if (r.media == null) return Error.MissingInitialMedia;
}
