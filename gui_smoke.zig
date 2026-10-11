//! The headless ra8_gui smoke run (RA8EMU-1089): five frames of the GPIO
//! blink fixture on SDL's dummy driver, then exit. Part of `gui-test`, so
//! `zig build test` needs no SDL.

const std = @import("std");
pub fn smoke(b: *std.Build, exe: *std.Build.Step.Compile) *std.Build.Step {
    const run = b.addRunArtifact(exe);
    run.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    run.addArgs(&.{ "--frames", "5" });
    run.addFileArg(b.path("tests/fixtures/gpio/blink.elf"));
    run.expectExitCode(0);
    return &run.step;
}
