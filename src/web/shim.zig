const api = @import("game_api");
const game = @import("game");

const Arena = struct {
    memory: [*]u8,
    used: usize = 0,

    pub fn pushStruct(arena: *Arena, T: type) *T {
        return @ptrCast(arena.pushBytes(@sizeOf(T), @alignOf(T)));
    }

    pub fn pushArray(arena: *Arena, T: type, len: usize) []T {
        return @ptrCast(arena.pushBytes(@sizeOf(T) * len, @alignOf(T)));
    }

    pub fn pushArrayAligned(arena: *Arena, T: type, len: usize, comptime alignment: usize) []align(alignment) T {
        return @ptrCast(arena.pushBytes(@sizeOf(T) * len, alignment));
    }

    pub fn pushBytes(arena: *Arena, len: usize, comptime alignment: usize) []align(alignment) u8 {
        const offset = alignOffset(arena.memory + arena.used, alignment);
        arena.used += offset + len;
        return @alignCast(arena.memory[arena.used - len .. arena.used]);
    }

    inline fn alignOffset(ptr: [*]u8, alignment: usize) usize {
        const aligned_ptr = alignUp(@intFromPtr(ptr), alignment);
        return aligned_ptr - @intFromPtr(ptr);
    }

    inline fn alignUp(val: usize, alignment: usize) usize {
        return alignDown(val + alignment - 1, alignment);
    }

    inline fn alignDown(val: usize, alignment: usize) usize {
        if (alignment == 0 or alignment & (alignment - 1) != 0) @compileError("alignment not a power of 2");
        return val & ~(alignment - 1);
    }
};

var global_arena = Arena{ .memory = @extern([*]u8, .{ .name = "__heap_base" }) };

export fn allocMemory(permanent_len: usize, transient_len: usize) callconv(.c) *api.Memory {
    const memory = global_arena.pushStruct(api.Memory);
    memory.* = .{
        .permanent_storage = global_arena.pushArray(u8, permanent_len).ptr,
        .permanent_storage_len = permanent_len,

        .transient_storage = global_arena.pushArray(u8, transient_len).ptr,
        .transient_storage_len = transient_len,

        // TODO: platform file/queue ops
        .file_ops = undefined,
        .work_queue = undefined,
    };
    return memory;
}

export fn allocScreen(width: u32, height: u32) callconv(.c) *api.Screen {
    const screen = global_arena.pushStruct(api.Screen);
    // TODO: align pitch properly
    screen.* = .{
        .height = height,
        .width = width,
        .pitch = width * 4,
        .memory = global_arena.pushArrayAligned(u8, height * width * 4, api.cache_line).ptr,
    };
    return screen;
}

export fn allocInput(expected_frame_time: f32) callconv(.c) *api.Input {
    const input = global_arena.pushStruct(api.Input);
    input.* = .{
        .exe_reloaded = false,
        .seconds_to_update = expected_frame_time,
    };
    return input;
}

export fn allocAudio(buf_samples: usize, sample_rate: u32) callconv(.c) *api.Audio {
    const audio = global_arena.pushStruct(api.Audio);
    audio.* = .{
        .buffer = global_arena.pushArray([2]i16, buf_samples).ptr,
        .sample_count = buf_samples,
        .samples_per_second = sample_rate,
    };
    return audio;
}

comptime {
    _ = game.updateAndRender;
    _ = game.outputSound;
}
