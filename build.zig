const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shared = b.dependency("venom_std", .{ .target = target, .optimize = optimize });

    // The presentation-client core, importable as `venom-desk`.
    const mod = b.addModule("venom-desk", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    mod.addImport("proto", shared.module("proto"));
    // Presentation-client logic shared with `venomx attach` (keys, tags, status
    // layout); headless, so no renderer is built for it.
    const term = b.dependency("venom_term", .{ .target = target, .optimize = optimize, .headless = true });
    mod.addImport("term_chrome", term.module("chrome"));

    const tests = b.addTest(.{ .root_module = mod });
    b.default_step.dependOn(&tests.step);
    const test_step = b.step("test", "Run unit tests and, when a venomx binary is available, the live two-client case");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The binary: daemon, CLI and the full-screen client in one.
    // Pane content goes through venom-term (its renderer and Vt), never
    // libvaxis or libghostty directly.
    const term_full = b.dependency("venom_term", .{ .target = target, .optimize = optimize });
    const exe_mod = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .link_libc = true });
    // The core again, on the renderer's venom-term instance, so one
    // `chrome` module serves both (a file may belong to one module only).
    const exe_core = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    exe_core.addImport("proto", shared.module("proto"));
    exe_core.addImport("term_chrome", term_full.module("chrome"));
    exe_mod.addImport("venom-desk", exe_core);
    exe_mod.addImport("term_chrome", term_full.module("chrome"));
    exe_mod.addImport("venom-term", term_full.module("venom-term"));
    exe_mod.addImport("vt", term_full.module("vt"));
    inline for (.{ "proto", "cli", "cfg", "log", "supervisor", "xdg" }) |name| exe_mod.addImport(name, shared.module(name));
    const exe = b.addExecutable(.{ .name = "venom-desk", .root_module = exe_mod });
    b.installArtifact(exe);
    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    b.default_step.dependOn(&exe_tests.step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // Agent-contract conformance: venom-std's packaged suite against
    // `venom-desk serve`, which never touches venomx.
    const conformance = @import("venom_std").addConformance(b, .{ .suite = shared.path("conformance/agent_contract.py"), .exe = exe, .profile = b.path("conformance/venom-desk.json") });
    b.step("test-conformance", "Run the venom-std agent-contract conformance suite against venom-desk").dependOn(&conformance.step);
    test_step.dependOn(&conformance.step);

    // The two presentation clients side by side on real PTYs.
    const screen = b.addExecutable(.{ .name = "desk-screen", .root_module = b.createModule(.{ .root_source_file = b.path("test/screen.zig"), .target = target, .optimize = optimize }) });
    screen.root_module.addImport("vt", term_full.module("vt"));
    const attach_e2e = b.addSystemCommand(&.{"python3"});
    attach_e2e.addFileArg(b.path("test/attach.py"));
    attach_e2e.addArtifactArg(exe);
    attach_e2e.addArtifactArg(screen);
    attach_e2e.has_side_effects = true;
    attach_e2e.expectExitCode(0);
    b.step("test-attach", "Run venom-desk attach next to venomx attach on real PTYs").dependOn(&attach_e2e.step);
    test_step.dependOn(&attach_e2e.step);

    // Test-only probe: connects to a real venomx daemon as venom-desk and
    // prints what it would show (status line, attention, floats, palette).
    const probe = b.addExecutable(.{ .name = "desk-probe", .root_module = b.createModule(.{ .root_source_file = b.path("test/probe.zig"), .target = target, .optimize = optimize, .link_libc = true }) });
    probe.root_module.addImport("venom-desk", mod);
    probe.root_module.addImport("proto", shared.module("proto"));
    b.default_step.dependOn(&probe.step);

    // Live case: venom-desk next to `venomx attach` on one session. Needs a venomx
    // binary built from venomx main; skipped (with a message) without one.
    const venomx = b.option([]const u8, "venomx", "venomx binary for the live test (default ../venomx/zig-out/bin/venomx)") orelse "../venomx/zig-out/bin/venomx";
    const live = b.addSystemCommand(&.{"python3"});
    live.addFileArg(b.path("test/live.py"));
    live.addArtifactArg(probe);
    live.addArg(venomx);
    // The key-table, popup and float cases drive `venom-desk attach` on a PTY.
    live.addArtifactArg(exe);
    live.addArtifactArg(screen);
    live.has_side_effects = true;
    live.expectExitCode(0);
    test_step.dependOn(&live.step);
    b.step("test-live", "Run the live two-client case against a venomx binary").dependOn(&live.step);
    attach_e2e.addArg(venomx);
}
