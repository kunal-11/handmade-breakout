const std = @import("std");
const builtin = @import("builtin");

pub const cache_line = 64;

/// 32 bits per pixel - R G B X
/// pitch should be cache aligned with padding if possible
pub const Screen = extern struct {
    memory: [*]align(cache_line) u8,
    width: u32,
    height: u32,
    pitch: usize,
};

/// 32 bits per sample, 2 channels - LL RR
pub const Audio = extern struct {
    buffer: [*][2]i16,
    sample_count: usize,

    samples_per_second: u32,
};

pub const Memory = extern struct {
    permanent_storage: [*]u8,
    permanent_storage_len: usize,

    transient_storage: [*]u8,
    transient_storage_len: usize,

    work_queue: WorkQueue,
    file_ops: FileOps,
};

pub const WorkQueue = extern struct {
    pub const Queue = anyopaque;
    pub const Callback = *const fn (data: ?*anyopaque) callconv(.c) void;

    high_priority_queue: *Queue,
    low_priority_queue: *Queue,
    add_entry: *const fn (*Queue, Callback, ?*anyopaque) callconv(.c) void,
    complete_all_work: *const fn (*Queue) callconv(.c) void,
};

pub const FileOps = extern struct {
    pub const FileType = enum(u8) {
        asset,
    };
    pub const Handle = anyopaque;
    pub const ReadFile = *const fn (handle: *Handle, offset: u64, size: usize, dest: *anyopaque) callconv(.c) bool;

    /// returns null on error
    open_file: *const fn (file_type: FileType) callconv(.c) ?*Handle,

    /// returns true on success
    read_file: ReadFile,
};

pub const Input = extern struct {
    pub const ButtonState = extern struct {
        half_transition_count: u32 = 0,
        ended_down: bool = false,

        pub fn pressed(self: *const ButtonState) bool {
            return self.half_transition_count > 1 or (self.half_transition_count == 1 and self.ended_down);
        }
    };

    pub const Controller = extern struct {
        move_up: ButtonState = .{},
        move_down: ButtonState = .{},
        move_left: ButtonState = .{},
        move_right: ButtonState = .{},

        action_up: ButtonState = .{},
        action_down: ButtonState = .{},
        action_left: ButtonState = .{},
        action_right: ButtonState = .{},

        left_shoulder: ButtonState = .{},
        right_shoulder: ButtonState = .{},
        back: ButtonState = .{},
        start: ButtonState = .{},
    };

    pub const Mouse = extern struct {
        left: ButtonState = .{},
        middle: ButtonState = .{},
        right: ButtonState = .{},
        ex0: ButtonState = .{},
        ex1: ButtonState = .{},

        x: f32 = 0,
        y: f32 = 0,
        z: f32 = 0,
    };

    /// first is assumed to be keyboard
    controllers: [1]Controller = .{.{}},
    mouse: Mouse = .{},

    exe_reloaded: bool,
    seconds_to_update: f32,
};

pub const UpdateAndRender = *const fn (*Screen, *Memory, *Input) callconv(.c) void;
pub const OutputSound = *const fn (*Audio, *Memory) callconv(.c) void;
