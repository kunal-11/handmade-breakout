const std = @import("std");
const sdl3 = @import("sdl3");
const api = @import("game_api");

const builtin = @import("builtin");

const SCREEN_WIDTH = switch (builtin.os.tag) {
    .macos => 1472,
    else => 1920,
};

const SCREEN_HEIGHT = switch (builtin.os.tag) {
    .macos => 900,
    else => 1080,
};

const AUDIO_SAMPLE_RATE = 48_000;

const THREAD_COUNT = 7;

const REFRESH_RATE_HZ = 60;

const GAME_LIB_PATH = switch (builtin.os.tag) {
    .linux => "zig-out/lib/libgame.so",
    .macos => "zig-out/lib/libgame.dylib",
    else => @compileError("unsupported platform"),
};

const KB = 1 << 10;
const MB = 1 << 20;
const GB = 1 << 30;

fn error_cb(err: ?[:0]const u8) void {
    if (err) |e| {
        std.debug.print("SDL Error: {s}\n", .{e});
    }
}

fn audio_cb(data: ?*Game, stream: sdl3.audio.Stream, additional_amount: usize, _: usize) void {
    if (data) |g| {
        g.audio.sample_count = additional_amount / 4;
        g.output_sound(&g.audio, &g.memory);
        stream.putData(@ptrCast(g.audio.buffer[0..g.audio.sample_count])) catch {
            std.debug.panic("Error outputting audio to SDL!\n", .{});
        };
    }
}

const Game = struct {
    screen: api.Screen,
    input: api.Input,
    memory: api.Memory,
    audio: api.Audio,

    output_sound: api.OutputSound = undefined,
    update_and_render: api.UpdateAndRender = undefined,

    lib_path: []const u8,
    last_load_time: std.Io.Timestamp = .zero,
    last_lib: ?std.DynLib = null,

    fn refreshGameLib(self: *Game) !void {
        const stat = try std.Io.Dir.cwd().statFile(single_threaded_io, self.lib_path, .{});
        if (stat.mtime.nanoseconds <= self.last_load_time.nanoseconds) {
            self.input.exe_reloaded = false;
            return;
        }
        self.input.exe_reloaded = true;
        self.last_load_time = stat.mtime;

        if (self.last_lib) |*last_lib| {
            last_lib.close();
        }
        var lib = try std.DynLib.open(self.lib_path);
        self.output_sound = lib.lookup(api.OutputSound, "outputSound") orelse return error.MissingExport;
        self.update_and_render = lib.lookup(api.UpdateAndRender, "updateAndRender") orelse return error.MissingExport;

        self.last_lib = lib;
    }
};

const single_threaded_io = std.Io.Threaded.global_single_threaded.io();

