const std = @import("std");
const Step = std.Build.Step;

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const native_opts = Options{ .optimize = optimize, .target = target };

    const game_so = buildGameSo(b, native_opts);

    // build game so
    const lib_cmd = b.addInstallArtifact(game_so, .{});
    const lib_step = b.step("lib", "Build game dynamic lib");
    lib_step.dependOn(&lib_cmd.step);

    // emit game so asm
    const emit_asm = b.addInstallFile(game_so.getEmittedAsm(), "game.s");
    const asm_step = b.step("asm", "emit game assembly");
    asm_step.dependOn(&emit_asm.step);

    const sdl_platform_exe = buildSDLPlatformExe(b, native_opts);

    // run sld platform
    const run_cmd = b.addRunArtifact(sdl_platform_exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run SDL platform");
    run_step.dependOn(&run_cmd.step);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory, .simd128 }),
    });
    const wasm_opts = Options{ .optimize = optimize, .target = wasm_target };
    const wasm_exe = buildGameWasm(b, wasm_opts);

    // build web files
    const web_out_dir = "web";
    const wasm_cmd = b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{ .override = .{ .custom = web_out_dir } } });
    const web_platform = b.addInstallDirectory(.{
        .source_dir = b.path("src/web/static"),
        .install_dir = .{ .custom = web_out_dir },
        .install_subdir = "",
    });

    const web_step = b.step("web", "Build game web files");
    web_step.dependOn(&wasm_cmd.step);
    web_step.dependOn(&web_platform.step);

    // check build for errors, no binaries created
    const check = b.step("check", "Check build");
    check.dependOn(&game_so.step);
    check.dependOn(&sdl_platform_exe.step);
    check.dependOn(&wasm_exe.step);

    // default build step
    b.installArtifact(game_so);
    b.installArtifact(sdl_platform_exe);
    b.installArtifact(wasm_exe);
}

fn gameApiModule(b: *std.Build, opts: Options) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
}

fn workQueueModule(b: *std.Build, game_api: *std.Build.Module, opts: Options) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/work_q.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "game_api", .module = game_api },
        },
    });
}

fn buildGameWasm(b: *std.Build, opts: Options) *Step.Compile {
    const game_api_module = gameApiModule(b, opts);

    const game_module = b.createModule(.{
        .root_source_file = b.path("src/game/game.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "game_api", .module = game_api_module },
        },
    });

    const shim_module = b.createModule(.{
        .root_source_file = b.path("src/web/shim.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "work_queue", .module = workQueueModule(b, game_api_module, opts) },
            .{ .name = "game_api", .module = game_api_module },
            .{ .name = "game", .module = game_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = shim_module,
        .use_llvm = true,
    });

    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.import_memory = true;
    exe.shared_memory = true;
    exe.max_memory = 1024 * 64 * 1024;

    return exe;
}

fn buildGameSo(b: *std.Build, opts: Options) *Step.Compile {
    const game_module = b.createModule(.{
        .root_source_file = b.path("src/game/game.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "game_api", .module = gameApiModule(b, opts) },
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

    const game_api_moudle = gameApiModule(b, opts);

    const sdl_platform_module = b.createModule(.{
        .root_source_file = b.path("src/sdl/sdl.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "sdl3", .module = sdl3_module },
            .{ .name = "game_api", .module = game_api_moudle },
            .{ .name = "work_queue", .module = workQueueModule(b, game_api_moudle, opts) },
        },
    });

    return b.addExecutable(.{
        .name = "handmade",
        .root_module = sdl_platform_module,
        .use_llvm = true,
    });
}
