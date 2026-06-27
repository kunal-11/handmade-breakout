const std = @import("std");
const Step = std.Build.Step;

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    game_api_module: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const game_api = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
    });

    const opts = Options{
        .target = target,
        .optimize = optimize,
        .game_api_module = game_api,
    };

    const game_so = buildGameSo(b, opts);

    // build game so
    const lib_cmd = b.addInstallArtifact(game_so, .{});
    const lib_step = b.step("lib", "Build game dynamic lib");
    lib_step.dependOn(&lib_cmd.step);

    // emit game so asm
    const emit_asm = b.addInstallFile(game_so.getEmittedAsm(), "game.s");
    const asm_step = b.step("asm", "emit game assembly");
    asm_step.dependOn(&emit_asm.step);

    const sdl_platform_exe = buildSDLPlatformExe(b, opts);

    // run sld platform
    const run_cmd = b.addRunArtifact(sdl_platform_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run SDL platform");
    run_step.dependOn(&run_cmd.step);

    // check build for errors, no binaries created
    const check = b.step("check", "Check build");
    check.dependOn(&game_so.step);
    check.dependOn(&sdl_platform_exe.step);

    // default build step
    b.installArtifact(game_so);
    b.installArtifact(sdl_platform_exe);
}

fn buildGameSo(b: *std.Build, opts: Options) *Step.Compile {
    const game_module = b.createModule(.{
        .root_source_file = b.path("src/game/game.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "game_api", .module = opts.game_api_module },
        },
        // needed for debug symbols lookup with dlopen
        .link_libc = true,
    });

    return b.addLibrary(.{
        .name = "game",
        .linkage = .dynamic,
        .root_module = game_module,
        .use_llvm = true,
    });
}

fn buildSDLPlatformExe(b: *std.Build, opts: Options) *Step.Compile {
    const sdl3_module = b.dependency("sdl3", .{
        .target = opts.target,
        .optimize = opts.optimize,
    }).module("sdl3");

    const sdl_platform_module = b.createModule(.{
        .root_source_file = b.path("src/sdl/sdl.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_module },
            .{ .name = "game_api", .module = opts.game_api_module },
        },
    });

    return b.addExecutable(.{
        .name = "handmade",
        .root_module = sdl_platform_module,
        .use_llvm = true,
    });
}