pub fn main() !void {
    defer sdl3.shutdown();

    sdl3.errors.error_callback = error_cb;
    const init_flags = sdl3.InitFlags{ .video = true, .audio = true };
    try sdl3.init(init_flags);
    defer sdl3.quit(init_flags);

    // Allocate memory
    const page_allocator = std.heap.page_allocator;
    const permanent_memory = try page_allocator.alloc(u8, 64 * MB);
    defer page_allocator.free(permanent_memory);
    @memset(permanent_memory, 0);

    const transient_memory = try page_allocator.alloc(u8, 8 * GB);
    defer page_allocator.free(transient_memory);
    @memset(transient_memory, 0);

    const screen_buffer = try page_allocator.alignedAlloc(u8, .fromByteUnits(api.cache_line), SCREEN_HEIGHT * SCREEN_WIDTH * 4);
    defer page_allocator.free(screen_buffer);
    const audio_buffer = try page_allocator.alloc([2]i16, AUDIO_SAMPLE_RATE);
    defer page_allocator.free(audio_buffer);

    // Initial window setup.
    const window = try sdl3.video.Window.init("Hello SDL", SCREEN_WIDTH, SCREEN_HEIGHT, .{ .high_pixel_density = false });
    defer window.deinit();
    const screen_surface = try sdl3.surface.Surface.initFrom(SCREEN_WIDTH, SCREEN_HEIGHT, .array_rgbx_32, screen_buffer);

    // Initial Timer setup
    // const display = try window.getDisplayForWindow();
    // const mode = try display.getCurrentMode();
    // const monitor_refresh_hz = mode.refresh_rate orelse 60;
    const refresh_hz: f32 = REFRESH_RATE_HZ;
    const target_seconds_per_frame = 1.0 / refresh_hz;
    const schedular_granularity_ns = 0;

    // Work queue setup
    const worker_count = THREAD_COUNT;
    var semaphore = std.Io.Semaphore{};
    var high_priority_work_queue: wq.WorkQueue = .{ .semaphore = &semaphore };
    var low_priority_work_queue: wq.WorkQueue = .{ .semaphore = &semaphore };
    for (0..worker_count) |_| {
        const thread = try std.Thread.spawn(.{}, wqWorker, .{ &high_priority_work_queue, &low_priority_work_queue, &semaphore });
        thread.detach();
    }

    var g: Game = .{
        .screen = .{
            .memory = screen_buffer.ptr,

            .width = SCREEN_WIDTH,
            .height = SCREEN_HEIGHT,
            .pitch = SCREEN_WIDTH * 4,
        },
        .audio = .{
            .buffer = audio_buffer.ptr,
            .samples_per_second = AUDIO_SAMPLE_RATE,
            .sample_count = AUDIO_SAMPLE_RATE,
        },
        .input = .{
            .seconds_to_update = target_seconds_per_frame,
            .exe_reloaded = false,
        },
        .memory = .{
            .permanent_storage = permanent_memory.ptr,
            .permanent_storage_len = permanent_memory.len,

            .transient_storage = transient_memory.ptr,
            .transient_storage_len = transient_memory.len,

            .work_queue = .{
                .high_priority_queue = &high_priority_work_queue,
                .low_priority_queue = &low_priority_work_queue,
                .add_entry = &wqAddEntry,
                .complete_all_work = &wqCompleteAllWork,
            },

            .file_ops = .{
                .find_files_with_ext = &findFileWithExt,
                .close_iterator = &closeFileIterator,
                .open_next_file = &openNextFile,
                .read_file = &readFile,
            },
        },
        .lib_path = GAME_LIB_PATH,
    };
    try g.refreshGameLib();

    // Initial sound setup.
    var audio_stream = try sdl3.audio.Device.default_playback.openStream(.{
        .format = .signed_16_bit_little_endian,
        .num_channels = 2,
        .sample_rate = AUDIO_SAMPLE_RATE,
    }, Game, audio_cb, &g);
    defer audio_stream.deinit();
    try audio_stream.resumeDevice();

    // Game loop
    const counter_frequency = sdl3.timer.getPerformanceFrequency();
    var last_frame_sync = sdl3.timer.getPerformanceCounter();
    var last_frame_end = sdl3.timer.getPerformanceCounter();

    var quit = false;
    while (!quit) {
        quit = handleInputs(&g.input);
        {
            // TODO: remove this lock if app supportes thread safe output audio
            try audio_stream.lock();
            defer audio_stream.unlock() catch unreachable;

            try g.refreshGameLib();

            g.update_and_render(&g.screen, &g.memory, &g.input);
        }

        const window_surface = try window.getSurface();
        try screen_surface.blitScaled(null, window_surface, null, .nearest);

        var seconds_elapsed = secondsElapsed(last_frame_sync, sdl3.timer.getPerformanceCounter(), counter_frequency);
        const ns_remaining: u64 = @trunc(@max(target_seconds_per_frame - seconds_elapsed, 0) * 1000_000_000);
        if (ns_remaining > schedular_granularity_ns) {
            sdl3.timer.delayNanoseconds(ns_remaining - schedular_granularity_ns);
        }
        seconds_elapsed = secondsElapsed(last_frame_sync, sdl3.timer.getPerformanceCounter(), counter_frequency);
        while (target_seconds_per_frame - seconds_elapsed > 0) {
            seconds_elapsed = secondsElapsed(last_frame_sync, sdl3.timer.getPerformanceCounter(), counter_frequency);
        }
        last_frame_sync = sdl3.timer.getPerformanceCounter();

        try window.updateSurface();

        const end_counter = sdl3.timer.getPerformanceCounter();
        const frame_secs = secondsElapsed(last_frame_end, end_counter, counter_frequency);
        std.debug.print("Time: {} | FPS: {}\n", .{ frame_secs * 1000, 1 / frame_secs });
        last_frame_end = end_counter;
    }
}

fn handleInputs(input: *api.Input) bool {
    for (&input.controllers) |*controller| {
        inline for (std.meta.fields(api.Input.Controller)) |field| {
            @field(controller, field.name).half_transition_count = 0;
        }
    }

    inline for (std.meta.fields(api.Input.Mouse)) |field| {
        if (@TypeOf(@field(input.mouse, field.name)) == api.Input.ButtonState) {
            @field(input.mouse, field.name).half_transition_count = 0;
        }
    }

    while (sdl3.events.poll()) |event| {
        switch (event) {
            .quit => return true,
            .terminating => return true,
            .key_down, .key_up => |key| handleKeyDown(&input.controllers[0], key),
            .mouse_button_down, .mouse_button_up => |button| handleMouseButton(&input.mouse, button),
            else => {},
        }
    }

    _, input.mouse.x, input.mouse.y = sdl3.mouse.getState();
    // TODO: handle scroll wheel mouse z

    return false;
}

fn handleMouseButton(mouse: *api.Input.Mouse, button: sdl3.events.MouseButton) void {
    switch (button.button) {
        .left => handleButton(&mouse.left, button.down),
        .middle => handleButton(&mouse.middle, button.down),
        .right => handleButton(&mouse.right, button.down),
        .x1 => handleButton(&mouse.ex0, button.down),
        .x2 => handleButton(&mouse.ex1, button.down),
        else => {},
    }
}

fn handleKeyDown(keyboard: *api.Input.Controller, key: sdl3.events.Keyboard) void {
    if (key.repeat) return;
    if (key.scancode) |code| switch (code) {
        .w => handleButton(&keyboard.move_up, key.down),
        .a => handleButton(&keyboard.move_left, key.down),
        .s => handleButton(&keyboard.move_down, key.down),
        .d => handleButton(&keyboard.move_right, key.down),
        .q => handleButton(&keyboard.left_shoulder, key.down),
        .e => handleButton(&keyboard.right_shoulder, key.down),
        .left => handleButton(&keyboard.action_left, key.down),
        .right => handleButton(&keyboard.action_right, key.down),
        .up => handleButton(&keyboard.action_up, key.down),
        .down => handleButton(&keyboard.action_down, key.down),
        .space => handleButton(&keyboard.start, key.down),
        .backspace => handleButton(&keyboard.back, key.down),
        else => {},
    };
}

fn handleButton(button: *api.Input.ButtonState, is_down: bool) void {
    std.debug.assert(is_down != button.ended_down);
    button.ended_down = is_down;
    button.half_transition_count += 1;
}

fn secondsElapsed(start: u64, end: u64, frequency: u64) f32 {
    return @as(f32, @floatFromInt(end -% start)) / @as(f32, @floatFromInt(frequency));
}

// Work Queue
const wq = @import("work_q.zig");

fn wqWorker(high_priority_queue: *wq.WorkQueue, low_priority_queue: *wq.WorkQueue, sema: *std.Io.Semaphore) void {
    while (true) {
        sema.wait(single_threaded_io) catch unreachable;
        while (!high_priority_queue.doNextEntry()) {}
        while (!low_priority_queue.doNextEntry()) {}
    }
}

fn wqAddEntry(queue: *api.WorkQueue.Queue, cb: api.WorkQueue.Callback, data: ?*anyopaque) callconv(.c) void {
    const work_queue: *wq.WorkQueue = @ptrCast(@alignCast(queue));
    work_queue.addEntry(cb, data);
}

fn wqCompleteAllWork(queue: *api.WorkQueue.Queue) callconv(.c) void {
    const work_queue: *wq.WorkQueue = @ptrCast(@alignCast(queue));
    work_queue.completeAllWork();
}

// File Handling
const FileIterator = extern struct {
    header: api.FileOps.Iterator,
    files: [*][*:0]u8,
    file_count: u32,
    current_index: u32,
};

const file_search_fmt = ".assets/*.{s}";

fn findFileWithExt(ext: [*:0]const u8) callconv(.c) ?*api.FileOps.Iterator {
    var buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrintZ(&buf, file_search_fmt, .{ext}) catch {
        std.debug.panic("File Error: ext too long!\n", .{});
    };
    const files = sdl3.filesystem.globDirectory(".", pattern, .{}) catch return null;
    const result = sdl3.allocator.create(FileIterator) catch return null;

    result.* = .{
        .files = files.ptr,
        .file_count = @intCast(files.len),
        .current_index = 0,
        .header = .{ .has_error = false },
    };
    return @ptrCast(result);
}

fn closeFileIterator(api_itr: *api.FileOps.Iterator) callconv(.c) void {
    const itr: *FileIterator = @ptrCast(@alignCast(api_itr));
    sdl3.free(itr.files);
    sdl3.free(itr);
}

const FileHandle = struct {
    file: std.Io.File,
};

fn openNextFile(api_itr: *api.FileOps.Iterator) callconv(.c) ?*api.FileOps.Handle {
    const itr: *FileIterator = @ptrCast(@alignCast(api_itr));
    if (itr.current_index >= itr.file_count) return null;

    const file_path = std.mem.span(itr.files[itr.current_index]);
    const file = std.Io.Dir.cwd().openFile(single_threaded_io, file_path, .{}) catch {
        itr.header.has_error = true;
        return null;
    };
    const handle = sdl3.allocator.create(FileHandle) catch {
        itr.header.has_error = true;
        return null;
    };
    handle.* = .{ .file = file };
    itr.current_index += 1;
    return handle;
}

fn readFile(api_handle: *api.FileOps.Handle, offset: u64, size: u64, dest: *anyopaque) callconv(.c) bool {
    const handle: *FileHandle = @ptrCast(@alignCast(api_handle));
    const buffer: [*]u8 = @ptrCast(dest);
    const read_bytes = handle.file.readPositionalAll(single_threaded_io, buffer[0..size], offset) catch return false;
    return read_bytes == size;
}
